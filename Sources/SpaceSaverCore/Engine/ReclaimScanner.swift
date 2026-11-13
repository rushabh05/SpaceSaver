import Foundation

/// Runs every analyzer and returns de-duplicated, sorted cleanup candidates.
public final class ReclaimScanner: @unchecked Sendable {
    public let env: ScanEnvironment
    public let cancellation = CancellationFlag()
    private let lock = NSLock()
    private var _phase = "Starting"
    private var _finished: [CleanupCategory] = []

    public init(env: ScanEnvironment) { self.env = env }

    public var phase: String { lock.withLock { _phase } }
    public var finishedCategories: [CleanupCategory] { lock.withLock { _finished } }
    public func cancel() { cancellation.cancel() }

    public func run(categories: Set<CleanupCategory> = Set(CleanupCategory.reclaimScanCategories),
                    customRules: [LocationRule] = LocationRule.loadCustom()) -> ScanSummary {
        let start = Date()
        let running = env.settings.activeAppGuard ? RunningApps.snapshot() : .none
        let evaluator = RuleEvaluator(env: env, running: running, cancel: cancellation)
        let allRules = RuleCatalog.all + customRules
        let claimed = evaluator.claimedPaths(allRules)

        var tasks: [(CleanupCategory, () -> [CleanupItem])] = []
        func add(_ category: CleanupCategory, _ work: @escaping () -> [CleanupItem]) {
            if categories.contains(category) { tasks.append((category, work)) }
        }
        let env = self.env
        let cancel = cancellation
        add(.projectArtifacts) { ProjectAnalyzer(env: env, cancel: cancel).analyze() }
        add(.xcode) {
            evaluator.evaluate(RuleCatalog.rules(for: .xcode), claimed: claimed)
                + SimulatorAnalyzer(env: env, running: running).analyze()
        }
        add(.docker) { DockerAnalyzer(env: env).analyze() }
        add(.packageCaches) { evaluator.evaluate(RuleCatalog.rules(for: .packageCaches), claimed: claimed) }
        add(.ideCaches) {
            evaluator.evaluate(RuleCatalog.rules(for: .ideCaches), claimed: claimed)
                + WorkspaceStorageAnalyzer(env: env).analyze()
        }
        add(.aiModels) {
            evaluator.evaluate(RuleCatalog.rules(for: .aiModels), claimed: claimed) + OllamaAnalyzer(env: env).analyze()
        }
        add(.aiSessions) { AISessionAnalyzer(env: env, running: running).analyze() }
        add(.agentWorktrees) { WorktreeAnalyzer(env: env).analyze() }
        add(.systemJunk) { evaluator.evaluate(RuleCatalog.rules(for: .systemJunk), claimed: claimed) }
        add(.appleDevices) { evaluator.evaluate(RuleCatalog.rules(for: .appleDevices), claimed: claimed) }
        add(.downloads) { DownloadsAnalyzer(env: env).analyze() }
        add(.leftovers) { LeftoverAnalyzer(env: env, running: running).analyze() }
        add(.trash) { TrashAnalyzer(env: env).analyze() }
        if !customRules.isEmpty {
            add(.custom) { evaluator.evaluate(customRules, claimed: claimed) }
        }

        var results: [CleanupItem] = []
        let group = DispatchGroup()
        for (category, work) in tasks {
            group.enter()
            DispatchQueue.global(qos: .userInitiated).async { [self] in
                defer { group.leave() }
                if cancellation.isCancelled { return }
                lock.withLock { _phase = "Scanning \(category.title)" }
                let items = work()
                lock.withLock {
                    results.append(contentsOf: items)
                    _finished.append(category)
                    _phase = "Finished \(category.title)"
                }
            }
        }
        group.wait()

        let items = Self.deduplicate(results).sorted { $0.size > $1.size }
        return ScanSummary(date: Date(), items: items, duration: Date().timeIntervalSince(start))
    }

    /// Removes paths that appear in more than one item (keeping the more specific category), and
    /// items nested inside another item's folder.
    static func deduplicate(_ items: [CleanupItem]) -> [CleanupItem] {
        let priority: [CleanupCategory] = [.agentWorktrees, .projectArtifacts, .aiSessions, .aiModels, .xcode, .docker, .ideCaches,
                                           .packageCaches, .appleDevices, .downloads, .leftovers, .custom, .systemJunk, .trash]
        let ordered = items.sorted {
            (priority.firstIndex(of: $0.category) ?? 99) < (priority.firstIndex(of: $1.category) ?? 99)
        }
        var claimed: [String] = []
        var out: [CleanupItem] = []
        for var item in ordered {
            if item.paths.isEmpty {
                out.append(item)
                continue
            }
            let kept = item.paths.filter { path in
                !claimed.contains { Paths.isWithin(path, $0) || Paths.isWithin($0, path) }
            }
            if kept.isEmpty { continue }
            if kept.count != item.paths.count {
                let ratio = Double(kept.count) / Double(item.paths.count)
                item.size = Int64(Double(item.size) * ratio)
                item.paths = kept
            }
            claimed.append(contentsOf: kept)
            out.append(item)
        }
        return out
    }
}

/// Picks the least risky set of items that frees at least `target` bytes.
public enum RoomPlanner {
    public struct Plan: Sendable {
        public var items: [CleanupItem]
        public var total: Int64
        public var target: Int64
        public var satisfied: Bool { total >= target }
    }

    public static func plan(toFree target: Int64, from candidates: [CleanupItem],
                            maxRisk: RiskLevel = .review) -> Plan {
        let usable = candidates.filter { $0.isSelectable && $0.risk <= maxRisk && $0.size > 0 }
        // Safest first; within a risk level, largest first so fewer items are touched.
        let sorted = usable.sorted { a, b in
            a.risk != b.risk ? a.risk < b.risk : a.size > b.size
        }
        var chosen: [CleanupItem] = []
        var total: Int64 = 0
        for item in sorted where total < target {
            chosen.append(item)
            total += item.size
        }
        return Plan(items: chosen, total: total, target: target)
    }
}

/// Answers "will X GB fit?" for the CLI, MCP and the app.
public struct PreflightResult: Codable, Sendable {
    public var requiredBytes: Int64
    public var headroomBytes: Int64
    public var freeBytes: Int64
    public var purgeableBytes: Int64
    public var fits: Bool
    public var shortfallBytes: Int64
    public var message: String
}

public enum Preflight {
    public static func check(requiredBytes: Int64, headroomBytes: Int64 = 2_000_000_000,
                             disk: DiskStatus? = DiskStatus.current()) -> PreflightResult {
        let free = disk?.free ?? 0
        let purgeable = disk?.purgeable ?? 0
        let need = requiredBytes + headroomBytes
        let fits = free >= need
        let shortfall = max(need - free, 0)
        let message: String
        if fits {
            message = "Fits. Needs \(ByteFormat.string(requiredBytes)) + \(ByteFormat.string(headroomBytes)) headroom; \(ByteFormat.string(free)) free."
        } else if free + purgeable >= need {
            message = "Probably fits: \(ByteFormat.string(free)) free plus \(ByteFormat.string(purgeable)) macOS can purge on demand. Short by \(ByteFormat.string(shortfall)) of truly free space."
        } else {
            message = "Doesn't fit. Needs \(ByteFormat.string(need)) including headroom; only \(ByteFormat.string(free)) free. Free up \(ByteFormat.string(shortfall))."
        }
        return PreflightResult(requiredBytes: requiredBytes, headroomBytes: headroomBytes, freeBytes: free,
                               purgeableBytes: purgeable, fits: fits, shortfallBytes: shortfall, message: message)
    }
}
