//! SpaceSaver's data folder: `%LOCALAPPDATA%\SpaceSaver` (override with `SPACESAVER_DATA_DIR`).

use crate::activity::ActivityLog;
use crate::model::ScanSummary;
use serde::Serialize;
use std::fs;
use std::io;
use std::path::{Path, PathBuf};

pub fn default_data_dir() -> PathBuf {
    if let Some(dir) = std::env::var_os("SPACESAVER_DATA_DIR").filter(|v| !v.is_empty()) {
        return PathBuf::from(dir);
    }
    let local = std::env::var_os("LOCALAPPDATA")
        .filter(|v| !v.is_empty())
        .map(PathBuf::from)
        .unwrap_or_else(std::env::temp_dir);
    local.join("SpaceSaver")
}

#[derive(Debug, Clone)]
pub struct Store {
    dir: PathBuf,
}

impl Store {
    pub fn new(dir: impl Into<PathBuf>) -> Self {
        Store { dir: dir.into() }
    }

    pub fn open_default() -> Self {
        Store::new(default_data_dir())
    }

    pub fn dir(&self) -> &Path {
        &self.dir
    }

    pub fn activity(&self) -> ActivityLog {
        ActivityLog::new(self.dir.join("activity.json"))
    }

    pub fn save_scan(&self, summary: &ScanSummary) -> io::Result<()> {
        write_json_atomic(&self.dir.join("last-scan.json"), summary)
    }

    pub fn load_scan(&self) -> Option<ScanSummary> {
        let data = fs::read(self.dir.join("last-scan.json")).ok()?;
        serde_json::from_slice(&data).ok()
    }
}

/// Writes JSON to a temporary file, then renames it over the target.
pub(crate) fn write_json_atomic<T: Serialize + ?Sized>(path: &Path, value: &T) -> io::Result<()> {
    if let Some(parent) = path.parent() {
        fs::create_dir_all(parent)?;
    }
    let data = serde_json::to_vec_pretty(value).map_err(|e| io::Error::new(io::ErrorKind::Other, e))?;
    let tmp = path.with_extension("json.tmp");
    fs::write(&tmp, data)?;
    fs::rename(&tmp, path)
}
