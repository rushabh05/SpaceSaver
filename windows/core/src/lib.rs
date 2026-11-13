//! SpaceSaver for Windows: the engine behind the CLI and the desktop app.
//!
//! * [`scan`] finds regenerable developer data (project build folders in dormant projects,
//!   package-manager and editor caches, AI models, old temp files) and reports WSL and Docker
//!   disk images, which it never deletes.
//! * [`SafetyGuard`] is the last check before anything is removed.
//! * [`Cleaner`] moves items to the Recycle Bin, logs each run in the [`ActivityLog`] and can
//!   restore them by their original path.

pub mod activity;
pub mod cleanup;
pub mod env;
pub mod format;
pub mod fsutil;
pub mod model;
pub mod paths;
pub mod projects;
pub mod rules;
pub mod safety;
pub mod scan;
pub mod store;
pub mod system;
pub mod caches;
pub mod wsl;

pub use activity::{ActivityEntry, ActivityLog, ActivityStatus, TrashRecord};
pub use cleanup::{
    CleanOptions, CleanProgress, CleanReport, Cleaner, PlannedItem, RecycleBinSettings, RestoreReport, RestoreRequest,
    Skipped, SystemRecycleBin, SystemTrash, Trasher,
};
pub use env::ScanEnv;
pub use format::{age_label, ago, format_bytes};
pub use model::{Category, CategorySummary, CleanupItem, DiskInfo, Method, Risk, ScanSummary};
pub use safety::{GuardConfig, SafetyError, SafetyGuard};
pub use scan::{scan, ScanOptions};
pub use store::Store;
pub use system::RecycleBinInfo;
