//! WSL distro and Docker Desktop virtual disks (`ext4.vhdx`, `docker_data.vhdx`).
//!
//! These grow as Linux writes files and never shrink by themselves. SpaceSaver reports them
//! and explains how to compact them; it never deletes them (the method is always Manual).

use crate::env::ScanEnv;
use crate::fsutil::{expand, is_reparse, lstat, mtime};
use crate::model::{Category, CleanupItem, Method, Risk};
use crate::paths;
use std::collections::HashSet;
use std::path::PathBuf;

#[derive(Debug, Clone)]
struct Disk {
    path: PathBuf,
    distro: Option<String>,
}

pub fn analyze(env: &ScanEnv) -> Vec<CleanupItem> {
    let mut disks: Vec<Disk> = Vec::new();
    if env.use_registry {
        disks.extend(registry_disks());
    }
    for pattern in [
        env.local.join(r"Packages\*\LocalState\ext4.vhdx"),
        env.local.join(r"wsl\*\ext4.vhdx"),
        env.local.join(r"Docker\wsl\*\*.vhdx"),
    ] {
        disks.extend(expand(&pattern).into_iter().map(|path| Disk { path, distro: None }));
    }

    let mut seen = HashSet::new();
    let mut items = Vec::new();
    for disk in disks {
        if !seen.insert(paths::key_of(&disk.path)) {
            continue;
        }
        let Some(meta) = lstat(&disk.path) else { continue };
        if is_reparse(&meta) || !meta.is_file() || meta.len() < env.min_bytes {
            continue;
        }
        items.push(make_item(env, &disk, meta.len(), mtime(&meta)));
    }
    items.sort_by(|a, b| b.size.cmp(&a.size));
    items
}

fn make_item(env: &ScanEnv, disk: &Disk, size: u64, modified: i64) -> CleanupItem {
    let file = paths::normalize(&disk.path.to_string_lossy());
    let lower = file.to_lowercase();
    let docker = lower.contains(r"\docker\wsl\")
        || disk.distro.as_deref().map(|d| d.to_lowercase().starts_with("docker-desktop")).unwrap_or(false);
    let distro = disk.distro.clone().or_else(|| distro_from_path(&disk.path));
    // Folder and distro names are untrusted: they only ever appear as quoted literals.
    let file_ps = ps_quote(&file);

    let (title, explanation, instructions, commands) = if docker {
        let title = match disk.distro.as_deref() {
            Some(name) => format!("Docker Desktop disk ({name})"),
            None => "Docker Desktop data disk".to_string(),
        };
        let commands = vec![
            "docker system prune".to_string(),
            "wsl --shutdown".to_string(),
            format!("Optimize-VHD -Path {file_ps} -Mode Full"),
        ];
        let instructions = format!(
            "Docker Desktop keeps images, containers, volumes and build cache in this virtual disk. It grows as you pull and build, and never shrinks by itself.\n\n\
             1. Free space inside it first (removes stopped containers, unused networks, dangling images and build cache):\n   docker system prune\n\n\
             2. Quit Docker Desktop, then stop WSL:\n   wsl --shutdown\n\n\
             3. Compact the file in an elevated PowerShell (needs the Hyper-V module):\n   Optimize-VHD -Path {file_ps} -Mode Full\n\n\
             {diskpart}",
            diskpart = diskpart_steps(&file)
        );
        (
            title,
            "Docker Desktop's virtual disk. SpaceSaver never deletes it: that would wipe every image, container and volume.".to_string(),
            instructions,
            commands,
        )
    } else {
        let name = ps_quote(distro.as_deref().unwrap_or("<distro>"));
        let title = match &distro {
            Some(d) => format!("WSL · {d}"),
            None => "WSL distro disk".to_string(),
        };
        let commands = vec![
            "wsl --shutdown".to_string(),
            format!("Optimize-VHD -Path {file_ps} -Mode Full"),
            format!("wsl --manage {name} --set-sparse true"),
        ];
        let instructions = format!(
            "This virtual disk holds the {label} Linux file system. It grows as Linux writes files but never shrinks by itself, even after you delete them.\n\n\
             1. Delete what you don't need inside Linux, then stop WSL:\n   wsl --shutdown\n\n\
             2. Compact the file in an elevated PowerShell (needs the Hyper-V module):\n   Optimize-VHD -Path {file_ps} -Mode Full\n\n\
             {diskpart}\n\n\
             3. Let it shrink automatically from now on (WSL 2.0 or later), in PowerShell:\n   wsl --manage {name} --set-sparse true",
            label = distro.as_deref().unwrap_or("WSL"),
            diskpart = diskpart_steps(&file)
        );
        (
            title,
            "A WSL distro's virtual disk. SpaceSaver never deletes it: that would delete the whole Linux install and its files.".to_string(),
            instructions,
            commands,
        )
    };

    let mut tags = vec!["VHDX".to_string(), "Never deleted".to_string()];
    if let Some(d) = &distro {
        tags.push(d.clone());
    }
    CleanupItem {
        id: format!("wsl:{}", paths::key(&file)),
        category: Category::WslDocker,
        title,
        subtitle: paths::display(&file, &env.home),
        paths: vec![file],
        size,
        files: 1,
        risk: Risk::Review,
        method: Method::Manual { instructions, commands },
        explanation,
        regenerate: if docker {
            "Nothing is deleted. Compacting keeps your images, containers and volumes and gives back the unused space."
        } else {
            "Nothing is deleted. Compacting keeps all your Linux files and gives back the unused space."
        }
        .to_string(),
        tags,
        recommended: false,
        blocked_reason: None,
        last_activity: (modified > 0).then_some(modified),
        group: None,
    }
}

/// A PowerShell single-quoted string literal: nothing inside it is expanded or run. Every
/// character PowerShell treats as a single quote (`'` and the curly quotes U+2018 to U+201B)
/// is doubled.
pub fn ps_quote(s: &str) -> String {
    let mut out = String::with_capacity(s.len() + 2);
    out.push('\'');
    for c in s.chars() {
        if matches!(c, '\'' | '\u{2018}' | '\u{2019}' | '\u{201A}' | '\u{201B}') {
            out.push(c);
        }
        out.push(c);
    }
    out.push('\'');
    out
}

fn diskpart_steps(file: &str) -> String {
    format!(
        "   Without Hyper-V (Windows Home), use diskpart in an elevated terminal instead:\n   diskpart\n   select vdisk file=\"{file}\"\n   attach vdisk readonly\n   compact vdisk\n   detach vdisk\n   exit"
    )
}

/// `...\Packages\CanonicalGroupLimited.Ubuntu22.04LTS_79rhkp1fndgsc\LocalState\ext4.vhdx` → `Ubuntu22.04LTS`.
fn distro_from_path(path: &std::path::Path) -> Option<String> {
    let package = path.parent()?.parent()?.file_name()?.to_string_lossy().to_string();
    let parent_is_local_state = path.parent()?.file_name()?.to_string_lossy().eq_ignore_ascii_case("LocalState");
    if !parent_is_local_state {
        return None;
    }
    let family = package.split('_').next().unwrap_or(package.as_str());
    let name = family.split_once('.').map(|(_, rest)| rest).unwrap_or(family);
    (!name.is_empty()).then(|| name.to_string())
}

/// WSL distros registered for this user: `HKCU\Software\Microsoft\Windows\CurrentVersion\Lxss`.
#[cfg(windows)]
fn registry_disks() -> Vec<Disk> {
    use winreg::enums::HKEY_CURRENT_USER;
    use winreg::RegKey;
    let mut out = Vec::new();
    let Ok(lxss) = RegKey::predef(HKEY_CURRENT_USER).open_subkey(r"Software\Microsoft\Windows\CurrentVersion\Lxss") else {
        return out;
    };
    for sub in lxss.enum_keys().flatten() {
        let Ok(key) = lxss.open_subkey(&sub) else { continue };
        let distro: Option<String> = key.get_value("DistributionName").ok();
        let base: Option<String> = key.get_value("BasePath").ok();
        let vhd: String = key.get_value("VhdFileName").unwrap_or_else(|_| "ext4.vhdx".to_string());
        if let Some(base) = base {
            // Never touch a network path while scanning (Windows would connect and send the
            // user's credentials).
            let norm = paths::normalize(&base);
            if norm.starts_with(r"\\") {
                continue;
            }
            let base = PathBuf::from(norm);
            out.push(Disk { path: base.join(vhd), distro });
        }
    }
    out
}

#[cfg(not(windows))]
fn registry_disks() -> Vec<Disk> {
    Vec::new()
}

#[cfg(test)]
mod tests {
    use super::ps_quote;

    #[test]
    fn powershell_literals_are_inert() {
        assert_eq!(ps_quote(r"C:\Users\me\ext4.vhdx"), r"'C:\Users\me\ext4.vhdx'");
        assert_eq!(ps_quote("it's"), "'it''s'");
        assert_eq!(ps_quote("a\u{2019}b"), "'a\u{2019}\u{2019}b'");
        assert_eq!(ps_quote("$(calc)`n"), "'$(calc)`n'");
    }
}
