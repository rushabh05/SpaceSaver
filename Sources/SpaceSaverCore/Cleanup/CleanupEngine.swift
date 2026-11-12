import CryptoKit
import Foundation

public struct TrashRecord: Codable, Hashable, Sendable {
    public var original: String
    /// Where the item ended up in the Trash. nil once purged or restored.
    public var trashed: String?
    public var bytes: Int64
}

public enum ActivityStatus: String, Codable, Sendable {
    case completed, partial, failed, restored, purged
}

public struct ActivityEntry: Codable, Identifiable, Hashable, Sendable {
    public var id: UUID
    public var date: Date
    public var title: String
    public var category: CleanupCategory
    public var bytes: Int64
    public var method: String
    public var records: [TrashRecord]
    public var archivePath: String?
    public var commandOutput: String?
    public var status: ActivityStatus
    public var errors: [String]
    /// "app", "cli", "schedule" or "agent:<plan id>".
    public var source: String

    public var canRestore: Bool {
        status != .restored && status != .purged && records.contains { $0.trashed.map(Paths.exists) ?? false }
    }

    public var bytesInTrash: Int64 {
        guard status != .restored && status != .purged else { return 0 }
        return records.filter { $0.trashed.map(Paths.exists) ?? false }.reduce(0) { $0 + $1.bytes }
    }
}

/// Persistent cleanup history (~/.spacesaver/activity.json), shared by app, CLI and scheduler.
public final class ActivityLog: @unchecked Sendable {
    public let path: String

    public init(paths: AppPaths = .default) {
        paths.ensure()
        self.path = paths.activity
    }

    public init(file: String) { self.path = file }

    public func entries() -> [ActivityEntry] {
        JSONStore.load([ActivityEntry].self, from: path) ?? []
    }

    public func append(_ newEntries: [ActivityEntry]) {
        guard !newEntries.isEmpty else { return }
        modify { $0.insert(contentsOf: newEntries.reversed(), at: 0) }
    }

    public func modify(_ change: (inout [ActivityEntry]) -> Void) {
        JSONStore.withLock(path) {
            var list = entries()
            change(&list)
            if list.count > 2000 { list = Array(list.prefix(2000)) }
            try? JSONStore.save(list, to: path)
        }
    }
}

/// Abstracts the Trash so tests can use a temp folder instead of the real one.
public protocol TrashProvider: Sendable {
    func trash(_ path: String) throws -> String
}

public struct SystemTrash: TrashProvider {
    public init() {}

    public func trash(_ path: String) throws -> String {
        var resulting: NSURL?
        try FileManager.default.trashItem(at: URL(fileURLWithPath: path), resultingItemURL: &resulting)
        return resulting?.path ?? ""
    }
}

public struct CleanupReport: Sendable {
    public var entries: [ActivityEntry] = []
    public var skipped: [(CleanupItem, String)] = []

    public var bytesCleaned: Int64 { entries.filter { $0.status != .failed }.reduce(0) { $0 + $1.bytes } }
    public var bytesMovedToTrash: Int64 { entries.reduce(0) { $0 + $1.bytesInTrash } }
    public var errors: [String] { entries.flatMap(\.errors) + skipped.map { "\($0.0.title): \($0.1)" } }
}

public final class CleanupEngine: @unchecked Sendable {
    public var safety: SafetyGuard
    public var log: ActivityLog
    public var trash: TrashProvider
    public var paths: AppPaths

    public init(safety: SafetyGuard, log: ActivityLog, trash: TrashProvider = SystemTrash(), paths: AppPaths = .default) {
        self.safety = safety
        self.log = log
        self.trash = trash
        self.paths = paths
    }

    public convenience init(settings: Settings = .load()) {
        self.init(safety: SafetyGuard(excluded: settings.excludedPaths), log: ActivityLog())
    }

    /// Cleans items one at a time. `progress(done, total, title)` is called on the worker thread.
    public func clean(_ items: [CleanupItem], source: String, dryRun: Bool = false,
                      progress: ((Int, Int, String) -> Void)? = nil) -> CleanupReport {
        var report = CleanupReport()
        for (index, item) in items.enumerated() {
            progress?(index, items.count, item.title)
            if let reason = item.blockedReason {
                report.skipped.append((item, reason))
                continue
            }
            if dryRun { continue }
            let entry: ActivityEntry
            switch item.method {
            case .trash: entry = trashPaths(item, source: source)
            case .archiveThenTrash: entry = archiveThenTrash(item, source: source)
            case .command(let exe, let args): entry = runCommand(item, executable: exe, arguments: args, source: source)
            case .emptyTrash: entry = emptyTrash(item, source: source)
            case .manual:
                report.skipped.append((item, "Needs a manual step"))
                continue
            }
            report.entries.append(entry)
        }
        progress?(items.count, items.count, "Done")
        log.append(report.entries)
        return report
    }

    private func newEntry(_ item: CleanupItem, source: String) -> ActivityEntry {
        ActivityEntry(id: UUID(), date: Date(), title: item.title, category: item.category, bytes: 0,
                      method: item.method.label, records: [], archivePath: nil, commandOutput: nil,
                      status: .completed, errors: [], source: source)
    }

    private func sizeOf(_ path: String, item: CleanupItem) -> Int64 {
        item.paths.count == 1 ? item.size : DirectorySizer.measure(path).bytes
    }

    func trashPaths(_ item: CleanupItem, source: String) -> ActivityEntry {
        var entry = newEntry(item, source: source)
        for raw in item.paths {
            do {
                let path = try safety.validate(raw)
                let bytes = sizeOf(path, item: item)
                let destination = try trash.trash(path)
                entry.records.append(TrashRecord(original: path, trashed: destination, bytes: bytes))
                entry.bytes += bytes
            } catch {
                entry.errors.append("\(Paths.abbreviate(raw)): \(error.localizedDescription)")
            }
        }
        entry.status = entry.errors.isEmpty ? .completed : (entry.records.isEmpty ? .failed : .partial)
        return entry
    }

    func archiveThenTrash(_ item: CleanupItem, source: String) -> ActivityEntry {
        var entry = newEntry(item, source: source)
        let valid = item.paths.compactMap { try? safety.validate($0) }
        guard !valid.isEmpty else {
            entry.status = .failed
            entry.errors = ["Nothing left to archive"]
            return entry
        }
        do {
            let archive = try Archiver.archive(valid, name: item.title, vault: paths.vault)
            entry.archivePath = archive.path
            var trashed = trashPaths(item, source: source)
            trashed.archivePath = archive.path
            trashed.method = item.method.label
            trashed.commandOutput = "Archived \(valid.count) items to \(Paths.abbreviate(archive.path)) " +
                "(\(ByteFormat.string(archive.size)), SHA-256 \(archive.sha256.prefix(16))…)"
            return trashed
        } catch {
            entry.status = .failed
            entry.errors = ["Archive failed, nothing was removed: \(error.localizedDescription)"]
            return entry
        }
    }

    func runCommand(_ item: CleanupItem, executable: String, arguments: [String], source: String) -> ActivityEntry {
        var entry = newEntry(item, source: source)
        let result = Shell.run(executable, arguments, timeout: 900)
        entry.commandOutput = (result.stdout + result.stderr).trimmingCharacters(in: .whitespacesAndNewlines)
            .sanitizedForDisplay.suffix(4000).description
        if result.ok {
            entry.bytes = Self.reclaimedFromOutput(result.stdout) ?? item.size
            entry.status = .completed
        } else {
            entry.status = .failed
            entry.errors.append(result.timedOut ? "Timed out" : "Exit code \(result.status): \(result.stderr.prefix(300))")
        }
        return entry
    }

    /// Docker prints "Total reclaimed space: 1.2GB".
    static func reclaimedFromOutput(_ output: String) -> Int64? {
        guard let line = output.split(separator: "\n").last(where: { $0.contains("reclaimed space") }),
              let value = line.split(separator: ":").last else { return nil }
        return ByteFormat.parse(String(value))
    }

    func emptyTrash(_ item: CleanupItem, source: String) -> ActivityEntry {
        var entry = newEntry(item, source: source)
        let trashDir = Paths.expand("~/.Trash")
        for child in Paths.children(trashDir) {
            let path = Paths.join(trashDir, child)
            let bytes = DirectorySizer.measure(path).bytes
            do {
                try FileManager.default.removeItem(atPath: path)
                entry.bytes += bytes
            } catch {
                entry.errors.append("\(child): \(error.localizedDescription)")
            }
        }
        entry.status = entry.errors.isEmpty ? .completed : .partial
        // Records of earlier SpaceSaver cleanups now point at nothing.
        log.modify { list in
            for i in list.indices where list[i].status == .completed || list[i].status == .partial {
                if !list[i].records.contains(where: { $0.trashed.map(Paths.exists) ?? false }) && !list[i].records.isEmpty {
                    list[i].status = .purged
                }
            }
        }
        return entry
    }

    // MARK: Undo and purge

    /// Moves everything from an activity entry back to where it was.
    @discardableResult
    public func restore(_ id: UUID) throws -> Int {
        var restored = 0
        var failures: [String] = []
        log.modify { list in
            guard let index = list.firstIndex(where: { $0.id == id }) else { return }
            for r in list[index].records.indices {
                let record = list[index].records[r]
                guard let trashed = record.trashed, Paths.exists(trashed) else { continue }
                if Paths.exists(record.original) {
                    failures.append("\(Paths.abbreviate(record.original)) already exists")
                    continue
                }
                do {
                    try FileManager.default.createDirectory(atPath: Paths.parent(record.original),
                                                            withIntermediateDirectories: true)
                    try FileManager.default.moveItem(atPath: trashed, toPath: record.original)
                    list[index].records[r].trashed = nil
                    restored += 1
                } catch {
                    failures.append("\(Paths.abbreviate(record.original)): \(error.localizedDescription)")
                }
            }
            if restored > 0 { list[index].status = .restored }
        }
        if restored == 0, let first = failures.first {
            throw NSError(domain: "SpaceSaver", code: 1, userInfo: [NSLocalizedDescriptionKey: first])
        }
        return restored
    }

    /// Permanently deletes SpaceSaver-cleaned items from the Trash. Only touches paths SpaceSaver
    /// itself put there, never anything else in the Trash.
    @discardableResult
    public func purge(olderThanDays days: Int? = nil, ids: Set<UUID>? = nil) -> Int64 {
        let cutoff = days.map { Date().addingTimeInterval(-Double($0) * 86_400) }
        let trashRoot = Paths.expand("~/.Trash")
        var freed: Int64 = 0
        log.modify { list in
            for i in list.indices {
                let entry = list[i]
                if let ids, !ids.contains(entry.id) { continue }
                if let cutoff, entry.date > cutoff { continue }
                guard entry.status == .completed || entry.status == .partial else { continue }
                var removedAny = false
                for r in entry.records.indices {
                    guard let trashed = entry.records[r].trashed, Paths.exists(trashed) else { continue }
                    // Only inside a Trash folder (user's or a volume's .Trashes), and only what we put there.
                    guard Paths.isWithin(trashed, trashRoot) || trashed.contains("/.Trashes/") else { continue }
                    if (try? FileManager.default.removeItem(atPath: trashed)) != nil {
                        freed += entry.records[r].bytes
                        list[i].records[r].trashed = nil
                        removedAny = true
                    }
                }
                if removedAny || !entry.records.contains(where: { $0.trashed.map(Paths.exists) ?? false }) {
                    if !entry.records.isEmpty { list[i].status = .purged }
                }
            }
        }
        return freed
    }

    public func bytesHeldInTrash() -> Int64 {
        log.entries().reduce(0) { $0 + $1.bytesInTrash }
    }
}

// MARK: - Archive vault

public struct ArchiveResult: Sendable {
    public var path: String
    public var size: Int64
    public var sha256: String
}

/// Compresses files into the vault as a POSIX tar.gz, verifies it reads back, and records its
/// SHA-256 in a manifest next to it. Originals are only removed after verification passes.
public enum Archiver {
    public static func archive(_ sources: [String], name: String, vault: String) throws -> ArchiveResult {
        try FileManager.default.createDirectory(atPath: vault, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
        let safeName = name.unicodeScalars.map { CharacterSet.alphanumerics.contains($0) ? Character($0) : "-" }
            .reduce(into: "") { $0.append($1) }.prefix(60)
        let archivePath = Paths.join(vault, "\(stamp)-\(safeName).tar.gz")

        // tar -C / with relative paths keeps the full original location inside the archive.
        let listFile = archivePath + ".list"
        let relative = sources.map { String($0.dropFirst()) }
        try relative.joined(separator: "\n").write(toFile: listFile, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(atPath: listFile) }

        let create = Shell.run("/usr/bin/tar", ["--format", "ustar", "-czf", archivePath, "-C", "/", "-T", listFile],
                               timeout: 1800)
        guard create.ok else {
            // ustar can't store very long names; fall back to pax.
            let retry = Shell.run("/usr/bin/tar", ["-czf", archivePath, "-C", "/", "-T", listFile], timeout: 1800)
            guard retry.ok else {
                try? FileManager.default.removeItem(atPath: archivePath)
                throw NSError(domain: "Archiver", code: Int(retry.status),
                              userInfo: [NSLocalizedDescriptionKey: retry.stderr.prefix(300).description])
            }
            return try finish(archivePath, sources: sources)
        }
        return try finish(archivePath, sources: sources)
    }

    private static func finish(_ archivePath: String, sources: [String]) throws -> ArchiveResult {
        let verify = Shell.run("/usr/bin/tar", ["-tzf", archivePath], timeout: 900)
        let listed = verify.stdout.split(separator: "\n").count
        guard verify.ok, listed >= sources.count else {
            try? FileManager.default.removeItem(atPath: archivePath)
            throw NSError(domain: "Archiver", code: 2,
                          userInfo: [NSLocalizedDescriptionKey: "Archive verification failed"])
        }
        chmod(archivePath, 0o600)
        let sha = DuplicateFinder.fullHash(archivePath) ?? ""
        let size = DirectorySizer.measure(archivePath).bytes
        let manifest: [String: Any] = [
            "created": ISO8601DateFormatter().string(from: Date()),
            "sha256": sha,
            "sources": sources,
            "restore": "tar -xzf '\(archivePath)' -C /",
        ]
        if let data = try? JSONSerialization.data(withJSONObject: manifest, options: [.prettyPrinted, .sortedKeys]) {
            FileManager.default.createFile(atPath: archivePath + ".json", contents: data,
                                           attributes: [.posixPermissions: 0o600])
        }
        return ArchiveResult(path: archivePath, size: size, sha256: sha)
    }

    public static func vaultSize(_ vault: String = AppPaths.default.vault) -> Int64 {
        DirectorySizer.measure(vault).bytes
    }
}
