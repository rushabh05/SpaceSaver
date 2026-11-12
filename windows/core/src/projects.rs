//! Finds regenerable build and dependency folders in code projects and decides, per project,
//! whether it's dormant enough to clean (no git activity or root-file edits in 45 days).

use crate::env::ScanEnv;
use crate::format::age_label;
use crate::fsutil::{self, is_reparse, lstat, measure, mtime};
use crate::model::{Category, CleanupItem, Risk};
use crate::paths;
use crate::rules::{artifact_rules_named, ArtifactRule};
use rayon::prelude::*;
use std::collections::{HashMap, HashSet};
use std::fs::{self, File};
use std::io::{Read, Seek, SeekFrom};
use std::path::{Path, PathBuf};

const MAX_DEPTH: usize = 12;

#[derive(Debug, Clone)]
struct Found {
    artifact: PathBuf,
    project_root: PathBuf,
    rule: &'static ArtifactRule,
    lockfile: Option<&'static str>,
    root_modified: i64,
    orphan: bool,
}

/// When a project was last worked on.
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct ProjectActivity {
    /// Unix seconds of the newest commit/checkout, git index write or root-file edit.
    pub last_activity: Option<i64>,
    pub git: bool,
}

struct WalkContext {
    skip: HashSet<String>,
}

/// Folders under the user profile that are never searched for projects: app data, media
/// libraries and tool caches covered by other rules.
fn skipped_dirs(env: &ScanEnv) -> HashSet<String> {
    let h = &env.home;
    let mut skip: HashSet<String> = [
        "AppData",
        "Application Data",
        "Local Settings",
        "Pictures",
        "Music",
        "Videos",
        "Favorites",
        "Contacts",
        "Searches",
        "Links",
        "Saved Games",
        "3D Objects",
        "MicrosoftEdgeBackups",
        "scoop",
        r"go\pkg",
        "miniconda3",
        "anaconda3",
        "miniforge3",
    ]
    .iter()
    .map(|s| paths::key_of(&h.join(s)))
    .collect();
    for p in [&env.local, &env.roaming, &env.temp, &env.cargo_home, &env.gradle_home, &env.go_mod, &env.android_sdk] {
        skip.insert(paths::key_of(p));
    }
    if let Some(d) = &env.data_dir {
        skip.insert(paths::key_of(d));
    }
    skip
}

/// Scans `env.project_roots` and returns one item per artifact folder of at least
/// `env.min_bytes`.
pub fn analyze(env: &ScanEnv) -> Vec<CleanupItem> {
    let ctx = WalkContext { skip: skipped_dirs(env) };
    let roots: Vec<&PathBuf> = env.project_roots.iter().filter(|r| fsutil::is_real_dir(r)).collect();
    let found: Vec<Found> = roots.par_iter().flat_map_iter(|r| walk(r, 0, &ctx)).collect();
    if found.is_empty() {
        return Vec::new();
    }

    let sizes: Vec<fsutil::Stats> = found.par_iter().map(|f| measure(&f.artifact)).collect();

    let mut unique_roots: Vec<(PathBuf, i64)> = Vec::new();
    let mut seen = HashSet::new();
    for f in &found {
        if seen.insert(paths::key_of(&f.project_root)) {
            unique_roots.push((f.project_root.clone(), f.root_modified));
        }
    }
    let activity: HashMap<String, ProjectActivity> = unique_roots
        .par_iter()
        .map(|(root, modified)| (paths::key_of(root), project_activity(root, *modified, &env.home)))
        .collect();

    found
        .iter()
        .zip(sizes)
        .filter(|(_, size)| size.bytes >= env.min_bytes)
        .map(|(f, size)| {
            let project = activity.get(&paths::key_of(&f.project_root)).cloned().unwrap_or_default();
            make_item(env, f, size, &project)
        })
        .collect()
}

fn walk(dir: &Path, depth: usize, ctx: &WalkContext) -> Vec<Found> {
    let Ok(read) = fs::read_dir(dir) else { return Vec::new() };
    let mut names: HashSet<String> = HashSet::new();
    let mut dirs: Vec<(String, PathBuf)> = Vec::new();
    let mut root_modified = 0i64;
    for entry in read.flatten() {
        let Ok(meta) = entry.metadata() else { continue };
        let name = entry.file_name().to_string_lossy().to_string();
        names.insert(name.to_lowercase());
        if is_reparse(&meta) {
            continue; // never follow junctions or symlinks
        }
        if meta.is_dir() {
            dirs.push((name, entry.path()));
        } else {
            root_modified = root_modified.max(mtime(&meta));
        }
    }

    let mut found = Vec::new();
    let mut next = Vec::new();
    for (name, path) in dirs {
        let lower = name.to_lowercase();
        let rules = artifact_rules_named(&lower);
        if !rules.is_empty() {
            if let Some(rule) = rules.iter().copied().find(|r| r.matches(&names)) {
                found.push(Found {
                    lockfile: rule.lockfile(&names),
                    artifact: path,
                    project_root: dir.to_path_buf(),
                    rule,
                    root_modified,
                    orphan: false,
                });
                continue;
            }
            if lower == "node_modules" {
                // node_modules with no package.json beside it: its project may be gone.
                found.push(Found {
                    artifact: path,
                    project_root: dir.to_path_buf(),
                    rule: rules[0],
                    lockfile: None,
                    root_modified,
                    orphan: true,
                });
                continue;
            }
        }
        if lower.starts_with('.') || lower.starts_with('$') || lower == "node_modules" {
            continue;
        }
        if depth >= MAX_DEPTH || ctx.skip.contains(&paths::key_of(&path)) {
            continue;
        }
        next.push(path);
    }
    if !next.is_empty() {
        let deeper: Vec<Found> = next.par_iter().flat_map_iter(|p| walk(p, depth + 1, ctx)).collect();
        found.extend(deeper);
    }
    found
}

fn make_item(env: &ScanEnv, f: &Found, size: fsutil::Stats, project: &ProjectActivity) -> CleanupItem {
    let idle_days = project.last_activity.map(|t| ((env.now - t).max(0) / 86_400) as u64);
    let dormant = idle_days.map(|d| d >= env.dormant_days).unwrap_or(true);
    let mut risk = f.rule.risk;
    let mut tags = vec![f.rule.ecosystem.to_string()];
    let mut notes: Vec<String> = Vec::new();
    let project_name = f.project_root.file_name().map(|n| n.to_string_lossy().to_string()).unwrap_or_default();
    let artifact_name = f.artifact.file_name().map(|n| n.to_string_lossy().to_string()).unwrap_or_default();
    let root_shown = paths::display(&f.project_root.to_string_lossy(), &env.home);

    if f.orphan {
        tags.push("Orphaned".to_string());
        risk = risk.max(Risk::Review);
        notes.push("There's no package.json next to it, so the project it belonged to may be gone.".to_string());
    } else if let Some(idle) = idle_days {
        if dormant {
            tags.push(format!("Dormant {}", age_label(idle)));
        } else {
            tags.push(if idle == 0 { "Active today".to_string() } else { format!("Active {idle}d ago") });
            risk = risk.max(Risk::Review);
            notes.push(if idle == 0 {
                "You worked on this project today. Cleaning it means a rebuild next time you open it.".to_string()
            } else {
                format!("You worked on this project {idle} days ago. Cleaning it means a rebuild next time you open it.")
            });
        }
    }
    if project.git {
        tags.push("git".to_string());
    }
    if !f.rule.lockfiles.is_empty() && !f.orphan {
        match f.lockfile {
            Some(lock) => tags.push(lock.to_string()),
            None => {
                tags.push("No lockfile".to_string());
                risk = risk.max(Risk::Review);
                notes.push("No lockfile, so reinstalling may resolve different dependency versions.".to_string());
            }
        }
    }

    let mut regenerate = f.rule.regenerate.to_string();
    if f.rule.directory == "node_modules" {
        regenerate = match f.lockfile {
            Some("yarn.lock") => "yarn install",
            Some("pnpm-lock.yaml") => "pnpm install",
            Some("bun.lockb") | Some("bun.lock") => "bun install",
            Some(_) => "npm ci",
            None => "npm install",
        }
        .to_string();
    }

    let mut explanation = if f.orphan {
        "A node_modules folder whose project may no longer exist.".to_string()
    } else {
        format!(
            "{} {} folder for {}. It's generated from the project's manifest and can be rebuilt.",
            f.rule.ecosystem, artifact_name, project_name
        )
    };
    for note in &notes {
        explanation.push(' ');
        explanation.push_str(note);
    }

    let path_s = f.artifact.to_string_lossy().to_string();
    CleanupItem {
        id: format!("project:{}", paths::key(&path_s)),
        category: Category::ProjectArtifacts,
        title: format!("{project_name} › {artifact_name}"),
        subtitle: paths::display(&path_s, &env.home),
        paths: vec![path_s],
        size: size.bytes,
        files: size.files,
        risk,
        method: crate::model::Method::RecycleBin,
        explanation,
        regenerate: format!("Run `{regenerate}` in {root_shown}"),
        tags,
        recommended: risk == Risk::Safe && dormant && !f.orphan,
        blocked_reason: None,
        last_activity: project.last_activity,
        group: Some(root_shown),
    }
}

/// Latest sign of life: newest root-file edit, last git reflog entry, git index write.
pub fn project_activity(root: &Path, root_modified: i64, stop_at: &Path) -> ProjectActivity {
    let mut latest = root_modified;
    let mut git = false;
    if let Some(git_dir) = find_git_dir(root, stop_at) {
        git = true;
        if let Some(ts) = last_git_activity(&git_dir) {
            latest = latest.max(ts);
        }
        if let Some(meta) = lstat(&git_dir.join("index")) {
            latest = latest.max(mtime(&meta));
        }
    }
    ProjectActivity { last_activity: (latest > 0).then_some(latest), git }
}

/// The `.git` directory for `path` or one of its parents (up to `stop_at`). Handles worktrees,
/// where `.git` is a file containing `gitdir: <path>`.
pub fn find_git_dir(path: &Path, stop_at: &Path) -> Option<PathBuf> {
    let stop = paths::key_of(stop_at);
    let mut dir = path.to_path_buf();
    for _ in 0..8 {
        let dot_git = dir.join(".git");
        if let Some(meta) = lstat(&dot_git) {
            if meta.is_dir() && !is_reparse(&meta) {
                return Some(dot_git);
            }
            if meta.is_file() {
                if let Ok(text) = fs::read_to_string(&dot_git) {
                    if let Some(rest) = text.trim().strip_prefix("gitdir:") {
                        let target = rest.trim();
                        let p = PathBuf::from(target.replace('/', "\\"));
                        return Some(if paths::is_absolute(target) { p } else { dir.join(p) });
                    }
                }
            }
        }
        if paths::key_of(&dir) == stop {
            break;
        }
        match dir.parent() {
            Some(parent) => dir = parent.to_path_buf(),
            None => break,
        }
    }
    None
}

/// Timestamp of the newest reflog entry in `.git/logs/HEAD`, read from the end of the file
/// without running git. Falls back to the modification time of `.git/HEAD`.
pub fn last_git_activity(git_dir: &Path) -> Option<i64> {
    let log = git_dir.join("logs").join("HEAD");
    let Ok(mut file) = File::open(&log) else {
        return lstat(&git_dir.join("HEAD")).map(|m| mtime(&m));
    };
    let len = file.metadata().ok()?.len();
    file.seek(SeekFrom::Start(len.saturating_sub(4096))).ok()?;
    let mut buf = Vec::new();
    file.read_to_end(&mut buf).ok()?;
    let text = String::from_utf8_lossy(&buf);
    // "<old> <new> Name <email> <unix-ts> <tz>\t<message>"
    let line = text.lines().filter(|l| !l.trim().is_empty()).last()?;
    let header = line.split('\t').next().unwrap_or(line);
    let after_email = &header[header.rfind('>')? + 1..];
    after_email.split_whitespace().next()?.parse::<i64>().ok()
}
