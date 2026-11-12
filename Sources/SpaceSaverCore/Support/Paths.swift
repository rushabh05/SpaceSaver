import Foundation

/// Where analyzers look. Injectable so tests can point everything at a temp directory.
public struct ScanEnvironment: Sendable {
    public var home: String
    public var settings: Settings
    public var now: Date

    public init(home: String = NSHomeDirectory(), settings: Settings = Settings(), now: Date = Date()) {
        self.home = (home as NSString).standardizingPath
        self.settings = settings
        self.now = now
    }

    public func expand(_ path: String) -> String { Paths.expand(path, home: home) }
}

public enum Paths {
    public static var home: String { NSHomeDirectory() }

    public static func expand(_ path: String, home: String = NSHomeDirectory()) -> String {
        if path == "~" { return home }
        if path.hasPrefix("~/") { return home + String(path.dropFirst(1)) }
        return path
    }

    public static func abbreviate(_ path: String, home: String = NSHomeDirectory()) -> String {
        if path == home { return "~" }
        if path.hasPrefix(home + "/") { return "~" + path.dropFirst(home.count) }
        return path
    }

    /// Strips the home directory and user name from a path before it leaves the machine
    /// (e.g. to a local LLM prompt), so file paths can't identify the user.
    public static func anonymize(_ path: String, home: String = NSHomeDirectory()) -> String {
        var p = abbreviate(path, home: home)
        let user = NSUserName()
        if !user.isEmpty { p = p.replacingOccurrences(of: user, with: "<user>") }
        return p
    }

    public static func exists(_ path: String) -> Bool {
        var st = stat()
        return lstat(path, &st) == 0
    }

    public static func isDirectory(_ path: String) -> Bool {
        var st = stat()
        guard stat(path, &st) == 0 else { return false }
        return (st.st_mode & S_IFMT) == S_IFDIR
    }

    public static func modificationDate(_ path: String) -> Date? {
        var st = stat()
        guard lstat(path, &st) == 0 else { return nil }
        return Date(timeIntervalSince1970: TimeInterval(st.st_mtimespec.tv_sec))
    }

    public static func join(_ base: String, _ name: String) -> String {
        base.hasSuffix("/") ? base + name : base + "/" + name
    }

    public static func parent(_ path: String) -> String { (path as NSString).deletingLastPathComponent }
    public static func name(_ path: String) -> String { (path as NSString).lastPathComponent }

    /// true if `path` equals `ancestor` or lives inside it.
    public static func isWithin(_ path: String, _ ancestor: String) -> Bool {
        if ancestor == "/" { return path.hasPrefix("/") }
        return path == ancestor || path.hasPrefix(ancestor + "/")
    }

    /// Lists directory entry names (no dot entries). Empty on error.
    public static func children(_ path: String) -> [String] {
        (try? FileManager.default.contentsOfDirectory(atPath: path)) ?? []
    }

    /// Expands `*` and `?` wildcards in path components: "~/Library/Caches/Google/Chrome*".
    public static func glob(_ pattern: String, home: String = NSHomeDirectory()) -> [String] {
        let expanded = expand(pattern, home: home)
        guard expanded.contains("*") || expanded.contains("?") else {
            return exists(expanded) ? [expanded] : []
        }
        let components = expanded.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        var results = ["/"]
        for component in components {
            var next: [String] = []
            let isPattern = component.contains("*") || component.contains("?")
            for base in results {
                if isPattern {
                    for child in children(base) where fnmatch(component, child, 0) == 0 {
                        next.append(join(base, child))
                    }
                } else {
                    let candidate = join(base, component)
                    if exists(candidate) { next.append(candidate) }
                }
            }
            results = next
            if results.isEmpty { break }
        }
        return results.sorted()
    }

    /// Package extensions we treat as opaque leaves when walking for projects or duplicates.
    public static let packageExtensions: Set<String> = [
        "app", "bundle", "framework", "photoslibrary", "musiclibrary", "tvlibrary", "xcarchive",
        "plugin", "kext", "appex", "xpc", "photolibrary", "aplibrary", "fcpbundle", "logicx",
        "imovielibrary", "band", "sparsebundle", "dmg", "xcassets", "lproj",
    ]

    public static func isPackage(_ name: String) -> Bool {
        let ext = (name as NSString).pathExtension.lowercased()
        return !ext.isEmpty && packageExtensions.contains(ext)
    }
}

/// SpaceSaver's own data directory (~/.spacesaver), shared by the app and the CLI.
public struct AppPaths: Sendable {
    public let base: String

    public init(base: String = Paths.expand("~/.spacesaver")) {
        self.base = base
    }

    public static let `default` = AppPaths()

    public var settings: String { base + "/settings.json" }
    public var activity: String { base + "/activity.json" }
    public var history: String { base + "/history.json" }
    public var customRules: String { base + "/rules.json" }
    public var plans: String { base + "/plans" }
    public var vault: String { base + "/vault" }
    public var mcpAudit: String { base + "/mcp-audit.jsonl" }
    public var autoLog: String { base + "/auto.log" }
    public var lastScan: String { base + "/last-scan.json" }

    public func ensure() {
        let fm = FileManager.default
        for dir in [base, plans, vault] {
            if !fm.fileExists(atPath: dir) {
                try? fm.createDirectory(atPath: dir, withIntermediateDirectories: true,
                                        attributes: [.posixPermissions: 0o700])
            }
        }
    }
}

/// Atomic JSON persistence with owner-only permissions and an advisory lock, so the app,
/// the CLI and the scheduled agent can share files safely.
public enum JSONStore {
    public static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        e.dateEncodingStrategy = .iso8601
        return e
    }()

    public static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()

    public static func load<T: Decodable>(_ type: T.Type, from path: String) -> T? {
        guard let data = FileManager.default.contents(atPath: path) else { return nil }
        return try? decoder.decode(type, from: data)
    }

    public static func save<T: Encodable>(_ value: T, to path: String) throws {
        let data = try encoder.encode(value)
        let dir = Paths.parent(path)
        if !FileManager.default.fileExists(atPath: dir) {
            try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
        }
        try data.write(to: URL(fileURLWithPath: path), options: .atomic)
        chmod(path, 0o600)
    }

    /// Runs `body` while holding an exclusive flock on `path + ".lock"`.
    public static func withLock<T>(_ path: String, _ body: () throws -> T) rethrows -> T {
        let lockPath = path + ".lock"
        let fd = open(lockPath, O_CREAT | O_RDWR | O_CLOEXEC, 0o600)
        if fd >= 0 { flock(fd, LOCK_EX) }
        defer {
            if fd >= 0 {
                flock(fd, LOCK_UN)
                close(fd)
            }
        }
        return try body()
    }
}
