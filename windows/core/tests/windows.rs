//! Integration tests. They create real files, junctions and git metadata in a temporary
//! "user profile", so they only run on Windows.
#![cfg(windows)]

use spacesaver_core::activity::{ActivityEntry, ActivityLog};
use spacesaver_core::cleanup::{pick_bin_item, CleanOptions, Cleaner, RecycleBinSettings, RestoreRequest, Trasher};
use spacesaver_core::model::{Category, CleanupItem, Method, Risk};
use spacesaver_core::paths;
use spacesaver_core::safety::{GuardConfig, SafetyError, SafetyGuard};
use spacesaver_core::{
    caches, fsutil, projects, scan, wsl, ActivityStatus, RecycleBinInfo, ScanEnv, ScanOptions, Store,
};
use std::collections::HashMap;
use std::fs;
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicUsize, Ordering};
use std::sync::Mutex;
use std::time::{Duration, SystemTime};
use tempfile::TempDir;

// ---------- helpers ----------

struct Sandbox {
    tmp: TempDir,
    home: PathBuf,
    temp: PathBuf,
}

impl Sandbox {
    fn new() -> Self {
        let tmp = tempfile::tempdir().unwrap();
        let home = tmp.path().join("home");
        let temp = home.join(r"AppData\Local\Temp");
        fs::create_dir_all(&temp).unwrap();
        Sandbox { tmp, home, temp }
    }

    fn env(&self) -> ScanEnv {
        let mut env = ScanEnv::for_home(&self.home);
        env.min_bytes = 1;
        env
    }

    fn guard(&self) -> SafetyGuard {
        SafetyGuard::new(GuardConfig::for_home(&self.home, &self.temp))
    }

    fn outside(&self) -> PathBuf {
        self.tmp.path().join("outside")
    }
}

fn write(path: &Path, bytes: usize) {
    fs::create_dir_all(path.parent().unwrap()).unwrap();
    fs::write(path, vec![7u8; bytes]).unwrap();
}

fn age(path: &Path, days: u64) {
    let when = SystemTime::now() - Duration::from_secs(days * 86_400);
    let file = fs::OpenOptions::new().write(true).open(path).unwrap();
    file.set_modified(when).unwrap();
}

/// A Node project with a 2 KB node_modules whose root files were last touched `days` ago.
fn node_project(root: &Path, days: u64) -> PathBuf {
    write(&root.join("package.json"), 20);
    write(&root.join("package-lock.json"), 20);
    write(&root.join(r"node_modules\left-pad\index.js"), 2048);
    age(&root.join("package.json"), days);
    age(&root.join("package-lock.json"), days);
    root.join("node_modules")
}

fn find<'a>(items: &'a [CleanupItem], suffix: &str) -> Option<&'a CleanupItem> {
    let suffix = suffix.to_lowercase();
    items.iter().find(|i| i.paths.iter().any(|p| p.to_lowercase().ends_with(&suffix)))
}

/// One thing in the fake Recycle Bin.
struct BinItem {
    key: String,
    time_deleted: i64,
    dest: PathBuf,
}

/// Moves things into a folder instead of the Recycle Bin, and restores them the way
/// `SystemTrash` does: by original path, choosing among same-path items with `pick_bin_item`.
struct FakeTrash {
    bin: PathBuf,
    items: Mutex<Vec<BinItem>>,
    counter: AtomicUsize,
}

impl FakeTrash {
    fn new(bin: PathBuf) -> Self {
        fs::create_dir_all(&bin).unwrap();
        FakeTrash { bin, items: Mutex::new(Vec::new()), counter: AtomicUsize::new(0) }
    }

    /// Items in the bin.
    fn count(&self) -> usize {
        self.items.lock().unwrap().len()
    }

    /// Puts a folder that "was deleted from `original` at `time_deleted`" in the bin, holding
    /// one file called `marker`.
    fn plant(&self, original: &Path, time_deleted: i64, marker: &str) {
        let n = self.counter.fetch_add(1, Ordering::SeqCst);
        let dest = self.bin.join(format!("planted-{n}"));
        write(&dest.join(marker), 1);
        self.items.lock().unwrap().push(BinItem { key: paths::key_of(original), time_deleted, dest });
    }
}

impl Trasher for FakeTrash {
    fn trash(&self, path: &Path) -> Result<(), String> {
        let n = self.counter.fetch_add(1, Ordering::SeqCst);
        let dest = self.bin.join(n.to_string());
        fs::rename(path, &dest).map_err(|e| e.to_string())?;
        self.items.lock().unwrap().push(BinItem { key: paths::key_of(path), time_deleted: fsutil::now(), dest });
        Ok(())
    }

    fn restore(&self, requests: &[RestoreRequest]) -> Vec<Result<(), String>> {
        requests
            .iter()
            .map(|req| {
                let mut items = self.items.lock().unwrap();
                let want = paths::key_of(&req.original);
                let candidates: Vec<(usize, i64)> = items
                    .iter()
                    .enumerate()
                    .filter(|(_, it)| it.key == want)
                    .map(|(i, it)| (i, it.time_deleted))
                    .collect();
                let index = pick_bin_item(&candidates, req).ok_or("not in bin")?;
                let item = items.remove(index);
                fs::create_dir_all(req.original.parent().unwrap()).map_err(|e| e.to_string())?;
                fs::rename(&item.dest, &req.original).map_err(|e| e.to_string())
            })
            .collect()
    }
}

/// Fails (like a crash) once `allow` items have been moved.
struct CrashingTrash {
    inner: FakeTrash,
    allow: usize,
}

impl Trasher for CrashingTrash {
    fn trash(&self, path: &Path) -> Result<(), String> {
        if self.inner.count() >= self.allow {
            panic!("simulated crash in the middle of a cleanup");
        }
        self.inner.trash(path)
    }

    fn restore(&self, requests: &[RestoreRequest]) -> Vec<Result<(), String>> {
        self.inner.restore(requests)
    }
}

/// Recycle Bin settings for pretend drives: a path with a `drive-x` folder in it is on `X:\`,
/// and so on; `drive-net` has no bin. Records which drives were asked about.
struct FakeBins {
    drives: HashMap<String, Result<RecycleBinInfo, String>>,
    asked: Mutex<Vec<String>>,
}

impl FakeBins {
    fn new() -> Self {
        FakeBins { drives: HashMap::new(), asked: Mutex::new(Vec::new()) }
    }

    fn drive(mut self, drive: &str, max_bytes: u64, disabled: bool) -> Self {
        self.drives.insert(drive.to_string(), Ok(RecycleBinInfo { drive: drive.to_string(), max_bytes, disabled }));
        self
    }

    fn unreadable(mut self, drive: &str) -> Self {
        self.drives.insert(drive.to_string(), Err("access denied".to_string()));
        self
    }
}

impl RecycleBinSettings for FakeBins {
    fn bin_of(&self, path: &Path) -> Option<String> {
        let s = path.to_string_lossy().to_lowercase();
        let marker = s.split('\\').find_map(|c| c.strip_prefix("drive-"))?;
        if marker == "net" {
            return None;
        }
        Some(format!("{}:\\", marker.to_uppercase()))
    }

    fn settings(&self, drive: &str) -> Result<RecycleBinInfo, String> {
        self.asked.lock().unwrap().push(drive.to_string());
        self.drives.get(drive).cloned().unwrap_or_else(|| Err("no such drive".to_string()))
    }
}

// ---------- rules and project detection ----------

#[test]
fn artifact_needs_its_manifest() {
    let sb = Sandbox::new();
    let code = sb.home.join("code");
    // Gradle build folder: recognised. A random "build" folder: ignored.
    write(&code.join(r"android-app\build.gradle"), 10);
    write(&code.join(r"android-app\build\out.bin"), 100);
    write(&code.join(r"notes\build\out.bin"), 100);
    // target needs Cargo.toml or pom.xml.
    write(&code.join(r"rusty\Cargo.toml"), 10);
    write(&code.join(r"rusty\target\debug\app.exe"), 100);
    write(&code.join(r"random\target\x.bin"), 100);
    // bin/obj need a .NET project file.
    write(&code.join(r"dotnet\App.csproj"), 10);
    write(&code.join(r"dotnet\bin\Debug\App.dll"), 100);
    write(&code.join(r"dotnet\obj\project.assets.json"), 100);
    write(&code.join(r"scripts\bin\tool.exe"), 100);
    // node_modules without package.json is reported, but as an orphan that isn't recommended.
    write(&code.join(r"leftover\node_modules\x\index.js"), 100);

    let items = projects::analyze(&sb.env());
    assert!(find(&items, r"android-app\build").is_some());
    assert!(find(&items, r"notes\build").is_none());
    assert!(find(&items, r"rusty\target").is_some());
    assert!(find(&items, r"random\target").is_none());
    assert!(find(&items, r"dotnet\bin").is_some());
    assert!(find(&items, r"dotnet\obj").is_some());
    assert!(find(&items, r"scripts\bin").is_none());
    let orphan = find(&items, r"leftover\node_modules").expect("orphan node_modules");
    assert!(!orphan.recommended);
    assert!(orphan.tags.iter().any(|t| t == "Orphaned"));
}

#[test]
fn dormant_projects_are_recommended_active_ones_are_not() {
    let sb = Sandbox::new();
    let code = sb.home.join("code");
    let dormant = node_project(&code.join("old-site"), 120);
    let active = node_project(&code.join("new-site"), 0);

    // Root files are old, but the git reflog shows a commit 3 days ago: active.
    node_project(&code.join("committed"), 200);
    let ts = SystemTime::now().duration_since(SystemTime::UNIX_EPOCH).unwrap().as_secs() - 3 * 86_400;
    write(&code.join(r"committed\.git\HEAD"), 0);
    let reflog = format!("{z} {o} Dev <dev@example.com> {ts} +0000\tcommit: work\n", z = "0".repeat(40), o = "1".repeat(40));
    write(&code.join(r"committed\.git\logs\HEAD"), 0);
    fs::write(code.join(r"committed\.git\logs\HEAD"), reflog).unwrap();
    age(&code.join(r"committed\.git\HEAD"), 200);

    let items = projects::analyze(&sb.env());
    let d = find(&items, &dormant.to_string_lossy()).expect("dormant project");
    assert!(d.recommended, "dormant: {:?}", d.tags);
    assert_eq!(d.risk, Risk::Safe);
    assert!(d.tags.iter().any(|t| t.starts_with("Dormant")), "{:?}", d.tags);
    assert!(d.tags.iter().any(|t| t == "package-lock.json"));

    let a = find(&items, &active.to_string_lossy()).expect("active project");
    assert!(!a.recommended);
    assert_eq!(a.risk, Risk::Review);
    assert!(a.tags.iter().any(|t| t == "Active today"), "{:?}", a.tags);

    let c = find(&items, r"committed\node_modules").expect("committed project");
    assert!(!c.recommended);
    assert!(c.tags.iter().any(|t| t == "Active 3d ago"), "{:?}", c.tags);
    assert!(c.tags.iter().any(|t| t == "git"));
}

#[test]
fn missing_lockfile_needs_review() {
    let sb = Sandbox::new();
    let root = sb.home.join(r"code\nolock");
    write(&root.join("package.json"), 20);
    write(&root.join(r"node_modules\a\index.js"), 100);
    age(&root.join("package.json"), 100);
    let items = projects::analyze(&sb.env());
    let item = find(&items, r"nolock\node_modules").unwrap();
    assert_eq!(item.risk, Risk::Review);
    assert!(!item.recommended);
    assert!(item.tags.iter().any(|t| t == "No lockfile"));
}

#[test]
fn cache_rules_use_windows_locations() {
    let sb = Sandbox::new();
    let local = sb.home.join(r"AppData\Local");
    write(&local.join(r"npm-cache\_cacache\content-v2\sha512\aa\blob"), 4096);
    write(&local.join(r"NuGet\v3-cache\abc\pkg.nupkg"), 4096);
    write(&sb.home.join(r".nuget\packages\newtonsoft.json\13.0.3\lib.dll"), 4096);
    write(&sb.home.join(r".cache\huggingface\hub\models--org--tiny\blobs\x"), 4096);
    write(&sb.home.join(r"AppData\Roaming\Code\CachedData\x"), 4096);
    write(&local.join(r"JetBrains\IntelliJIdea2024.2\caches\index"), 4096);

    let items = caches::analyze(&sb.env(), &Default::default());
    let npm = items.iter().find(|i| i.id == "pkg.npm").expect("npm cache");
    assert_eq!(npm.risk, Risk::Safe);
    assert!(npm.recommended);
    assert_eq!(npm.size, 4096);
    assert!(items.iter().find(|i| i.id == "pkg.nuget.http").unwrap().recommended);
    let packages = items.iter().find(|i| i.id == "pkg.nuget.packages").unwrap();
    assert_eq!(packages.risk, Risk::Review);
    assert!(!packages.recommended);
    let hf = items.iter().find(|i| i.category == Category::AiModels).unwrap();
    assert!(hf.title.ends_with("org/tiny"), "{}", hf.title);
    assert!(items.iter().any(|i| i.id == "ide.code.cache"));
    assert!(items.iter().any(|i| i.title.contains("IntelliJIdea2024.2")));
}

#[test]
fn running_app_blocks_its_cache() {
    let sb = Sandbox::new();
    write(&sb.home.join(r"AppData\Roaming\Code\CachedData\x"), 4096);
    let running = ["code".to_string()].into_iter().collect();
    let items = caches::analyze(&sb.env(), &running);
    let code = items.iter().find(|i| i.id == "ide.code.cache").unwrap();
    assert!(code.blocked_reason.as_deref().unwrap_or("").contains("VS Code"));
    assert!(!code.recommended);
}

#[test]
fn old_temp_files_only() {
    let sb = Sandbox::new();
    write(&sb.temp.join("old-installer.msi"), 4096);
    age(&sb.temp.join("old-installer.msi"), 30);
    write(&sb.temp.join("fresh.log"), 4096);
    let item = caches::old_temp_files(&sb.env()).expect("temp item");
    assert_eq!(item.paths.len(), 1);
    assert!(item.paths[0].ends_with("old-installer.msi"));
    assert!(item.recommended);
}

#[test]
fn wsl_disks_are_reported_but_never_cleaned() {
    let sb = Sandbox::new();
    let vhdx = sb
        .home
        .join(r"AppData\Local\Packages\CanonicalGroupLimited.Ubuntu22.04LTS_79rhkp1fndgsc\LocalState\ext4.vhdx");
    write(&vhdx, 8192);
    let docker = sb.home.join(r"AppData\Local\Docker\wsl\disk\docker_data.vhdx");
    write(&docker, 8192);

    let items = wsl::analyze(&sb.env());
    assert_eq!(items.len(), 2);
    let ubuntu = items.iter().find(|i| i.title.contains("Ubuntu22.04LTS")).expect("distro name");
    assert!(!ubuntu.recommended);
    match &ubuntu.method {
        Method::Manual { instructions, commands } => {
            assert!(instructions.contains("wsl --shutdown"));
            assert!(instructions.contains("Optimize-VHD"));
            assert!(instructions.contains("compact vdisk"));
            assert!(commands.iter().any(|c| c.contains("--set-sparse true")));
        }
        other => panic!("expected manual, got {other:?}"),
    }
    assert!(items.iter().any(|i| i.title.starts_with("Docker Desktop")));

    // Even if asked to, the cleaner refuses manual items.
    let store = Store::new(sb.tmp.path().join("data"));
    let log = store.activity();
    let fake = FakeTrash::new(sb.tmp.path().join("bin"));
    let guard = sb.guard();
    let report = Cleaner::new(&guard, &fake, &log).clean(&items, &CleanOptions::run("test"), &mut |_| {});
    assert_eq!(report.skipped.len(), 2);
    assert!(vhdx.exists() && docker.exists());
    assert_eq!(fake.count(), 0);
}

// ---------- safety guard ----------

fn assert_protected(guard: &SafetyGuard, path: &Path) {
    match guard.validate(path) {
        Err(SafetyError::Protected { .. }) => {}
        other => panic!("expected {} to be protected, got {other:?}", path.display()),
    }
}

#[test]
fn guard_refuses_system_folders_and_drive_roots() {
    let sb = Sandbox::new();
    let guard = sb.guard();
    let drive = std::env::var("SystemDrive").unwrap_or_else(|_| "C:".into());
    for p in [
        format!(r"{drive}\"),
        format!(r"{drive}\Windows"),
        format!(r"{drive}\Windows\System32"),
        format!(r"{drive}\Program Files"),
        format!(r"{drive}\Program Files (x86)"),
        format!(r"{drive}\ProgramData"),
        format!(r"{drive}\Users"),
        format!(r"\\?\{drive}\WINDOWS\system32"),
        format!(r"{drive}/windows/./system32/.."),
    ] {
        assert_protected(&guard, Path::new(&p));
    }
}

#[test]
fn guard_refuses_profile_and_its_top_level_folders() {
    let sb = Sandbox::new();
    for sub in ["Desktop", "Documents", "Downloads", "Pictures", "Music", "Videos", "OneDrive - Contoso", "projects", r"AppData\Roaming", r".ssh\keys", r".aws\sso", r".docker\contexts"] {
        fs::create_dir_all(sb.home.join(sub)).unwrap();
    }
    let guard = sb.guard();
    assert_protected(&guard, &sb.home);
    assert_protected(&guard, &sb.home.join("Desktop"));
    assert_protected(&guard, &sb.home.join("DOCUMENTS")); // case-insensitive
    assert_protected(&guard, &sb.home.join("Downloads."));
    assert_protected(&guard, &sb.home.join("OneDrive - Contoso"));
    assert_protected(&guard, &sb.home.join("projects"));
    assert_protected(&guard, &sb.home.join("AppData"));
    assert_protected(&guard, &sb.home.join(r"AppData\Local"));
    assert_protected(&guard, &sb.home.join(r"AppData\Roaming"));
    assert_protected(&guard, &sb.home.join(r"AppData\Local\Temp"));
    assert_protected(&guard, &sb.home.join(r".ssh\keys"));
    assert_protected(&guard, &sb.home.join(r".aws\sso"));
    assert_protected(&guard, &sb.home.join(r".docker\contexts"));
}

#[test]
fn guard_refuses_git_internals_and_outside_paths() {
    let sb = Sandbox::new();
    write(&sb.home.join(r"code\app\.git\objects\pack\x.pack"), 10);
    write(&sb.outside().join(r"proj\node_modules\x.js"), 10);
    let guard = sb.guard();
    assert_protected(&guard, &sb.home.join(r"code\app\.git\objects"));
    assert_protected(&guard, &sb.home.join(r"code\app\.GIT"));
    match guard.validate(&sb.outside().join(r"proj\node_modules")) {
        Err(SafetyError::OutsideAllowed(_)) => {}
        other => panic!("expected outside, got {other:?}"),
    }
    assert!(matches!(guard.validate(Path::new(r"relative\path")), Err(SafetyError::NotAbsolute(_))));
    assert!(matches!(guard.validate(&sb.home.join(r"code\missing")), Err(SafetyError::Missing(_))));
}

#[test]
fn guard_allows_regular_artifacts_in_any_spelling() {
    let sb = Sandbox::new();
    let nm = sb.home.join(r"code\app\node_modules");
    write(&nm.join("x.js"), 10);
    write(&sb.temp.join(r"old\file.tmp"), 10);
    let guard = sb.guard();
    assert!(guard.validate(&nm).is_ok());
    let upper = nm.to_string_lossy().to_uppercase();
    assert!(guard.validate(Path::new(&upper)).is_ok());
    assert!(guard.validate(Path::new(&format!(r"\\?\{}", nm.display()))).is_ok());
    assert!(guard.validate(Path::new(&nm.to_string_lossy().replace('\\', "/"))).is_ok());
    assert!(guard.validate(&sb.temp.join("old")).is_ok());
}

// ---------- junctions ----------

#[test]
fn junctions_are_never_followed_or_removed() {
    let sb = Sandbox::new();
    let outside = sb.outside();
    write(&outside.join("big.bin"), 50_000);
    let project = outside.join("proj");
    node_project(&project, 200);
    let code = sb.home.join("code");
    fs::create_dir_all(&code).unwrap();
    write(&code.join(r"real\data.bin"), 1_000);
    let link = code.join("link");
    junction::create(&outside, &link).expect("create junction");
    assert!(junction::exists(&link).unwrap());

    // The sizer counts the real folder once and doesn't go through the junction.
    assert_eq!(fsutil::measure(&code).bytes, 1_000);
    assert_eq!(fsutil::measure(&link).bytes, 0);

    // The project walker doesn't find the project behind the junction.
    let items = projects::analyze(&sb.env());
    assert!(find(&items, r"proj\node_modules").is_none(), "{items:?}");

    // The guard refuses the junction itself and anything reached through it.
    assert_protected(&sb.guard(), &link);
    assert!(sb.guard().validate(&link.join(r"proj\node_modules")).is_err());
    assert!(sb.guard().validate(&link.join("big.bin")).is_err());

    // Expanding cache patterns doesn't walk through junctions either.
    let local = sb.home.join(r"AppData\Local");
    fs::create_dir_all(&local).unwrap();
    junction::create(&outside, local.join("JetBrains")).unwrap();
    assert!(fsutil::expand(&local.join(r"JetBrains\*")).is_empty());
}

// ---------- cleanup, restore, activity ----------

fn dormant_scan(sb: &Sandbox) -> (PathBuf, Vec<CleanupItem>) {
    let nm = node_project(&sb.home.join(r"code\old-app"), 90);
    let summary = scan(&sb.env(), Some(&sb.guard()), &ScanOptions { categories: Some(vec![Category::ProjectArtifacts]) });
    let items: Vec<CleanupItem> = summary.recommended().into_iter().cloned().collect();
    assert_eq!(items.len(), 1, "{:?}", summary.items);
    (nm, items)
}

#[test]
fn dry_run_deletes_nothing() {
    let sb = Sandbox::new();
    let (nm, items) = dormant_scan(&sb);
    let store = Store::new(sb.tmp.path().join("data"));
    let log = store.activity();
    let fake = FakeTrash::new(sb.tmp.path().join("bin"));
    let guard = sb.guard();
    let report = Cleaner::new(&guard, &fake, &log).clean(&items, &CleanOptions::dry_run("test"), &mut |_| {});
    assert!(report.dry_run);
    assert_eq!(report.items.len(), 1);
    assert!(report.bytes > 0);
    assert!(nm.join(r"left-pad\index.js").exists());
    assert_eq!(fake.count(), 0);
    assert!(log.entries().is_empty());
    assert!(report.entry.is_none());
}

#[test]
fn clean_and_restore_round_trip() {
    let sb = Sandbox::new();
    let (nm, items) = dormant_scan(&sb);
    let store = Store::new(sb.tmp.path().join("data"));
    let log = store.activity();
    let fake = FakeTrash::new(sb.tmp.path().join("bin"));
    let guard = sb.guard();
    let cleaner = Cleaner::new(&guard, &fake, &log);

    let mut steps = 0;
    let report = cleaner.clean(&items, &CleanOptions::run("test"), &mut |_| steps += 1);
    assert!(steps >= 2);
    assert!(report.errors.is_empty(), "{:?}", report.errors);
    assert!(!nm.exists());
    assert_eq!(fake.count(), 1);
    assert_eq!(report.moved_ids, vec![items[0].id.clone()]);
    let entry = report.entry.expect("activity entry");
    assert_eq!(entry.status, ActivityStatus::Completed);
    assert_eq!(entry.records.len(), 1);
    assert_eq!(entry.bytes, items[0].size);

    // Restore by a prefix of the id.
    let restored = cleaner.restore(&entry.id[..6]).expect("restore");
    assert_eq!(restored.restored, 1);
    assert!(restored.errors.is_empty(), "{:?}", restored.errors);
    assert!(nm.join(r"left-pad\index.js").exists());
    let saved = log.find(&entry.id).unwrap();
    assert_eq!(saved.status, ActivityStatus::Restored);
    assert!(!saved.can_restore());
    assert!(cleaner.restore(&entry.id).is_err(), "nothing left to restore");
}

#[test]
fn restore_never_overwrites() {
    let sb = Sandbox::new();
    let (nm, items) = dormant_scan(&sb);
    let store = Store::new(sb.tmp.path().join("data"));
    let log = store.activity();
    let fake = FakeTrash::new(sb.tmp.path().join("bin"));
    let guard = sb.guard();
    let cleaner = Cleaner::new(&guard, &fake, &log);
    let entry = cleaner.clean(&items, &CleanOptions::run("test"), &mut |_| {}).entry.unwrap();
    write(&nm.join("new.js"), 5); // something new appeared at the original path
    let report = cleaner.restore(&entry.id).unwrap();
    assert_eq!(report.restored, 0);
    assert_eq!(report.errors.len(), 1);
    assert_eq!(fake.count(), 1);
}

#[test]
fn guard_blocks_cleanup_of_protected_paths_even_if_listed() {
    let sb = Sandbox::new();
    write(&sb.home.join(r"Documents\thesis.docx"), 100);
    let docs = sb.home.join("Documents").to_string_lossy().to_string();
    let item = CleanupItem::new("evil", Category::SystemJunk, "Documents", vec![docs], 100, Risk::Safe);
    let store = Store::new(sb.tmp.path().join("data"));
    let log = store.activity();
    let fake = FakeTrash::new(sb.tmp.path().join("bin"));
    let guard = sb.guard();
    let report = Cleaner::new(&guard, &fake, &log).clean(&[item], &CleanOptions::run("test"), &mut |_| {});
    assert_eq!(fake.count(), 0);
    assert_eq!(report.errors.len(), 1);
    assert!(sb.home.join(r"Documents\thesis.docx").exists());
}

#[test]
fn activity_log_persists() {
    let sb = Sandbox::new();
    let (_nm, items) = dormant_scan(&sb);
    let dir = sb.tmp.path().join("data");
    let fake = FakeTrash::new(sb.tmp.path().join("bin"));
    let guard = sb.guard();
    let log = Store::new(&dir).activity();
    let report = Cleaner::new(&guard, &fake, &log).clean(&items, &CleanOptions::run("cli"), &mut |_| {});
    let id = report.entry.expect("entry").id;
    // A fresh log reading the same file sees the entry.
    let reopened = ActivityLog::new(dir.join("activity.json"));
    let entries = reopened.entries();
    assert_eq!(entries.len(), 1);
    assert_eq!(entries[0].id, id);
    assert_eq!(entries[0].source, "cli");
    assert_eq!(entries[0].records[0].category, Category::ProjectArtifacts);
    assert!(entries[0].can_restore());

    // Last scan round-trips too.
    let store = Store::new(&dir);
    let summary = scan(&sb.env(), None, &ScanOptions::default());
    store.save_scan(&summary).unwrap();
    let loaded = store.load_scan().unwrap();
    assert_eq!(loaded.items.len(), summary.items.len());
}

#[test]
fn full_scan_summarises_categories() {
    let sb = Sandbox::new();
    node_project(&sb.home.join(r"code\old-app"), 90);
    write(&sb.home.join(r"AppData\Local\pip\Cache\http-v2\a"), 4096);
    let summary = scan(&sb.env(), Some(&sb.guard()), &ScanOptions::default());
    let projects = summary.categories.iter().find(|c| c.id == Category::ProjectArtifacts).unwrap();
    assert_eq!(projects.count, 1);
    let caches = summary.categories.iter().find(|c| c.id == Category::PackageCaches).unwrap();
    assert_eq!(caches.size, 4096);
    assert_eq!(caches.recommended_size, 4096);
    assert!(summary.recommended_size() > 4096);
    let json = serde_json::to_string(&summary).unwrap();
    assert!(json.contains("\"recommendedSize\""));
    assert!(json.contains("\"kind\":\"recycleBin\""));
}

// ---------- 8.3 short names ----------

/// The 8.3 short name of `path`'s last component, or `None` when the volume doesn't create
/// them (or this name doesn't need one).
fn short_name(path: &Path) -> Option<String> {
    use std::ffi::OsString;
    use std::os::windows::ffi::{OsStrExt, OsStringExt};
    use windows_sys::Win32::Storage::FileSystem::GetShortPathNameW;
    let wide: Vec<u16> = path.as_os_str().encode_wide().chain(Some(0)).collect();
    let mut buf = vec![0u16; 2048];
    // SAFETY: `wide` is NUL-terminated and `buf` has the length we pass.
    let n = unsafe { GetShortPathNameW(wide.as_ptr(), buf.as_mut_ptr(), buf.len() as u32) } as usize;
    if n == 0 || n >= buf.len() {
        return None;
    }
    let short = PathBuf::from(OsString::from_wide(&buf[..n]));
    let last = short.file_name()?.to_string_lossy().to_string();
    let long = path.file_name()?.to_string_lossy().to_string();
    (!last.eq_ignore_ascii_case(&long)).then_some(last)
}

#[test]
fn guard_resolves_short_names_in_the_last_component() {
    let sb = Sandbox::new();
    let microsoft = sb.home.join(r"AppData\Roaming\Microsoft");
    let credentials = microsoft.join("Credentials");
    let spacesaver = sb.home.join(r"AppData\Local\SpaceSaver");
    let git = sb.home.join(r"code\app\.git");
    let regular = sb.home.join(r"code\app\node_modules_cache");
    write(&credentials.join("blob"), 10);
    write(&spacesaver.join("activity.json"), 10);
    write(&git.join("HEAD"), 10);
    write(&regular.join("x.js"), 10);
    let guard = sb.guard();

    let mut checked = 0;
    for target in [&microsoft, &credentials, &spacesaver, &git] {
        let Some(short) = short_name(target) else {
            eprintln!("no 8.3 name for {}; skipped", target.display());
            continue;
        };
        // Only the last component is short: the parent is spelled out in full.
        let spelled = target.parent().unwrap().join(&short);
        assert_ne!(paths::key_of(&spelled), paths::key_of(target));
        assert_protected(&guard, &spelled);
        checked += 1;
    }
    if let Some(short) = short_name(&regular) {
        let resolved = guard.validate(&regular.parent().unwrap().join(&short)).expect("a regular folder by its short name");
        assert!(
            resolved.to_string_lossy().to_lowercase().ends_with(r"\node_modules_cache"),
            "the guard returns the long name: {}",
            resolved.display()
        );
        checked += 1;
    }
    if checked == 0 {
        eprintln!("8.3 short names are disabled on this volume; nothing to check");
    } else {
        eprintln!("checked {checked} paths spelled with 8.3 short names");
    }
}

// ---------- Recycle Bin limits ----------

fn item_at(sb: &Sandbox, id: &str, rel: &str, size: u64) -> (PathBuf, CleanupItem) {
    let path = sb.home.join(rel);
    write(&path.join("data.bin"), 16);
    let item = CleanupItem::new(id, Category::SystemJunk, id, vec![path.to_string_lossy().to_string()], size, Risk::Safe);
    (path, item)
}

#[test]
fn recycle_bin_limits_are_per_drive_cumulative_and_fail_closed() {
    let sb = Sandbox::new();
    let (x1, x1_item) = item_at(&sb, "x1", r"code\drive-x\one", 2_000);
    let (x2, x2_item) = item_at(&sb, "x2", r"code\drive-x\two", 2_000);
    let (w, w_item) = item_at(&sb, "w", r"code\drive-w\big", 2_000);
    let (y1, y1_item) = item_at(&sb, "y1", r"code\drive-y\one", 10);
    let (y2, y2_item) = item_at(&sb, "y2", r"code\drive-y\two", 10);
    let (z, z_item) = item_at(&sb, "z", r"code\drive-z\one", 10);
    let (net, net_item) = item_at(&sb, "net", r"code\drive-net\one", 10);
    let items = vec![x1_item, x2_item, w_item, y1_item, y2_item, z_item, net_item];
    let bins = FakeBins::new().drive("X:\\", 3_000, false).drive("W:\\", 1_000, false).unreadable("Y:\\").drive("Z:\\", 1 << 40, true);

    let store = Store::new(sb.tmp.path().join("data"));
    let log = store.activity();
    let fake = FakeTrash::new(sb.tmp.path().join("bin"));
    let guard = sb.guard();
    let cleaner = Cleaner::new(&guard, &fake, &log).with_recycle_bin(&bins);

    let check = |report: &spacesaver_core::CleanReport| {
        let reason = |id: &str| {
            report.skipped.iter().find(|s| s.id == id).map(|s| s.reason.clone()).unwrap_or_else(|| panic!("{id} not skipped: {report:?}"))
        };
        assert_eq!(report.items.iter().map(|i| i.id.as_str()).collect::<Vec<_>>(), vec!["x1"]);
        assert!(reason("x2").contains("already moved"), "{}", reason("x2"));
        assert!(reason("w").contains("Too big"), "{}", reason("w"));
        assert!(reason("y1").contains("Couldn't read the Recycle Bin settings"), "{}", reason("y1"));
        assert!(reason("y2").contains("Couldn't read the Recycle Bin settings"), "{}", reason("y2"));
        assert!(reason("z").contains("turned off"), "{}", reason("z"));
        assert!(reason("net").contains("no Recycle Bin"), "{}", reason("net"));
    };

    // The dry run reports the same refusals and moves nothing.
    let dry = cleaner.clean(&items, &CleanOptions::dry_run("test"), &mut |_| {});
    check(&dry);
    assert_eq!(fake.count(), 0);

    let report = cleaner.clean(&items, &CleanOptions::run("test"), &mut |_| {});
    check(&report);
    assert!(!x1.exists());
    for p in [&x2, &w, &y1, &y2, &z, &net] {
        assert!(p.exists(), "{} should not have moved", p.display());
    }
    assert_eq!(fake.count(), 1);

    // Each drive's settings were read once per run (Y only once despite two items).
    let mut asked = bins.asked.lock().unwrap().clone();
    asked.sort();
    assert_eq!(asked, vec!["W:\\", "W:\\", "X:\\", "X:\\", "Y:\\", "Y:\\", "Z:\\", "Z:\\"]);
}

// ---------- activity log durability ----------

fn sample_entry(id: &str) -> ActivityEntry {
    ActivityEntry {
        id: id.to_string(),
        date: 0,
        title: "sample".to_string(),
        source: "test".to_string(),
        bytes: 0,
        records: Vec::new(),
        status: ActivityStatus::Completed,
        errors: Vec::new(),
    }
}

fn names_in(dir: &Path) -> Vec<String> {
    fs::read_dir(dir).unwrap().flatten().map(|e| e.file_name().to_string_lossy().to_string()).collect()
}

#[test]
fn corrupt_activity_log_is_kept_not_overwritten() {
    let tmp = tempfile::tempdir().unwrap();
    let path = tmp.path().join("activity.json");
    fs::write(&path, b"[{ this is not json").unwrap();
    let log = ActivityLog::new(&path);
    assert!(log.entries().is_empty());

    log.append(sample_entry("aaaa1111")).unwrap();
    assert_eq!(log.entries().len(), 1);
    let kept: Vec<String> = names_in(tmp.path()).into_iter().filter(|n| n.starts_with("activity.json.corrupt-")).collect();
    assert_eq!(kept.len(), 1, "{:?}", names_in(tmp.path()));
    assert_eq!(fs::read(tmp.path().join(&kept[0])).unwrap(), b"[{ this is not json");

    // A second corrupt log in the same second gets its own name.
    fs::write(&path, b"garbage").unwrap();
    log.append(sample_entry("bbbb2222")).unwrap();
    let kept = names_in(tmp.path()).into_iter().filter(|n| n.starts_with("activity.json.corrupt-")).count();
    assert_eq!(kept, 2);
    assert!(!names_in(tmp.path()).iter().any(|n| n.contains(".tmp-")), "temp files left: {:?}", names_in(tmp.path()));
}

#[test]
fn nothing_moves_when_the_activity_log_cannot_be_written() {
    let sb = Sandbox::new();
    let (nm, items) = dormant_scan(&sb);
    let dir = sb.tmp.path().join("data");
    // A folder where the lock file should be: the log can't be locked, so it can't be written.
    fs::create_dir_all(dir.join("activity.json.lock")).unwrap();
    let log = ActivityLog::new(dir.join("activity.json"));
    let fake = FakeTrash::new(sb.tmp.path().join("bin"));
    let guard = sb.guard();
    let report = Cleaner::new(&guard, &fake, &log).clean(&items, &CleanOptions::run("test"), &mut |_| {});
    assert!(report.log_error.is_some(), "{report:?}");
    assert!(report.entry.is_none());
    assert!(report.items.is_empty());
    assert!(nm.exists());
    assert_eq!(fake.count(), 0);
}

#[test]
fn interrupted_cleanup_leaves_a_restorable_record() {
    let sb = Sandbox::new();
    let first = node_project(&sb.home.join(r"code\old-one"), 90);
    let second = node_project(&sb.home.join(r"code\old-two"), 90);
    let summary = scan(&sb.env(), Some(&sb.guard()), &ScanOptions { categories: Some(vec![Category::ProjectArtifacts]) });
    let items: Vec<CleanupItem> = summary.recommended().into_iter().cloned().collect();
    assert_eq!(items.len(), 2, "{:?}", summary.items);

    let store = Store::new(sb.tmp.path().join("data"));
    let log = store.activity();
    let crashing = CrashingTrash { inner: FakeTrash::new(sb.tmp.path().join("bin")), allow: 1 };
    let guard = sb.guard();
    let outcome = std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| {
        Cleaner::new(&guard, &crashing, &log).clean(&items, &CleanOptions::run("test"), &mut |_| {})
    }));
    assert!(outcome.is_err(), "the cleanup should have been interrupted");
    assert_eq!(first.exists() as u8 + second.exists() as u8, 1, "exactly one folder moved before the crash");

    let entries = log.entries();
    assert_eq!(entries.len(), 1);
    let entry = &entries[0];
    assert_eq!(entry.status, ActivityStatus::Incomplete);
    assert_eq!(entry.records.len(), 1);
    assert!(entry.can_restore());

    let restored = Cleaner::new(&guard, &crashing.inner, &log).restore(&entry.id).expect("restore");
    assert_eq!(restored.restored, 1, "{:?}", restored.errors);
    assert!(first.join(r"left-pad\index.js").exists());
    assert!(second.join(r"left-pad\index.js").exists());
}

// ---------- restore picks the right Recycle Bin item ----------

#[test]
fn bin_item_choice_uses_the_recorded_time() {
    let req = |at: i64, until: i64| RestoreRequest { original: PathBuf::from(r"C:\x"), deleted_at: at, deleted_until: until };
    let items = [(0, 100), (1, 200), (2, 300), (3, 201)];
    // Earliest at or after the recorded time, within the window.
    assert_eq!(pick_bin_item(&items, &req(199, 202)), Some(1));
    assert_eq!(pick_bin_item(&items, &req(199, 0)), Some(1));
    assert_eq!(pick_bin_item(&items, &req(250, 0)), Some(2));
    // A couple of seconds of slack either side.
    assert_eq!(pick_bin_item(&items, &req(102, 102)), Some(0));
    assert_eq!(pick_bin_item(&items, &req(150, 160)), None);
    assert_eq!(pick_bin_item(&items, &req(400, 0)), None);
    // Records from before times were kept: the newest.
    assert_eq!(pick_bin_item(&items, &req(0, 0)), Some(2));
    assert_eq!(pick_bin_item(&[], &req(199, 202)), None);
}

#[test]
fn restore_brings_back_what_spacesaver_moved_not_another_copy() {
    let sb = Sandbox::new();
    let (nm, items) = dormant_scan(&sb);
    let store = Store::new(sb.tmp.path().join("data"));
    let log = store.activity();
    let fake = FakeTrash::new(sb.tmp.path().join("bin"));
    let guard = sb.guard();
    let cleaner = Cleaner::new(&guard, &fake, &log);
    let before = fsutil::now();
    let entry = cleaner.clean(&items, &CleanOptions::run("test"), &mut |_| {}).entry.expect("entry");
    let record = &entry.records[0];
    assert!(record.deleted_at >= before && record.deleted_until >= record.deleted_at, "{record:?}");

    // The same path was also deleted long before and later on, by someone else.
    let original = Path::new(&record.original);
    let now = fsutil::now();
    fake.plant(original, now - 30 * 86_400, "older.txt");
    fake.plant(original, now + 600, "newer.txt");
    let report = cleaner.restore(&entry.id).expect("restore");
    assert_eq!(report.restored, 1, "{:?}", report.errors);
    assert!(nm.join(r"left-pad\index.js").exists());
    assert!(!nm.join("older.txt").exists() && !nm.join("newer.txt").exists());
    assert_eq!(fake.count(), 2);
}

// ---------- untrusted names and network paths ----------

#[test]
fn wsl_commands_quote_untrusted_paths() {
    let sb = Sandbox::new();
    let vhdx = sb.home.join(r"AppData\Local\Packages\Evil.Dist'ro$(calc)_x1\LocalState\ext4.vhdx");
    write(&vhdx, 8192);
    let items = wsl::analyze(&sb.env());
    assert_eq!(items.len(), 1);
    let Method::Manual { instructions, commands } = &items[0].method else { panic!("manual expected") };
    let optimize = commands.iter().find(|c| c.starts_with("Optimize-VHD")).expect("Optimize-VHD command");
    assert!(optimize.starts_with("Optimize-VHD -Path '"), "{optimize}");
    assert!(optimize.contains("Dist''ro$(calc)"), "{optimize}");
    assert!(!optimize.contains('"'), "{optimize}");
    let sparse = commands.iter().find(|c| c.contains("--set-sparse")).unwrap();
    assert!(sparse.contains("'Dist''ro$(calc)'"), "{sparse}");
    assert!(instructions.contains("-Path 'C:") || instructions.contains("-Path '"), "{instructions}");
}

#[test]
fn network_gitdir_is_never_followed() {
    let sb = Sandbox::new();
    let root = sb.home.join(r"code\worktree");
    node_project(&root, 120);
    // TEST-NET-3 address: nothing answers, and the scan must not even try.
    fs::write(root.join(".git"), "gitdir: //203.0.113.9/share/repo.git/worktrees/x\n").unwrap();
    assert!(projects::find_git_dir(&root, &sb.home).is_none());
    fs::write(root.join(".git"), "gitdir: \\\\203.0.113.9\\share\\repo.git\n").unwrap();
    assert!(projects::find_git_dir(&root, &sb.home).is_none());
    // A local gitdir is still followed.
    fs::write(root.join(".git"), "gitdir: ../main/.git/worktrees/worktree\n").unwrap();
    assert!(projects::find_git_dir(&root, &sb.home).is_some());
}

#[test]
fn deno_and_ollama_rules_take_only_their_cache_folders() {
    let sb = Sandbox::new();
    let deno = sb.home.join(r"AppData\Local\deno");
    write(&deno.join(r"remote\https\deno.land\abc"), 4096);
    write(&deno.join(r"npm\registry.npmjs.org\x\pkg.tgz"), 4096);
    write(&deno.join(r"location_data\abc\local_storage"), 4096);
    write(&deno.join(r"kv.sqlite3"), 4096);
    let ollama = sb.home.join(r".ollama\models");
    write(&ollama.join(r"blobs\sha256-abc"), 4096);
    write(&ollama.join(r"manifests\registry.ollama.ai\library\llama3\latest"), 100);
    write(&ollama.join(r"my-notes.txt"), 4096);

    let items = caches::analyze(&sb.env(), &Default::default());
    let deno_item = items.iter().find(|i| i.id == "pkg.deno").expect("deno cache");
    assert_eq!(deno_item.size, 8192);
    assert!(deno_item.paths.iter().all(|p| !p.to_lowercase().contains("location_data") && !p.ends_with("deno")), "{:?}", deno_item.paths);
    let ollama_item = items.iter().find(|i| i.id == "ai.ollama").expect("ollama models");
    assert_eq!(ollama_item.risk, Risk::Review);
    assert_eq!(ollama_item.size, 4196);
    assert!(ollama_item.paths.iter().all(|p| p.ends_with("blobs") || p.ends_with("manifests")), "{:?}", ollama_item.paths);
}
