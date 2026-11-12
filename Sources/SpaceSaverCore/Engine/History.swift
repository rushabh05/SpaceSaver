import Foundation

public struct DiskSample: Codable, Hashable, Sendable {
    public var date: Date
    public var total: Int64
    public var free: Int64
}

/// Sizes of the biggest folders from one storage-map scan, for "what grew since last time".
public struct ScanSnapshot: Codable, Sendable {
    public var root: String
    public var date: Date
    public var total: Int64
    public var folders: [String: Int64]

    /// Records folders down to `depth` levels that are at least `minSize`.
    public static func make(from root: FileNode, depth: Int = 4, minSize: Int64 = 20_000_000) -> ScanSnapshot {
        var folders: [String: Int64] = [:]
        func visit(_ node: FileNode, _ path: String, _ level: Int) {
            guard node.isDirectory, node.size >= minSize else { return }
            folders[path] = node.size
            guard level < depth else { return }
            for child in node.children where child.isDirectory {
                visit(child, Paths.join(path, child.name), level + 1)
            }
        }
        visit(root, root.name, 0)
        return ScanSnapshot(root: root.name, date: Date(), total: root.size, folders: folders)
    }
}

public struct GrowthEntry: Identifiable, Hashable, Sendable {
    public var path: String
    public var before: Int64
    public var after: Int64
    public var delta: Int64 { after - before }
    public var id: String { path }
}

public struct HistoryData: Codable, Sendable {
    public var samples: [DiskSample] = []
    public var snapshots: [ScanSnapshot] = []
}

/// Free-space history and storage-map snapshots (~/.spacesaver/history.json).
public final class HistoryStore: @unchecked Sendable {
    public let path: String

    public init(paths: AppPaths = .default) {
        paths.ensure()
        path = paths.history
    }

    public func load() -> HistoryData { JSONStore.load(HistoryData.self, from: path) ?? HistoryData() }

    private func modify(_ change: (inout HistoryData) -> Void) {
        JSONStore.withLock(path) {
            var data = load()
            change(&data)
            try? JSONStore.save(data, to: path)
        }
    }

    /// Records at most one sample per 30 minutes, keeping 180 days.
    public func recordSample(_ disk: DiskStatus, now: Date = Date()) {
        modify { data in
            if let last = data.samples.last, now.timeIntervalSince(last.date) < 1800 { return }
            data.samples.append(DiskSample(date: now, total: disk.total, free: disk.free))
            let cutoff = now.addingTimeInterval(-180 * 86_400)
            data.samples.removeAll { $0.date < cutoff }
        }
    }

    public func saveSnapshot(_ snapshot: ScanSnapshot) {
        modify { data in
            data.snapshots.append(snapshot)
            // Keep the last 5 per root.
            let forRoot = data.snapshots.filter { $0.root == snapshot.root }
            if forRoot.count > 5 {
                let drop = Set(forRoot.prefix(forRoot.count - 5).map(\.date))
                data.snapshots.removeAll { $0.root == snapshot.root && drop.contains($0.date) }
            }
        }
    }

    public func previousSnapshot(root: String, before date: Date = .distantFuture) -> ScanSnapshot? {
        load().snapshots.filter { $0.root == root && $0.date < date }.max { $0.date < $1.date }
    }

    /// Biggest changes between two snapshots. Only reports the deepest folder that explains a
    /// change, so a 5 GB growth in DerivedData isn't also listed for ~/Library and ~/Library/Developer.
    public static func growth(from old: ScanSnapshot, to new: ScanSnapshot, minDelta: Int64 = 100_000_000) -> [GrowthEntry] {
        let keys = Set(old.folders.keys).union(new.folders.keys)
        var changes: [GrowthEntry] = keys.compactMap { key in
            let before = old.folders[key] ?? 0
            let after = new.folders[key] ?? 0
            return abs(after - before) >= minDelta ? GrowthEntry(path: key, before: before, after: after) : nil
        }
        changes.sort { $0.path.count > $1.path.count }
        var explained: [GrowthEntry] = []
        for change in changes {
            let childDelta = explained.filter { Paths.parent($0.path) == change.path }.reduce(Int64(0)) { $0 + $1.delta }
            if abs(change.delta - childDelta) >= minDelta || childDelta == 0 {
                explained.append(change)
            }
        }
        return explained.filter { e in
            // Drop parents whose change is fully explained by a listed child.
            !explained.contains { Paths.parent($0.path) == e.path && abs($0.delta) >= abs(e.delta) * 9 / 10 }
        }.sorted { abs($0.delta) > abs($1.delta) }
    }
}

/// The last reclaim scan, so the menu bar, CLI and MCP can answer instantly.
public enum LastScanStore {
    public static func save(_ summary: ScanSummary, paths: AppPaths = .default) {
        paths.ensure()
        try? JSONStore.save(summary, to: paths.lastScan)
    }

    public static func load(paths: AppPaths = .default) -> ScanSummary? {
        JSONStore.load(ScanSummary.self, from: paths.lastScan)
    }
}
