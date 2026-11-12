//! Built-in knowledge: project artifact rules (ported from the macOS app's `ArtifactRule.all`)
//! and Windows locations of developer caches.

use crate::env::ScanEnv;
use crate::fsutil::wildcard_match;
use crate::model::{Category, Risk};
use std::collections::HashSet;
use std::path::{Path, PathBuf};

/// A build or dependency folder inside a project, recognised by its name plus a manifest next
/// to it, so a random folder called `build` is never flagged.
#[derive(Debug)]
pub struct ArtifactRule {
    pub directory: &'static str,
    /// Any one of these must sit next to the folder. `*` wildcards allowed (`*.csproj`).
    pub markers: &'static [&'static str],
    pub lockfiles: &'static [&'static str],
    pub regenerate: &'static str,
    pub ecosystem: &'static str,
    pub risk: Risk,
}

const fn rule(
    directory: &'static str,
    markers: &'static [&'static str],
    lockfiles: &'static [&'static str],
    regenerate: &'static str,
    ecosystem: &'static str,
    risk: Risk,
) -> ArtifactRule {
    ArtifactRule { directory, markers, lockfiles, regenerate, ecosystem, risk }
}

const NONE: &[&str] = &[];
const JS: &[&str] = &["package.json"];
const JS_LOCKS: &[&str] =
    &["package-lock.json", "yarn.lock", "pnpm-lock.yaml", "bun.lockb", "bun.lock", "npm-shrinkwrap.json"];
const PY: &[&str] = &["requirements.txt", "pyproject.toml", "Pipfile", "setup.py", "setup.cfg"];
const PY_TEST: &[&str] = &["requirements.txt", "pyproject.toml", "Pipfile", "setup.py", "setup.cfg", "pytest.ini"];
const PY_RUFF: &[&str] = &["requirements.txt", "pyproject.toml", "Pipfile", "setup.py", "setup.cfg", "ruff.toml"];
const PY_LOCKS: &[&str] = &["poetry.lock", "uv.lock", "Pipfile.lock", "requirements.txt", "pdm.lock"];
const GRADLE: &[&str] = &["build.gradle", "build.gradle.kts", "settings.gradle", "settings.gradle.kts"];
const DOTNET: &[&str] = &["*.csproj", "*.fsproj", "*.vbproj"];
const SAFE: Risk = Risk::Safe;
const REVIEW: Risk = Risk::Review;

/// 46 rules, the same list as the macOS app (plus `next.config.*` and `*.vbproj` markers).
pub static ARTIFACT_RULES: &[ArtifactRule] = &[
    rule("node_modules", JS, JS_LOCKS, "npm install", "Node.js", SAFE),
    rule(".next", &["next.config.js", "next.config.mjs", "next.config.ts", "next.config.cjs", "package.json"], NONE, "next build", "Next.js", SAFE),
    rule(".nuxt", JS, NONE, "nuxt build", "Nuxt", SAFE),
    rule(".output", &["nuxt.config.ts", "nuxt.config.js"], NONE, "nuxt build", "Nuxt", SAFE),
    rule(".svelte-kit", JS, NONE, "vite build", "SvelteKit", SAFE),
    rule(".turbo", &["package.json", "turbo.json"], NONE, "turbo run build", "Turborepo", SAFE),
    rule(".parcel-cache", JS, NONE, "parcel build", "Parcel", SAFE),
    rule(".angular", &["angular.json"], NONE, "ng build", "Angular", SAFE),
    rule(".docusaurus", JS, NONE, "docusaurus build", "Docusaurus", SAFE),
    rule(".astro", JS, NONE, "astro build", "Astro", SAFE),
    rule(".vercel", JS, NONE, "vercel build", "Vercel", SAFE),
    rule(".nx", &["nx.json"], NONE, "nx build", "Nx", SAFE),
    rule(".expo", &["app.json", "app.config.js", "app.config.ts"], NONE, "expo start", "Expo", SAFE),
    rule("coverage", JS, NONE, "npm test -- --coverage", "Test coverage", SAFE),
    rule("storybook-static", JS, NONE, "build-storybook", "Storybook", SAFE),
    rule("dist", JS, NONE, "npm run build", "JS build output", REVIEW),
    rule("target", &["Cargo.toml"], &["Cargo.lock"], "cargo build", "Rust", SAFE),
    rule("target", &["pom.xml"], NONE, "mvn package", "Maven", SAFE),
    rule(".build", &["Package.swift"], &["Package.resolved"], "swift build", "SwiftPM", SAFE),
    rule("DerivedData", &["*.xcodeproj", "*.xcworkspace"], NONE, "Build in Xcode", "Xcode", SAFE),
    rule("Pods", &["Podfile"], &["Podfile.lock"], "pod install", "CocoaPods", SAFE),
    rule(".gradle", GRADLE, NONE, "gradlew build", "Gradle", SAFE),
    rule("build", GRADLE, NONE, "gradlew build", "Gradle", SAFE),
    rule(".cxx", GRADLE, NONE, "gradlew build", "Android NDK", SAFE),
    rule(".venv", PY, PY_LOCKS, "uv sync / pip install -r requirements.txt", "Python venv", REVIEW),
    rule("venv", PY, &["poetry.lock", "uv.lock", "Pipfile.lock", "requirements.txt"], "python -m venv venv && pip install -r requirements.txt", "Python venv", REVIEW),
    rule(".tox", &["tox.ini", "pyproject.toml"], NONE, "tox", "tox", SAFE),
    rule(".pytest_cache", PY_TEST, NONE, "pytest", "pytest", SAFE),
    rule(".mypy_cache", PY, NONE, "mypy", "mypy", SAFE),
    rule(".ruff_cache", PY_RUFF, NONE, "ruff", "Ruff", SAFE),
    rule("vendor", &["composer.json"], &["composer.lock"], "composer install", "PHP Composer", SAFE),
    rule("bin", DOTNET, NONE, "dotnet build", ".NET", SAFE),
    rule("obj", DOTNET, NONE, "dotnet build", ".NET", SAFE),
    rule(".dart_tool", &["pubspec.yaml"], &["pubspec.lock"], "dart pub get", "Dart/Flutter", SAFE),
    rule("build", &["pubspec.yaml"], NONE, "flutter build", "Flutter", SAFE),
    rule(".terraform", &["main.tf", "versions.tf", "providers.tf"], &[".terraform.lock.hcl"], "terraform init", "Terraform", SAFE),
    rule("_build", &["mix.exs"], NONE, "mix compile", "Elixir", SAFE),
    rule("deps", &["mix.exs"], &["mix.lock"], "mix deps.get", "Elixir", SAFE),
    rule(".stack-work", &["stack.yaml"], NONE, "stack build", "Haskell", SAFE),
    rule("dist-newstyle", &["cabal.project", "*.cabal"], NONE, "cabal build", "Haskell", SAFE),
    rule(".zig-cache", &["build.zig"], NONE, "zig build", "Zig", SAFE),
    rule("zig-cache", &["build.zig"], NONE, "zig build", "Zig", SAFE),
    rule("zig-out", &["build.zig"], NONE, "zig build", "Zig", SAFE),
    rule("elm-stuff", &["elm.json"], NONE, "elm make", "Elm", SAFE),
    rule("cmake-build-debug", &["CMakeLists.txt"], NONE, "cmake --build", "CMake", SAFE),
    rule("cmake-build-release", &["CMakeLists.txt"], NONE, "cmake --build", "CMake", SAFE),
];

impl ArtifactRule {
    /// True when one of the markers is among `siblings` (lower-cased names in the same folder).
    pub fn matches(&self, siblings: &HashSet<String>) -> bool {
        self.markers.iter().any(|marker| {
            if marker.contains('*') {
                siblings.iter().any(|s| wildcard_match(marker, s))
            } else {
                siblings.contains(&marker.to_lowercase())
            }
        })
    }

    /// The first lockfile present among `siblings`.
    pub fn lockfile(&self, siblings: &HashSet<String>) -> Option<&'static str> {
        self.lockfiles.iter().copied().find(|l| siblings.contains(&l.to_lowercase()))
    }
}

/// Rules for a folder name (case-insensitive), in priority order.
pub fn artifact_rules_named(name: &str) -> Vec<&'static ArtifactRule> {
    let lower = name.to_lowercase();
    ARTIFACT_RULES.iter().filter(|r| r.directory.to_lowercase() == lower).collect()
}

/// The rule that applies to folder `name` given the lower-cased names next to it.
pub fn match_artifact(name: &str, siblings: &HashSet<String>) -> Option<&'static ArtifactRule> {
    artifact_rules_named(name).into_iter().find(|r| r.matches(siblings))
}

/// A known location of regenerable data.
#[derive(Debug, Clone)]
pub struct LocationRule {
    pub id: String,
    pub category: Category,
    pub title: String,
    /// Concrete paths; components may contain `*`.
    pub paths: Vec<PathBuf>,
    pub risk: Risk,
    pub explanation: String,
    pub regenerate: String,
    /// Each match becomes its own item (one per model, per IDE version...).
    pub each: bool,
    /// How to name an item when `each` is set.
    pub label: Label,
    /// Process names (lower case, no `.exe`) that keep this data in use.
    pub processes: Vec<&'static str>,
    /// Shown in "Close X first".
    pub app_name: String,
}

/// How to turn a matched path into a title suffix.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Label {
    /// The folder name.
    Name,
    /// The parent folder's name (`JetBrains\IntelliJIdea2024.2\caches` → `IntelliJIdea2024.2`).
    Parent,
    /// `models--org--name` → `org/name`.
    HuggingFace,
    /// `publisher\model` → `publisher/model`.
    ParentAndName,
}

impl Label {
    pub fn apply(self, path: &Path) -> String {
        let name = path.file_name().map(|n| n.to_string_lossy().to_string()).unwrap_or_default();
        let parent = path
            .parent()
            .and_then(|p| p.file_name())
            .map(|n| n.to_string_lossy().to_string())
            .unwrap_or_default();
        match self {
            Label::Name => name.trim_end_matches(".avd").to_string(),
            Label::Parent => parent,
            Label::ParentAndName => format!("{parent}/{name}"),
            Label::HuggingFace => {
                let mut parts = name.splitn(2, "--");
                let kind = parts.next().unwrap_or("");
                let rest = parts.next().unwrap_or(name.as_str()).replace("--", "/");
                if kind == "datasets" {
                    format!("{rest} (dataset)")
                } else {
                    rest
                }
            }
        }
    }
}

struct R {
    rule: LocationRule,
}

impl R {
    fn new(id: &str, category: Category, title: &str, paths: Vec<PathBuf>, risk: Risk, explanation: &str, regenerate: &str) -> Self {
        R {
            rule: LocationRule {
                id: id.to_string(),
                category,
                title: title.to_string(),
                paths,
                risk,
                explanation: explanation.to_string(),
                regenerate: regenerate.to_string(),
                each: false,
                label: Label::Name,
                processes: Vec::new(),
                app_name: String::new(),
            },
        }
    }

    fn each(mut self, label: Label) -> Self {
        self.rule.each = true;
        self.rule.label = label;
        self
    }

    fn running(mut self, app: &str, processes: &[&'static str]) -> Self {
        self.rule.app_name = app.to_string();
        self.rule.processes = processes.to_vec();
        self
    }

    fn done(self) -> LocationRule {
        self.rule
    }
}

const JETBRAINS: &[&str] = &[
    "idea64", "idea", "pycharm64", "pycharm", "webstorm64", "webstorm", "goland64", "goland", "rider64", "rider",
    "clion64", "clion", "phpstorm64", "phpstorm", "rubymine64", "rubymine", "datagrip64", "datagrip", "rustrover64",
    "rustrover",
];

/// Every cache location SpaceSaver knows on Windows, resolved for `env`.
pub fn location_rules(env: &ScanEnv) -> Vec<LocationRule> {
    use Category::*;
    let home = &env.home;
    let local = &env.local;
    let roaming = &env.roaming;
    let cargo = &env.cargo_home;
    let hf = &env.hf_home;

    let mut rules = vec![
        // Package managers and toolchains
        R::new("pkg.npm", PackageCaches, "npm cache",
               vec![local.join(r"npm-cache\_cacache"), local.join(r"npm-cache\_logs")], Risk::Safe,
               "npm's content-addressed download cache and debug logs.",
               "Re-downloaded on the next npm install.").done(),
        R::new("pkg.npx", PackageCaches, "npx cache", vec![local.join(r"npm-cache\_npx")], Risk::Safe,
               "Packages fetched by one-off npx commands.", "Fetched again when npx runs.").done(),
        R::new("pkg.pnpm", PackageCaches, "pnpm store", vec![local.join(r"pnpm\store")], Risk::Review,
               "pnpm's content-addressed store. Every pnpm project hard-links into it.",
               "`pnpm store prune` removes only unreferenced packages; deleting all of it means re-downloading everything.")
            .running("pnpm", &["pnpm"]).done(),
        R::new("pkg.yarn", PackageCaches, "Yarn cache", vec![local.join(r"Yarn\Cache"), local.join(r"Yarn\Berry\cache")],
               Risk::Safe, "Yarn's global package cache.", "Re-downloaded on the next yarn install.").done(),
        R::new("pkg.bun", PackageCaches, "Bun cache", vec![home.join(r".bun\install\cache")], Risk::Safe,
               "Bun's global install cache.", "Re-downloaded on the next bun install.").done(),
        R::new("pkg.pip", PackageCaches, "pip cache", vec![local.join(r"pip\Cache")], Risk::Safe,
               "Downloaded wheels and HTTP cache for pip.", "Re-downloaded on the next pip install.").done(),
        R::new("pkg.uv", PackageCaches, "uv cache", vec![local.join(r"uv\cache")], Risk::Safe,
               "uv's wheel and source cache.", "Re-downloaded by uv when needed.").running("uv", &["uv"]).done(),
        R::new("pkg.poetry", PackageCaches, "Poetry cache", vec![local.join(r"pypoetry\Cache")], Risk::Safe,
               "Poetry's package cache and the virtualenvs it created.", "Re-created by `poetry install`.").done(),
        R::new("pkg.nuget.http", PackageCaches, "NuGet HTTP cache",
               vec![local.join(r"NuGet\v3-cache"), local.join(r"NuGet\plugins-cache")], Risk::Safe,
               "Package metadata and .nupkg downloads NuGet keeps between restores.",
               "Re-downloaded on the next `dotnet restore` (same as `dotnet nuget locals http-cache --clear`).").done(),
        R::new("pkg.nuget.packages", PackageCaches, "NuGet global packages", vec![env.nuget_packages.clone()], Risk::Review,
               ".NET's global packages folder. Every project restores from it.",
               "Restored by `dotnet restore`, which re-downloads every package.").done(),
        R::new("pkg.gradle", PackageCaches, "Gradle caches",
               vec![env.gradle_home.join("caches"), env.gradle_home.join(r"wrapper\dists")], Risk::Safe,
               "Gradle's dependency cache and downloaded wrapper distributions.",
               "Re-downloaded on the next Gradle build.").done(),
        R::new("pkg.maven", PackageCaches, "Maven repository", vec![home.join(r".m2\repository")], Risk::Review,
               "Local Maven artifact cache. May contain artifacts you installed yourself with `mvn install`.",
               "Re-downloaded from remote repositories on the next build.").done(),
        R::new("pkg.cargo", PackageCaches, "Cargo registry",
               vec![cargo.join(r"registry\cache"), cargo.join(r"registry\src"), cargo.join(r"git\checkouts"), cargo.join(r"git\db")],
               Risk::Safe, "Downloaded crate sources and git dependencies.",
               "Re-downloaded on the next cargo build.").running("Cargo", &["cargo", "rust-analyzer"]).done(),
        R::new("pkg.go.build", PackageCaches, "Go build cache", vec![env.go_cache.clone()], Risk::Safe,
               "Compiled package cache.", "Equivalent to `go clean -cache`.").done(),
        R::new("pkg.go.mod", PackageCaches, "Go module cache", vec![env.go_mod.clone()], Risk::Review,
               "Downloaded Go modules.", "Equivalent to `go clean -modcache`; modules re-download on build.").done(),
        R::new("pkg.deno", PackageCaches, "Deno cache", vec![local.join("deno")], Risk::Safe,
               "Deno's remote module cache.", "Re-downloaded on run.").done(),
        R::new("pkg.nodegyp", PackageCaches, "node-gyp headers", vec![local.join(r"node-gyp\Cache")], Risk::Safe,
               "Node.js headers for building native modules.", "Re-downloaded when needed.").done(),
        R::new("pkg.playwright", PackageCaches, "Playwright browsers", vec![local.join("ms-playwright")], Risk::Review,
               "Browser builds downloaded by Playwright.", "`npx playwright install`.").done(),
        R::new("pkg.puppeteer", PackageCaches, "Puppeteer browsers", vec![home.join(r".cache\puppeteer")], Risk::Review,
               "Chrome builds downloaded by Puppeteer.", "Re-downloaded on the next install of puppeteer.").done(),
        R::new("pkg.cypress", PackageCaches, "Cypress binaries", vec![local.join(r"Cypress\Cache")], Risk::Safe,
               "Cypress app binaries for each version you've installed.", "`npx cypress install`.").done(),
        R::new("pkg.electron", PackageCaches, "Electron downloads",
               vec![local.join(r"electron\Cache"), local.join(r"electron-builder\Cache")], Risk::Safe,
               "Electron release zips cached by electron-builder and @electron/get.", "Re-downloaded on build.").done(),
        R::new("pkg.android.avd", PackageCaches, "Android emulator", vec![home.join(r".android\avd\*.avd")], Risk::Review,
               "An Android Virtual Device image with its user data.",
               "Recreate it in Android Studio's Device Manager.")
            .each(Label::Name).running("the Android emulator", &["emulator", "qemu-system-x86_64", "qemu-system-aarch64"]).done(),
        R::new("pkg.android.images", PackageCaches, "Android system images", vec![env.android_sdk.join(r"system-images\*")], Risk::Review,
               "Emulator system images for one API level.", "Reinstall from the SDK Manager.")
            .each(Label::Name).done(),
        R::new("pkg.hf.xet", PackageCaches, "Hugging Face transfer cache", vec![hf.join("xet")], Risk::Safe,
               "Chunk cache used while downloading models.", "Not needed after downloads finish.").done(),
        // JetBrains and Android Studio
        R::new("ide.jetbrains", IdeCaches, "JetBrains caches", vec![local.join(r"JetBrains\*\caches")], Risk::Safe,
               "Indexes and caches for one JetBrains IDE version. Old versions leave theirs behind.",
               "Re-indexed when the IDE opens a project.")
            .each(Label::Parent).running("the JetBrains IDE", JETBRAINS).done(),
        R::new("ide.jetbrains.logs", IdeCaches, "JetBrains logs", vec![local.join(r"JetBrains\*\log")], Risk::Safe,
               "IDE log files.", "Not needed.").done(),
        R::new("ide.androidstudio", IdeCaches, "Android Studio caches", vec![local.join(r"Google\AndroidStudio*\caches")], Risk::Safe,
               "Android Studio indexes and caches for one version.", "Re-indexed on next open.")
            .each(Label::Parent).running("Android Studio", &["studio64", "studio"]).done(),
        // AI models
        R::new("ai.huggingface", AiModels, "Hugging Face", vec![hf.join(r"hub\models--*"), hf.join(r"hub\datasets--*")], Risk::Review,
               "A model or dataset snapshot downloaded by transformers, diffusers or huggingface-cli.",
               "Re-downloaded from the Hub the next time code loads it.")
            .each(Label::HuggingFace).done(),
        R::new("ai.ollama", AiModels, "Ollama models", vec![env.ollama_models.clone()], Risk::Review,
               "Model weights pulled with `ollama pull`.", "`ollama pull <model>` downloads them again.")
            .running("Ollama", &["ollama", "ollama app"]).done(),
        R::new("ai.lmstudio", AiModels, "LM Studio", vec![home.join(r".lmstudio\models\*\*"), home.join(r".cache\lm-studio\models\*\*")],
               Risk::Review, "A GGUF model downloaded in LM Studio.", "Re-download it from LM Studio's Discover tab.")
            .each(Label::ParentAndName).running("LM Studio", &["lm studio", "lms"]).done(),
        R::new("ai.torch", AiModels, "PyTorch Hub cache", vec![home.join(r".cache\torch")], Risk::Review,
               "Weights downloaded by torch.hub and torchvision.", "Re-downloaded on next load.").done(),
        R::new("ai.whisper", AiModels, "Whisper models", vec![home.join(r".cache\whisper")], Risk::Review,
               "OpenAI Whisper speech model weights.", "Re-downloaded on next transcription.").done(),
        // System junk
        R::new("sys.crashdumps", SystemJunk, "Crash dumps", vec![local.join("CrashDumps")], Risk::Safe,
               "Memory dumps Windows writes when an app crashes. Only useful to that app's developers.",
               "Not needed.").done(),
    ];

    // VS Code family: %APPDATA%\<folder>
    let editors: [(&str, &str, &'static str); 5] = [
        ("Code", "VS Code", "code"),
        ("Code - Insiders", "VS Code Insiders", "code - insiders"),
        ("Cursor", "Cursor", "cursor"),
        ("Windsurf", "Windsurf", "windsurf"),
        ("VSCodium", "VSCodium", "vscodium"),
    ];
    for (folder, name, exe) in editors {
        let base = roaming.join(folder);
        let caches = ["Cache", "CachedData", "CachedExtensionVSIXs", "Code Cache", "GPUCache", "CachedProfilesData"]
            .iter()
            .map(|c| base.join(c))
            .collect();
        let id = folder.to_lowercase().replace(' ', "");
        rules.push(
            R::new(&format!("ide.{id}.cache"), IdeCaches, &format!("{name} caches"), caches, Risk::Safe,
                   &format!("Electron, GPU and extension download caches for {name}."),
                   &format!("Rebuilt when {name} starts."))
                .running(name, &[exe]).done(),
        );
        rules.push(
            R::new(&format!("ide.{id}.logs"), IdeCaches, &format!("{name} logs"), vec![base.join("logs")], Risk::Safe,
                   &format!("Log files from {name}."), "Not needed.")
                .running(name, &[exe]).done(),
        );
    }
    rules
}

#[cfg(test)]
mod tests {
    use super::*;

    fn names(list: &[&str]) -> HashSet<String> {
        list.iter().map(|s| s.to_lowercase()).collect()
    }

    #[test]
    fn has_the_full_mac_rule_list() {
        assert!(ARTIFACT_RULES.len() >= 45, "{} rules", ARTIFACT_RULES.len());
    }

    #[test]
    fn manifest_is_required() {
        assert!(match_artifact("node_modules", &names(&["package.json"])).is_some());
        assert!(match_artifact("node_modules", &names(&["readme.md"])).is_none());
        assert!(match_artifact("build", &names(&["Makefile"])).is_none());
        assert_eq!(match_artifact("build", &names(&["build.gradle.kts"])).unwrap().ecosystem, "Gradle");
        assert_eq!(match_artifact("build", &names(&["pubspec.yaml"])).unwrap().ecosystem, "Flutter");
        assert_eq!(match_artifact("target", &names(&["Cargo.toml"])).unwrap().ecosystem, "Rust");
        assert_eq!(match_artifact("target", &names(&["pom.xml"])).unwrap().ecosystem, "Maven");
        assert!(match_artifact("target", &names(&["package.json"])).is_none());
        assert_eq!(match_artifact("bin", &names(&["App.csproj"])).unwrap().ecosystem, ".NET");
        assert_eq!(match_artifact("OBJ", &names(&["lib.fsproj"])).unwrap().ecosystem, ".NET");
        assert!(match_artifact("bin", &names(&["package.json"])).is_none());
        assert!(match_artifact(".next", &names(&["next.config.mjs"])).is_some());
        assert!(match_artifact(".venv", &names(&["pyproject.toml"])).is_some());
        assert!(match_artifact(".venv", &names(&["main.py"])).is_none());
    }

    #[test]
    fn labels() {
        assert_eq!(Label::HuggingFace.apply(Path::new(r"C:\x\hub\models--meta-llama--Llama-3.2-1B")), "meta-llama/Llama-3.2-1B");
        assert_eq!(Label::Parent.apply(Path::new(r"C:\x\JetBrains\IntelliJIdea2024.2\caches")), "IntelliJIdea2024.2");
    }
}
