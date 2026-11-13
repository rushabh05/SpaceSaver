//! Moving items to the Recycle Bin, logging what moved, and putting it back.

use crate::activity::{new_id, ActivityEntry, ActivityLog, ActivityStatus, TrashRecord};
use crate::format::format_bytes;
use crate::fsutil;
use crate::model::{CleanupItem, Method};
use crate::paths;
use crate::safety::{SafetyError, SafetyGuard};
use crate::system::RecycleBinInfo;
use serde::Serialize;
use std::collections::HashMap;
use std::path::{Path, PathBuf};

/// Seconds of slack when matching a Recycle Bin item's deletion time to the time SpaceSaver
/// recorded around the move.
const RESTORE_SLACK_SECS: i64 = 2;

/// One path to put back, with the window in which SpaceSaver moved it to the bin.
#[derive(Debug, Clone)]
pub struct RestoreRequest {
    pub original: PathBuf,
    /// Unix seconds just before the move (0 for records written by older versions).
    pub deleted_at: i64,
    /// Unix seconds just after the move returned (0 when unknown).
    pub deleted_until: i64,
}

/// Where removed things go. The real one is the Windows Recycle Bin; tests use a fake.
pub trait Trasher {
    /// Moves `path` to the bin.
    fn trash(&self, path: &Path) -> Result<(), String>;
    /// Puts each path back where it was. One result per input, in order.
    fn restore(&self, requests: &[RestoreRequest]) -> Vec<Result<(), String>>;
}

/// The Windows Recycle Bin, through the `trash` crate.
#[derive(Debug, Clone, Copy, Default)]
pub struct SystemTrash;

/// Picks the bin item SpaceSaver moved: among items with the same original path, the earliest
/// deleted at or after the recorded time (within the recorded window when there is one). Records
/// from before deletion times were kept fall back to the newest item.
pub fn pick_bin_item(candidates: &[(usize, i64)], req: &RestoreRequest) -> Option<usize> {
    if req.deleted_at <= 0 {
        return candidates.iter().max_by_key(|(_, t)| *t).map(|(i, _)| *i);
    }
    candidates
        .iter()
        .filter(|(_, t)| *t >= req.deleted_at - RESTORE_SLACK_SECS)
        .filter(|(_, t)| req.deleted_until <= 0 || *t <= req.deleted_until + RESTORE_SLACK_SECS)
        .min_by_key(|(_, t)| *t)
        .map(|(i, _)| *i)
}

impl Trasher for SystemTrash {
    fn trash(&self, path: &Path) -> Result<(), String> {
        trash::delete(path).map_err(|e| e.to_string())
    }

    #[cfg(windows)]
    fn restore(&self, requests: &[RestoreRequest]) -> Vec<Result<(), String>> {
        let items = match trash::os_limited::list() {
            Ok(items) => items,
            Err(e) => {
                return requests.iter().map(|_| Err(format!("Couldn't read the Recycle Bin: {e}"))).collect();
            }
        };
        requests
            .iter()
            .map(|req| {
                let want = paths::key_of(&req.original);
                let candidates: Vec<(usize, i64)> = items
                    .iter()
                    .enumerate()
                    .filter(|(_, it)| paths::key_of(&it.original_path()) == want)
                    .map(|(i, it)| (i, it.time_deleted))
                    .collect();
                match pick_bin_item(&candidates, req) {
                    Some(i) => trash::os_limited::restore_all([items[i].clone()]).map_err(|e| e.to_string()),
                    None if candidates.is_empty() => {
                        Err("Not in the Recycle Bin any more (it may have been emptied)".to_string())
                    }
                    None => Err(
                        "The Recycle Bin has other items from this path, but not the one SpaceSaver moved (it may have been emptied)"
                            .to_string(),
                    ),
                }
            })
            .collect()
    }

    #[cfg(not(windows))]
    fn restore(&self, requests: &[RestoreRequest]) -> Vec<Result<(), String>> {
        requests.iter().map(|_| Err("Restore is only supported on Windows".to_string())).collect()
    }
}

/// Recycle Bin settings, per volume. The cleaner asks once per volume and run.
pub trait RecycleBinSettings {
    /// The root of the volume that really holds `path` (`C:\`, or the folder a volume is
    /// mounted at), or `None` when that can't be told. The cleaner then refuses the path.
    fn bin_of(&self, path: &Path) -> Option<String> {
        crate::system::volume_root_of(path)
    }

    /// The Recycle Bin settings of the volume at `root`. An error means they couldn't be read,
    /// and the cleaner then refuses everything on that volume.
    fn settings(&self, root: &str) -> Result<RecycleBinInfo, String>;
}

/// The real settings, from the registry.
#[derive(Debug, Clone, Copy, Default)]
pub struct SystemRecycleBin;

impl RecycleBinSettings for SystemRecycleBin {
    fn settings(&self, root: &str) -> Result<RecycleBinInfo, String> {
        crate::system::recycle_bin_info(root)
    }
}

#[derive(Debug, Clone)]
pub struct CleanOptions {
    /// Report what would happen without moving anything.
    pub dry_run: bool,
    /// "cli" or "app", recorded in the activity log.
    pub source: String,
    /// Title for the activity entry (defaults to the item's title or "N items").
    pub title: Option<String>,
}

impl CleanOptions {
    pub fn dry_run(source: &str) -> Self {
        CleanOptions { dry_run: true, source: source.to_string(), title: None }
    }

    pub fn run(source: &str) -> Self {
        CleanOptions { dry_run: false, source: source.to_string(), title: None }
    }
}

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct CleanProgress {
    pub done: usize,
    pub total: usize,
    pub current: String,
    pub bytes: u64,
}

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Skipped {
    pub id: String,
    pub title: String,
    pub reason: String,
}

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct PlannedItem {
    pub id: String,
    pub title: String,
    pub size: u64,
    pub paths: Vec<String>,
}

#[derive(Debug, Clone, Default, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct CleanReport {
    pub dry_run: bool,
    /// Items moved (or, in a dry run, that would be moved).
    pub items: Vec<PlannedItem>,
    /// Ids of items whose every path moved.
    pub moved_ids: Vec<String>,
    pub bytes: u64,
    pub skipped: Vec<Skipped>,
    pub errors: Vec<String>,
    /// The activity entry written for this run (not for dry runs). `None` when the activity
    /// log couldn't be written, so there is nothing to restore by id.
    pub entry: Option<ActivityEntry>,
    /// Set when the activity log couldn't be written. The run stops at that point; anything
    /// listed in `items` did move and can only be restored from the Recycle Bin by hand.
    pub log_error: Option<String>,
}

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct RestoreReport {
    pub entry: ActivityEntry,
    pub restored: usize,
    pub errors: Vec<String>,
}

pub struct Cleaner<'a> {
    guard: &'a SafetyGuard,
    trash: &'a dyn Trasher,
    log: &'a ActivityLog,
    bins: Option<&'a dyn RecycleBinSettings>,
}

impl<'a> Cleaner<'a> {
    /// A cleaner without Recycle Bin checks (tests). The CLI and the app always add them with
    /// [`Cleaner::with_recycle_bin`].
    pub fn new(guard: &'a SafetyGuard, trash: &'a dyn Trasher, log: &'a ActivityLog) -> Self {
        Cleaner { guard, trash, log, bins: None }
    }

    /// Refuse items the Recycle Bin can't hold (Windows would delete them permanently): on a
    /// drive whose bin is off or whose settings can't be read, bigger than the bin, or that
    /// would take this run's total on that drive past the bin's limit.
    pub fn with_recycle_bin(mut self, bins: &'a dyn RecycleBinSettings) -> Self {
        self.bins = Some(bins);
        self
    }

    /// Moves every selectable item to the Recycle Bin. Each path is validated by the safety
    /// guard first. Manual and command items are never run.
    ///
    /// The run's activity entry is written before the first move and updated after every
    /// moved path, so an interrupted run still leaves a record that can be restored. If the
    /// log can't be written, nothing more is moved and `log_error` is set.
    pub fn clean(&self, items: &[CleanupItem], opts: &CleanOptions, progress: &mut dyn FnMut(&CleanProgress)) -> CleanReport {
        let mut report = CleanReport { dry_run: opts.dry_run, ..Default::default() };
        let total = items.len();
        let mut bin_cache: HashMap<String, Result<RecycleBinInfo, String>> = HashMap::new();
        let mut bin_used: HashMap<String, u64> = HashMap::new();
        let mut entry: Option<ActivityEntry> = None;
        let mut log_error: Option<String> = None;
        let first_title = opts.title.clone().unwrap_or_else(|| match items {
            [one] => one.title.clone(),
            many => format!("{} items", many.len()),
        });

        for (index, item) in items.iter().enumerate() {
            progress(&CleanProgress { done: index, total, current: item.title.clone(), bytes: report.bytes });
            let skip = |reason: String| Skipped { id: item.id.clone(), title: item.title.clone(), reason };

            if log_error.is_some() {
                report.skipped.push(skip("Not attempted: the activity log couldn't be written".to_string()));
                continue;
            }
            if let Some(reason) = &item.blocked_reason {
                report.skipped.push(skip(reason.clone()));
                continue;
            }
            match &item.method {
                Method::RecycleBin => {}
                Method::Manual { .. } => {
                    report.skipped.push(skip("Manual steps: SpaceSaver never does this for you".to_string()));
                    continue;
                }
                Method::Command { .. } => {
                    report.skipped.push(skip("A command to run yourself: SpaceSaver never runs it".to_string()));
                    continue;
                }
            }

            // Validate every path and work out what each weighs before anything moves.
            let mut planned: Vec<(PathBuf, u64)> = Vec::new();
            let mut failed = false;
            for raw in &item.paths {
                match self.guard.validate(Path::new(raw)) {
                    Ok(path) => {
                        let bytes = if item.paths.len() == 1 { item.size } else { fsutil::measure(&path).bytes };
                        planned.push((path, bytes));
                    }
                    Err(SafetyError::Missing(_)) => {} // already gone
                    Err(e) => {
                        report.errors.push(format!("{}: {e}", item.title));
                        failed = true;
                    }
                }
            }
            if planned.is_empty() {
                if !failed {
                    report.skipped.push(skip("Already gone".to_string()));
                }
                continue;
            }
            if let Some(bins) = self.bins {
                if let Err(reason) = reserve_bin_space(bins, &planned, &mut bin_cache, &mut bin_used) {
                    report.skipped.push(skip(reason));
                    continue;
                }
            }

            let mut moved_paths = Vec::new();
            let mut moved_bytes = 0u64;
            for (path, bytes) in planned {
                let shown = path.to_string_lossy().to_string();
                if opts.dry_run {
                    moved_paths.push(shown);
                    moved_bytes += bytes;
                    continue;
                }
                if entry.is_none() {
                    let fresh = ActivityEntry {
                        id: new_id(),
                        date: fsutil::now(),
                        title: first_title.clone(),
                        source: opts.source.clone(),
                        bytes: 0,
                        records: Vec::new(),
                        status: ActivityStatus::Incomplete,
                        errors: Vec::new(),
                    };
                    if let Err(e) = self.log.append(fresh.clone()) {
                        log_error = Some(format!("Couldn't write the activity log, so nothing was moved: {e}"));
                        failed = true;
                        break;
                    }
                    entry = Some(fresh);
                }
                let deleted_at = fsutil::now();
                match self.trash.trash(&path) {
                    Ok(()) => {
                        let deleted_until = fsutil::now();
                        let current = entry.as_mut().expect("entry written before the first move");
                        current.records.push(TrashRecord {
                            original: shown.clone(),
                            title: item.title.clone(),
                            category: item.category,
                            bytes,
                            restored: false,
                            deleted_at,
                            deleted_until,
                        });
                        current.bytes += bytes;
                        moved_paths.push(shown.clone());
                        moved_bytes += bytes;
                        if let Err(e) = self.log.update(current) {
                            log_error = Some(format!(
                                "Couldn't update the activity log after moving {shown}, so SpaceSaver stopped there: {e}"
                            ));
                            failed = true;
                            break;
                        }
                    }
                    Err(e) => {
                        report.errors.push(format!("{} ({shown}): {e}", item.title));
                        failed = true;
                    }
                }
            }
            if !moved_paths.is_empty() {
                if !failed {
                    report.moved_ids.push(item.id.clone());
                }
                report.bytes += moved_bytes;
                report.items.push(PlannedItem {
                    id: item.id.clone(),
                    title: item.title.clone(),
                    size: moved_bytes,
                    paths: moved_paths,
                });
            }
        }
        progress(&CleanProgress { done: total, total, current: String::new(), bytes: report.bytes });

        if !opts.dry_run {
            let title = opts.title.clone().unwrap_or_else(|| match report.items.as_slice() {
                [one] => one.title.clone(),
                many => format!("{} items", many.len()),
            });
            match entry.take() {
                Some(mut done) => {
                    done.status = if done.records.is_empty() {
                        ActivityStatus::Failed
                    } else if report.errors.is_empty() && log_error.is_none() {
                        ActivityStatus::Completed
                    } else {
                        ActivityStatus::Partial
                    };
                    done.title = title;
                    done.errors = report.errors.clone();
                    if log_error.is_none() {
                        match self.log.update(&done) {
                            Ok(()) => report.entry = Some(done),
                            Err(e) => log_error = Some(format!("Couldn't update the activity log: {e}")),
                        }
                    }
                }
                None if !report.errors.is_empty() && log_error.is_none() => {
                    // Nothing moved, but record the failure.
                    let failed = ActivityEntry {
                        id: new_id(),
                        date: fsutil::now(),
                        title,
                        source: opts.source.clone(),
                        bytes: 0,
                        records: Vec::new(),
                        status: ActivityStatus::Failed,
                        errors: report.errors.clone(),
                    };
                    match self.log.append(failed.clone()) {
                        Ok(()) => report.entry = Some(failed),
                        Err(e) => log_error = Some(format!("Couldn't write the activity log: {e}")),
                    }
                }
                None => {}
            }
        }
        if let Some(e) = log_error {
            report.errors.push(e.clone());
            report.log_error = Some(e);
        }
        report
    }

    /// Puts everything from activity entry `id` (or a unique prefix) back where it was.
    pub fn restore(&self, id: &str) -> Result<RestoreReport, String> {
        let mut entry = self.log.find(id).ok_or_else(|| format!("No activity entry with id {id}"))?;
        let mut errors = Vec::new();
        let mut indexes = Vec::new();
        let mut requests = Vec::new();
        for (i, record) in entry.records.iter().enumerate() {
            if record.restored {
                continue;
            }
            let original = PathBuf::from(&record.original);
            if fsutil::lstat(&original).is_some() {
                errors.push(format!("Something already exists at {}", record.original));
                continue;
            }
            indexes.push(i);
            requests.push(RestoreRequest {
                original,
                deleted_at: record.deleted_at,
                deleted_until: record.deleted_until,
            });
        }
        if indexes.is_empty() && errors.is_empty() {
            return Err("Everything from this cleanup has already been restored.".to_string());
        }
        let results = if requests.is_empty() { Vec::new() } else { self.trash.restore(&requests) };
        let mut restored = 0;
        for (i, result) in indexes.into_iter().zip(results) {
            match result {
                Ok(()) => {
                    entry.records[i].restored = true;
                    restored += 1;
                }
                Err(e) => errors.push(format!("{}: {e}", entry.records[i].original)),
            }
        }
        if entry.records.iter().all(|r| r.restored) {
            entry.status = ActivityStatus::Restored;
        } else if entry.records.iter().any(|r| r.restored) {
            entry.status = ActivityStatus::PartiallyRestored;
        }
        self.log.update(&entry).map_err(|e| format!("Couldn't write the activity log: {e}"))?;
        Ok(RestoreReport { entry, restored, errors })
    }
}

/// Checks that `planned` fits in the Recycle Bin of each volume it is on, counting what this
/// run has already moved there, and reserves the space. Fails closed: an unknown volume,
/// unreadable settings, a volume without a Recycle Bin or a disabled bin all refuse the item.
fn reserve_bin_space(
    bins: &dyn RecycleBinSettings,
    planned: &[(PathBuf, u64)],
    cache: &mut HashMap<String, Result<RecycleBinInfo, String>>,
    used: &mut HashMap<String, u64>,
) -> Result<(), String> {
    let mut need: Vec<(RecycleBinInfo, u64)> = Vec::new();
    for (path, bytes) in planned {
        let root = bins.bin_of(path).ok_or_else(|| {
            format!("Couldn't tell which drive {} is on, so SpaceSaver won't risk a permanent delete", path.display())
        })?;
        let info = cache.entry(root.clone()).or_insert_with(|| bins.settings(&root)).clone().map_err(|e| {
            format!("Couldn't read the Recycle Bin settings for {root} ({e}), so SpaceSaver won't risk a permanent delete")
        })?;
        if let Some(kind) = &info.no_bin {
            return Err(format!(
                "{} is on {kind} ({}), which has no Recycle Bin, so Windows would delete it permanently",
                path.display(),
                info.drive
            ));
        }
        if info.disabled {
            return Err(format!("The Recycle Bin is turned off for {}, so Windows would delete it permanently", info.drive));
        }
        match need.iter_mut().find(|(known, _)| known.volume == info.volume) {
            Some((_, total)) => *total += bytes,
            None => need.push((info, *bytes)),
        }
    }
    for (info, bytes) in &need {
        let already = used.get(&info.volume).copied().unwrap_or(0);
        if already.saturating_add(*bytes) > info.max_bytes {
            return Err(if already == 0 {
                format!(
                    "Too big for the Recycle Bin ({} limit on {}), so Windows would delete it permanently",
                    format_bytes(info.max_bytes),
                    info.drive
                )
            } else {
                format!(
                    "The Recycle Bin on {} holds {} and this cleanup already moved {} there; adding this would make Windows delete items for good",
                    info.drive,
                    format_bytes(info.max_bytes),
                    format_bytes(already)
                )
            });
        }
    }
    for (info, bytes) in need {
        *used.entry(info.volume).or_insert(0) += bytes;
    }
    Ok(())
}
