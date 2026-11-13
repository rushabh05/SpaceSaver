//! Runs every analyzer in parallel and puts the results together.

use crate::env::ScanEnv;
use crate::model::{Category, CleanupItem, ScanSummary};
use crate::safety::SafetyGuard;
use crate::{caches, projects, system, wsl};
use std::collections::HashSet;
use std::path::Path;
use std::time::Instant;

#[derive(Debug, Clone, Default)]
pub struct ScanOptions {
    /// Only these categories (all when `None`).
    pub categories: Option<Vec<Category>>,
}

impl ScanOptions {
    fn wants(&self, c: Category) -> bool {
        self.categories.as_ref().map(|v| v.contains(&c)).unwrap_or(true)
    }
}

/// Scans everything. When a `guard` is given, items it would refuse are marked blocked with
/// the reason, so the UI never offers something the cleaner will refuse.
pub fn scan(env: &ScanEnv, guard: Option<&SafetyGuard>, opts: &ScanOptions) -> ScanSummary {
    let start = Instant::now();
    let running: HashSet<String> = if env.check_processes { system::running_processes() } else { HashSet::new() };

    let (project_items, (cache_items, (temp_item, wsl_items))) = rayon::join(
        || if opts.wants(Category::ProjectArtifacts) { projects::analyze(env) } else { Vec::new() },
        || {
            rayon::join(
                || caches::analyze(env, &running),
                || {
                    rayon::join(
                        || if opts.wants(Category::SystemJunk) { caches::old_temp_files(env) } else { None },
                        || if opts.wants(Category::WslDocker) { wsl::analyze(env) } else { Vec::new() },
                    )
                },
            )
        },
    );

    let mut items: Vec<CleanupItem> = project_items;
    items.extend(cache_items);
    items.extend(temp_item);
    items.extend(wsl_items);
    items.retain(|i| opts.wants(i.category));

    if let Some(guard) = guard {
        for item in items.iter_mut() {
            if item.blocked_reason.is_some() || !item.method.is_actionable() {
                continue;
            }
            for p in &item.paths {
                if let Err(e) = guard.validate(Path::new(p)) {
                    item.blocked_reason = Some(e.to_string());
                    item.recommended = false;
                    break;
                }
            }
        }
    }

    items.sort_by(|a, b| a.category.cmp(&b.category).then(b.size.cmp(&a.size)));
    let disk = system::disk_info(&system::system_drive());
    let mut summary = ScanSummary::new(items, disk, env.now, start.elapsed().as_millis() as u64);
    if opts.wants(Category::SystemJunk) {
        if let Some(problem) = env.temp_problem() {
            summary.notes.push(format!("Old temporary files skipped: {problem}."));
        }
    }
    summary
}
