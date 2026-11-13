//! File-system helpers: reparse-point detection, a parallel directory sizer and a small glob.
//!
//! Nothing here follows symlinks, junctions or any other reparse point. pnpm and other tools
//! create junctions inside projects; following them would double-count sizes and could lead
//! a cleanup outside the folder it was aimed at.

use rayon::prelude::*;
use std::fs::{self, Metadata};
use std::path::{Path, PathBuf};
use std::time::{SystemTime, UNIX_EPOCH};

/// `FILE_ATTRIBUTE_REPARSE_POINT`.
pub const FILE_ATTRIBUTE_REPARSE_POINT: u32 = 0x400;

/// True for symlinks, junctions, mount points and every other reparse point (OneDrive
/// placeholders, deduplicated files, app execution aliases).
pub fn is_reparse(meta: &Metadata) -> bool {
    #[cfg(windows)]
    {
        use std::os::windows::fs::MetadataExt;
        meta.file_attributes() & FILE_ATTRIBUTE_REPARSE_POINT != 0
    }
    #[cfg(not(windows))]
    {
        meta.file_type().is_symlink()
    }
}

/// Metadata without following links.
pub fn lstat(path: &Path) -> Option<Metadata> {
    fs::symlink_metadata(path).ok()
}

/// Exists and is not a reparse point.
pub fn exists_real(path: &Path) -> bool {
    lstat(path).map(|m| !is_reparse(&m)).unwrap_or(false)
}

/// A real directory (not a junction or symlink to one).
pub fn is_real_dir(path: &Path) -> bool {
    lstat(path).map(|m| m.is_dir() && !is_reparse(&m)).unwrap_or(false)
}

/// Last-write time in Unix seconds (0 if unknown).
pub fn mtime(meta: &Metadata) -> i64 {
    meta.modified()
        .ok()
        .and_then(|t| t.duration_since(UNIX_EPOCH).ok())
        .map(|d| d.as_secs() as i64)
        .unwrap_or(0)
}

/// Current time in Unix seconds.
pub fn now() -> i64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_secs() as i64)
        .unwrap_or(0)
}

/// Size of a file or folder tree.
#[derive(Debug, Clone, Copy, Default, PartialEq, Eq)]
pub struct Stats {
    /// Logical bytes of all regular files.
    pub bytes: u64,
    pub files: u64,
    /// Newest file modification time (Unix seconds).
    pub newest: i64,
}

impl Stats {
    pub fn merge(self, other: Stats) -> Stats {
        Stats {
            bytes: self.bytes + other.bytes,
            files: self.files + other.files,
            newest: self.newest.max(other.newest),
        }
    }
}

/// Total logical size of a file or folder tree, walked in parallel. Reparse points are skipped
/// entirely: never followed and never counted.
pub fn measure(path: &Path) -> Stats {
    let Some(meta) = lstat(path) else { return Stats::default() };
    if is_reparse(&meta) {
        return Stats::default();
    }
    if !meta.is_dir() {
        return Stats { bytes: meta.len(), files: 1, newest: mtime(&meta) };
    }
    measure_dir(path)
}

fn measure_dir(dir: &Path) -> Stats {
    let Ok(read) = fs::read_dir(dir) else { return Stats::default() };
    let mut stats = Stats::default();
    let mut subdirs = Vec::new();
    for entry in read.flatten() {
        // On Windows DirEntry::metadata comes from the directory listing and doesn't follow links.
        let Ok(meta) = entry.metadata() else { continue };
        if is_reparse(&meta) {
            continue;
        }
        if meta.is_dir() {
            subdirs.push(entry.path());
        } else {
            stats.bytes += meta.len();
            stats.files += 1;
            stats.newest = stats.newest.max(mtime(&meta));
        }
    }
    if subdirs.is_empty() {
        return stats;
    }
    let nested = subdirs
        .par_iter()
        .map(|d| measure_dir(d))
        .reduce(Stats::default, Stats::merge);
    stats.merge(nested)
}

/// Case-insensitive wildcard match supporting `*` and `?`.
pub fn wildcard_match(pattern: &str, name: &str) -> bool {
    let p: Vec<char> = pattern.to_lowercase().chars().collect();
    let n: Vec<char> = name.to_lowercase().chars().collect();
    let (mut pi, mut ni) = (0usize, 0usize);
    let mut star: Option<usize> = None;
    let mut mark = 0usize;
    while ni < n.len() {
        if pi < p.len() && (p[pi] == '?' || p[pi] == n[ni]) {
            pi += 1;
            ni += 1;
        } else if pi < p.len() && p[pi] == '*' {
            star = Some(pi);
            mark = ni;
            pi += 1;
        } else if let Some(s) = star {
            pi = s + 1;
            mark += 1;
            ni = mark;
        } else {
            return false;
        }
    }
    while pi < p.len() && p[pi] == '*' {
        pi += 1;
    }
    pi == p.len()
}

/// Expands a path whose components may contain `*` or `?`. Only existing paths are returned;
/// reparse points are never matched or walked through.
pub fn expand(pattern: &Path) -> Vec<PathBuf> {
    let norm = crate::paths::normalize(&pattern.to_string_lossy());
    let comps: Vec<&str> = norm.split('\\').filter(|c| !c.is_empty()).collect();
    let Some(first_wild) = comps.iter().position(|c| c.contains('*') || c.contains('?')) else {
        let p = PathBuf::from(&norm);
        return if exists_real(&p) { vec![p] } else { Vec::new() };
    };

    let mut base = comps[..first_wild].join("\\");
    if base.ends_with(':') {
        base.push('\\');
    } else if norm.starts_with(r"\\") {
        base = format!(r"\\{base}");
    }
    let base = PathBuf::from(base);
    if !is_real_dir(&base) {
        return Vec::new();
    }

    let mut current = vec![base];
    for comp in &comps[first_wild..] {
        let mut next = Vec::new();
        for dir in &current {
            if comp.contains('*') || comp.contains('?') {
                let Ok(read) = fs::read_dir(dir) else { continue };
                for entry in read.flatten() {
                    let name = entry.file_name().to_string_lossy().to_string();
                    if !wildcard_match(comp, &name) {
                        continue;
                    }
                    let Ok(meta) = entry.metadata() else { continue };
                    if !is_reparse(&meta) {
                        next.push(entry.path());
                    }
                }
            } else {
                let p = dir.join(comp);
                if exists_real(&p) {
                    next.push(p);
                }
            }
        }
        current = next;
    }
    current.sort();
    current
}

#[cfg(test)]
mod tests {
    use super::wildcard_match;

    #[test]
    fn wildcards() {
        assert!(wildcard_match("*.csproj", "App.CSPROJ"));
        assert!(wildcard_match("next.config.*", "next.config.mjs"));
        assert!(wildcard_match("models--*", "models--org--name"));
        assert!(!wildcard_match("*.csproj", "app.fsproj"));
        assert!(wildcard_match("AndroidStudio*", "AndroidStudio2024.1"));
        assert!(!wildcard_match("a?c", "abbc"));
    }
}
