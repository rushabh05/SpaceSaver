//! The data the scanner produces and the UI and CLI show. Serialised as camelCase JSON.

use serde::{Deserialize, Serialize};

/// How safe it is to remove something.
#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord, Hash, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum Risk {
    /// Rebuilt automatically or with one command. No user data.
    Safe,
    /// Rebuildable, but that costs time or bandwidth (a big re-download, a long rebuild).
    Review,
    /// May hold personal data or work you can't regenerate.
    Caution,
}

impl Risk {
    pub fn title(self) -> &'static str {
        match self {
            Risk::Safe => "Safe",
            Risk::Review => "Review",
            Risk::Caution => "Caution",
        }
    }

    pub fn summary(self) -> &'static str {
        match self {
            Risk::Safe => "Regenerates automatically. No personal data.",
            Risk::Review => "Can be rebuilt or re-downloaded, but that takes time or bandwidth.",
            Risk::Caution => "May contain personal data. Check the contents first.",
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord, Hash, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum Category {
    ProjectArtifacts,
    PackageCaches,
    IdeCaches,
    AiModels,
    WslDocker,
    SystemJunk,
}

impl Category {
    pub const ALL: [Category; 6] = [
        Category::ProjectArtifacts,
        Category::PackageCaches,
        Category::IdeCaches,
        Category::AiModels,
        Category::WslDocker,
        Category::SystemJunk,
    ];

    pub fn id(self) -> &'static str {
        match self {
            Category::ProjectArtifacts => "projectArtifacts",
            Category::PackageCaches => "packageCaches",
            Category::IdeCaches => "ideCaches",
            Category::AiModels => "aiModels",
            Category::WslDocker => "wslDocker",
            Category::SystemJunk => "systemJunk",
        }
    }

    pub fn title(self) -> &'static str {
        match self {
            Category::ProjectArtifacts => "Project Artifacts",
            Category::PackageCaches => "Package Caches",
            Category::IdeCaches => "IDEs & Editors",
            Category::AiModels => "AI Models",
            Category::WslDocker => "WSL & Docker",
            Category::SystemJunk => "System Junk",
        }
    }

    pub fn blurb(self) -> &'static str {
        match self {
            Category::ProjectArtifacts => {
                "node_modules, build outputs and virtualenvs in projects you haven't touched lately."
            }
            Category::PackageCaches => "Download caches for npm, pnpm, Yarn, pip, uv, NuGet, Cargo, Gradle, Go and others.",
            Category::IdeCaches => "Caches and logs for VS Code, Cursor, Windsurf, JetBrains IDEs and Android Studio.",
            Category::AiModels => "Hugging Face, Ollama, LM Studio and other local model weights.",
            Category::WslDocker => {
                "WSL and Docker Desktop virtual disks. They never shrink by themselves; SpaceSaver shows how to compact them."
            }
            Category::SystemJunk => "Crash dumps and temporary files nothing has touched for a week.",
        }
    }

    /// Accepts the id (`packageCaches`) or a short alias (`caches`).
    pub fn parse(s: &str) -> Option<Category> {
        let s = s.to_ascii_lowercase();
        Category::ALL.into_iter().find(|c| c.id().to_ascii_lowercase() == s).or(match s.as_str() {
            "projects" | "project" | "artifacts" => Some(Category::ProjectArtifacts),
            "caches" | "packages" | "cache" => Some(Category::PackageCaches),
            "ide" | "ides" | "editors" => Some(Category::IdeCaches),
            "ai" | "models" => Some(Category::AiModels),
            "wsl" | "docker" => Some(Category::WslDocker),
            "junk" | "system" | "temp" => Some(Category::SystemJunk),
            _ => None,
        })
    }
}

/// How an item gets removed.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(tag = "kind", rename_all = "camelCase")]
pub enum Method {
    /// Move to the Recycle Bin. Undoable from Activity.
    RecycleBin,
    /// SpaceSaver never does this itself; the instructions explain the steps and `commands`
    /// are the lines to copy.
    Manual { instructions: String, commands: Vec<String> },
    /// A tool's own cleanup command. Shown for copying; never run automatically.
    Command { program: String, args: Vec<String> },
}

impl Method {
    /// Only Recycle Bin moves are ever performed by SpaceSaver.
    pub fn is_actionable(&self) -> bool {
        matches!(self, Method::RecycleBin)
    }

    pub fn label(&self) -> String {
        match self {
            Method::RecycleBin => "Move to Recycle Bin".to_string(),
            Method::Manual { .. } => "Manual steps".to_string(),
            Method::Command { program, args } => {
                std::iter::once(program.clone()).chain(args.iter().cloned()).collect::<Vec<_>>().join(" ")
            }
        }
    }
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct CleanupItem {
    pub id: String,
    pub category: Category,
    pub title: String,
    /// Secondary text, usually the shortened path.
    pub subtitle: String,
    pub paths: Vec<String>,
    /// Logical bytes.
    pub size: u64,
    pub files: u64,
    pub risk: Risk,
    pub method: Method,
    /// What this is, in plain English.
    pub explanation: String,
    /// How it comes back if you need it.
    pub regenerate: String,
    #[serde(default)]
    pub tags: Vec<String>,
    /// Pre-selected for Smart Clean.
    pub recommended: bool,
    /// Set when the item can't be cleaned right now (app running, refused by the safety guard).
    #[serde(default)]
    pub blocked_reason: Option<String>,
    /// Last sign of activity (Unix seconds).
    #[serde(default)]
    pub last_activity: Option<i64>,
    /// Rows with the same group are shown together (a project's folder, for example).
    #[serde(default)]
    pub group: Option<String>,
}

impl CleanupItem {
    /// A plain Recycle Bin item with no tags. Analyzers fill in the rest.
    pub fn new(id: impl Into<String>, category: Category, title: impl Into<String>, paths: Vec<String>, size: u64, risk: Risk) -> Self {
        let paths_vec = paths;
        let subtitle = paths_vec.first().cloned().unwrap_or_default();
        CleanupItem {
            id: id.into(),
            category,
            title: title.into(),
            subtitle,
            paths: paths_vec,
            size,
            files: 0,
            risk,
            method: Method::RecycleBin,
            explanation: String::new(),
            regenerate: String::new(),
            tags: Vec::new(),
            recommended: risk == Risk::Safe,
            blocked_reason: None,
            last_activity: None,
            group: None,
        }
    }

    /// Can be ticked and cleaned.
    pub fn is_selectable(&self) -> bool {
        self.blocked_reason.is_none() && self.method.is_actionable()
    }
}

/// Space on one drive.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct DiskInfo {
    /// `C:\`
    pub drive: String,
    pub total: u64,
    /// Bytes available to the current user.
    pub free: u64,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct CategorySummary {
    pub id: Category,
    pub title: String,
    pub blurb: String,
    /// Everything found in this category.
    pub size: u64,
    /// What Smart Clean would take.
    pub recommended_size: u64,
    pub count: usize,
}

/// The result of a scan, saved to `last-scan.json`.
#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ScanSummary {
    /// A random id for this scan. The app only cleans from the scan it produced itself, and
    /// checks that the review the user confirmed was opened on that same scan.
    #[serde(default)]
    pub id: String,
    pub version: u32,
    /// Unix seconds.
    pub date: i64,
    pub duration_ms: u64,
    pub disk: Option<DiskInfo>,
    pub categories: Vec<CategorySummary>,
    pub items: Vec<CleanupItem>,
}

impl ScanSummary {
    pub fn new(items: Vec<CleanupItem>, disk: Option<DiskInfo>, date: i64, duration_ms: u64) -> Self {
        let categories = Category::ALL
            .into_iter()
            .map(|c| {
                let in_cat: Vec<&CleanupItem> = items.iter().filter(|i| i.category == c).collect();
                CategorySummary {
                    id: c,
                    title: c.title().to_string(),
                    blurb: c.blurb().to_string(),
                    size: in_cat.iter().map(|i| i.size).sum(),
                    recommended_size: in_cat
                        .iter()
                        .filter(|i| i.recommended && i.is_selectable())
                        .map(|i| i.size)
                        .sum(),
                    count: in_cat.len(),
                }
            })
            .collect();
        ScanSummary { id: crate::activity::new_id(), version: 1, date, duration_ms, disk, categories, items }
    }

    /// Items Smart Clean would move.
    pub fn recommended(&self) -> Vec<&CleanupItem> {
        self.items.iter().filter(|i| i.recommended && i.is_selectable()).collect()
    }

    pub fn recommended_size(&self) -> u64 {
        self.recommended().iter().map(|i| i.size).sum()
    }

    pub fn total_size(&self) -> u64 {
        self.items.iter().map(|i| i.size).sum()
    }

    /// Recomputes the category totals after items were removed. Keeps the scan's id.
    pub fn refresh(&mut self) {
        let items = std::mem::take(&mut self.items);
        let fresh = ScanSummary::new(items, self.disk.clone(), self.date, self.duration_ms);
        self.categories = fresh.categories;
        self.items = fresh.items;
    }
}
