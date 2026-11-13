//! Where things live on this machine. Tests build one around a temporary "user profile".

use std::path::{Path, PathBuf};

#[derive(Debug, Clone)]
pub struct ScanEnv {
    /// `%USERPROFILE%`
    pub home: PathBuf,
    /// `%LOCALAPPDATA%`
    pub local: PathBuf,
    /// `%APPDATA%`
    pub roaming: PathBuf,
    /// `%TEMP%`
    pub temp: PathBuf,
    /// `%CARGO_HOME%` or `~\.cargo`
    pub cargo_home: PathBuf,
    /// `%GRADLE_USER_HOME%` or `~\.gradle`
    pub gradle_home: PathBuf,
    /// `%NUGET_PACKAGES%` or `~\.nuget\packages`
    pub nuget_packages: PathBuf,
    /// `%GOCACHE%` or `%LOCALAPPDATA%\go-build`
    pub go_cache: PathBuf,
    /// `%GOMODCACHE%`, `%GOPATH%\pkg\mod` or `~\go\pkg\mod`
    pub go_mod: PathBuf,
    /// `%HF_HOME%` or `~\.cache\huggingface`
    pub hf_home: PathBuf,
    /// `%OLLAMA_MODELS%` or `~\.ollama\models`
    pub ollama_models: PathBuf,
    /// `%DENO_DIR%` or `%LOCALAPPDATA%\deno`
    pub deno_dir: PathBuf,
    /// `%ANDROID_HOME%`, `%ANDROID_SDK_ROOT%` or `%LOCALAPPDATA%\Android\Sdk`
    pub android_sdk: PathBuf,
    /// Folders searched for projects (default: the user profile).
    pub project_roots: Vec<PathBuf>,
    /// SpaceSaver's own data folder, never scanned.
    pub data_dir: Option<PathBuf>,
    /// A project with no commits or root-file edits for this many days is dormant.
    pub dormant_days: u64,
    /// Temp entries untouched for this many days are offered for cleanup.
    pub temp_age_days: u64,
    /// Items smaller than this are not reported.
    pub min_bytes: u64,
    /// "Now" in Unix seconds.
    pub now: i64,
    /// Read WSL distros from the registry.
    pub use_registry: bool,
    /// Block caches of running apps.
    pub check_processes: bool,
}

impl ScanEnv {
    /// Default layout for a Windows user profile at `home`.
    pub fn for_home(home: &Path) -> Self {
        let home = home.to_path_buf();
        let local = home.join("AppData").join("Local");
        let roaming = home.join("AppData").join("Roaming");
        ScanEnv {
            temp: local.join("Temp"),
            cargo_home: home.join(".cargo"),
            gradle_home: home.join(".gradle"),
            nuget_packages: home.join(".nuget").join("packages"),
            go_cache: local.join("go-build"),
            go_mod: home.join("go").join("pkg").join("mod"),
            hf_home: home.join(".cache").join("huggingface"),
            ollama_models: home.join(".ollama").join("models"),
            deno_dir: local.join("deno"),
            android_sdk: local.join("Android").join("Sdk"),
            project_roots: vec![home.clone()],
            data_dir: None,
            dormant_days: 45,
            temp_age_days: 7,
            min_bytes: 1_000_000,
            now: crate::fsutil::now(),
            use_registry: false,
            check_processes: false,
            home,
            local,
            roaming,
        }
    }

    /// The current user's environment, honouring tool-specific overrides such as `CARGO_HOME`.
    pub fn from_system() -> Self {
        let home = var_path("USERPROFILE")
            .or_else(|| var_path("HOME"))
            .unwrap_or_else(|| PathBuf::from(r"C:\Users\Default"));
        let mut env = ScanEnv::for_home(&home);
        if let Some(p) = var_path("LOCALAPPDATA") {
            env.local = p;
        }
        if let Some(p) = var_path("APPDATA") {
            env.roaming = p;
        }
        // %TEMP% often uses an 8.3 short name (C:\Users\RUNNER~1\...); resolve it for display.
        let temp = std::env::temp_dir();
        env.temp = std::fs::canonicalize(&temp)
            .map(|p| PathBuf::from(crate::paths::normalize(&p.to_string_lossy())))
            .unwrap_or(temp);
        env.cargo_home = var_path("CARGO_HOME").unwrap_or(env.cargo_home);
        env.gradle_home = var_path("GRADLE_USER_HOME").unwrap_or(env.gradle_home);
        env.nuget_packages = var_path("NUGET_PACKAGES").unwrap_or(env.nuget_packages);
        env.go_cache = var_path("GOCACHE").unwrap_or_else(|| env.local.join("go-build"));
        env.go_mod = var_path("GOMODCACHE")
            .or_else(|| var_path("GOPATH").map(|p| p.join("pkg").join("mod")))
            .unwrap_or(env.go_mod);
        env.hf_home = var_path("HF_HOME").unwrap_or(env.hf_home);
        env.ollama_models = var_path("OLLAMA_MODELS").unwrap_or(env.ollama_models);
        env.deno_dir = var_path("DENO_DIR").unwrap_or_else(|| env.local.join("deno"));
        env.android_sdk = var_path("ANDROID_HOME")
            .or_else(|| var_path("ANDROID_SDK_ROOT"))
            .unwrap_or_else(|| env.local.join("Android").join("Sdk"));
        env.data_dir = Some(crate::store::default_data_dir());
        env.use_registry = true;
        env.check_processes = true;
        env
    }
}

impl ScanEnv {
    /// Why `self.temp` can't be trusted as a temp folder, if it can't. See [`temp_problem`].
    pub fn temp_problem(&self) -> Option<String> {
        temp_problem(&self.temp, &self.home, &self.local)
    }
}

/// Why `temp` doesn't look like a real temp folder, or `None` when it does. Old files in it are
/// only offered, and it is only an allowed place to delete from, when it does.
///
/// A temp folder is `%LOCALAPPDATA%\Temp` (or a folder inside it, such as a Remote Desktop
/// session's `Temp\2`), or a folder named `Temp` or `Tmp`, that is not a drive or share root,
/// not the profile or a folder above it, not a top-level folder of the profile, not inside
/// Desktop, Documents, Downloads, Pictures, Music, Videos, Favorites or OneDrive, and not a
/// Windows system folder.
pub fn temp_problem(temp: &Path, home: &Path, local: &Path) -> Option<String> {
    use crate::paths::{is_within, key};
    let canon = canonical_key;
    let t = canon(temp);
    let h = canon(home);
    let shown = crate::paths::normalize(&temp.to_string_lossy());
    let why = |reason: &str| Some(format!("TEMP points to {shown}, {reason}, so SpaceSaver doesn't treat it as a temp folder"));

    let parent = Path::new(&t).parent().map(|p| key(&p.to_string_lossy()));
    let Some(parent) = parent else { return why("the root of a drive or network share") };
    if is_within(&h, &t) {
        return why("which is your user profile or a folder above it");
    }
    if parent == h {
        return why("a top-level folder of your user profile");
    }
    let mut personal: Vec<String> = ["Desktop", "Documents", "Downloads", "Pictures", "Music", "Videos", "Favorites"]
        .iter()
        .map(|sub| key(&format!(r"{h}\{sub}")))
        .collect();
    for var in ["OneDrive", "OneDriveConsumer", "OneDriveCommercial"] {
        if let Some(p) = std::env::var_os(var).filter(|v| !v.is_empty()) {
            personal.push(canon(Path::new(&p)));
        }
    }
    if personal.iter().any(|p| is_within(&t, p)) {
        return why("inside one of your personal folders");
    }
    for sys in crate::safety::system_dirs() {
        let s = canon(&sys);
        if is_within(&t, &s) || is_within(&s, &t) {
            return why("a Windows system folder");
        }
    }
    let default_temp = canon(&local.join("Temp"));
    let name = crate::paths::name(&t);
    if is_within(&t, &default_temp) || name == "temp" || name == "tmp" {
        return None;
    }
    why("which isn't named Temp or Tmp")
}

/// Comparison key of `p` with links and 8.3 names resolved. A path that doesn't exist yet is
/// resolved through its nearest existing parent.
fn canonical_key(p: &Path) -> String {
    let mut tail: Vec<std::ffi::OsString> = Vec::new();
    let mut current = p.to_path_buf();
    loop {
        if let Ok(resolved) = std::fs::canonicalize(&current) {
            let mut full = resolved;
            for part in tail.iter().rev() {
                full.push(part);
            }
            return crate::paths::key(&full.to_string_lossy());
        }
        match (current.file_name().map(|n| n.to_os_string()), current.parent()) {
            (Some(name), Some(parent)) => {
                tail.push(name);
                current = parent.to_path_buf();
            }
            _ => return crate::paths::key(&p.to_string_lossy()),
        }
    }
}

fn var_path(name: &str) -> Option<PathBuf> {
    let v = std::env::var_os(name)?;
    if v.is_empty() {
        return None;
    }
    // GOPATH may hold several entries; use the first.
    let s = v.to_string_lossy();
    let first = s.split(';').next().unwrap_or("").trim();
    if first.is_empty() {
        None
    } else {
        Some(PathBuf::from(first))
    }
}
