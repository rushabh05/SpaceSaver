//! A JSON log of every cleanup, with what was moved, so it can be restored.

use crate::model::Category;
use serde::{Deserialize, Serialize};
use std::fs;
use std::io;
use std::path::{Path, PathBuf};

const MAX_ENTRIES: usize = 500;

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum ActivityStatus {
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

    pub fn entries(&self) -> Vec<ActivityEntry> {
        let Ok(data) = fs::read(&self.path) else { return Vec::new() };
        serde_json::from_slice(&data).unwrap_or_default()
    }

    pub fn append(&self, entry: ActivityEntry) -> io::Result<()> {
        let mut all = self.entries();
        all.insert(0, entry);
        all.truncate(MAX_ENTRIES);
        crate::store::write_json_atomic(&self.path, &all)
    }

    pub fn update(&self, entry: &ActivityEntry) -> io::Result<()> {
        let mut all = self.entries();
        match all.iter_mut().find(|e| e.id == entry.id) {
            Some(slot) => *slot = entry.clone(),
            None => all.insert(0, entry.clone()),
        }
        crate::store::write_json_atomic(&self.path, &all)
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
