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
    /// so the cleaner refuses it.
    pub max_bytes: Option<u64>,
    /// "Don't move files to the Recycle Bin" is set for this drive.
    pub disabled: bool,
}

/// Reads the Recycle Bin size limit and "delete immediately" setting for the drive holding
/// `path`, from `HKCU\...\Explorer\BitBucket\Volume\{GUID}`. Without a per-volume setting the
/// limit falls back to 5% of the drive.
#[cfg(windows)]
pub fn recycle_bin_info(path: &Path) -> Option<RecycleBinInfo> {
    use windows_sys::Win32::Storage::FileSystem::GetVolumeNameForVolumeMountPointW;
    use winreg::enums::HKEY_CURRENT_USER;
    use winreg::RegKey;

    let root = drive_of(path)?;
    let disk = disk_info(&root);
    let fallback = disk.as_ref().map(|d| d.total / 20);

    let mount = wide(&root);
    let mut buf = [0u16; 128];
    // SAFETY: `mount` is NUL-terminated and `buf` has the length we pass.
    let ok = unsafe { GetVolumeNameForVolumeMountPointW(mount.as_ptr(), buf.as_mut_ptr(), buf.len() as u32) };
    let mut max_bytes = fallback;
    let mut disabled = false;
    if ok != 0 {
        let len = buf.iter().position(|&c| c == 0).unwrap_or(buf.len());
        let volume = String::from_utf16_lossy(&buf[..len]);
        if let (Some(start), Some(end)) = (volume.find('{'), volume.find('}')) {
            if end > start {
                let guid = &volume[start..=end];
                let sub = format!(r"Software\Microsoft\Windows\CurrentVersion\Explorer\BitBucket\Volume\{guid}");
                if let Ok(k) = RegKey::predef(HKEY_CURRENT_USER).open_subkey(sub) {
                    if let Ok(mb) = k.get_value::<u32, _>("MaxCapacity") {
                        max_bytes = Some(u64::from(mb) * 1024 * 1024);
                    }
                    if let Ok(nuke) = k.get_value::<u32, _>("NukeOnDelete") {
                        disabled = nuke == 1;
                    }
                }
            }
        }
    }
    Some(RecycleBinInfo { drive: root, max_bytes, disabled })
}

#[cfg(not(windows))]
pub fn recycle_bin_info(_path: &Path) -> Option<RecycleBinInfo> {
    None
}
