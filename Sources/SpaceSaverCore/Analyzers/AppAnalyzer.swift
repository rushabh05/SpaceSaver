import AppKit
import CoreServices
import Foundation

// App uninstalling, and leftovers of apps that are already gone.
//
// Matching is deliberately conservative: a Library folder only counts as an app's leftover when
// it's named after the app's exact bundle ID (or, for a few locations, its distinctive name), and
// an orphan only counts when no installed or running app from the same vendor could own it.

public struct Leftover: Codable, Hashable, Sendable, Identifiable {
    public var id: String { path }
    public var path: String
    public var kind: String
    public var size: Int64
}

public struct AppRecord: Codable, Hashable, Sendable, Identifiable {
    public var id: String { path }
    public var path: String
    public var name: String
    public var bundleID: String
    public var version: String?
    public var size: Int64
    public var lastUsed: Date?
    public var fromAppStore: Bool
    /// Installs a system extension (security, VPN, drivers): usually needs its own uninstaller.
    public var hasSystemExtension = false
    public var leftovers: [Leftover]

    public var leftoverSize: Int64 { leftovers.reduce(0) { $0 + $1.size } }
    public var totalSize: Int64 { size + leftoverSize }
}

public enum LeftoverLocations {
    /// `{id}` is the bundle ID, `{name}` the app's name.
    static let templates: [(String, String)] = [
        ("Library/Application Support/{id}", "Application Support"),
        ("Library/Application Support/{name}", "Application Support"),
        ("Library/Caches/{id}", "Cache"),
        ("Library/Containers/{id}", "Sandbox container"),
        ("Library/Saved Application State/{id}.savedState", "Saved window state"),
        ("Library/HTTPStorages/{id}", "Web storage"),
        ("Library/HTTPStorages/{id}.binarycookies", "Cookies"),
        ("Library/WebKit/{id}", "WebKit data"),
        ("Library/Logs/{id}", "Logs"),
        ("Library/Logs/{name}", "Logs"),
        ("Library/Application Scripts/{id}", "App scripts"),
        ("Library/Cookies/{id}.binarycookies", "Cookies"),
    ]

    /// Names too generic to match folders by ("Code" could be anything).
    static let genericNames: Set<String> = [
        "app", "code", "data", "logs", "cache", "caches", "helper", "agent", "electron", "chrome",
        "google", "microsoft", "apple", "settings", "preferences", "support", "update", "updater",
    ]

    /// Candidate leftover paths for an app, whether or not they exist.
    public static func candidates(home: String, bundleID: String, name: String) -> [(path: String, kind: String)] {
        var out: [(String, String)] = []
        var seen = Set<String>()
        let nameUsable = name.count >= 4 && !genericNames.contains(name.lowercased()) && !name.contains("/")
        for (template, kind) in templates {
            if template.contains("{name}") && !nameUsable { continue }
            let rel = template.replacingOccurrences(of: "{id}", with: bundleID).replacingOccurrences(of: "{name}", with: name)
            let path = Paths.join(home, rel)
            if seen.insert(path.lowercased()).inserted { out.append((path, kind)) }
        }
        let groups = Paths.join(home, "Library/Group Containers")
        for child in Paths.children(groups) where child.lowercased().hasSuffix("." + bundleID.lowercased()) {
            out.append((Paths.join(groups, child), "Group container"))
        }
        return out
    }
}

public struct AppInventory: Sendable {
    public var env: ScanEnvironment
    /// Folders searched for apps (default: /Applications and ~/Applications).
    public var roots: [String]

    public init(env: ScanEnvironment = ScanEnvironment(), roots: [String]? = nil) {
        self.env = env
        self.roots = roots ?? ["/Applications", Paths.join(env.home, "Applications")]
    }

    /// .app bundles in the Applications folders, including one level of subfolders
    /// ("/Applications/Adobe Photoshop 2025/Adobe Photoshop 2025.app").
    public func appBundles() -> [String] {
        var out: [String] = []
        for root in roots {
            for child in Paths.children(root) where !child.hasPrefix(".") {
                let full = Paths.join(root, child)
                if child.hasSuffix(".app") {
                    out.append(full)
                } else if Paths.isDirectory(full) {
                    out += Paths.children(full).filter { $0.hasSuffix(".app") }.map { Paths.join(full, $0) }
                }
            }
        }
        return out
    }

    /// Installed third-party apps with their sizes, last-used dates and existing leftovers.
    public func load(cancel: CancellationFlag? = nil) -> [AppRecord] {
        let bundles = appBundles()
        let lock = NSLock()
        var records: [AppRecord] = []
        DispatchQueue.concurrentPerform(iterations: bundles.count) { i in
            if cancel?.isCancelled == true { return }
            if let record = record(for: bundles[i]) {
                lock.withLock { records.append(record) }
            }
        }
        return records.sorted { $0.totalSize > $1.totalSize }
    }

    public func record(for path: String) -> AppRecord? {
        guard let app = InstalledApp(bundleURL: URL(fileURLWithPath: path)),
              !Self.isProtected(bundleID: app.bundleID) else { return nil }
        let name = (FileManager.default.displayName(atPath: path) as NSString).deletingPathExtension
        let leftovers = LeftoverLocations.candidates(home: env.home, bundleID: app.bundleID, name: name)
            .filter { Paths.exists($0.path) && !Self.isInside($0.path, path) }
            .map { Leftover(path: $0.path, kind: $0.kind, size: DirectorySizer.measure($0.path, threads: 2).bytes) }
            .filter { $0.size > 0 }
        return AppRecord(path: path, name: name, bundleID: app.bundleID, version: app.info["CFBundleShortVersionString"],
                         size: DirectorySizer.measure(path, threads: 2).bytes, lastUsed: Self.lastUsed(path),
                         fromAppStore: Paths.exists(path + "/Contents/_MASReceipt/receipt"),
                         hasSystemExtension: !Paths.children(path + "/Contents/Library/SystemExtensions").isEmpty,
                         leftovers: leftovers)
    }

    /// Apple's own apps and SpaceSaver itself are never offered for removal.
    public static func isProtected(bundleID: String) -> Bool {
        let id = bundleID.lowercased()
        return id.hasPrefix("com.apple.") || id == "com.spacesaver.app"
    }

    static func isInside(_ path: String, _ ancestor: String) -> Bool { Paths.isWithin(path, ancestor) }

    /// When the app was last opened, from Spotlight.
    public static func lastUsed(_ path: String) -> Date? {
        guard let item = MDItemCreate(kCFAllocatorDefault, path as CFString) else { return nil }
        return MDItemCopyAttribute(item, kMDItemLastUsedDate) as? Date
    }

    /// Cleanup items for uninstalling `app` plus the chosen leftovers.
    public func uninstallItems(_ app: AppRecord, leftovers chosen: Set<String>, running: RunningApps) -> [CleanupItem] {
        let blocked = running.bundleIDs.contains(app.bundleID.lowercased()) ? "\(app.name) is open. Quit it first." : nil
        var items = [CleanupItem(
            id: "app:" + app.path, category: .apps, title: app.name, subtitle: Paths.abbreviate(app.path, home: env.home),
            paths: [app.path], size: app.size, risk: .review, method: .trash,
            explanation: "The \(app.name) app\(app.version.map { " (version \($0))" } ?? "").",
            regenerate: app.fromAppStore ? "Reinstall it from the App Store." : "Reinstall it from its website or installer.",
            lastModified: app.lastUsed,
            tags: (app.fromAppStore ? ["App Store"] : []) + (app.hasSystemExtension ? ["System extension"] : []),
            blockedReason: blocked,
            recommended: false, group: app.bundleID)]
        for leftover in app.leftovers where chosen.contains(leftover.path) {
            items.append(CleanupItem(
                id: "app-leftover:" + leftover.path, category: .apps, title: "\(app.name): \(leftover.kind)",
                subtitle: Paths.abbreviate(leftover.path, home: env.home), paths: [leftover.path], size: leftover.size,
                risk: .review, method: .trash, explanation: "\(leftover.kind) that \(app.name) keeps in your Library.",
                regenerate: "Recreated with default settings if you reinstall \(app.name).", blockedReason: blocked,
                recommended: false, group: app.bundleID))
        }
        return items
    }
}

/// Library folders left behind by apps that are no longer installed.
public struct LeftoverAnalyzer: Sendable {
    public var env: ScanEnvironment
    public var running: RunningApps
    public var minAgeDays = 30
    public var minSize: Int64 = 1_000_000

    public init(env: ScanEnvironment, running: RunningApps) {
        self.env = env
        self.running = running
    }

    static let locations: [(String, String, RiskLevel)] = [
        ("Library/Application Support", "Application Support", .review),
        ("Library/Containers", "Sandbox container", .review),
        ("Library/Saved Application State", "Saved window state", .safe),
        ("Library/HTTPStorages", "Web storage", .safe),
        ("Library/WebKit", "WebKit data", .safe),
        ("Library/Application Scripts", "App scripts", .safe),
    ]

    public func analyze(installedIDs: Set<String>? = nil) -> [CleanupItem] {
        let installed = installedIDs ?? Self.installedBundleIDs(home: env.home)
        var found: [String: [(path: String, kind: String, risk: RiskLevel)]] = [:]
        for (rel, kind, risk) in Self.locations {
            let dir = Paths.join(env.home, rel)
            for child in Paths.children(dir) {
                var id = child
                for suffix in [".savedState", ".binarycookies"] where id.hasSuffix(suffix) { id.removeLast(suffix.count) }
                guard Self.looksLikeBundleID(id), !owned(id, installed: installed) else { continue }
                found[id, default: []].append((Paths.join(dir, child), kind, risk))
            }
        }

        let sizes = DirectorySizer.measureAll(found.values.flatMap { $0.map(\.path) })
        var items: [CleanupItem] = []
        for (id, entries) in found {
            let measured = entries.compactMap { sizes[$0.path] }
            let total = measured.reduce(0) { $0 + $1.bytes }
            guard total >= minSize else { continue }
            let newest = measured.compactMap(\.newestDate).max()
            if let newest, env.now.timeIntervalSince(newest) < Double(minAgeDays) * 86_400 { continue }
            let risk = entries.map(\.risk).max() ?? .review
            let kinds = Array(Set(entries.map(\.kind))).sorted().joined(separator: ", ")
            items.append(CleanupItem(
                id: "leftovers:" + id, category: .leftovers, title: Self.friendlyName(id), subtitle: "\(id) · \(kinds)",
                paths: entries.map(\.path).sorted(), size: total, risk: risk,
                explanation: "Left behind by an app that's no longer installed (\(id)): \(kinds.lowercased()).",
                regenerate: "Only needed if you reinstall the app and want its old settings and data back.",
                lastModified: newest, tags: ["Not installed"], itemCount: entries.count))
        }
        return items
    }

    func owned(_ id: String, installed: Set<String>) -> Bool {
        let lower = id.lowercased()
        if running.bundleIDs.contains(lower) || installed.contains(lower) { return true }
        if AppInventory.isProtected(bundleID: lower) { return true }
        // Same vendor as something installed (helpers, updaters, renamed apps): leave it alone.
        let vendor = lower.split(separator: ".").prefix(2).joined(separator: ".")
        if installed.contains(where: { $0 == vendor || $0.hasPrefix(vendor + ".") }) { return true }
        if running.bundleIDs.contains(where: { $0.hasPrefix(vendor + ".") }) { return true }
        // Installed somewhere else that Launch Services knows about.
        return NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) != nil
    }

    /// Bundle IDs of apps (and the helper apps inside them) in the usual Applications folders.
    public static func installedBundleIDs(home: String) -> Set<String> {
        var ids = Set<String>()
        let roots = ["/Applications", "/Applications/Utilities", "/System/Applications", "/System/Applications/Utilities",
                     Paths.join(home, "Applications"), "/Library/Application Support"]
        func add(_ app: String, depth: Int) {
            if let info = InstalledApp(bundleURL: URL(fileURLWithPath: app)) { ids.insert(info.bundleID.lowercased()) }
            guard depth < 2 else { return }
            for sub in ["Contents/Library/LoginItems", "Contents/Helpers", "Contents/Applications", "Contents/Frameworks"] {
                let dir = Paths.join(app, sub)
                for child in Paths.children(dir) where child.hasSuffix(".app") { add(Paths.join(dir, child), depth: depth + 1) }
            }
        }
        for root in roots {
            for child in Paths.children(root) where !child.hasPrefix(".") {
                let full = Paths.join(root, child)
                if child.hasSuffix(".app") {
                    add(full, depth: 0)
                } else if Paths.isDirectory(full) {
                    for sub in Paths.children(full) where sub.hasSuffix(".app") { add(Paths.join(full, sub), depth: 0) }
                }
            }
        }
        return ids
    }

    /// "com.vendor.product" style names only; Apple's and group containers are excluded.
    public static func looksLikeBundleID(_ s: String) -> Bool {
        let parts = s.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count >= 3, !s.contains(" "), !s.lowercased().hasPrefix("group.") else { return false }
        let first = parts[0]
        guard (2...6).contains(first.count), first.allSatisfy({ $0.isLowercase && $0.isLetter }) else { return false }
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_"))
        return parts.allSatisfy { !$0.isEmpty && $0.unicodeScalars.allSatisfy(allowed.contains) }
    }

    /// "com.spotify.client" → "Spotify", "com.adobe.Acrobat.Pro" → "Acrobat Pro".
    public static func friendlyName(_ id: String) -> String {
        let parts = id.split(separator: ".").map(String.init)
        let generic: Set<String> = ["client", "app", "mac", "macos", "osx", "desktop", "application", "main"]
        let editions: Set<String> = ["pro", "lite", "free", "beta", "plus", "mini", "max", "hd", "dc", "se", "x"]
        var pick = parts.last ?? id
        if generic.contains(pick.lowercased()), parts.count >= 4 {
            pick = parts[parts.count - 2]
        } else if generic.contains(pick.lowercased()), parts.count >= 2 {
            pick = parts[parts.count - 2]
        } else if editions.contains(pick.lowercased()), parts.count >= 4 {
            pick = parts[parts.count - 2] + " " + pick
        }
        let spaced = pick.replacingOccurrences(of: "-", with: " ").replacingOccurrences(of: "_", with: " ")
        return spaced.prefix(1).uppercased() + spaced.dropFirst()
    }
}
