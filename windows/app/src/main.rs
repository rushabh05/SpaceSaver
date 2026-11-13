// No console window in release builds.
#![cfg_attr(not(debug_assertions), windows_subsystem = "windows")]

//! SpaceSaver for Windows: a Tauri shell around `spacesaver-core`. The frontend in `ui/` never
//! passes paths to delete; it passes item ids and the id of the scan it showed, and the backend
//! only cleans from a scan this process made in the last hour. Every path still goes through
//! the safety guard.

use spacesaver_core as ss;
use ss::{
    ActivityEntry, CleanOptions, CleanReport, Cleaner, DiskInfo, GuardConfig, RestoreReport, SafetyGuard, ScanEnv,
    ScanOptions, ScanSummary, Store, SystemRecycleBin, SystemTrash,
};
use std::sync::Mutex;
use std::time::{Duration, Instant};
use tauri::Emitter;

/// A scan older than this must be repeated before cleaning: projects may have become active,
/// apps may be running and sizes (which the Recycle Bin checks use) may have changed.
const MAX_SCAN_AGE: Duration = Duration::from_secs(60 * 60);

/// The last scan this process made. Only this one is ever cleaned from.
struct LiveScan {
    summary: ScanSummary,
    made: Instant,
}

static LIVE_SCAN: Mutex<Option<LiveScan>> = Mutex::new(None);

fn live_scan() -> std::sync::MutexGuard<'static, Option<LiveScan>> {
    LIVE_SCAN.lock().unwrap_or_else(|e| e.into_inner())
}

#[tauri::command]
fn disk_status() -> Option<DiskInfo> {
    ss::system::disk_info(&ss::system::system_drive())
}

/// The scan to show: this session's, or else the one saved by an earlier run or the CLI. A
/// saved scan is only for display; cleaning needs a fresh scan.
#[tauri::command]
fn last_scan() -> Option<ScanSummary> {
    if let Some(live) = live_scan().as_ref() {
        return Some(live.summary.clone());
    }
    Store::open_default().load_scan()
}

#[tauri::command]
async fn scan() -> Result<ScanSummary, String> {
    let summary = tauri::async_runtime::spawn_blocking(|| {
        let env = ScanEnv::from_system();
        let guard = SafetyGuard::new(GuardConfig::from_system());
        ss::scan(&env, Some(&guard), &ScanOptions::default())
    })
    .await
    .map_err(|e| e.to_string())?;
    let _ = Store::open_default().save_scan(&summary);
    *live_scan() = Some(LiveScan { summary: summary.clone(), made: Instant::now() });
    Ok(summary)
}

/// The live scan, if it is `scan_id` and fresh enough to clean from.
fn scan_to_clean(scan_id: &str) -> Result<ScanSummary, String> {
    let slot = live_scan();
    let live = slot.as_ref().ok_or_else(|| "Scan again before cleaning.".to_string())?;
    if live.summary.id != scan_id {
        return Err("The scan changed after you opened this review. Check the list again before cleaning.".to_string());
    }
    if live.made.elapsed() > MAX_SCAN_AGE {
        return Err("This scan is more than an hour old. Scan again before cleaning.".to_string());
    }
    Ok(live.summary.clone())
}

/// Drops what moved from the live scan, unless a newer scan replaced it meanwhile.
fn forget_moved(scan_id: &str, moved: &[String]) {
    let mut slot = live_scan();
    if let Some(live) = slot.as_mut().filter(|l| l.summary.id == scan_id) {
        live.summary.items.retain(|i| !moved.contains(&i.id));
        live.summary.refresh();
        let _ = Store::open_default().save_scan(&live.summary);
    }
}

/// Cleans items `ids` from scan `scan_id`, which must be the scan this process made last and
/// no more than an hour old.
#[tauri::command]
async fn clean(app: tauri::AppHandle, ids: Vec<String>, scan_id: String) -> Result<CleanReport, String> {
    let summary = scan_to_clean(&scan_id)?;
    let items: Vec<_> = summary.items.iter().filter(|i| ids.contains(&i.id)).cloned().collect();
    if items.is_empty() {
        return Err("Nothing selected.".to_string());
    }
    let report = tauri::async_runtime::spawn_blocking(move || {
        let store = Store::open_default();
        let log = store.activity();
        let guard = SafetyGuard::new(GuardConfig::from_system());
        let trash = SystemTrash;
        let bins = SystemRecycleBin;
        let cleaner = Cleaner::new(&guard, &trash, &log).with_recycle_bin(&bins);
        cleaner.clean(&items, &CleanOptions::run("app"), &mut |p| {
            let _ = app.emit("clean-progress", p.clone());
        })
    })
    .await
    .map_err(|e| e.to_string())?;
    forget_moved(&scan_id, &report.moved_ids);
    Ok(report)
}

#[tauri::command]
fn activity() -> Vec<ActivityEntry> {
    Store::open_default().activity().entries()
}

#[tauri::command]
async fn restore(id: String) -> Result<RestoreReport, String> {
    tauri::async_runtime::spawn_blocking(move || {
        let store = Store::open_default();
        let log = store.activity();
        let guard = SafetyGuard::new(GuardConfig::from_system());
        let trash = SystemTrash;
        Cleaner::new(&guard, &trash, &log).restore(&id)
    })
    .await
    .map_err(|e| e.to_string())?
}

/// Opens Explorer with the item selected. Only for local paths in the scan being shown; never
/// a network (UNC) path, which would make Windows connect to that server.
#[tauri::command]
fn reveal(path: String) -> Result<(), String> {
    let network = path.starts_with(r"\\") || path.starts_with("//") || path.starts_with(r"\/") || path.starts_with(r"/\");
    if network || !ss::paths::is_absolute(&path) || path.contains('"') {
        return Err("Unknown path".to_string());
    }
    let known = last_scan()
        .map(|s| s.items.iter().any(|i| i.paths.iter().any(|p| p == &path)))
        .unwrap_or(false);
    if !known {
        return Err("Unknown path".to_string());
    }
    let target = if std::path::Path::new(&path).exists() {
        path
    } else {
        std::path::Path::new(&path)
            .parent()
            .map(|p| p.to_string_lossy().to_string())
            .ok_or_else(|| "Path no longer exists".to_string())?
    };
    open_explorer(&target)
}

#[cfg(windows)]
fn open_explorer(path: &str) -> Result<(), String> {
    use std::os::windows::process::CommandExt;
    std::process::Command::new("explorer.exe")
        .raw_arg(format!("/select,\"{path}\""))
        .spawn()
        .map(|_| ())
        .map_err(|e| e.to_string())
}

#[cfg(not(windows))]
fn open_explorer(_path: &str) -> Result<(), String> {
    Err("Reveal is only supported on Windows".to_string())
}

fn main() {
    tauri::Builder::default()
        .invoke_handler(tauri::generate_handler![disk_status, last_scan, scan, clean, activity, restore, reveal])
        .run(tauri::generate_context!())
        .expect("error while running SpaceSaver");
}
