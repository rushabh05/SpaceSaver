import Darwin
import Foundation

/// A node in the storage map. Directories keep every subdirectory; files below
/// `keepFilesAtLeast` are folded into one "smaller items" node per folder to bound memory.
public final class FileNode: Identifiable, Hashable, @unchecked Sendable {
    public enum Kind: UInt8, Sendable { case directory, file, aggregate }

    public let name: String
    public let kind: Kind
    public internal(set) var size: Int64
    public internal(set) var fileCount: Int
    public internal(set) var modified: Int
    public internal(set) var children: [FileNode] = []
    public internal(set) weak var parent: FileNode?
    /// Unreadable (permission denied): its size is unknown, not zero.
    public internal(set) var isDenied = false

    init(name: String, kind: Kind, size: Int64 = 0, fileCount: Int = 0, modified: Int = 0, parent: FileNode?) {
        self.name = name
        self.kind = kind
        self.size = size
        self.fileCount = fileCount
        self.modified = modified
        self.parent = parent
    }

    public var id: ObjectIdentifier { ObjectIdentifier(self) }
    public var isDirectory: Bool { kind == .directory }
    public var isPackage: Bool { kind == .directory && Paths.isPackage(name) }

    public var path: String {
        guard let parent else { return name }
        return Paths.join(parent.path, name)
    }

    public var displayName: String {
        if kind == .aggregate { return name }
        return parent == nil ? Paths.abbreviate(name) : name
    }

    public var ancestors: [FileNode] {
        var chain: [FileNode] = []
        var node: FileNode? = self
        while let n = node {
            chain.append(n)
            node = n.parent
        }
        return chain.reversed()
    }

    public static func == (a: FileNode, b: FileNode) -> Bool { a === b }
    public func hash(into hasher: inout Hasher) { hasher.combine(ObjectIdentifier(self)) }

    /// Finds a descendant by absolute path.
    public func find(path target: String) -> FileNode? {
        let base = path
        guard Paths.isWithin(target, base) else { return nil }
        if target == base { return self }
        let rest = target.dropFirst(base == "/" ? 1 : base.count + 1)
        var node: FileNode = self
        for component in rest.split(separator: "/") {
            guard let next = node.children.first(where: { $0.name == component }) else { return nil }
            node = next
        }
        return node
    }

    /// Removes a child (after it was cleaned) and propagates the size change upward.
    public func removeChild(_ child: FileNode) {
        guard let index = children.firstIndex(where: { $0 === child }) else { return }
        children.remove(at: index)
        var node: FileNode? = self
        while let n = node {
            n.size -= child.size
            n.fileCount -= child.fileCount
            node = n.parent
        }
    }
}

public struct LargeFile: Identifiable, Hashable, Codable, Sendable {
    public var path: String
    public var size: Int64
    public var modified: Date
    public var id: String { path }
}

public struct ScanProgress: Sendable {
    public var files = 0
    public var directories = 0
    public var bytes: Int64 = 0
    public var denied = 0
    public var current = ""

    public init() {}
}

/// Builds a FileNode tree for the storage map, collecting large files on the way.
public final class TreeScanner: @unchecked Sendable {
    public struct Options: Sendable {
        public var root: String
        public var keepFilesAtLeast: Int64 = 1 << 20
        public var largeFileThreshold: Int64 = 100_000_000
        public var excluded: [String] = []
        public var threads = ParallelWalker.defaultThreads

        public init(root: String) { self.root = root }
    }

    public let options: Options
    public let cancellation = CancellationFlag()

    private let lock = NSLock()
    private var _progress = ScanProgress()
    private var _largeFiles: [LargeFile] = []
    private var seenHardLinks = Set<UInt64>()
    private let allowedDevices: Set<Int32>
    private let skip: Set<String>

    public init(options: Options) {
        var opts = options
        opts.root = (options.root as NSString).standardizingPath
        self.options = opts

        var devices = Set<Int32>()
        var st = stat()
        if stat(opts.root, &st) == 0 { devices.insert(st.st_dev) }
        var skip = Set(opts.excluded)
        if opts.root == "/" {
            // Scan the boot volume through its firmlinks instead of the raw volume mounts,
            // so user data isn't counted twice.
            if stat("/System/Volumes/Data", &st) == 0 { devices.insert(st.st_dev) }
            skip.formUnion(["/System/Volumes", "/Volumes", "/dev", "/net", "/home", "/Network", "/cores"])
        }
        self.allowedDevices = devices
        self.skip = skip
    }

    public var progress: ScanProgress { lock.withLock { _progress } }
    public var largeFiles: [LargeFile] { lock.withLock { _largeFiles.sorted { $0.size > $1.size } } }
    public func cancel() { cancellation.cancel() }

    /// Scans synchronously on the calling thread plus worker threads. Returns the finalized tree.
    public func scan() -> FileNode {
        let root = FileNode(name: options.root, kind: .directory, parent: nil)
        let keep = options.keepFilesAtLeast
        let largeThreshold = options.largeFileThreshold

        ParallelWalker.walk(
            roots: [WalkJob(path: options.root, depth: 0, context: root)],
            threads: options.threads,
            cancel: cancellation
        ) { [self] job, entries, result in
            let node = job.context
            if result.error != 0 {
                node.isDenied = result.error == EPERM || result.error == EACCES
                lock.withLock { _progress.denied += 1 }
                return []
            }
            if !allowedDevices.isEmpty, !allowedDevices.contains(result.device) {
                return [] // another volume mounted inside the tree
            }

            var next: [WalkJob<FileNode>] = []
            var children: [FileNode] = []
            var smallSize: Int64 = 0
            var smallCount = 0
            var fileCount = 0
            var bytes: Int64 = 0
            var large: [LargeFile] = []
            var hardLinked: [(UInt64, Int64, String, Int)] = []

            for entry in entries {
                switch entry.kind {
                case .directory:
                    let childPath = Paths.join(job.path, entry.name)
                    if skip.contains(childPath) { continue }
                    let child = FileNode(name: entry.name, kind: .directory, modified: entry.modified, parent: node)
                    children.append(child)
                    next.append(WalkJob(path: childPath, depth: job.depth + 1, context: child))
                default:
                    if entry.linkCount > 1 && entry.kind == .file {
                        hardLinked.append((entry.fileID, entry.allocatedSize, entry.name, entry.modified))
                        continue
                    }
                    fileCount += 1
                    bytes += entry.allocatedSize
                    if entry.allocatedSize >= keep {
                        children.append(FileNode(name: entry.name, kind: .file, size: entry.allocatedSize,
                                                 fileCount: 1, modified: entry.modified, parent: node))
                    } else {
                        smallSize += entry.allocatedSize
                        smallCount += 1
                    }
                    if entry.allocatedSize >= largeThreshold {
                        large.append(LargeFile(path: Paths.join(job.path, entry.name), size: entry.allocatedSize,
                                               modified: Date(timeIntervalSince1970: TimeInterval(entry.modified))))
                    }
                }
            }

            lock.lock()
            // Hard links: count the shared data once.
            for (id, size, name, modified) in hardLinked where seenHardLinks.insert(id).inserted {
                fileCount += 1
                bytes += size
                if size >= keep {
                    children.append(FileNode(name: name, kind: .file, size: size, fileCount: 1,
                                             modified: modified, parent: node))
                } else {
                    smallSize += size
                    smallCount += 1
                }
            }
            _progress.files += fileCount
            _progress.directories += 1
            _progress.bytes += bytes
            _progress.current = job.path
            _largeFiles.append(contentsOf: large)
            lock.unlock()

            if smallCount > 0 {
                let label = smallCount == 1 ? "1 small file" : "\(smallCount) small files"
                children.append(FileNode(name: label, kind: .aggregate, size: smallSize,
                                         fileCount: smallCount, parent: node))
            }
            node.children = children
            return next
        }

        Self.finalize(root)
        return root
    }

    /// Bottom-up size totals and children sorted largest first.
    static func finalize(_ node: FileNode) {
        guard node.kind == .directory else { return }
        var size: Int64 = 0
        var count = 0
        for child in node.children {
            finalize(child)
            size += child.size
            count += child.fileCount
        }
        node.size = size
        node.fileCount = count
        node.children.sort { $0.size > $1.size }
    }
}

public struct DirectorySize: Sendable, Hashable {
    public var bytes: Int64 = 0
    public var files = 0
    /// Most recent modification time of anything inside (unix seconds).
    public var newest = 0

    public var newestDate: Date? { newest > 0 ? Date(timeIntervalSince1970: TimeInterval(newest)) : nil }
}

/// Fast recursive size of a folder (or a file), staying on one volume.
public enum DirectorySizer {
    public static func measure(_ path: String, threads: Int = 4, cancel: CancellationFlag? = nil) -> DirectorySize {
        var st = stat()
        guard lstat(path, &st) == 0 else { return DirectorySize() }
        if (st.st_mode & S_IFMT) != S_IFDIR {
            return DirectorySize(bytes: Int64(st.st_blocks) * 512, files: 1, newest: st.st_mtimespec.tv_sec)
        }
        let device = st.st_dev
        let lock = NSLock()
        var total = DirectorySize(bytes: 0, files: 0, newest: st.st_mtimespec.tv_sec)
        var seen = Set<UInt64>()

        ParallelWalker.walk(roots: [WalkJob(path: path, depth: 0, context: ())], threads: threads,
                            cancel: cancel) { job, entries, result in
            guard result.error == 0, result.device == device else { return [] }
            var bytes: Int64 = 0
            var files = 0
            var newest = 0
            var next: [WalkJob<Void>] = []
            var links: [(UInt64, Int64)] = []
            for entry in entries {
                newest = max(newest, entry.modified)
                if entry.kind == .directory {
                    next.append(WalkJob(path: Paths.join(job.path, entry.name), depth: job.depth + 1, context: ()))
                } else if entry.linkCount > 1 && entry.kind == .file {
                    links.append((entry.fileID, entry.allocatedSize))
                } else {
                    bytes += entry.allocatedSize
                    files += 1
                }
            }
            lock.lock()
            for (id, size) in links where seen.insert(id).inserted {
                bytes += size
                files += 1
            }
            total.bytes += bytes
            total.files += files
            total.newest = max(total.newest, newest)
            lock.unlock()
            return next
        }
        return total
    }

    /// Sizes many paths concurrently.
    public static func measureAll(_ paths: [String], cancel: CancellationFlag? = nil) -> [String: DirectorySize] {
        let lock = NSLock()
        var results: [String: DirectorySize] = [:]
        let list = Array(Set(paths))
        DispatchQueue.concurrentPerform(iterations: list.count) { i in
            let size = measure(list[i], threads: 2, cancel: cancel)
            lock.withLock { results[list[i]] = size }
        }
        return results
    }
}
