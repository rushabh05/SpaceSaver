import Foundation

/// Thread-safe cancellation flag shared between UI and worker threads.
public final class CancellationFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false

    public init() {}

    public var isCancelled: Bool { lock.withLock { cancelled } }
    public func cancel() { lock.withLock { cancelled = true } }
}

/// A directory waiting to be read, with caller-defined context (e.g. the tree node to fill).
public struct WalkJob<Context> {
    public var path: String
    public var depth: Int
    public var context: Context

    public init(path: String, depth: Int, context: Context) {
        self.path = path
        self.depth = depth
        self.context = context
    }
}

/// Work-stealing parallel directory walker. Each directory is read exactly once by one
/// worker; the visitor decides which subdirectories to descend into. Depth-first (LIFO)
/// so the queue stays small even on huge trees.
public enum ParallelWalker {
    public static var defaultThreads: Int { max(4, min(ProcessInfo.processInfo.activeProcessorCount, 16)) }

    public static func walk<Context>(
        roots: [WalkJob<Context>],
        threads: Int = ParallelWalker.defaultThreads,
        cancel: CancellationFlag? = nil,
        visit: @escaping (WalkJob<Context>, [DirEntry], BulkReader.Result) -> [WalkJob<Context>]
    ) {
        let queue = WorkQueue<WalkJob<Context>>(roots)
        let workerCount = max(1, threads)
        let group = DispatchGroup()

        let work = {
            var entries: [DirEntry] = []
            entries.reserveCapacity(256)
            while let job = queue.pop() {
                if cancel?.isCancelled == true {
                    queue.finish(adding: [])
                    continue
                }
                entries.removeAll(keepingCapacity: true)
                let result = BulkReader.read(job.path) { entries.append($0) }
                let next = visit(job, entries, result)
                queue.finish(adding: next)
            }
        }

        for _ in 1..<workerCount {
            group.enter()
            let thread = Thread {
                work()
                group.leave()
            }
            thread.stackSize = 1 << 20
            thread.qualityOfService = .userInitiated
            thread.start()
        }
        work()
        group.wait()
    }
}

final class WorkQueue<T>: @unchecked Sendable {
    private var items: [T]
    private var active = 0
    private let condition = NSCondition()

    init(_ initial: [T]) { items = initial }

    /// Next job, or nil once the queue is empty and no worker can add more.
    func pop() -> T? {
        condition.lock()
        defer { condition.unlock() }
        while items.isEmpty {
            if active == 0 {
                condition.broadcast()
                return nil
            }
            condition.wait()
        }
        active += 1
        return items.removeLast()
    }

    func finish(adding newItems: [T]) {
        condition.lock()
        items.append(contentsOf: newItems)
        active -= 1
        condition.broadcast()
        condition.unlock()
    }
}
