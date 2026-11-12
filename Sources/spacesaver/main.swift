import Foundation
import SpaceSaverCore

// spacesaver: command-line front end for SpaceSaver. Shares settings, activity and plans
// with the app through ~/.spacesaver.

setvbuf(stdout, nil, _IOLBF, 0)

let version = MCPServer.serverVersion
var args = Array(CommandLine.arguments.dropFirst())
let command = args.isEmpty ? "help" : args.removeFirst()

// MARK: - Argument helpers

func flag(_ name: String) -> Bool {
    if let i = args.firstIndex(of: name) {
        args.remove(at: i)
        return true
    }
    return false
}

func option(_ name: String) -> String? {
    guard let i = args.firstIndex(of: name), i + 1 < args.count else { return nil }
    let value = args[i + 1]
    args.removeSubrange(i...(i + 1))
    return value
}

func options(_ name: String) -> [String] {
    var values: [String] = []
    while let v = option(name) { values.append(v) }
    return values
}

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("spacesaver: \(message)\n".utf8))
    exit(1)
}

func printJSON<T: Encodable>(_ value: T) {
    let data = (try? JSONStore.encoder.encode(value)) ?? Data()
    print(String(decoding: data, as: UTF8.self))
}

let isTTY = isatty(STDOUT_FILENO) != 0
func color(_ code: String, _ text: String) -> String { isTTY ? "\u{1B}[\(code)m\(text)\u{1B}[0m" : text }
func bold(_ t: String) -> String { color("1", t) }
func dim(_ t: String) -> String { color("2", t) }
func riskColored(_ r: RiskLevel) -> String {
    switch r {
    case .safe: return color("32", "safe   ")
    case .review: return color("33", "review ")
    case .caution: return color("31", "caution")
    }
}

func pad(_ s: String, _ width: Int) -> String {
    s.count >= width ? String(s.prefix(width - 1)) + "…" : s + String(repeating: " ", count: width - s.count)
}

func lpad(_ s: String, _ width: Int) -> String {
    s.count >= width ? s : String(repeating: " ", count: width - s.count) + s
}

func parseCategories(_ raw: [String]) -> Set<CleanupCategory> {
    guard !raw.isEmpty else { return Set(CleanupCategory.reclaimScanCategories) }
    var set = Set<CleanupCategory>()
    for name in raw.flatMap({ $0.split(separator: ",").map(String.init) }) {
        guard let c = CleanupCategory.allCases.first(where: {
            $0.rawValue.lowercased() == name.lowercased() || $0.title.lowercased() == name.lowercased()
        }) else {
            fail("unknown category '\(name)'. Choose from: \(CleanupCategory.reclaimScanCategories.map(\.rawValue).joined(separator: ", "))")
        }
        set.insert(c)
    }
    return set
}

func runScan(_ categories: Set<CleanupCategory>, quiet: Bool) -> ScanSummary {
    let settings = Settings.load()
    let scanner = ReclaimScanner(env: ScanEnvironment(settings: settings))
    let done = CancellationFlag()
    if !quiet && isatty(STDERR_FILENO) != 0 {
        Thread.detachNewThread {
            let frames = ["⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏"]
            var i = 0
            while !done.isCancelled {
                FileHandle.standardError.write(Data("\r\(frames[i % frames.count]) \(scanner.phase)\u{1B}[K".utf8))
                i += 1
                Thread.sleep(forTimeInterval: 0.1)
            }
            FileHandle.standardError.write(Data("\r\u{1B}[K".utf8))
        }
    }
    let summary = scanner.run(categories: categories)
    done.cancel()
    Thread.sleep(forTimeInterval: 0.15)
    // A partial scan only replaces the categories it covered in the saved results.
    var saved = summary
    if categories.count < CleanupCategory.reclaimScanCategories.count, let previous = LastScanStore.load() {
        saved.items = previous.items.filter { !categories.contains($0.category) } + summary.items
        saved.items.sort { $0.size > $1.size }
    }
    LastScanStore.save(saved)
    return summary
}

func printItems(_ items: [CleanupItem]) {
    let grouped = Dictionary(grouping: items, by: \.category)
    for category in CleanupCategory.allCases {
        guard let list = grouped[category], !list.isEmpty else { continue }
        print("\n" + bold("\(category.title)") + dim("  \(ByteFormat.string(list.totalSize))"))
        for item in list.sorted(by: { $0.size > $1.size }) {
            let blocked = item.blockedReason.map { color("2", "  ⏸ \($0)") } ?? ""
            let star = item.recommended && item.isSelectable ? color("32", "●") : " "
            print("  \(star) \(lpad(ByteFormat.string(item.size), 10))  \(riskColored(item.risk))  \(pad(item.title, 44)) \(dim(item.subtitle))\(blocked)")
        }
    }
}

// MARK: - Commands

switch command {
case "help", "-h", "--help":
    print("""
    \(bold("spacesaver")) \(version): find and safely reclaim disk space on macOS

    \(bold("USAGE"))
      spacesaver <command> [options]

    \(bold("COMMANDS"))
      status                       Disk usage, purgeable space and last scan
      scan [-c category] [--json]  Find reclaimable space (● = recommended)
      clean [options]              Clean recommended items (dry run unless --yes)
          -c, --category <name>      Limit to categories (repeatable, comma-separated)
          --include-review           Also clean "review" items (never "caution")
          --yes                      Actually clean (moves to Trash; Docker uses prune)
      map [path] [--depth N]       Biggest folders under a path (default: home)
      large [path] [--min 500MB]   Largest files
      dupes [path...] [--min 1MB]  Duplicate files by SHA-256
      explain <path>               What a folder is and whether it's safe to remove
      preflight <GB> [--headroom 2]  Will an operation needing <GB> fit?
      secrets [path...]            Audit AI session logs for leaked API keys
      activity [--limit 20]        Cleanup history
      restore <id>                 Undo a cleanup (moves items back from Trash)
      purge [--days 7]             Permanently remove SpaceSaver-cleaned items from Trash
      auto [--force]               Scheduled run (used by the LaunchAgent)
      mcp                          Run the MCP server for AI agents (stdio)
      rules                        Show built-in rules and the custom rules file

    \(bold("CATEGORIES"))
      \(CleanupCategory.reclaimScanCategories.map(\.rawValue).joined(separator: ", "))

    \(bold("AI AGENTS"))
      claude mcp add spacesaver -- \(CommandLine.arguments[0]) mcp
    """)

case "version", "--version", "-v":
    print("spacesaver \(version)")

case "status":
    let json = flag("--json")
    guard let disk = DiskStatus.current() else { fail("couldn't read disk status") }
    HistoryStore().recordSample(disk)
    let last = LastScanStore.load()
    if json {
        struct Out: Encodable {
            var disk: DiskStatus
            var lastScan: Date?
            var safeToClean: Int64?
        }
        printJSON(Out(disk: disk, lastScan: last?.date, safeToClean: last?.recommendedSize))
        break
    }
    let width = 40
    let filled = Int(disk.usedFraction * Double(width))
    let bar = String(repeating: "█", count: filled) + String(repeating: "░", count: width - filled)
    print(bold("\(disk.volumeName)") + dim(" (\(disk.format))"))
    print("  \(color(disk.usedFraction > 0.9 ? "31" : "36", bar)) \(Int(disk.usedFraction * 100))%")
    print("  Used       \(ByteFormat.string(disk.used)) of \(ByteFormat.string(disk.total))")
    print("  Free       \(bold(ByteFormat.string(disk.free)))")
    print("  Purgeable  \(ByteFormat.string(disk.purgeable))  \(dim("(macOS frees this on demand)"))")
    let snapshots = LocalSnapshots.list()
    if !snapshots.isEmpty { print("  Snapshots  \(snapshots.count) local Time Machine snapshots") }
    let held = CleanupEngine().bytesHeldInTrash()
    if held > 0 { print("  In Trash   \(ByteFormat.string(held)) from SpaceSaver cleanups (run `spacesaver purge`)") }
    if let last {
        print("\n  Last scan  \(RelativeTime.string(since: last.date)): \(bold(ByteFormat.string(last.recommendedSize))) safe to clean")
    } else {
        print("\n  Run `spacesaver scan` to find reclaimable space.")
    }

case "scan":
    let categories = parseCategories(options("-c") + options("--category"))
    let json = flag("--json")
    let minSize = option("--min").flatMap(ByteFormat.parse) ?? 0
    let summary = runScan(categories, quiet: json)
    let items = summary.items.filter { $0.size >= minSize }
    if json {
        printJSON(ScanSummary(date: summary.date, items: items, duration: summary.duration))
        break
    }
    printItems(items)
    let selectable = items.filter(\.isSelectable)
    print("\n" + bold("Total reclaimable: \(ByteFormat.string(selectable.totalSize))") +
          "   recommended (●): " + color("32", ByteFormat.string(summary.recommendedSize)) +
          dim("   scanned in \(String(format: "%.1f", summary.duration))s"))
    print(dim("Clean recommended items with: spacesaver clean --yes"))

case "clean":
    let categories = parseCategories(options("-c") + options("--category"))
    let includeReview = flag("--include-review")
    let yes = flag("--yes") || flag("-y")
    let settings = Settings.load()
    var summary = LastScanStore.load()
    if summary == nil || Date().timeIntervalSince(summary!.date) > 3600 || flag("--rescan") {
        summary = runScan(categories, quiet: false)
    }
    let picks = summary!.items.filter { item in
        categories.contains(item.category) && item.isSelectable && item.method != .emptyTrash
            && (item.recommended || (includeReview && item.risk == .review))
            && item.risk != .caution
    }
    if picks.isEmpty {
        print("Nothing to clean with these options.")
        break
    }
    printItems(picks)
    print("\n" + bold("Would clean \(picks.count) items, \(ByteFormat.string(picks.totalSize))."))
    guard yes else {
        print(dim("Dry run. Add --yes to move these to the Trash (Docker items use docker prune)."))
        break
    }
    let engine = CleanupEngine(settings: settings)
    let report = engine.clean(picks, source: "cli") { done, total, title in
        if isatty(STDERR_FILENO) != 0 {
            FileHandle.standardError.write(Data("\r[\(done)/\(total)] \(title)\u{1B}[K".utf8))
        }
    }
    FileHandle.standardError.write(Data("\r\u{1B}[K".utf8))
    print(color("32", "✓ Cleaned \(ByteFormat.string(report.bytesCleaned))."))
    if report.bytesMovedToTrash > 0 {
        print("  \(ByteFormat.string(report.bytesMovedToTrash)) is in the Trash and restorable for \(settings.trashRetentionDays) days " +
              "(`spacesaver activity`, `spacesaver restore <id>`). Run `spacesaver purge --days 0` to free it now.")
    }
    for error in report.errors { print(color("31", "  ✗ \(error)")) }
    var remaining = LastScanStore.load() ?? summary!
    let cleanedIDs = Set(picks.map(\.id))
    remaining.items.removeAll { cleanedIDs.contains($0.id) }
    LastScanStore.save(remaining)

case "map":
    let root = Paths.expand(args.first(where: { !$0.hasPrefix("-") }) ?? "~")
    let depth = Int(option("--depth") ?? "1") ?? 1
    let top = Int(option("--top") ?? "20") ?? 20
    let start = Date()
    var options = TreeScanner.Options(root: root)
    options.excluded = Settings.load().expandedExclusions(home: NSHomeDirectory())
    let scanner = TreeScanner(options: options)
    let tree = scanner.scan()
    let elapsed = Date().timeIntervalSince(start)
    let progress = scanner.progress
    print(bold("\(Paths.abbreviate(root))  \(ByteFormat.string(tree.size))") +
          dim("  \(progress.files) files, \(progress.directories) folders in \(String(format: "%.1f", elapsed))s" +
              (progress.denied > 0 ? ", \(progress.denied) unreadable" : "")))
    func show(_ node: FileNode, level: Int) {
        for child in node.children.prefix(top) {
            let share = tree.size > 0 ? Double(child.size) / Double(tree.size) : 0
            let bar = String(repeating: "▇", count: max(Int(share * 30), share > 0.005 ? 1 : 0))
            let indent = String(repeating: "  ", count: level)
            print("\(lpad(ByteFormat.string(child.size), 10))  \(color("36", pad(bar, 31)))\(indent)\(child.displayName)\(child.isDirectory ? "/" : "")")
            if level + 1 < depth && child.isDirectory { show(child, level: level + 1) }
        }
    }
    show(tree, level: 0)
    let history = HistoryStore()
    let snapshot = ScanSnapshot.make(from: tree)
    if let previous = history.previousSnapshot(root: tree.name) {
        let changes = HistoryStore.growth(from: previous, to: snapshot).prefix(8)
        if !changes.isEmpty {
            print("\n" + bold("Changes since \(RelativeTime.string(since: previous.date))"))
            for c in changes {
                let sign = c.delta >= 0 ? color("31", "+" + ByteFormat.string(c.delta)) : color("32", "−" + ByteFormat.string(-c.delta))
                print("  \(lpad(sign, 12))  \(Paths.abbreviate(c.path))")
            }
        }
    }
    history.saveSnapshot(snapshot)

case "large":
    let root = Paths.expand(args.first(where: { !$0.hasPrefix("-") }) ?? "~")
    let minSize = option("--min").flatMap(ByteFormat.parse) ?? Int64(Settings.load().largeFileThresholdMB) * 1_000_000
    let top = Int(option("--top") ?? "30") ?? 30
    var options = TreeScanner.Options(root: root)
    options.largeFileThreshold = minSize
    options.keepFilesAtLeast = minSize
    let scanner = TreeScanner(options: options)
    _ = scanner.scan()
    let files = scanner.largeFiles.prefix(top)
    if flag("--json") { printJSON(Array(files)); break }
    for f in files {
        print("\(lpad(ByteFormat.string(f.size), 10))  \(dim(RelativeTime.age(of: f.modified).padding(toLength: 6, withPad: " ", startingAt: 0)))  \(Paths.abbreviate(f.path))")
    }
    if files.isEmpty { print("No files over \(ByteFormat.string(minSize)).") }

case "dupes", "duplicates":
    let minSize = option("--min").flatMap(ByteFormat.parse) ?? Int64(Settings.load().duplicateMinSizeMB) * 1_000_000
    let json = flag("--json")
    let roots = args.filter { !$0.hasPrefix("-") }.map { Paths.expand($0) }
    let finder = DuplicateFinder(roots: roots.isEmpty ? [NSHomeDirectory()] : roots, minSize: minSize,
                                 excluded: Settings.load().expandedExclusions(home: NSHomeDirectory()))
    let groups = finder.find()
    if json { printJSON(groups); break }
    for g in groups.prefix(50) {
        print(bold("\(ByteFormat.string(g.reclaimable)) reclaimable") + dim("  \(g.files.count) × \(ByteFormat.string(g.size))  sha256 \(g.hash.prefix(12))"))
        for (i, f) in g.files.enumerated() {
            print("   \(i == g.keep ? color("32", "keep") : color("33", "dup ")) \(Paths.abbreviate(f.path))")
        }
    }
    let total = groups.reduce(Int64(0)) { $0 + $1.reclaimable }
    print("\n" + bold("\(groups.count) duplicate groups, \(ByteFormat.string(total)) reclaimable.") +
          dim(" Review and remove them in the SpaceSaver app."))

case "explain":
    guard let raw = args.first else { fail("usage: spacesaver explain <path>") }
    let path = (Paths.expand(raw) as NSString).standardizingPath
    let exp = KnowledgeBase().explain(path)
    print(bold(exp.title) + "  " + riskColored(exp.risk) + dim("  (\(exp.source))"))
    print(exp.summary)
    if let r = exp.regenerate { print(dim("Rebuild: ") + r) }
    if Paths.exists(path) { print(dim("Size: ") + ByteFormat.string(DirectorySizer.measure(path).bytes)) }
    if !SafetyGuard(excluded: Settings.load().excludedPaths).isAllowed(path) {
        print(color("31", "SpaceSaver will not remove this path (protected)."))
    }

case "preflight":
    guard let raw = args.first, let gbValue = Double(raw) else { fail("usage: spacesaver preflight <GB> [--headroom GB]") }
    let headroom = Double(option("--headroom") ?? "2") ?? 2
    let result = Preflight.check(requiredBytes: Int64(gbValue * 1e9), headroomBytes: Int64(headroom * 1e9))
    print((result.fits ? color("32", "✓ ") : color("31", "✗ ")) + result.message)
    if !result.fits, let scan = LastScanStore.load() {
        let plan = RoomPlanner.plan(toFree: result.shortfallBytes, from: scan.items)
        print("\nSafest way to free \(ByteFormat.string(result.shortfallBytes)):")
        printItems(plan.items)
        print(plan.satisfied ? "" : color("33", "\nEven all safe and review items aren't enough."))
    }
    exit(result.fits ? 0 : 2)

case "secrets":
    var targets = args.filter { !$0.hasPrefix("-") }.map { Paths.expand($0) }
    if targets.isEmpty {
        targets = ["~/.claude/projects", "~/.codex/sessions", "~/.gemini/tmp", "~/.continue/sessions",
                   "~/.copilot/session-state", "~/.claude/history.jsonl"].map { Paths.expand($0) }.filter(Paths.exists)
    }
    print(dim("Scanning \(targets.count) locations offline…"))
    let findings = SecretScanner.scan(files: targets)
    if findings.isEmpty {
        print(color("32", "✓ No credentials found."))
        break
    }
    let byKind = Dictionary(grouping: findings, by: \.kind)
    for (kind, list) in byKind.sorted(by: { $0.value.count > $1.value.count }) {
        print(color("31", "\(kind): \(list.count)"))
        for f in list.prefix(10) {
            let location = Paths.abbreviate(f.file) + ":" + String(f.line)
            print("   \(f.redacted)  \(dim(location))")
        }
    }
    print("\n" + bold("Rotate these keys") + ", then archive or delete the transcripts (SpaceSaver › AI Session Logs).")
    exit(3)

case "activity":
    let limit = Int(option("--limit") ?? "20") ?? 20
    let entries = ActivityLog().entries().prefix(limit)
    if flag("--json") { printJSON(Array(entries)); break }
    if entries.isEmpty { print("No cleanups yet.") }
    let df = DateFormatter()
    df.dateStyle = .short
    df.timeStyle = .short
    for e in entries {
        let restorable = e.canRestore ? color("32", " ↩ restorable") : ""
        print("\(dim(String(e.id.uuidString.prefix(8)))) \(df.string(from: e.date))  \(lpad(ByteFormat.string(e.bytes), 10))  \(pad(e.title, 40)) \(dim(e.status.rawValue + " · " + e.source))\(restorable)")
        for err in e.errors.prefix(2) { print(color("31", "         \(err)")) }
    }

case "restore":
    guard let prefix = args.first?.lowercased() else { fail("usage: spacesaver restore <activity id>") }
    let log = ActivityLog()
    let matches = log.entries().filter { $0.id.uuidString.lowercased().hasPrefix(prefix) }
    guard matches.count == 1, let entry = matches.first else {
        fail(matches.isEmpty ? "no activity entry starts with \(prefix)" : "ambiguous id, use more characters")
    }
    do {
        let n = try CleanupEngine().restore(entry.id)
        print(color("32", "✓ Restored \(n) item\(n == 1 ? "" : "s") from \(entry.title)."))
    } catch {
        fail(error.localizedDescription)
    }

case "purge":
    let days = Int(option("--days") ?? "\(Settings.load().trashRetentionDays)") ?? 7
    let freed = CleanupEngine().purge(olderThanDays: days)
    print(freed > 0 ? color("32", "✓ Permanently freed \(ByteFormat.string(freed)).")
                    : "Nothing older than \(days) days to purge.")

case "auto":
    let outcome = AutoCleaner().run(force: flag("--force"))
    let stamp = ISO8601DateFormatter().string(from: Date())
    print("[\(stamp)] \(outcome.message)")

case "mcp":
    MCPServer().run()

case "rules":
    for category in CleanupCategory.allCases {
        let rules = RuleCatalog.rules(for: category)
        guard !rules.isEmpty else { continue }
        print(bold(category.title))
        for r in rules { print("  \(riskColored(r.risk)) \(pad(r.title, 36)) \(dim(r.paths.first ?? ""))") }
    }
    print("\n" + bold("Project artifacts: ") + Set(ArtifactRule.all.map(\.directory)).sorted().joined(separator: ", "))
    print("\nCustom rules: \(AppPaths.default.customRules) " + dim("(JSON array, same fields as built-in rules)"))

default:
    fail("unknown command '\(command)'. Run `spacesaver help`.")
}
