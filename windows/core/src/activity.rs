//! A JSON log of every cleanup, with what was moved, so it can be restored.

use crate::model::Category;
use serde::{Deserialize, Serialize};
use std::fs::{self, File, OpenOptions};
use std::io;
use std::path::{Path, PathBuf};

const MAX_ENTRIES: usize = 500;

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum ActivityStatus {
    /// Written before the first move and updated after each one. An entry still in this state
    /// once the run is over means the run was interrupted; what it lists did move.
    Incomplete,
    Completed,
    Partial,
    Failed,
    Restored,
    PartiallyRestored,
}

/// One path moved to the Recycle Bin.
#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct TrashRecord {
    /// Where it was (and where Restore puts it back).
    pub original: String,
    /// The item it belonged to.
    pub title: String,
    pub category: Category,
    pub bytes: u64,
    #[serde(default)]
    pub restored: bool,
    /// Unix seconds just before the move, so Restore can tell this item from others moved
    /// from the same path (0 in records from older versions).
    #[serde(default)]
    pub deleted_at: i64,
    /// Unix seconds just after the move returned (0 in records from older versions).
    #[serde(default)]
    pub deleted_until: i64,
}

/// One cleanup run.
#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ActivityEntry {
    /// Short id for `spacesaver restore <id>`.
    pub id: String,
    /// Unix seconds.
    pub date: i64,
    pub title: String,
    /// "cli" or "app".
    pub source: String,
    pub bytes: u64,
    pub records: Vec<TrashRecord>,
    pub status: ActivityStatus,
    #[serde(default)]
    pub errors: Vec<String>,
}

impl ActivityEntry {
    /// Something from this run is still in the Recycle Bin.
    pub fn can_restore(&self) -> bool {
        self.records.iter().any(|r| !r.restored)
    }
}

/// Newest entries first, stored in `activity.json`.
///
/// Every change is a read-modify-write under an exclusive lock on `activity.json.lock`, so the
/// CLI and the app can't overwrite each other's entries. A log that exists but can't be read or
/// parsed is never overwritten: it is renamed to `activity.json.corrupt-<unix seconds>` first.
#[derive(Debug, Clone)]
pub struct ActivityLog {
    path: PathBuf,
}

impl ActivityLog {
    pub fn new(path: impl Into<PathBuf>) -> Self {
        ActivityLog { path: path.into() }
    }

    pub fn path(&self) -> &Path {
        &self.path
    }

    /// The entries, for display. An unreadable log reads as empty here; writes preserve it.
    pub fn entries(&self) -> Vec<ActivityEntry> {
        let Ok(data) = fs::read(&self.path) else { return Vec::new() };
        serde_json::from_slice(&data).unwrap_or_default()
    }

    pub fn append(&self, entry: ActivityEntry) -> io::Result<()> {
        self.modify(|all| {
            all.insert(0, entry);
            all.truncate(MAX_ENTRIES);
        })
    }

    pub fn update(&self, entry: &ActivityEntry) -> io::Result<()> {
        self.modify(|all| match all.iter_mut().find(|e| e.id == entry.id) {
            Some(slot) => *slot = entry.clone(),
            None => all.insert(0, entry.clone()),
        })
    }

    /// Finds an entry by id or by a unique id prefix.
    pub fn find(&self, id: &str) -> Option<ActivityEntry> {
        let id = id.trim().to_lowercase();
        if id.is_empty() {
            return None;
        }
        let all = self.entries();
        if let Some(exact) = all.iter().find(|e| e.id == id) {
            return Some(exact.clone());
        }
        let mut matches = all.into_iter().filter(|e| e.id.starts_with(&id));
        let first = matches.next()?;
        if matches.next().is_some() {
            return None;
        }
        Some(first)
    }

    fn modify(&self, change: impl FnOnce(&mut Vec<ActivityEntry>)) -> io::Result<()> {
        let _lock = self.lock()?;
        let mut all = self.load_for_write()?;
        change(&mut all);
        crate::store::write_json_atomic(&self.path, &all)
    }

    /// Exclusive lock held for one read-modify-write; released when the file is dropped.
    fn lock(&self) -> io::Result<File> {
        if let Some(parent) = self.path.parent() {
            fs::create_dir_all(parent)?;
        }
        let mut name = self.path.file_name().map(|n| n.to_os_string()).unwrap_or_default();
        name.push(".lock");
        let file = OpenOptions::new().create(true).truncate(false).read(true).write(true).open(self.path.with_file_name(name))?;
        file.lock()?;
        Ok(file)
    }

    /// The current entries. A log that exists but can't be read or parsed is moved aside first,
    /// and if that fails the write is refused.
    fn load_for_write(&self) -> io::Result<Vec<ActivityEntry>> {
        let problem = match fs::read(&self.path) {
            Ok(data) => match serde_json::from_slice::<Vec<ActivityEntry>>(&data) {
                Ok(all) => return Ok(all),
                Err(e) => format!("it isn't valid: {e}"),
            },
            Err(e) if e.kind() == io::ErrorKind::NotFound => return Ok(Vec::new()),
            Err(e) => format!("it can't be read: {e}"),
        };
        let aside = self.corrupt_path();
        fs::rename(&self.path, &aside).map_err(|e| {
            io::Error::new(
                e.kind(),
                format!("{} exists but {problem}, and it couldn't be moved aside ({e}), so it was left alone", self.path.display()),
            )
        })?;
        Ok(Vec::new())
    }

    /// `activity.json.corrupt-<unix seconds>`, with `-2`, `-3`... if that name is taken.
    fn corrupt_path(&self) -> PathBuf {
        let base = self.path.file_name().map(|n| n.to_string_lossy().to_string()).unwrap_or_default();
        let stem = format!("{base}.corrupt-{}", crate::fsutil::now());
        let mut candidate = self.path.with_file_name(&stem);
        let mut n = 2;
        while candidate.exists() {
            candidate = self.path.with_file_name(format!("{stem}-{n}"));
            n += 1;
        }
        candidate
    }
}

/// A short random id (8 hex digits) without pulling in a UUID crate.
pub fn new_id() -> String {
    use std::collections::hash_map::RandomState;
    use std::hash::{BuildHasher, Hasher};
    let mut h = RandomState::new().build_hasher();
    let nanos = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_nanos())
        .unwrap_or(0);
    h.write_u128(nanos);
    h.write_u32(std::process::id());
    format!("{:08x}", h.finish() as u32)
}
