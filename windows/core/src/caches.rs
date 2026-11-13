//! Evaluates the cache location rules, and finds old files in `%TEMP%`.

use crate::env::ScanEnv;
use crate::fsutil::{expand, is_reparse, lstat, measure, mtime, Stats};
use crate::model::{Category, CleanupItem, Method, Risk};
use crate::paths;
use crate::rules::{location_rules, LocationRule};
use rayon::prelude::*;
use std::collections::HashSet;
use std::fs;
use std::path::PathBuf;

/// One item per rule (or per match, for `each` rules) that holds at least `env.min_bytes`.
pub fn analyze(env: &ScanEnv, running: &HashSet<String>) -> Vec<CleanupItem> {
    let rules = location_rules(env);
    let mut groups: Vec<(usize, Vec<PathBuf>)> = Vec::new();
    for (i, rule) in rules.iter().enumerate() {
        let mut matched: Vec<PathBuf> = Vec::new();
        let mut seen = HashSet::new();
        for pattern in &rule.paths {
            for p in expand(pattern) {
                if seen.insert(paths::key_of(&p)) {
                    matched.push(p);
                }
            }
        }
        if matched.is_empty() {
            continue;
        }
        if rule.each {
            groups.extend(matched.into_iter().map(|p| (i, vec![p])));
        } else {
            groups.push((i, matched));
        }
    }

    let measured: Vec<(usize, Vec<PathBuf>, Stats)> = groups
        .into_par_iter()
        .map(|(i, group)| {
            let stats = group.iter().map(|p| measure(p)).fold(Stats::default(), Stats::merge);
            (i, group, stats)
        })
        .collect();

    measured
        .into_iter()
        .filter(|(_, _, stats)| stats.bytes >= env.min_bytes)
        .map(|(i, group, stats)| make_item(env, &rules[i], group, stats, running))
        .collect()
}

fn make_item(env: &ScanEnv, rule: &LocationRule, group: Vec<PathBuf>, stats: Stats, running: &HashSet<String>) -> CleanupItem {
    let first = group[0].to_string_lossy().to_string();
    let title = if rule.each { format!("{} · {}", rule.title, rule.label.apply(&group[0])) } else { rule.title.clone() };
    let id = if rule.each { format!("{}:{}", rule.id, paths::key(&first)) } else { rule.id.clone() };
    let subtitle = if group.len() > 1 {
        format!("{} (+{} more)", paths::display(&first, &env.home), group.len() - 1)
    } else {
        paths::display(&first, &env.home)
    };
    let blocked_reason = rule
        .processes
        .iter()
        .find(|p| running.contains(**p))
        .map(|_| format!("{} is running. Close it first.", rule.app_name));
    let mut tags = Vec::new();
    if stats.files > 0 {
        tags.push(format!("{} files", stats.files));
    }
    CleanupItem {
        id,
        category: rule.category,
        title,
        subtitle,
        paths: group.iter().map(|p| p.to_string_lossy().to_string()).collect(),
        size: stats.bytes,
        files: stats.files,
        risk: rule.risk,
        method: Method::RecycleBin,
        explanation: rule.explanation.clone(),
        regenerate: rule.regenerate.clone(),
        tags,
        recommended: rule.risk == Risk::Safe && blocked_reason.is_none(),
        blocked_reason,
        last_activity: (stats.newest > 0).then_some(stats.newest),
        group: None,
    }
}

/// Top-level entries of `%TEMP%` that nothing has modified for `env.temp_age_days`, as one item.
pub fn old_temp_files(env: &ScanEnv) -> Option<CleanupItem> {
    let cutoff = env.now - env.temp_age_days as i64 * 86_400;
    let read = fs::read_dir(&env.temp).ok()?;
    let candidates: Vec<PathBuf> = read
        .flatten()
        .filter(|e| e.metadata().map(|m| !is_reparse(&m) && mtime(&m) <= cutoff).unwrap_or(false))
        .map(|e| e.path())
        .collect();
    let mut old: Vec<(PathBuf, Stats)> = candidates
        .par_iter()
        .filter_map(|p| {
            let meta = lstat(p)?;
            let stats = measure(p);
            // A folder counts as old only if nothing inside it changed recently either.
            if meta.is_dir() && stats.newest > cutoff {
                return None;
            }
            Some((p.clone(), stats))
        })
        .collect();
    if old.is_empty() {
        return None;
    }
    old.sort_by(|a, b| b.1.bytes.cmp(&a.1.bytes));
    let stats = old.iter().fold(Stats::default(), |acc, (_, s)| acc.merge(*s));
    if stats.bytes < env.min_bytes {
        return None;
    }
    let temp_shown = paths::display(&env.temp.to_string_lossy(), &env.home);
    let days = env.temp_age_days;
    let mut item = CleanupItem::new(
        "sys.temp",
        Category::SystemJunk,
        "Old temporary files",
        old.iter().map(|(p, _)| p.to_string_lossy().to_string()).collect(),
        stats.bytes,
        Risk::Safe,
    );
    item.subtitle = format!("{temp_shown} · {} entries untouched for {days}+ days", old.len());
    item.files = stats.files;
    item.explanation = format!(
        "Files and folders in your temp folder that nothing has changed for {days} days. Installers and apps leave these behind. Anything still in use is skipped."
    );
    item.regenerate = "Not needed. Apps recreate temp files when they need them.".to_string();
    item.tags = vec![format!("{} entries", old.len())];
    item.last_activity = (stats.newest > 0).then_some(stats.newest);
    Some(item)
}
