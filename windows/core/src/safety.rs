//! The last line of defence. Every removal, from the app or the CLI, goes through
//! [`SafetyGuard::validate`] first.

use crate::fsutil::is_reparse;
use crate::paths::{self, is_within, key};
use std::fmt;
use std::fs;
use std::path::{Path, PathBuf};

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum SafetyError {
    NotAbsolute(String),
    Missing(String),
    Protected { path: String, reason: String },
    OutsideAllowed(String),
}

impl fmt::Display for SafetyError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            SafetyError::NotAbsolute(p) => write!(f, "Not an absolute path: {p}"),
            SafetyError::Missing(p) => write!(f, "No longer exists: {p}"),
            SafetyError::Protected { path, reason } => write!(f, "Protected ({reason}): {path}"),
            SafetyError::OutsideAllowed(p) => {
                write!(f, "Outside your user profile and temp folder, so SpaceSaver won't touch it: {p}")
            }
        }
    }
}

impl std::error::Error for SafetyError {}

/// What the guard protects. [`GuardConfig::from_system`] reads the real machine; tests point
/// `home` and `temp` at temporary folders.
#[derive(Debug, Clone)]
pub struct GuardConfig {
    /// The user profile. Only paths inside it (or inside `temp`) may be removed.
    pub home: PathBuf,
    pub temp: PathBuf,
    /// `%LOCALAPPDATA%` and `%APPDATA%` when they're not in the default place.
    pub local: Option<PathBuf>,
    pub roaming: Option<PathBuf>,
    /// SpaceSaver's own data folder.
    pub data_dir: Option<PathBuf>,
    /// Windows, Program Files, ProgramData and friends.
    pub system_dirs: Vec<PathBuf>,
    /// More folders that must never be removed themselves (OneDrive roots, for example).
    pub extra_protected: Vec<PathBuf>,
}

impl GuardConfig {
    /// A guard for `home` and `temp` that also refuses the real system folders.
    pub fn for_home(home: &Path, temp: &Path) -> Self {
        GuardConfig {
            home: home.to_path_buf(),
            temp: temp.to_path_buf(),
            local: None,
            roaming: None,
            data_dir: None,
            system_dirs: system_dirs(),
            extra_protected: Vec::new(),
        }
    }

    pub fn from_system() -> Self {
        let env = crate::env::ScanEnv::from_system();
        let mut cfg = GuardConfig::for_home(&env.home, &env.temp);
        cfg.local = Some(env.local.clone());
        cfg.roaming = Some(env.roaming.clone());
        cfg.data_dir = env.data_dir.clone();
        for var in ["OneDrive", "OneDriveConsumer", "OneDriveCommercial"] {
            if let Some(p) = std::env::var_os(var).filter(|v| !v.is_empty()) {
                let p = PathBuf::from(p);
                for sub in ["Desktop", "Documents", "Pictures"] {
                    cfg.extra_protected.push(p.join(sub));
                }
                cfg.extra_protected.push(p);
            }
        }
        cfg
    }
}

/// Windows system folders, from the environment plus the defaults on the system drive.
pub fn system_dirs() -> Vec<PathBuf> {
    let mut dirs = Vec::new();
    for var in ["SystemRoot", "windir", "ProgramFiles", "ProgramFiles(x86)", "ProgramW6432", "ProgramData", "ALLUSERSPROFILE", "PUBLIC"] {
        if let Some(v) = std::env::var_os(var).filter(|v| !v.is_empty()) {
            dirs.push(PathBuf::from(v));
        }
    }
    let drive = std::env::var("SystemDrive").unwrap_or_else(|_| "C:".to_string());
    for sub in [
        "Windows",
        "Program Files",
        "Program Files (x86)",
        "ProgramData",
        "$Recycle.Bin",
        "System Volume Information",
        "Recovery",
        "Boot",
        r"Users\Public",
        r"Users\Default",
        r"Users\All Users",
    ] {
        dirs.push(PathBuf::from(format!(r"{drive}\{sub}")));
    }
    dirs
}

/// Validates paths before removal. See the README's safety model.
#[derive(Debug, Clone)]
pub struct SafetyGuard {
    homes: Vec<String>,
    allowed: Vec<String>,
    protected_exact: Vec<String>,
    system: Vec<String>,
    sensitive: Vec<(String, &'static str)>,
}

/// The lexical key and, when it exists, the canonical key (junctions and 8.3 names resolved).
fn variants(path: &Path) -> Vec<String> {
    let mut out = vec![key(&path.to_string_lossy())];
    if let Ok(canon) = fs::canonicalize(path) {
        let k = key(&canon.to_string_lossy());
        if !out.contains(&k) {
            out.push(k);
        }
    }
    out
}

fn protected(path: &str, reason: &str) -> SafetyError {
    SafetyError::Protected { path: path.to_string(), reason: reason.to_string() }
}

impl SafetyGuard {
    pub fn new(cfg: GuardConfig) -> Self {
        let homes = variants(&cfg.home);
        let temps = variants(&cfg.temp);
        let mut allowed = homes.clone();
        allowed.extend(temps.iter().cloned());

        let mut protected_exact: Vec<String> = Vec::new();
        let mut sensitive: Vec<(String, &'static str)> = Vec::new();
        for h in &homes {
            protected_exact.push(h.clone());
            for sub in [
                "Desktop",
                "Documents",
                "Downloads",
                "Pictures",
                "Music",
                "Videos",
                "Favorites",
                "AppData",
                r"AppData\Local",
                r"AppData\Roaming",
                r"AppData\LocalLow",
                r"AppData\Local\Temp",
                r"AppData\Local\Packages",
                r"AppData\Local\Programs",
                r"AppData\Local\Microsoft",
                r"AppData\Roaming\Microsoft",
                r"AppData\Local\Docker",
                r".cache",
                r".config",
            ] {
                protected_exact.push(key(&format!(r"{h}\{sub}")));
            }
            for (sub, reason) in [
                (".ssh", "SSH keys"),
                (".gnupg", "GPG keys"),
                (r"AppData\Roaming\gnupg", "GPG keys"),
                (".aws", "AWS credentials"),
                (".azure", "Azure credentials"),
                (".kube", "Kubernetes config"),
                (".docker", "Docker config and credentials"),
                (r".config\gh", "GitHub CLI credentials"),
                (r"AppData\Roaming\Microsoft\Credentials", "Windows credentials"),
                (r"AppData\Local\Microsoft\Credentials", "Windows credentials"),
                (r"AppData\Roaming\Microsoft\Protect", "Windows data protection keys"),
                (r"AppData\Roaming\Microsoft\SystemCertificates", "certificates"),
                (r"AppData\Local\SpaceSaver", "SpaceSaver data"),
            ] {
                sensitive.push((key(&format!(r"{h}\{sub}")), reason));
            }
        }
        for t in &temps {
            protected_exact.push(t.clone());
        }
        for p in cfg.local.iter().chain(cfg.roaming.iter()).chain(cfg.extra_protected.iter()) {
            protected_exact.extend(variants(p));
        }
        if let Some(d) = &cfg.data_dir {
            for k in variants(d) {
                sensitive.push((k, "SpaceSaver data"));
            }
        }
        let mut system = Vec::new();
        for d in &cfg.system_dirs {
            for k in variants(d) {
                if !system.contains(&k) {
                    system.push(k);
                }
            }
        }
        SafetyGuard { homes, allowed, protected_exact, system, sensitive }
    }

    /// Checks that `raw` may be moved to the Recycle Bin and returns the resolved path to use.
    ///
    /// Refused: relative paths, missing paths, drive roots, Windows system folders, the user
    /// profile and its top-level folders, AppData roots, credential folders (`.ssh`, `.aws`,
    /// `.gnupg`, `.kube`, `.docker`...), anything inside a `.git` folder, any reparse point
    /// (symlink, junction...) and anything that isn't inside the user profile or `%TEMP%`
    /// once junctions and short names in its parent are resolved.
    pub fn validate(&self, raw: &Path) -> Result<PathBuf, SafetyError> {
        let raw_s = raw.to_string_lossy().to_string();
        if !paths::is_absolute(&raw_s) {
            return Err(SafetyError::NotAbsolute(raw_s));
        }
        let lexical = paths::normalize(&raw_s);
        let lexical_path = PathBuf::from(&lexical);
        let lex_key = key(&lexical);
        self.check_rules(&lexical, &lex_key)?;

        let meta = fs::symlink_metadata(&lexical_path).map_err(|_| SafetyError::Missing(lexical.clone()))?;
        if is_reparse(&meta) {
            return Err(protected(&lexical, "link, junction or other reparse point"));
        }
        let (Some(parent), Some(name)) = (lexical_path.parent(), lexical_path.file_name()) else {
            return Err(protected(&lexical, "drive root"));
        };

        // Resolve junctions, symlinks and 8.3 short names in the parent chain, so
        // "~\link-to-somewhere\x" is judged by where it really is.
        let canon_parent = fs::canonicalize(parent).map_err(|_| SafetyError::Missing(lexical.clone()))?;
        let resolved = paths::normalize(&canon_parent.join(name).to_string_lossy());
        let res_key = key(&resolved);
        if res_key != lex_key {
            self.check_rules(&resolved, &res_key)?;
        }
        if !self.allowed.iter().any(|root| is_within(&res_key, root) && &res_key != root) {
            return Err(SafetyError::OutsideAllowed(resolved));
        }
        Ok(PathBuf::from(resolved))
    }

    pub fn is_allowed(&self, path: &Path) -> bool {
        self.validate(path).is_ok()
    }

    fn check_rules(&self, shown: &str, k: &str) -> Result<(), SafetyError> {
        let parent_key = Path::new(k).parent().map(|p| key(&p.to_string_lossy()));
        if parent_key.is_none() {
            return Err(protected(shown, "drive root"));
        }
        for sys in &self.system {
            if is_within(k, sys) || is_within(sys, k) {
                return Err(protected(shown, "Windows system folder"));
            }
        }
        for root in &self.protected_exact {
            if is_within(root, k) {
                return Err(protected(shown, "user profile or AppData folder"));
            }
        }
        if let Some(parent) = &parent_key {
            if self.homes.iter().any(|h| h == parent) {
                return Err(protected(shown, "top-level folder of your user profile"));
            }
        }
        for (tree, reason) in &self.sensitive {
            if is_within(k, tree) || is_within(tree, k) {
                return Err(protected(shown, reason));
            }
        }
        if k.split('\\').any(|c| c == ".git") {
            return Err(protected(shown, "git repository data"));
        }
        Ok(())
    }
}
