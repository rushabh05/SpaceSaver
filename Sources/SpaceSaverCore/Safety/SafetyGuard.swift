import AppKit
import Darwin
import Foundation

public enum SafetyError: LocalizedError, Equatable {
    case notAbsolute(String)
    case missing(String)
    case protected(String, reason: String)
    case excluded(String)
    case outsideAllowedRoots(String)

    public var errorDescription: String? {
        switch self {
        case .notAbsolute(let p): return "Not an absolute path: \(p)"
        case .missing(let p): return "No longer exists: \(Paths.abbreviate(p))"
        case .protected(let p, let reason): return "Protected: \(Paths.abbreviate(p)) (\(reason))"
        case .excluded(let p): return "Excluded in Settings: \(Paths.abbreviate(p))"
        case .outsideAllowedRoots(let p): return "Outside the locations SpaceSaver manages: \(Paths.abbreviate(p))"
        }
    }
}

/// Last line of defence before anything is moved or deleted. Every removal goes through
/// `validate`, whatever asked for it (UI, CLI, scheduler or an AI agent via MCP).
public struct SafetyGuard: Sendable {
    public var home: String
    public var excluded: [String]

    public init(home: String = NSHomeDirectory(), excluded: [String] = []) {
        self.home = (home as NSString).standardizingPath
        self.excluded = excluded.map { (Paths.expand($0, home: home) as NSString).standardizingPath }
    }

    /// Folders that must never be removed themselves (their contents may be).
    public var protectedRoots: [String] {
        [
            "/", "/System", "/Library", "/Applications", "/Users", "/private", "/usr", "/bin", "/sbin",
            "/opt", "/opt/homebrew", "/Volumes", home,
            home + "/Desktop", home + "/Documents", home + "/Downloads", home + "/Library", home + "/Pictures",
            home + "/Movies", home + "/Music", home + "/Applications", home + "/Public",
            home + "/Library/Caches", home + "/Library/Application Support", home + "/Library/Containers",
            home + "/Library/Group Containers", home + "/Library/Developer", home + "/Library/Mobile Documents",
            home + "/Library/CloudStorage", home + "/.Trash", home + "/.cache", home + "/.config",
            home + "/.local", home + "/.claude", home + "/.claude/projects", home + "/.codex",
            home + "/.codex/sessions",
        ]
    }

    /// Never touch anything inside these (secrets, keychains, config).
    public var sensitiveTrees: [(String, String)] {
        [
            (home + "/.ssh", "SSH keys"),
            (home + "/.gnupg", "GPG keys"),
            (home + "/.aws", "AWS credentials"),
            (home + "/.kube", "Kubernetes config"),
            (home + "/.docker/config.json", "Docker credentials"),
            (home + "/.config/gh", "GitHub CLI credentials"),
            (home + "/Library/Keychains", "Keychains"),
            (home + "/Library/Mail", "Mail"),
            (home + "/Library/Messages", "Messages"),
            (home + "/Library/Mobile Documents", "iCloud Drive"),
            (home + "/Library/Preferences", "App preferences"),
            (home + "/.spacesaver", "SpaceSaver data"),
            ("/System", "macOS system files"),
            ("/usr", "macOS system files"),
            ("/bin", "macOS system files"),
            ("/sbin", "macOS system files"),
        ]
    }

    public func validate(_ rawPath: String) throws -> String {
        guard rawPath.hasPrefix("/") else { throw SafetyError.notAbsolute(rawPath) }
        let path = (rawPath as NSString).standardizingPath
        guard Paths.exists(path) else { throw SafetyError.missing(path) }

        // Resolve symlinks in the parent so "~/link-to-ssh/id_rsa" can't sneak past the checks.
        // The item itself may be a symlink; trashing a symlink only moves the link.
        let resolvedParent = (Paths.parent(path) as NSString).resolvingSymlinksInPath
        let resolved = Paths.join(resolvedParent, Paths.name(path))

        for candidate in Set([path, resolved]) {
            for root in protectedRoots where candidate == root || isAncestor(candidate, of: root) {
                throw SafetyError.protected(path, reason: candidate == root ? "system or home folder"
                                                : "contains \(Paths.abbreviate(root, home: home))")
            }
            for (tree, reason) in sensitiveTrees where Paths.isWithin(candidate, tree) {
                throw SafetyError.protected(path, reason: reason)
            }
            if candidate.split(separator: "/").contains(".git") {
                throw SafetyError.protected(path, reason: "git repository data")
            }
            if Paths.isWithin(candidate, home + "/.claude"),
               candidate.contains("/memory") || Paths.exists(Paths.join(candidate, "memory")) {
                throw SafetyError.protected(path, reason: "Claude Code memory")
            }
            for ex in excluded where Paths.isWithin(candidate, ex) || isAncestor(candidate, of: ex) {
                throw SafetyError.excluded(path)
            }
        }
        return path
    }

    public func isAllowed(_ path: String) -> Bool { (try? validate(path)) != nil }

    private func isAncestor(_ a: String, of b: String) -> Bool {
        a != b && Paths.isWithin(b, a)
    }
}

/// Which apps and processes are running, so their live caches aren't pulled out from under them.
public struct RunningApps: Sendable {
    public var processNames: Set<String>
    public var bundleIDs: Set<String>
    public var appNames: [String: String] // lowercased bundle id -> display name

    public static func snapshot() -> RunningApps {
        var names = Set<String>()
        let maxCount = proc_listallpids(nil, 0)
        if maxCount > 0 {
            var pids = [pid_t](repeating: 0, count: Int(maxCount) + 64)
            let n = proc_listallpids(&pids, Int32(pids.count * MemoryLayout<pid_t>.size))
            var buffer = [CChar](repeating: 0, count: 256)
            for pid in pids.prefix(Int(max(n, 0))) where pid > 0 {
                if proc_name(pid, &buffer, UInt32(buffer.count)) > 0 {
                    names.insert(String(cString: buffer).lowercased())
                }
            }
        }
        var ids = Set<String>()
        var appNames: [String: String] = [:]
        for app in NSWorkspace.shared.runningApplications {
            if let id = app.bundleIdentifier?.lowercased() {
                ids.insert(id)
                appNames[id] = app.localizedName ?? id
            }
            if let name = app.localizedName { names.insert(name.lowercased()) }
        }
        return RunningApps(processNames: names, bundleIDs: ids, appNames: appNames)
    }

    public static let none = RunningApps(processNames: [], bundleIDs: [], appNames: [:])

    /// Returns the name of the first running match, if any.
    public func running(processes: [String], bundleIDs ids: [String]) -> String? {
        for p in processes where processNames.contains(p.lowercased()) { return p }
        for id in ids where bundleIDs.contains(id.lowercased()) { return appNames[id.lowercased()] ?? id }
        return nil
    }
}

/// Friendly names for folders named after bundle identifiers ("com.spotify.client" -> "Spotify").
public enum AppNames {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var cache: [String: String?] = [:]

    public static func displayName(forFolder folder: String) -> String {
        var id = folder
        var suffix = ""
        if id.hasSuffix(".ShipIt") {
            id = String(id.dropLast(7))
            suffix = " (updater)"
        }
        guard id.split(separator: ".").count >= 3 else { return folder }
        if let name = lookup(id) { return name + suffix }
        return folder
    }

    static func lookup(_ bundleID: String) -> String? {
        if let cached = lock.withLock({ cache[bundleID] }) { return cached }
        var name: String?
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
            name = FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: "")
        }
        lock.withLock { cache[bundleID] = name }
        return name
    }
}
