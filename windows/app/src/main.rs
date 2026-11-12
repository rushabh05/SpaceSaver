// No console window in release builds.
#![cfg_attr(not(debug_assertions), windows_subsystem = "windows")]

//! SpaceSaver for Windows: a Tauri shell around `spacesaver-core`. The frontend in `ui/` never
//! passes paths to delete; it passes item ids from the last scan, and every path still goes
//! through the safety guard.

use spacesaver_core as ss;
use ss::{
    ActivityEntry, CleanOptions, CleanReport, Cleaner, DiskInfo, GuardConfig, RestoreReport, SafetyGuard, ScanEnv,
    ScanOptions, ScanSummary, Store, SystemTrash,
};
use std::sync::Mutex;
use tauri::Emitter;

static LAST_SCAN: Mutex<Option<ScanSummary>> = Mutex::new(None);

fn cached_scan() -> Option<ScanSummary> {
    let mut slot = LAST_SCAN.lock().unwrap_or_else(|e| e.into_inner());
    if slot.is_none() {
        *slot = Store::open_default().load_scan();
    }
    slot.clone()
}

fn set_cached_scan(summary: ScanSummary) {
    let _ = Store::open_default().save_scan(&summary);
    *LAST_SCAN.lock().unwrap_or_else(|e| e.into_inner()) = Some(summary);
}

#[tauri::command]
fn disk_status() -> Option<DiskInfo> {
    ss::system::disk_info(&ss::system::system_drive())
}

#[tauri::command]
fn last_scan() -> Option<ScanSummary> {
    cached_scan()
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
    set_cached_scan(summary.clone());
    Ok(summary)
}

#[tauri::command]
async fn clean(app: tauri::AppHandle, ids: Vec<String>) -> Result<CleanReport, String> {
    let summary = cached_scan().ok_or_else(|| "Scan first.".to_string())?;
    let items: Vec<_> = summary.items.iter().filter(|i| ids.contains(&i.id)).cloned().collect();
    if items.is_empty() {
        return Err("Nothing selected.".to_string());
    }
    let report = tauri::async_runtime::spawn_blocking(move || {
        let store = Store::open_default();
        let log = store.activity();
        let guard = SafetyGuard::new(GuardConfig::from_system());
        let trash = SystemTrash;
        let home = ScanEnv::from_system().home;
        let cleaner = Cleaner::new(&guard, &trash, &log).with_recycle_bin(ss::system::recycle_bin_info(&home));
        cleaner.clean(&items, &CleanOptions::run("app"), &mut |p| {
            let _ = app.emit("clean-progress", p.clone());
        })
    })
    .await
    .map_err(|e| e.to_string())?;

    let mut updated = summary;
    updated.items.retain(|i| !report.moved_ids.contains(&i.id));
    updated.refresh();
    set_cached_scan(updated);
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

/// Opens Explorer with the item selected. Only for paths in the last scan.
#[tauri::command]
fn reveal(path: String) -> Result<(), String> {
    let known = cached_scan()
        .map(|s| s.items.iter().any(|i| i.paths.iter().any(|p| p == &path)))
        .unwrap_or(false);
    if !known || path.contains('"') {
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
