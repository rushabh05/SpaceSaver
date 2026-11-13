import AppKit
import Observation
import SpaceSaverCore
import SwiftUI

enum SidebarSection: Hashable {
    case overview
    case storageMap
    case category(CleanupCategory)
    case largeFiles
    case duplicates
    case apps
    case activity
    case approvals
}

struct Toast: Identifiable, Equatable {
    let id = UUID()
    var text: String
    var isError = false
}

/// A short notification the Dynamic Island shows for a few seconds.
struct IslandPeek: Identifiable, Equatable {
    let id = UUID()
    var symbol: String
    var tint: Color
    var title: String
    var subtitle: String
}

struct CleaningProgress: Equatable {
    var done: Int
    var total: Int
    var title: String
    var fraction: Double { total > 0 ? Double(done) / Double(total) : 0 }
}

/// What the cleanup confirmation sheet is about to do.
struct CleanupRequest: Identifiable {
    let id = UUID()
    var items: [CleanupItem]
    var title: String
    /// Set when the request came from an agent plan.
    var planID: String?
}

@MainActor
@Observable
final class AppModel {
    static let shared = AppModel()

    let paths = AppPaths.default
    var settings: SpaceSaverCore.Settings { didSet { if settings != oldValue { try? settings.save(paths) } } }

    // Disk
    var disk: DiskStatus?
    var samples: [DiskSample] = []
    var snapshotsCount = 0
    var hasFullDiskAccess = Permissions.hasFullDiskAccess

    // Reclaim scan
    var scan: ScanSummary?
    var isScanning = false
    var scanPhase = ""
    var scanFinished: [CleanupCategory] = []
    private var scanner: ReclaimScanner?
    var selection: Set<String> = []

    // Navigation and feedback
    var section: SidebarSection = .overview
    var cleaning: CleaningProgress?
    var islandPeek: IslandPeek?
    private var started = false
    var toast: Toast?
    var cleanupRequest: CleanupRequest?

    // Apps (uninstaller)
    var apps: [AppRecord] = []
    var appsLoading = false
    var appsLoaded = false

    // Updates
    var update: UpdateRelease?
    var updateStatus: UpdateStatus = .idle

    // Activity and agents
    var activity: [ActivityEntry] = []
    var plans: [CleanupPlan] = []
    var heldInTrash: Int64 = 0

    // Storage map
    var mapRootPath = NSHomeDirectory()
    var mapRoot: FileNode?
    var mapCurrent: FileNode?
    var mapScanning = false
    var mapProgress = ScanProgress()
    var mapDuration: TimeInterval = 0
    var largeFiles: [LargeFile] = []
    var largeFilesRoot: String?
    var growth: [GrowthEntry] = []
    var previousSnapshotDate: Date?
    private var treeScanner: TreeScanner?

    // Duplicates
    var duplicateRoots: [String] = [NSHomeDirectory()]
    var duplicateGroups: [DuplicateGroup] = []
    var duplicateIncluded: Set<String> = []
    var duplicatesScanning = false
    var duplicatesScanned = false
    var duplicateProgress = DuplicateProgress()
    private var duplicateFinder: DuplicateFinder?

    // AI
    var secretFindings: [String: [SecretFinding]] = [:]
    var auditing = false
    var aiExplanations: [String: String] = [:]
    var explaining: Set<String> = []

    private var timer: Timer?

    init() {
        settings = SpaceSaverCore.Settings.load()
        paths.ensure()
    }

    // MARK: Lifecycle

    func start() {
        guard !started else { return }
        started = true
        scan = LastScanStore.load(paths: paths)
        selection = Set(scan?.items.filter { $0.recommended && $0.isSelectable }.map(\.id) ?? [])
        refreshDisk()
        refreshActivity()
        refreshPlans()
        samples = HistoryStore(paths: paths).load().samples
        Task.detached(priority: .utility) {
            let count = LocalSnapshots.list().count
            await MainActor.run { self.snapshotsCount = count }
        }
        if settings.schedule.purgeExpiredTrash { purgeExpired(silent: true) }
        checkForUpdatesIfDue()
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 20, repeats: true) { _ in
            Task { @MainActor in
                self.refreshDisk()
                self.refreshPlans()
                self.checkForUpdatesIfDue()
            }
        }
    }

    func refreshDisk() {
        guard let status = DiskStatus.current() else { return }
        disk = status
        let store = HistoryStore(paths: paths)
        store.recordSample(status)
        samples = store.load().samples
        hasFullDiskAccess = Permissions.hasFullDiskAccess
    }

    func refreshActivity() {
        let log = ActivityLog(paths: paths)
        activity = log.entries()
        heldInTrash = activity.reduce(0) { $0 + $1.bytesInTrash }
    }

    func refreshPlans() {
        let latest = PlanStore(paths: paths).all()
        let hadPending = Set(plans.filter { $0.status == .pending }.map(\.id))
        plans = latest
        let newPending = latest.filter { $0.status == .pending && !hadPending.contains($0.id) }
        if plansLoadedOnce, let first = newPending.first {
            show("\(first.requester) is asking to free \(ByteFormat.string(first.totalSize)). Review it in Agent Requests.")
            peek("person.badge.shield.checkmark", .purple, "\(first.requester) wants \(ByteFormat.compact(first.totalSize))",
                 "Open SpaceSaver to approve or reject")
        }
        plansLoadedOnce = true
    }

    private var plansLoadedOnce = false

    var pendingPlans: [CleanupPlan] { plans.filter { $0.status == .pending } }

    var scanFraction: Double {
        Double(scanFinished.count) / Double(max(CleanupCategory.reclaimScanCategories.count, 1))
    }

    var quickCleanItems: [CleanupItem] {
        recommendedItems.filter { $0.method.isUndoable && $0.risk == .safe }
    }

    func peek(_ symbol: String, _ tint: Color, _ title: String, _ subtitle: String) {
        let p = IslandPeek(symbol: symbol, tint: tint, title: title, subtitle: subtitle)
        islandPeek = p
        Task {
            try? await Task.sleep(for: .seconds(4))
            if islandPeek?.id == p.id { islandPeek = nil }
        }
    }

    func show(_ text: String, error: Bool = false) {
        withAnimation(.snappy) { toast = Toast(text: text, isError: error) }
        let id = toast?.id
        Task {
            try? await Task.sleep(for: .seconds(error ? 7 : 5))
            if toast?.id == id { withAnimation(.snappy) { toast = nil } }
        }
    }

    // MARK: Reclaim scan

    func items(_ category: CleanupCategory) -> [CleanupItem] {
        scan?.items.filter { $0.category == category } ?? []
    }

    func total(_ category: CleanupCategory) -> Int64 {
        items(category).filter(\.isSelectable).totalSize
    }

    var recommendedItems: [CleanupItem] {
        scan?.items.filter { $0.recommended && $0.isSelectable } ?? []
    }

    var selectedItems: [CleanupItem] {
        scan?.items.filter { selection.contains($0.id) && $0.isSelectable } ?? []
    }

    func startScan(categories: Set<CleanupCategory> = Set(CleanupCategory.reclaimScanCategories)) {
        guard !isScanning else { return }
        isScanning = true
        scanFinished = []
        scanPhase = "Starting"
        let scanner = ReclaimScanner(env: ScanEnvironment(settings: settings))
        self.scanner = scanner
        let customRules = LocationRule.loadCustom(paths)
        let poll = Task { @MainActor in
            while !Task.isCancelled {
                scanPhase = scanner.phase
                scanFinished = scanner.finishedCategories
                try? await Task.sleep(for: .milliseconds(150))
            }
        }
        let fullScan = categories.count >= CleanupCategory.reclaimScanCategories.count - 1
        Task.detached(priority: .userInitiated) {
            let summary = scanner.run(categories: categories, customRules: customRules)
            await MainActor.run {
                poll.cancel()
                self.isScanning = false
                self.scanner = nil
                if scanner.cancellation.isCancelled {
                    self.show("Scan cancelled.")
                    return
                }
                var merged = summary
                if !fullScan, let old = self.scan {
                    // Partial rescan: replace only those categories.
                    merged.items = old.items.filter { !categories.contains($0.category) } + summary.items
                    merged.items.sort { $0.size > $1.size }
                }
                self.scan = merged
                LastScanStore.save(merged, paths: self.paths)
                self.selection = Set(merged.items.filter { $0.recommended && $0.isSelectable }.map(\.id))
                self.refreshDisk()
                self.show("Found \(ByteFormat.string(merged.items.filter(\.isSelectable).totalSize)) reclaimable in \(String(format: "%.0f", summary.duration))s. \(ByteFormat.string(merged.recommendedSize)) is recommended.")
                self.peek("sparkles", .green, "Scan complete", "\(ByteFormat.string(merged.recommendedSize)) safe to clean")
            }
        }
    }

    func cancelScan() { scanner?.cancel() }

    // MARK: Cleanup

    func requestCleanup(_ items: [CleanupItem], title: String? = nil, planID: String? = nil) {
        let usable = items.filter(\.isSelectable)
        guard !usable.isEmpty else { return }
        cleanupRequest = CleanupRequest(items: usable, title: title ?? "Clean \(ByteFormat.string(usable.totalSize))?",
                                        planID: planID)
    }

    /// Runs on a background thread; returns the report on the main actor.
    func performCleanup(_ request: CleanupRequest, progress: @escaping @Sendable (Int, Int, String) -> Void) async -> CleanupReport {
        let engine = CleanupEngine(safety: SafetyGuard(excluded: settings.excludedPaths), log: ActivityLog(paths: paths),
                                   paths: paths)
        let items = request.items
        let source = request.planID.map { "agent:\($0)" } ?? "app"
        cleaning = CleaningProgress(done: 0, total: items.count, title: items.first?.title ?? "")
        let report = await Task.detached(priority: .userInitiated) {
            engine.clean(items, source: source) { done, total, title in
                progress(done, total, title)
                Task { @MainActor in
                    if self.cleaning != nil { self.cleaning = CleaningProgress(done: done, total: total, title: title) }
                }
            }
        }.value
        cleaning = nil
        afterCleanup(items: items, report: report)
        if report.bytesCleaned > 0 {
            peek("checkmark.circle.fill", .green, "Cleaned \(ByteFormat.string(report.bytesCleaned))",
                 report.bytesMovedToTrash > 0 ? "In the Trash for \(settings.trashRetentionDays) days. Restorable." : "Space freed")
        }
        if let planID = request.planID {
            let ok = report.entries.contains { [ActivityStatus.completed, .partial].contains($0.status) }
            var summary = "Moved " + ByteFormat.string(report.bytesCleaned) + " to the Trash."
            if !report.errors.isEmpty { summary += " Errors: " + report.errors.joined(separator: "; ") }
            PlanStore(paths: paths).decide(planID, status: ok ? .executed : .failed, result: summary)
            refreshPlans()
        }
        return report
    }

    private func afterCleanup(items: [CleanupItem], report: CleanupReport) {
        let failedTitles = Set(report.entries.filter { $0.status == .failed }.map(\.title))
        let done = Set(items.filter { !failedTitles.contains($0.title) }.map(\.id))
        if var scan {
            scan.items.removeAll { done.contains($0.id) }
            withAnimation(Theme.spring) { self.scan = scan }
            LastScanStore.save(scan, paths: paths)
        }
        selection.subtract(done)
        // Keep derived views in sync.
        let removedPaths = Set(items.filter { done.contains($0.id) }.flatMap(\.paths))
        largeFiles.removeAll { removedPaths.contains($0.path) }
        pruneApps(removed: removedPaths)
        if !duplicateGroups.isEmpty {
            duplicateGroups = duplicateGroups.compactMap { group in
                var g = group
                g.files.removeAll { removedPaths.contains($0.path) }
                if g.files.count < 2 { return nil }
                g.keep = min(g.keep, g.files.count - 1)
                return g
            }
        }
        if let root = mapRoot {
            for path in removedPaths { if let node = root.find(path: path), let parent = node.parent { parent.removeChild(node) } }
            mapCurrent = mapCurrent ?? root
        }
        refreshActivity()
        refreshDisk()
    }

    func restore(_ entry: ActivityEntry) {
        let engine = CleanupEngine(settings: settings)
        do {
            let n = try engine.restore(entry.id)
            show("Restored \(n) item\(n == 1 ? "" : "s") to their original locations.")
        } catch {
            show(error.localizedDescription, error: true)
        }
        refreshActivity()
        refreshDisk()
    }

    func purge(ids: Set<UUID>? = nil) {
        let engine = CleanupEngine(settings: settings)
        Task.detached {
            let freed = engine.purge(olderThanDays: nil, ids: ids)
            await MainActor.run {
                self.refreshActivity()
                self.refreshDisk()
                self.show(freed > 0 ? "Permanently freed \(ByteFormat.string(freed))." : "Nothing left in the Trash to free.")
            }
        }
    }

    func purgeExpired(silent: Bool) {
        let engine = CleanupEngine(settings: settings)
        let days = settings.trashRetentionDays
        Task.detached(priority: .utility) {
            let freed = engine.purge(olderThanDays: days)
            await MainActor.run {
                self.refreshActivity()
                if freed > 0 && !silent { self.show("Freed \(ByteFormat.string(freed)) of expired Trash items.") }
            }
        }
    }

    func exclude(_ path: String) {
        let short = Paths.abbreviate(path)
        if !settings.excludedPaths.contains(short) { settings.excludedPaths.append(short) }
        if var scan {
            scan.items.removeAll { $0.paths.contains { Paths.isWithin($0, path) } }
            self.scan = scan
            LastScanStore.save(scan, paths: paths)
        }
        show("\(short) will be ignored from now on. Undo in Settings › Safety.")
    }

    // MARK: Agent plans

    func approve(_ plan: CleanupPlan) {
        PlanStore(paths: paths).decide(plan.id, status: .approved)
        requestCleanup(plan.asCleanupItems(), title: "Approve \(plan.requester)'s request?", planID: plan.id)
        refreshPlans()
    }

    func reject(_ plan: CleanupPlan) {
        PlanStore(paths: paths).decide(plan.id, status: .rejected, result: "Rejected by the user.")
        refreshPlans()
    }

    // MARK: Storage map

    func startMapScan(path: String? = nil) {
        if let path { mapRootPath = path }
        guard !mapScanning else { return }
        mapScanning = true
        mapProgress = ScanProgress()
        var options = TreeScanner.Options(root: mapRootPath)
        options.largeFileThreshold = Int64(settings.largeFileThresholdMB) * 1_000_000
        options.excluded = settings.expandedExclusions(home: NSHomeDirectory())
        let scanner = TreeScanner(options: options)
        treeScanner = scanner
        let start = Date()
        let poll = Task { @MainActor in
            while !Task.isCancelled {
                mapProgress = scanner.progress
                try? await Task.sleep(for: .milliseconds(120))
            }
        }
        let paths = self.paths
        Task.detached(priority: .userInitiated) {
            let tree = scanner.scan()
            let large = scanner.largeFiles
            let snapshot = ScanSnapshot.make(from: tree)
            let history = HistoryStore(paths: paths)
            let previous = history.previousSnapshot(root: tree.name)
            let growth = previous.map { HistoryStore.growth(from: $0, to: snapshot) } ?? []
            if !scanner.cancellation.isCancelled { history.saveSnapshot(snapshot) }
            await MainActor.run {
                poll.cancel()
                self.mapProgress = scanner.progress
                self.mapScanning = false
                self.treeScanner = nil
                if scanner.cancellation.isCancelled {
                    self.show("Storage map scan cancelled.")
                    return
                }
                self.mapDuration = Date().timeIntervalSince(start)
                self.peek("square.grid.3x3.fill", .blue, "Mapped \(Paths.abbreviate(tree.name))",
                          "\(ByteFormat.string(tree.size)) in \(tree.fileCount.formatted()) files")
                self.mapRoot = tree
                self.mapCurrent = tree
                self.largeFiles = large
                self.largeFilesRoot = tree.name
                self.growth = growth
                self.previousSnapshotDate = previous?.date
            }
        }
    }

    func cancelMapScan() { treeScanner?.cancel() }

    func trashNode(_ node: FileNode) {
        let path = node.path
        let exp = KnowledgeBase().explain(path)
        let item = CleanupItem(id: "map:\(path)", category: .largeFiles, title: node.displayName,
                               subtitle: Paths.abbreviate(path), paths: [path], size: node.size,
                               risk: max(exp.risk, .review), explanation: exp.summary, regenerate: exp.regenerate)
        requestCleanup([item], title: "Move \(node.displayName) to the Trash?")
    }

    // MARK: Duplicates

    func startDuplicateScan() {
        guard !duplicatesScanning else { return }
        duplicatesScanning = true
        duplicateGroups = []
        let finder = DuplicateFinder(roots: duplicateRoots, minSize: Int64(settings.duplicateMinSizeMB) * 1_000_000,
                                     excluded: settings.expandedExclusions(home: NSHomeDirectory()))
        duplicateFinder = finder
        let poll = Task { @MainActor in
            while !Task.isCancelled {
                duplicateProgress = finder.progress
                try? await Task.sleep(for: .milliseconds(150))
            }
        }
        Task.detached(priority: .userInitiated) {
            let groups = finder.find()
            await MainActor.run {
                poll.cancel()
                self.duplicatesScanning = false
                self.duplicateFinder = nil
                guard !finder.cancellation.isCancelled else { return }
                self.duplicatesScanned = true
                self.duplicateGroups = groups
                self.duplicateIncluded = Set(groups.map(\.id))
            }
        }
    }

    func cancelDuplicateScan() { duplicateFinder?.cancellation.cancel() }

    // MARK: AI

    func auditSecrets(_ items: [CleanupItem]) {
        guard !auditing else { return }
        auditing = true
        Task.detached(priority: .userInitiated) {
            let results = Dictionary(uniqueKeysWithValues: items.map { ($0.id, SecretScanner.scan(files: $0.paths)) })
            let found = results.values.reduce(0) { $0 + $1.count }
            await MainActor.run {
                self.secretFindings.merge(results) { $1 }
                self.auditing = false
                self.show(found == 0 ? "No credentials found in \(items.count) item\(items.count == 1 ? "" : "s")."
                                     : "Found \(found) credential\(found == 1 ? "" : "s"). Rotate them, then archive or delete the logs.",
                          error: found > 0)
            }
        }
    }

    func explainWithAI(path: String, size: Int64) {
        guard settings.ai.ollamaEnabled, !explaining.contains(path) else { return }
        explaining.insert(path)
        let explainer = OllamaExplainer(settings: settings.ai)
        let offline = KnowledgeBase().explain(path)
        let children = Paths.children(path)
        Task {
            do {
                let text = try await explainer.explain(path: path, size: size, children: children, offline: offline)
                aiExplanations[path] = text
            } catch {
                show(error.localizedDescription, error: true)
            }
            explaining.remove(path)
        }
    }

    // MARK: Helpers

    @ObservationIgnored var openWindowAction: OpenWindowAction?

    /// Brings the main window forward (or reopens it) from the menu bar or the island.
    func openMainWindow(section: SidebarSection? = nil) {
        if let section { withAnimation(Theme.spring) { self.section = section } }
        let main = NSApp.windows.first {
            ($0.identifier?.rawValue.hasPrefix("main") ?? false) && $0.styleMask.contains(.titled)
        }
        if let main {
            main.makeKeyAndOrderFront(nil)
        } else {
            openWindowAction?(id: "main")
        }
        NSApp.activate(ignoringOtherApps: true)
    }

    var cliPath: String? {
        let bundle = Bundle.main.bundleURL
        let candidates = [
            bundle.appendingPathComponent("Contents/Helpers/spacesaver").path,
            Bundle.main.executableURL?.deletingLastPathComponent().appendingPathComponent("spacesaver").path,
        ].compactMap { $0 }
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    func roomPlan(gb: Double) -> RoomPlanner.Plan {
        RoomPlanner.plan(toFree: Int64(gb * 1e9), from: scan?.items ?? [])
    }
}
