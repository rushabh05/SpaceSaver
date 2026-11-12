import CryptoKit
import Foundation

public struct DuplicateFile: Codable, Hashable, Sendable, Identifiable {
    public var path: String
    public var size: Int64
    public var modified: Date
    public var id: String { path }
}

public struct DuplicateGroup: Codable, Hashable, Sendable, Identifiable {
    public var hash: String
    public var size: Int64
    public var files: [DuplicateFile]
    /// Index of the copy to keep.
    public var keep: Int
    public var id: String { hash }

    public var reclaimable: Int64 { size * Int64(max(files.count - 1, 0)) }
    public var removable: [DuplicateFile] { files.enumerated().filter { $0.offset != keep }.map(\.element) }
}

public struct DuplicateProgress: Sendable {
    public var phase = "Collecting files"
    public var filesSeen = 0
    public var candidates = 0
    public var hashed = 0
    public var bytesHashed: Int64 = 0

    public init() {}
}

/// Finds byte-identical files: group by size → hash the first and last 16 KB → full SHA-256.
/// Hard links (same inode) aren't duplicates and iCloud placeholders are never read
/// (that would download them).
public final class DuplicateFinder: @unchecked Sendable {
    public var roots: [String]
    public var minSize: Int64
    public var excluded: [String]
    public let cancellation = CancellationFlag()
    private let lock = NSLock()
    private var _progress = DuplicateProgress()

    public init(roots: [String], minSize: Int64 = 1_000_000, excluded: [String] = []) {
        self.roots = roots
        self.minSize = minSize
        self.excluded = excluded
    }

    public var progress: DuplicateProgress { lock.withLock { _progress } }

    struct Candidate {
        var path: String
        var size: Int64
        var modified: Int
        var inode: UInt64
    }

    public func find(home: String = NSHomeDirectory()) -> [DuplicateGroup] {
        let skipNames: Set<String> = ["node_modules", ".git", "Library", ".Trash", "DerivedData", ".build", "target",
                                      ".venv", "venv", "Pods", ".cache", ".npm", ".cargo", ".rustup", ".gradle"]
        let minSize = self.minSize
        let excluded = self.excluded
        var bySize: [Int64: [Candidate]] = [:]

        ParallelWalker.walk(roots: roots.map { WalkJob(path: $0, depth: 0, context: ()) },
                            cancel: cancellation) { [self] job, entries, result in
            guard result.error == 0 else { return [] }
            var next: [WalkJob<Void>] = []
            var local: [Candidate] = []
            for e in entries {
                let path = Paths.join(job.path, e.name)
                if e.kind == .directory {
                    if e.name.hasPrefix(".") || skipNames.contains(e.name) || Paths.isPackage(e.name) { continue }
                    if excluded.contains(where: { Paths.isWithin(path, $0) }) { continue }
                    next.append(WalkJob(path: path, depth: job.depth + 1, context: ()))
                } else if e.kind == .file, e.logicalSize >= minSize, !e.isDataless, !e.name.hasPrefix(".") {
                    local.append(Candidate(path: path, size: e.logicalSize, modified: e.modified, inode: e.fileID))
                }
            }
            lock.lock()
            for c in local { bySize[c.size, default: []].append(c) }
            _progress.filesSeen += local.count
            lock.unlock()
            return next
        }
        if cancellation.isCancelled { return [] }

        // Same size, different inode.
        let sizeGroups: [[Candidate]] = bySize.values.compactMap { group in
            var seen = Set<UInt64>()
            let unique = group.filter { seen.insert($0.inode).inserted }
            return unique.count > 1 ? unique : nil
        }
        lock.withLock {
            _progress.phase = "Comparing contents"
            _progress.candidates = sizeGroups.reduce(0) { $0 + $1.count }
        }

        var groups: [DuplicateGroup] = []
        let resultLock = NSLock()
        DispatchQueue.concurrentPerform(iterations: sizeGroups.count) { i in
            if cancellation.isCancelled { return }
            let found = resolve(sizeGroups[i], home: home)
            resultLock.withLock { groups.append(contentsOf: found) }
        }
        return groups.sorted { $0.reclaimable > $1.reclaimable }
    }

    private func resolve(_ group: [Candidate], home: String) -> [DuplicateGroup] {
        // Cheap pass: head + tail sample.
        var byQuick: [String: [Candidate]] = [:]
        for c in group {
            guard let h = Self.quickHash(c.path, size: c.size) else { continue }
            byQuick[h, default: []].append(c)
        }
        var out: [DuplicateGroup] = []
        for quick in byQuick.values where quick.count > 1 {
            var byFull: [String: [Candidate]] = [:]
            for c in quick {
                if cancellation.isCancelled { return [] }
                guard let h = Self.fullHash(c.path) else { continue }
                byFull[h, default: []].append(c)
                lock.withLock {
                    _progress.hashed += 1
                    _progress.bytesHashed += c.size
                }
            }
            for (hash, files) in byFull where files.count > 1 {
                let dupes = files.map {
                    DuplicateFile(path: $0.path, size: $0.size, modified: Date(timeIntervalSince1970: TimeInterval($0.modified)))
                }
                out.append(DuplicateGroup(hash: hash, size: files[0].size, files: dupes,
                                          keep: Self.suggestKeep(dupes, home: home)))
            }
        }
        return out
    }

    /// Prefer the copy outside Downloads/Desktop/temp folders, then the oldest.
    public static func suggestKeep(_ files: [DuplicateFile], home: String) -> Int {
        func penalty(_ f: DuplicateFile) -> Int {
            var p = 0
            for weak in ["/Downloads/", "/Desktop/", "/tmp/", "/Temp/", " copy", "(1)", "(2)"] where f.path.contains(weak) { p += 1 }
            return p
        }
        let ranked = files.enumerated().sorted {
            let (a, b) = (penalty($0.element), penalty($1.element))
            return a != b ? a < b : $0.element.modified < $1.element.modified
        }
        return ranked.first?.offset ?? 0
    }

    static func quickHash(_ path: String, size: Int64) -> String? {
        guard let h = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? h.close() }
        let chunk = 16 * 1024
        var hasher = SHA256()
        guard let head = try? h.read(upToCount: chunk) else { return nil }
        hasher.update(data: head)
        if size > Int64(chunk * 2) {
            try? h.seek(toOffset: UInt64(size) - UInt64(chunk))
            if let tail = try? h.read(upToCount: chunk) { hasher.update(data: tail) }
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    public static func fullHash(_ path: String) -> String? {
        guard let h = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? h.close() }
        var hasher = SHA256()
        while let data = try? h.read(upToCount: 1 << 20), !data.isEmpty {
            hasher.update(data: data)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    /// Turns the user's keep choices into cleanup items.
    public static func items(for groups: [DuplicateGroup], home: String = NSHomeDirectory()) -> [CleanupItem] {
        groups.map { g in
            let keep = g.files[g.keep]
            return CleanupItem(
                id: "dup:\(g.hash)", category: .duplicates, title: Paths.name(keep.path),
                subtitle: "Keeping \(Paths.abbreviate(keep.path, home: home))", paths: g.removable.map(\.path),
                size: g.reclaimable, risk: .review,
                explanation: "\(g.files.count) identical copies (SHA-256 \(g.hash.prefix(12))…). One copy is kept.",
                regenerate: "Restore from Trash or Activity.", tags: ["\(g.files.count) copies"], recommended: false)
        }
    }
}
