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

/// Recycle Bin settings for one volume.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct RecycleBinInfo {
    /// Where the volume is mounted (`C:\`, or a folder for a volume mounted in one), for messages.
    pub drive: String,
    /// The volume itself (`\\?\Volume{GUID}\`), so two mount points of one volume share a budget.
    pub volume: String,
    /// Largest size the Recycle Bin keeps. Anything bigger would be deleted permanently,
    /// so the cleaner refuses it, and it keeps the total of one run under it too.
    pub max_bytes: u64,
    /// "Don't move files to the Recycle Bin" is set for this volume, by the user or by policy.
    pub disabled: bool,
    /// Set when the volume has no Recycle Bin at all, with the kind of drive ("a removable
    /// drive", "a network drive"...). Windows deletes from these permanently.
    #[serde(default)]
    pub no_bin: Option<String>,
}

const EXPLORER_POLICIES: &str = r"Software\Microsoft\Windows\CurrentVersion\Policies\Explorer";

// GetDriveTypeW results.
#[cfg(windows)]
const DRIVE_REMOVABLE: u32 = 2;
#[cfg(windows)]
const DRIVE_FIXED: u32 = 3;
#[cfg(windows)]
const DRIVE_REMOTE: u32 = 4;
#[cfg(windows)]
const DRIVE_CDROM: u32 = 5;
#[cfg(windows)]
const DRIVE_RAMDISK: u32 = 6;

/// The root of the volume that really holds `path`: `C:\`, the folder a volume is mounted at
/// (`C:\Users\me\models\`) or a share (`\\server\share\`). Always ends with `\`.
#[cfg(windows)]
pub fn volume_root_of(path: &Path) -> Option<String> {
    use windows_sys::Win32::Storage::FileSystem::GetVolumePathNameW;
    let norm = crate::paths::normalize(&path.to_string_lossy());
    // The extended form lifts the MAX_PATH limit.
    let long = if let Some(unc) = norm.strip_prefix(r"\\") { format!(r"\\?\UNC\{unc}") } else { format!(r"\\?\{norm}") };
    let input = wide(&long);
    let mut buf = vec![0u16; 32 * 1024];
    // SAFETY: `input` is NUL-terminated and `buf` has the length we pass.
    let ok = unsafe { GetVolumePathNameW(input.as_ptr(), buf.as_mut_ptr(), buf.len() as u32) };
    if ok == 0 {
        return None;
    }
    let len = buf.iter().position(|&c| c == 0).unwrap_or(buf.len());
    let raw = String::from_utf16_lossy(&buf[..len]);
    let mut root = if let Some(unc) = raw.strip_prefix(r"\\?\UNC\") {
        format!(r"\\{unc}")
    } else if let Some(rest) = raw.strip_prefix(r"\\?\") {
        rest.to_string()
    } else {
        raw
    };
    if root.is_empty() {
        return None;
    }
    if !root.ends_with('\\') {
        root.push('\\');
    }
    Some(root)
}

#[cfg(not(windows))]
pub fn volume_root_of(path: &Path) -> Option<String> {
    drive_of(path)
}

#[cfg(windows)]
fn drive_type(root: &str) -> u32 {
    use windows_sys::Win32::Storage::FileSystem::GetDriveTypeW;
    let w = wide(root);
    // SAFETY: `w` is NUL-terminated.
    unsafe { GetDriveTypeW(w.as_ptr()) }
}

/// `\\?\Volume{GUID}\` for a volume root or mount folder.
#[cfg(windows)]
fn volume_guid_path(root: &str) -> Option<String> {
    use windows_sys::Win32::Storage::FileSystem::GetVolumeNameForVolumeMountPointW;
    let mount = wide(root);
    let mut buf = [0u16; 128];
    // SAFETY: `mount` is NUL-terminated and `buf` has the length we pass.
    let ok = unsafe { GetVolumeNameForVolumeMountPointW(mount.as_ptr(), buf.as_mut_ptr(), buf.len() as u32) };
    if ok == 0 {
        return None;
    }
    let len = buf.iter().position(|&c| c == 0).unwrap_or(buf.len());
    Some(String::from_utf16_lossy(&buf[..len]))
}

/// Reads the Recycle Bin settings of the volume whose root (or mount folder) is `root`, as
/// returned by [`volume_root_of`]:
///
/// * only fixed drives have a Recycle Bin: removable, network, optical and RAM drives come back
///   with `no_bin` set, and a drive of unknown type is an error;
/// * the per-volume `MaxCapacity` (MB) and `NukeOnDelete` values under
///   `HKCU\...\Explorer\BitBucket\Volume\{GUID}` (without them the limit falls back to 5% of
///   the volume, and the bin counts as on);
/// * the `NoRecycleFiles` and `RecycleBinSize` (percent of the volume) policies under `HKLM`
///   and `HKCU\Software\Microsoft\Windows\CurrentVersion\Policies\Explorer`, which override them.
///
/// Fails when the volume, its type or its size can't be read. The cleaner then refuses
/// everything on that volume rather than risk a permanent delete.
#[cfg(windows)]
pub fn recycle_bin_info(root: &str) -> Result<RecycleBinInfo, String> {
    use winreg::enums::{HKEY_CURRENT_USER, HKEY_LOCAL_MACHINE};
    use winreg::RegKey;

    let mut root = root.to_string();
    if !root.ends_with('\\') {
        root.push('\\');
    }
    let guid_path = volume_guid_path(&root);
    let kind = guid_path
        .as_deref()
        .map(drive_type)
        .filter(|&k| k > 1)
        .unwrap_or_else(|| drive_type(&root));
    let no_bin = match kind {
        DRIVE_FIXED => None,
        DRIVE_REMOVABLE => Some("a removable drive"),
        DRIVE_REMOTE => Some("a network drive"),
        DRIVE_CDROM => Some("a CD or DVD drive"),
        DRIVE_RAMDISK => Some("a RAM disk"),
        _ => return Err(format!("couldn't tell what kind of drive {root} is")),
    };
    if let Some(no_bin) = no_bin {
        return Ok(RecycleBinInfo {
            drive: root.clone(),
            volume: guid_path.unwrap_or_else(|| root.clone()),
            max_bytes: 0,
            disabled: true,
            no_bin: Some(no_bin.to_string()),
        });
    }
    let volume = guid_path.ok_or_else(|| format!("couldn't identify the volume behind {root}"))?;
    let guid = match (volume.find('{'), volume.find('}')) {
        (Some(start), Some(end)) if end > start => volume[start..=end].to_string(),
        _ => return Err(format!("unexpected volume name for {root}")),
    };
    let disk = disk_info(&root).ok_or_else(|| format!("couldn't read the size of {root}"))?;

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
    Ok(RecycleBinInfo { drive: root, volume, max_bytes, disabled, no_bin: None })
}

#[cfg(not(windows))]
pub fn recycle_bin_info(root: &str) -> Result<RecycleBinInfo, String> {
    Err(format!("Recycle Bin settings for {root} can only be read on Windows"))
}
