import Foundation

/// The version of this build. `scripts/build-app.sh` and `scripts/release.sh` read it from here,
/// so bump it in this one place.
public enum AppVersion {
    public static let current = "1.1.1"

    /// The version of the installed app bundle when running from one (the app, or the CLI inside
    /// `Contents/Helpers`), otherwise the compiled-in version.
    public static var installed: String { InstalledApp.current?.version ?? current }
}

/// A dotted numeric version such as "1.2.3" or "v1.2". Pre-release suffixes ("-beta") are ignored.
public struct SemanticVersion: Comparable, CustomStringConvertible, Hashable, Sendable {
    public let parts: [Int]

    public init?(_ string: String) {
        var s = string.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.hasPrefix("v") || s.hasPrefix("V") { s.removeFirst() }
        if let dash = s.firstIndex(where: { $0 == "-" || $0 == "+" }) { s = String(s[..<dash]) }
        let pieces = s.split(separator: ".", omittingEmptySubsequences: false)
        guard (1...4).contains(pieces.count) else { return nil }
        var parts: [Int] = []
        for piece in pieces {
            guard let n = Int(piece), n >= 0 else { return nil }
            parts.append(n)
        }
        self.parts = parts
    }

    public var description: String { parts.map(String.init).joined(separator: ".") }

    public static func < (a: SemanticVersion, b: SemanticVersion) -> Bool {
        for i in 0..<max(a.parts.count, b.parts.count) {
            let x = i < a.parts.count ? a.parts[i] : 0
            let y = i < b.parts.count ? b.parts[i] : 0
            if x != y { return x < y }
        }
        return false
    }

    public static func == (a: SemanticVersion, b: SemanticVersion) -> Bool { !(a < b) && !(b < a) }
    public func hash(into hasher: inout Hasher) {
        var trimmed = parts
        while trimmed.last == 0 { trimmed.removeLast() }
        hasher.combine(trimmed)
    }
}

/// An installed SpaceSaver.app (or any app bundle) and the bits of its Info.plist we care about.
public struct InstalledApp: Sendable, Equatable {
    public var url: URL
    public var bundleID: String
    public var version: String
    public var info: [String: String]

    public init?(bundleURL: URL) {
        let plist = bundleURL.appendingPathComponent("Contents/Info.plist")
        guard let data = try? Data(contentsOf: plist),
              let dict = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let id = dict["CFBundleIdentifier"] as? String else { return nil }
        url = bundleURL.standardizedFileURL
        bundleID = id
        version = dict["CFBundleShortVersionString"] as? String ?? "0"
        info = dict.compactMapValues { $0 as? String }
    }

    /// The .app bundle that contains `executable`, if any (works for Contents/MacOS and Contents/Helpers).
    public static func enclosing(executable: String) -> InstalledApp? {
        var url = URL(fileURLWithPath: executable).resolvingSymlinksInPath()
        while url.path != "/" {
            url.deleteLastPathComponent()
            if url.pathExtension == "app" { return InstalledApp(bundleURL: url) }
        }
        return nil
    }

    public static var current: InstalledApp? {
        if Bundle.main.bundleURL.pathExtension == "app" { return InstalledApp(bundleURL: Bundle.main.bundleURL) }
        return enclosing(executable: CommandLine.arguments.first ?? "")
    }

    /// macOS runs apps opened straight from a download in a randomized read-only location
    /// ("App Translocation"); those can't update themselves until moved to Applications.
    public var isTranslocated: Bool { url.path.contains("/AppTranslocation/") }
}
