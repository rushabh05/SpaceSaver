//! Windows system queries: disk space, running processes and Recycle Bin limits.

use crate::model::DiskInfo;
use serde::{Deserialize, Serialize};
use std::collections::HashSet;
use std::path::Path;

/// `C:\` (from `%SystemDrive%`).
pub fn system_drive() -> String {
    let drive = std::env::var("SystemDrive").unwrap_or_else(|_| "C:".to_string());
    format!("{}\\", drive.trim_end_matches('\\'))
}

/// The drive root of a path (`C:\`), if it has a drive letter.
pub fn drive_of(path: &Path) -> Option<String> {
    let norm = crate::paths::normalize(&path.to_string_lossy());
    let b = norm.as_bytes();
    if b.len() >= 2 && b[1] == b':' {
        Some(format!("{}\\", &norm[..2]))
    } else {
        None
    }
}

/// Total and available space on the drive that holds `root`.
#[cfg(windows)]
pub fn disk_info(root: &str) -> Option<DiskInfo> {
    use windows_sys::Win32::Storage::FileSystem::GetDiskFreeSpaceExW;
    let wide = wide(root);
    let mut available: u64 = 0;
    let mut total: u64 = 0;
    let mut total_free: u64 = 0;
    // SAFETY: `wide` is NUL-terminated and the out-pointers are valid for the call.
    let ok = unsafe { GetDiskFreeSpaceExW(wide.as_ptr(), &mut available, &mut total, &mut total_free) };
    if ok == 0 {
        return None;
    }
    Some(DiskInfo { drive: root.to_string(), total, free: available })
}

#[cfg(not(windows))]
pub fn disk_info(_root: &str) -> Option<DiskInfo> {
    None
}

#[cfg(windows)]
fn wide(s: &str) -> Vec<u16> {
    use std::os::windows::ffi::OsStrExt;
    std::ffi::OsStr::new(s).encode_wide().chain(std::iter::once(0)).collect()
}

/// Lower-cased names of running processes, without `.exe`.
#[cfg(windows)]
pub fn running_processes() -> HashSet<String> {
    use windows_sys::Win32::Foundation::{CloseHandle, INVALID_HANDLE_VALUE};
    use windows_sys::Win32::System::Diagnostics::ToolHelp::{
        CreateToolhelp32Snapshot, Process32FirstW, Process32NextW, PROCESSENTRY32W, TH32CS_SNAPPROCESS,
    };
    let mut names = HashSet::new();
    // SAFETY: standard Toolhelp32 enumeration; the entry is zero-initialised with dwSize set
    // and the snapshot handle is closed before returning.
    unsafe {
        let snapshot = CreateToolhelp32Snapshot(TH32CS_SNAPPROCESS, 0);
        if snapshot == INVALID_HANDLE_VALUE {
            return names;
        }
        let mut entry: PROCESSENTRY32W = std::mem::zeroed();
        entry.dwSize = std::mem::size_of::<PROCESSENTRY32W>() as u32;
        if Process32FirstW(snapshot, &mut entry) != 0 {
            loop {
                let len = entry.szExeFile.iter().position(|&c| c == 0).unwrap_or(entry.szExeFile.len());
                let name = String::from_utf16_lossy(&entry.szExeFile[..len]).to_lowercase();
                names.insert(name.strip_suffix(".exe").unwrap_or(&name).to_string());
                if Process32NextW(snapshot, &mut entry) == 0 {
                    break;
                }
            }
        }
        CloseHandle(snapshot);
    }
    names
}

#[cfg(not(windows))]
pub fn running_processes() -> HashSet<String> {
    HashSet::new()
}

/// Recycle Bin settings for one drive.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct RecycleBinInfo {
    pub drive: String,
    /// Largest size the Recycle Bin keeps. Anything bigger would be deleted permanently,
    /// so the cleaner refuses it, and it keeps the total of one run under it too.
    pub max_bytes: u64,
    /// "Don't move files to the Recycle Bin" is set for this drive, by the user or by policy.
    pub disabled: bool,
}

const EXPLORER_POLICIES: &str = r"Software\Microsoft\Windows\CurrentVersion\Policies\Explorer";

/// Reads the Recycle Bin settings for the drive root `drive` (`C:\`):
///
/// * the per-volume `MaxCapacity` (MB) and `NukeOnDelete` values under
///   `HKCU\...\Explorer\BitBucket\Volume\{GUID}` (without them the limit falls back to 5% of
///   the drive, and the bin counts as on);
/// * the `NoRecycleFiles` and `RecycleBinSize` (percent of the drive) policies under
///   `HKLM` and `HKCU\Software\Microsoft\Windows\CurrentVersion\Policies\Explorer`, which
///   override them.
///
/// Fails when the drive's size or volume can't be read (a network drive, for example). The
/// cleaner then refuses everything on that drive rather than risk a permanent delete.
#[cfg(windows)]
pub fn recycle_bin_info(drive: &str) -> Result<RecycleBinInfo, String> {
    use windows_sys::Win32::Storage::FileSystem::GetVolumeNameForVolumeMountPointW;
    use winreg::enums::{HKEY_CURRENT_USER, HKEY_LOCAL_MACHINE};
    use winreg::RegKey;

    let root = drive_of(Path::new(drive)).ok_or_else(|| format!("{drive} is not a drive"))?;
    let disk = disk_info(&root).ok_or_else(|| format!("couldn't read the size of {root}"))?;

    let mount = wide(&root);
    let mut buf = [0u16; 128];
    // SAFETY: `mount` is NUL-terminated and `buf` has the length we pass.
    let ok = unsafe { GetVolumeNameForVolumeMountPointW(mount.as_ptr(), buf.as_mut_ptr(), buf.len() as u32) };
    if ok == 0 {
        return Err(format!("couldn't identify the volume behind {root}"));
    }
    let len = buf.iter().position(|&c| c == 0).unwrap_or(buf.len());
    let volume = String::from_utf16_lossy(&buf[..len]);
    let guid = match (volume.find('{'), volume.find('}')) {
        (Some(start), Some(end)) if end > start => volume[start..=end].to_string(),
        _ => return Err(format!("unexpected volume name for {root}")),
    };

    let mut max_bytes = disk.total / 20;
    let mut disabled = false;
    let sub = format!(r"Software\Microsoft\Windows\CurrentVersion\Explorer\BitBucket\Volume\{guid}");
    if let Ok(k) = RegKey::predef(HKEY_CURRENT_USER).open_subkey(sub) {
        if let Ok(mb) = k.get_value::<u32, _>("MaxCapacity") {
            max_bytes = u64::from(mb) * 1024 * 1024;
        }
        if let Ok(nuke) = k.get_value::<u32, _>("NukeOnDelete") {
            disabled = nuke != 0;
        }
    }

    // Group Policy wins over the user's own settings. With both hives set, the stricter applies.
    let mut policy_percent: Option<u64> = None;
    for hive in [HKEY_LOCAL_MACHINE, HKEY_CURRENT_USER] {
        let Ok(k) = RegKey::predef(hive).open_subkey(EXPLORER_POLICIES) else { continue };
        if let Ok(v) = k.get_value::<u32, _>("NoRecycleFiles") {
            if v != 0 {
                disabled = true;
            }
        }
        if let Ok(pct) = k.get_value::<u32, _>("RecycleBinSize") {
            let pct = u64::from(pct.min(100));
            policy_percent = Some(policy_percent.map_or(pct, |p: u64| p.min(pct)));
        }
    }
    if let Some(pct) = policy_percent {
        max_bytes = disk.total / 100 * pct;
    }
    Ok(RecycleBinInfo { drive: root, max_bytes, disabled })
}

#[cfg(not(windows))]
pub fn recycle_bin_info(drive: &str) -> Result<RecycleBinInfo, String> {
    Err(format!("Recycle Bin settings for {drive} can only be read on Windows"))
}
