//! SpaceSaver's data folder: `%LOCALAPPDATA%\SpaceSaver` (override with `SPACESAVER_DATA_DIR`).

use crate::activity::ActivityLog;
use crate::model::ScanSummary;
use serde::Serialize;
use std::fs;
use std::io;
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicU64, Ordering};

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

/// Writes JSON to a temporary file with a name unique to this process and call, then renames
/// it over the target, so two writers never share a temporary file.
pub(crate) fn write_json_atomic<T: Serialize + ?Sized>(path: &Path, value: &T) -> io::Result<()> {
    static COUNTER: AtomicU64 = AtomicU64::new(0);
    if let Some(parent) = path.parent() {
        fs::create_dir_all(parent)?;
    }
    let data = serde_json::to_vec_pretty(value).map_err(|e| io::Error::new(io::ErrorKind::Other, e))?;
    let mut name = path.file_name().map(|n| n.to_os_string()).unwrap_or_default();
    name.push(format!(".tmp-{}-{}", std::process::id(), COUNTER.fetch_add(1, Ordering::Relaxed)));
    let tmp = path.with_file_name(name);
    if let Err(e) = fs::write(&tmp, data) {
        let _ = fs::remove_file(&tmp);
        return Err(e);
    }
    // A reader or a virus scanner can hold the target open for a moment; try a few times.
    let mut attempt = 0;
    loop {
        match fs::rename(&tmp, path) {
            Ok(()) => return Ok(()),
            Err(e) if attempt < 5 && e.kind() == io::ErrorKind::PermissionDenied => {
                attempt += 1;
                std::thread::sleep(std::time::Duration::from_millis(40 * attempt));
            }
            Err(e) => {
                let _ = fs::remove_file(&tmp);
                return Err(e);
            }
        }
    }
}
