//! Moving items to the Recycle Bin, logging what moved, and putting it back.

use crate::activity::{new_id, ActivityEntry, ActivityLog, ActivityStatus, TrashRecord};
use crate::format::format_bytes;
use crate::fsutil;
use crate::model::{CleanupItem, Method};
use crate::paths;
use crate::safety::{SafetyError, SafetyGuard};
use crate::system::RecycleBinInfo;
use serde::Serialize;
use std::path::{Path, PathBuf};

/// Where removed things go. The real one is the Windows Recycle Bin; tests use a fake.
pub trait Trasher {
    /// Moves `path` to the bin.
    fn trash(&self, path: &Path) -> Result<(), String>;
    /// Puts each path back where it was. One result per input, in order.
    fn restore(&self, originals: &[PathBuf]) -> Vec<Result<(), String>>;
}

/// The Windows Recycle Bin, through the `trash` crate.
#[derive(Debug, Clone, Copy, Default)]
pub struct SystemTrash;

impl Trasher for SystemTrash {
    fn trash(&self, path: &Path) -> Result<(), String> {
        trash::delete(path).map_err(|e| e.to_string())
    }

    #[cfg(windows)]
    fn restore(&self, originals: &[PathBuf]) -> Vec<Result<(), String>> {
        let items = match trash::os_limited::list() {
            Ok(items) => items,
            Err(e) => {
                return originals.iter().map(|_| Err(format!("Couldn't read the Recycle Bin: {e}"))).collect();
            }
        };
        originals
            .iter()
            .map(|original| {
                let want = paths::key_of(original);
                let newest = items
                    .iter()
                    .filter(|it| paths::key_of(&it.original_path()) == want)
                    .max_by_key(|it| it.time_deleted)
                    .cloned();
                match newest {
                    Some(item) => trash::os_limited::restore_all([item]).map_err(|e| e.to_string()),
                    None => Err("Not in the Recycle Bin any more (it may have been emptied)".to_string()),
                }
            })
            .collect()
    }

    #[cfg(not(windows))]
    fn restore(&self, originals: &[PathBuf]) -> Vec<Result<(), String>> {
        originals.iter().map(|_| Err("Restore is only supported on Windows".to_string())).collect()
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
    /// The activity entry written for this run (not for dry runs).
    pub entry: Option<ActivityEntry>,
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
    bin: Option<RecycleBinInfo>,
}

impl<'a> Cleaner<'a> {
    pub fn new(guard: &'a SafetyGuard, trash: &'a dyn Trasher, log: &'a ActivityLog) -> Self {
        Cleaner { guard, trash, log, bin: None }
    }

    /// Refuse items the Recycle Bin can't hold (Windows would delete them permanently).
    pub fn with_recycle_bin(mut self, bin: Option<RecycleBinInfo>) -> Self {
        self.bin = bin;
        self
    }

    /// Moves every selectable item to the Recycle Bin. Each path is validated by the safety
    /// guard first. Manual and command items are never run. Logs one activity entry.
    pub fn clean(&self, items: &[CleanupItem], opts: &CleanOptions, progress: &mut dyn FnMut(&CleanProgress)) -> CleanReport {
        let mut report = CleanReport { dry_run: opts.dry_run, ..Default::default() };
        let mut records: Vec<TrashRecord> = Vec::new();
        let total = items.len();

        for (index, item) in items.iter().enumerate() {
            progress(&CleanProgress { done: index, total, current: item.title.clone(), bytes: report.bytes });
            let skip = |reason: String| Skipped { id: item.id.clone(), title: item.title.clone(), reason };

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
            if let Some(bin) = &self.bin {
                if bin.disabled {
                    report.skipped.push(skip(format!(
                        "The Recycle Bin is turned off for {}, so Windows would delete it permanently",
                        bin.drive
                    )));
                    continue;
                }
                if let Some(max) = bin.max_bytes {
                    if item.size > max {
                        report.skipped.push(skip(format!(
                            "Too big for the Recycle Bin ({} limit), so Windows would delete it permanently",
                            format_bytes(max)
                        )));
                        continue;
                    }
                }
            }

            let mut moved_paths = Vec::new();
            let mut moved_bytes = 0u64;
            let mut failed = false;
            for raw in &item.paths {
                let path = match self.guard.validate(Path::new(raw)) {
                    Ok(p) => p,
                    Err(SafetyError::Missing(_)) => continue, // already gone
                    Err(e) => {
                        report.errors.push(format!("{}: {e}", item.title));
                        failed = true;
                        continue;
                    }
                };
                let bytes = if item.paths.len() == 1 { item.size } else { fsutil::measure(&path).bytes };
                let shown = path.to_string_lossy().to_string();
                if opts.dry_run {
                    moved_paths.push(shown);
                    moved_bytes += bytes;
                    continue;
                }
                match self.trash.trash(&path) {
                    Ok(()) => {
                        records.push(TrashRecord {
                            original: shown.clone(),
                            title: item.title.clone(),
                            category: item.category,
                            bytes,
                            restored: false,
                        });
                        moved_paths.push(shown);
                        moved_bytes += bytes;
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
            } else if !failed {
                report.skipped.push(skip("Already gone".to_string()));
            }
        }
        progress(&CleanProgress { done: total, total, current: String::new(), bytes: report.bytes });

        if !opts.dry_run && (!records.is_empty() || !report.errors.is_empty()) {
            let status = if records.is_empty() {
                ActivityStatus::Failed
            } else if report.errors.is_empty() {
                ActivityStatus::Completed
            } else {
                ActivityStatus::Partial
            };
            let title = opts.title.clone().unwrap_or_else(|| match report.items.as_slice() {
                [one] => one.title.clone(),
                many => format!("{} items", many.len()),
            });
            let entry = ActivityEntry {
                id: new_id(),
                date: fsutil::now(),
                title,
                source: opts.source.clone(),
                bytes: report.bytes,
                records,
                status,
                errors: report.errors.clone(),
            };
            if let Err(e) = self.log.append(entry.clone()) {
                report.errors.push(format!("Couldn't write the activity log: {e}"));
            }
            report.entry = Some(entry);
        }
        report
    }

    /// Puts everything from activity entry `id` (or a unique prefix) back where it was.
    pub fn restore(&self, id: &str) -> Result<RestoreReport, String> {
        let mut entry = self.log.find(id).ok_or_else(|| format!("No activity entry with id {id}"))?;
        let mut errors = Vec::new();
        let mut indexes = Vec::new();
        let mut originals = Vec::new();
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
            originals.push(original);
        }
        if indexes.is_empty() && errors.is_empty() {
            return Err("Everything from this cleanup has already been restored.".to_string());
        }
        let results = if originals.is_empty() { Vec::new() } else { self.trash.restore(&originals) };
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
