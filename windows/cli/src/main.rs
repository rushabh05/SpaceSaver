//! `spacesaver`: the SpaceSaver for Windows command line.

use spacesaver_core as ss;
use ss::{
    ago, format_bytes, system, Category, CleanOptions, CleanProgress, CleanReport, Cleaner, CleanupItem, GuardConfig,
    Method, Risk, SafetyGuard, ScanEnv, ScanOptions, ScanSummary, Store, SystemRecycleBin, SystemTrash,
};
use std::path::PathBuf;
use std::process::ExitCode;

const VERSION: &str = env!("CARGO_PKG_VERSION");

fn help() -> String {
    format!(
        "SpaceSaver for Windows {VERSION}
Finds regenerable developer junk and moves it to the Recycle Bin, with undo.

Usage:
  spacesaver status [--json]               disk space and the last scan
  spacesaver scan [--json] [-c <category>] [--root <folder>]...
                                           reclaimable space (● = recommended)
  spacesaver clean [--yes] [--include-review] [-c <category>] [--root <folder>]... [--json]
                                           dry run unless --yes; moves items to the Recycle Bin
  spacesaver activity [--json]             past cleanups
  spacesaver restore <id> [--json]         put a cleanup back from the Recycle Bin
  spacesaver help

Categories: projects, caches, ide, ai, wsl, junk
Exit codes: 0 success, 1 failed or only partly done, 2 bad arguments.
WSL and Docker disks are never deleted; `spacesaver scan -c wsl` prints how to compact them.
Data folder: %LOCALAPPDATA%\\SpaceSaver
"
    )
}

enum CliError {
    Usage(String),
    Failed(String),
}

impl From<serde_json::Error> for CliError {
    fn from(e: serde_json::Error) -> Self {
        CliError::Failed(e.to_string())
    }
}

#[derive(Default)]
struct Flags {
    json: bool,
    yes: bool,
    include_review: bool,
    categories: Vec<Category>,
    roots: Vec<PathBuf>,
    positional: Vec<String>,
    /// Options as typed, to check them against the command.
    seen: Vec<&'static str>,
    help: bool,
}

fn parse(args: &[String]) -> Result<Flags, String> {
    let mut flags = Flags::default();
    let mut it = args.iter();
    while let Some(arg) = it.next() {
        match arg.as_str() {
            "--json" => {
                flags.json = true;
                flags.seen.push("--json");
            }
            "--yes" | "-y" => {
                flags.yes = true;
                flags.seen.push("--yes");
            }
            "--include-review" => {
                flags.include_review = true;
                flags.seen.push("--include-review");
            }
            "-c" | "--category" => {
                let value = it.next().ok_or("-c needs a category")?;
                let category = Category::parse(value).ok_or_else(|| format!("Unknown category: {value}"))?;
                flags.categories.push(category);
                flags.seen.push("-c");
            }
            "--root" => {
                let value = it.next().ok_or("--root needs a folder")?;
                flags.roots.push(absolute_root(value)?);
                flags.seen.push("--root");
            }
            "-h" | "--help" => flags.help = true,
            other if other.starts_with('-') && other.len() > 1 => return Err(format!("Unknown option: {other}")),
            other => flags.positional.push(other.to_string()),
        }
    }
    Ok(flags)
}

/// `--root` made absolute (relative to the current folder), normalised, and checked to be a
/// folder that exists.
fn absolute_root(value: &str) -> Result<PathBuf, String> {
    if value.trim().is_empty() {
        return Err("--root needs a folder".to_string());
    }
    let abs = std::path::absolute(value).map_err(|e| format!("--root {value}: {e}"))?;
    let abs = PathBuf::from(ss::paths::normalize(&abs.to_string_lossy()));
    if !abs.is_dir() {
        return Err(format!("--root {value}: not a folder ({})", abs.display()));
    }
    Ok(abs)
}

/// Options and positional arguments each command accepts.
fn check_args(command: &str, flags: &Flags) -> Result<(), String> {
    let (allowed, positional): (&[&str], usize) = match command {
        "status" | "activity" => (&["--json"][..], 0),
        "scan" => (&["--json", "-c", "--root"][..], 0),
        "clean" => (&["--json", "--yes", "--include-review", "-c", "--root"][..], 0),
        "restore" => (&["--json"][..], 1),
        "help" | "-h" | "--help" | "version" | "-V" | "--version" => (&[][..], 0),
        other => return Err(format!("Unknown command: {other}")),
    };
    if let Some(bad) = flags.seen.iter().find(|f| !allowed.contains(*f)) {
        return Err(format!("`{command}` doesn't take {bad}"));
    }
    if flags.positional.len() > positional {
        let extra = &flags.positional[positional..];
        return Err(format!("`{command}` doesn't take {}: {}", if extra.len() == 1 { "this argument" } else { "these arguments" }, extra.join(" ")));
    }
    Ok(())
}

fn main() -> ExitCode {
    let args: Vec<String> = std::env::args().skip(1).collect();
    let command = args.first().map(String::as_str).unwrap_or("help");
    let rest = if args.is_empty() { &args[..] } else { &args[1..] };

    let result = match parse(rest) {
        Err(message) => Err(CliError::Usage(message)),
        Ok(flags) if flags.help => {
            print!("{}", help());
            Ok(())
        }
        Ok(flags) => match check_args(command, &flags) {
            Err(message) => Err(CliError::Usage(message)),
            Ok(()) => match command {
                "status" => status(&flags),
                "scan" => scan(&flags),
                "clean" => clean(&flags),
                "activity" => activity(&flags),
                "restore" => restore(&flags),
                "help" | "-h" | "--help" => {
                    print!("{}", help());
                    Ok(())
                }
                "version" | "-V" | "--version" => {
                    println!("spacesaver {VERSION}");
                    Ok(())
                }
                other => Err(CliError::Usage(format!("Unknown command: {other}"))),
            },
        },
    };

    match result {
        Ok(()) => ExitCode::SUCCESS,
        Err(CliError::Usage(message)) => {
            eprintln!("{message}\n");
            eprint!("{}", help());
            ExitCode::from(2)
        }
        Err(CliError::Failed(message)) => {
            eprintln!("error: {message}");
            ExitCode::from(1)
        }
    }
}

fn plural(n: usize, one: &str) -> String {
    if n == 1 {
        format!("1 {one}")
    } else {
        format!("{n} {one}s")
    }
}

fn percent(part: u64, whole: u64) -> u64 {
    if whole == 0 {
        0
    } else {
        ((part as f64 / whole as f64) * 100.0).round() as u64
    }
}

// ---------- status ----------

fn status(flags: &Flags) -> Result<(), CliError> {
    let store = Store::open_default();
    let disk = system::disk_info(&system::system_drive());
    let last = store.load_scan();
    let entries = store.activity().entries();
    let restorable = entries.iter().filter(|e| e.can_restore()).count();

    if flags.json {
        let value = serde_json::json!({
            "version": VERSION,
            "disk": disk,
            "lastScan": last.as_ref().map(|s| serde_json::json!({
                "date": s.date,
                "total": s.total_size(),
                "recommended": s.recommended_size(),
                "items": s.items.len(),
            })),
            "activity": { "entries": entries.len(), "restorable": restorable },
            "dataDir": store.dir(),
        });
        println!("{}", serde_json::to_string_pretty(&value)?);
        return Ok(());
    }

    println!("SpaceSaver for Windows {VERSION}");
    match &disk {
        Some(d) => println!(
            "Disk {}  {} free of {} ({}% used)",
            d.drive,
            format_bytes(d.free),
            format_bytes(d.total),
            percent(d.total.saturating_sub(d.free), d.total)
        ),
        None => println!("Disk: unknown"),
    }
    match &last {
        Some(s) => println!(
            "Last scan {}: {} found, {} recommended",
            ago(ss::fsutil::now(), s.date),
            format_bytes(s.total_size()),
            format_bytes(s.recommended_size())
        ),
        None => println!("Last scan: never (run `spacesaver scan`)"),
    }
    println!("Activity: {}, {} restorable", plural(entries.len(), "cleanup"), restorable);
    println!("Data folder: {}", store.dir().display());
    Ok(())
}

// ---------- scan ----------

fn run_scan(flags: &Flags) -> ScanSummary {
    let mut env = ScanEnv::from_system();
    if !flags.roots.is_empty() {
        env.project_roots = flags.roots.clone();
    }
    let guard = SafetyGuard::new(GuardConfig::from_system());
    let opts = ScanOptions { categories: (!flags.categories.is_empty()).then(|| flags.categories.clone()) };
    ss::scan(&env, Some(&guard), &opts)
}

fn scan(flags: &Flags) -> Result<(), CliError> {
    if !flags.json {
        eprintln!("Scanning…");
    }
    let summary = run_scan(flags);
    if flags.categories.is_empty() && flags.roots.is_empty() {
        let _ = Store::open_default().save_scan(&summary);
    }
    if flags.json {
        println!("{}", serde_json::to_string_pretty(&summary)?);
        return Ok(());
    }
    print_summary(&summary, flags);
    Ok(())
}

fn risk_label(item: &CleanupItem) -> &'static str {
    match item.method {
        Method::RecycleBin => item.risk.title(),
        Method::Manual { .. } => "Manual",
        Method::Command { .. } => "Command",
    }
}

fn print_summary(summary: &ScanSummary, flags: &Flags) {
    println!(
        "Scanned in {:.1} s: {} found, {} recommended (●).",
        summary.duration_ms as f64 / 1000.0,
        format_bytes(summary.total_size()),
        format_bytes(summary.recommended_size())
    );
    if let Some(d) = &summary.disk {
        println!("Disk {}: {} free of {}.", d.drive, format_bytes(d.free), format_bytes(d.total));
    }
    let show_steps = flags.categories == [Category::WslDocker];
    for cat in &summary.categories {
        if cat.count == 0 {
            continue;
        }
        println!("\n{} · {}", cat.title, format_bytes(cat.size));
        for item in summary.items.iter().filter(|i| i.category == cat.id) {
            let mark = if item.recommended && item.is_selectable() { "●" } else { "○" };
            println!("  {mark} {:>9}  {:<7}  {}  {}", format_bytes(item.size), risk_label(item), item.title, item.subtitle);
            if let Some(reason) = &item.blocked_reason {
                println!("                        blocked: {reason}");
            }
            if let Method::Manual { instructions, commands } = &item.method {
                if show_steps {
                    for line in instructions.lines() {
                        println!("      {line}");
                    }
                    println!();
                } else if !commands.is_empty() {
                    println!("                        never deleted; to shrink: {}", commands.join("  →  "));
                }
            }
        }
    }
    if summary.items.is_empty() {
        println!("\nNothing found.");
    } else {
        println!("\nNext: `spacesaver clean` shows what Smart Clean would move; `spacesaver clean --yes` moves it to the Recycle Bin.");
    }
}

// ---------- clean ----------

fn clean(flags: &Flags) -> Result<(), CliError> {
    if !flags.json {
        eprintln!("Scanning…");
    }
    let summary = run_scan(flags);
    let selected: Vec<CleanupItem> = summary
        .items
        .iter()
        .filter(|i| i.is_selectable() && (i.recommended || (flags.include_review && i.risk == Risk::Review)))
        .cloned()
        .collect();

    let store = Store::open_default();
    let log = store.activity();
    let guard = SafetyGuard::new(GuardConfig::from_system());
    let trash = SystemTrash;
    let bins = SystemRecycleBin;
    let cleaner = Cleaner::new(&guard, &trash, &log).with_recycle_bin(&bins);
    let opts = if flags.yes { CleanOptions::run("cli") } else { CleanOptions::dry_run("cli") };
    let verbose = flags.yes && !flags.json;
    let mut progress = |p: &CleanProgress| {
        if verbose && p.done < p.total {
            eprintln!("[{}/{}] {}", p.done + 1, p.total, p.current);
        }
    };
    let report = cleaner.clean(&selected, &opts, &mut progress);

    if !report.dry_run && !report.moved_ids.is_empty() {
        if let Some(mut last) = store.load_scan() {
            last.items.retain(|i| !report.moved_ids.contains(&i.id));
            last.refresh();
            let _ = store.save_scan(&last);
        }
    }

    if flags.json {
        println!("{}", serde_json::to_string_pretty(&report)?);
    } else {
        print_report(&report, flags);
    }
    if report.dry_run {
        return Ok(());
    }
    if report.log_error.is_some() {
        return Err(CliError::Failed(if report.items.is_empty() {
            "the activity log couldn't be written, so nothing was moved".to_string()
        } else {
            "the activity log couldn't be written; restore what moved from the Recycle Bin yourself".to_string()
        }));
    }
    if !report.errors.is_empty() {
        return Err(CliError::Failed(if report.items.is_empty() {
            "nothing was moved".to_string()
        } else {
            format!("only partly done: {}", plural(report.errors.len(), "problem"))
        }));
    }
    Ok(())
}

/// Quotes a path for the suggested command line. Double quotes work in cmd and PowerShell;
/// a path with `$` or a backtick gets a PowerShell single-quoted literal instead, since
/// PowerShell would expand those inside double quotes.
fn quote_arg(arg: &str) -> String {
    if arg.contains('$') || arg.contains('`') {
        return ss::wsl::ps_quote(arg);
    }
    if !arg.is_empty() && !arg.chars().any(|c| c.is_whitespace() || "&|<>^;,'()@{}[]#%!".contains(c)) {
        arg.to_string()
    } else {
        format!("\"{arg}\"")
    }
}

fn print_report(report: &CleanReport, flags: &Flags) {
    if report.items.is_empty() && report.skipped.is_empty() && report.errors.is_empty() {
        if flags.include_review {
            println!("Nothing to clean.");
        } else {
            println!("Nothing recommended to clean. Add --include-review to include Review items.");
        }
        return;
    }
    if report.dry_run {
        println!("Dry run: nothing was moved.\n");
        println!("Would move {} ({}) to the Recycle Bin:", plural(report.items.len(), "item"), format_bytes(report.bytes));
    } else {
        println!("Moved {} ({}) to the Recycle Bin:", plural(report.items.len(), "item"), format_bytes(report.bytes));
    }
    for item in &report.items {
        println!("  {:>9}  {}", format_bytes(item.size), item.title);
    }
    if !report.skipped.is_empty() {
        println!("\nSkipped:");
        for s in &report.skipped {
            println!("  {}: {}", s.title, s.reason);
        }
    }
    if !report.errors.is_empty() {
        println!("\nProblems:");
        for e in &report.errors {
            println!("  {e}");
        }
    }
    if report.dry_run {
        let mut cmd = "spacesaver clean --yes".to_string();
        if flags.include_review {
            cmd.push_str(" --include-review");
        }
        for c in &flags.categories {
            cmd.push_str(" -c ");
            cmd.push_str(c.id());
        }
        for root in &flags.roots {
            cmd.push_str(" --root ");
            cmd.push_str(&quote_arg(&root.to_string_lossy()));
        }
        println!("\nRun `{cmd}` to move them.");
    } else if report.log_error.is_some() {
        println!("\nThe activity log couldn't be written, so this cleanup can't be undone with `spacesaver restore`.");
        if !report.items.is_empty() {
            println!("What moved is in the Recycle Bin; restore it from there.");
        }
    } else if let Some(entry) = &report.entry {
        println!("\nThe space is freed when you empty the Recycle Bin.");
        println!("Undo with: spacesaver restore {}", entry.id);
    }
}

// ---------- activity and restore ----------

fn activity(flags: &Flags) -> Result<(), CliError> {
    let entries = Store::open_default().activity().entries();
    if flags.json {
        println!("{}", serde_json::to_string_pretty(&entries)?);
        return Ok(());
    }
    if entries.is_empty() {
        println!("No cleanups yet.");
        return Ok(());
    }
    let now = ss::fsutil::now();
    println!("{:<9} {:<10} {:<18} {:>9}  WHAT", "ID", "WHEN", "STATUS", "SIZE");
    for e in &entries {
        let status = format!("{:?}", e.status);
        println!(
            "{:<9} {:<10} {:<18} {:>9}  {} ({}, {})",
            e.id,
            ago(now, e.date),
            status,
            format_bytes(e.bytes),
            e.title,
            e.source,
            plural(e.records.len(), "path")
        );
    }
    println!("\nRestore with: spacesaver restore <id>");
    Ok(())
}

fn restore(flags: &Flags) -> Result<(), CliError> {
    let id = flags.positional.first().ok_or_else(|| CliError::Usage("restore needs an activity id".to_string()))?;
    let store = Store::open_default();
    let log = store.activity();
    let guard = SafetyGuard::new(GuardConfig::from_system());
    let trash = SystemTrash;
    let report = Cleaner::new(&guard, &trash, &log).restore(id).map_err(CliError::Failed)?;
    if flags.json {
        println!("{}", serde_json::to_string_pretty(&report)?);
    } else {
        println!(
            "Restored {} of {} from \"{}\".",
            report.restored,
            plural(report.entry.records.len(), "path"),
            report.entry.title
        );
        for e in &report.errors {
            println!("  {e}");
        }
    }
    if !report.errors.is_empty() {
        return Err(CliError::Failed(if report.restored == 0 {
            "nothing was restored".to_string()
        } else {
            format!("only partly restored: {}", plural(report.errors.len(), "problem"))
        }));
    }
    Ok(())
}
