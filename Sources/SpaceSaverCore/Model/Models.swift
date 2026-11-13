import Foundation

/// How safe it is to remove something.
public enum RiskLevel: String, Codable, CaseIterable, Comparable, Sendable {
    /// Rebuilt automatically or with one command. No user data.
    case safe
    /// Rebuildable but costly (large re-download, long rebuild) or holds tool state.
    case review
    /// May hold personal data or work you can't regenerate. Check before removing.
    case caution

    public var title: String {
        switch self {
        case .safe: return "Safe"
        case .review: return "Review"
        case .caution: return "Caution"
        }
    }

    public var summary: String {
        switch self {
        case .safe: return "Regenerates automatically. No personal data."
        case .review: return "Can be rebuilt or re-downloaded, but that takes time or bandwidth."
        case .caution: return "May contain personal data. Check the contents first."
        }
    }

    private var order: Int {
        switch self {
        case .safe: return 0
        case .review: return 1
        case .caution: return 2
        }
    }

    public static func < (a: RiskLevel, b: RiskLevel) -> Bool { a.order < b.order }
}

public enum CategoryGroup: String, Codable, CaseIterable, Sendable {
    case developer = "Developer"
    case system = "Cleanup"
}

public enum CleanupCategory: String, Codable, CaseIterable, Sendable, Identifiable {
    case projectArtifacts
    case xcode
    case docker
    case packageCaches
    case ideCaches
    case aiModels
    case aiSessions
    case systemJunk
    case appleDevices
    case downloads
    case leftovers
    case largeFiles
    case duplicates
    case trash
    case custom
    case apps

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .projectArtifacts: return "Project Artifacts"
        case .xcode: return "Xcode & Simulators"
        case .docker: return "Docker & Containers"
        case .packageCaches: return "Package Caches"
        case .ideCaches: return "IDEs & Editors"
        case .aiModels: return "AI Models"
        case .aiSessions: return "AI Session Logs"
        case .systemJunk: return "System Junk"
        case .appleDevices: return "Devices & Installers"
        case .downloads: return "Old Downloads"
        case .leftovers: return "App Leftovers"
        case .largeFiles: return "Large Files"
        case .duplicates: return "Duplicates"
        case .trash: return "Trash"
        case .custom: return "Custom Rules"
        case .apps: return "Apps"
        }
    }

    public var symbol: String {
        switch self {
        case .projectArtifacts: return "shippingbox"
        case .xcode: return "hammer"
        case .docker: return "cube.transparent"
        case .packageCaches: return "archivebox"
        case .ideCaches: return "chevron.left.forwardslash.chevron.right"
        case .aiModels: return "cpu"
        case .aiSessions: return "bubble.left.and.text.bubble.right"
        case .systemJunk: return "sparkles"
        case .appleDevices: return "iphone"
        case .downloads: return "arrow.down.circle"
        case .leftovers: return "app.dashed"
        case .largeFiles: return "doc.zipper"
        case .duplicates: return "doc.on.doc"
        case .trash: return "trash"
        case .custom: return "slider.horizontal.3"
        case .apps: return "xmark.bin"
        }
    }

    public var blurb: String {
        switch self {
        case .projectArtifacts:
            return "node_modules, build outputs and virtualenvs in projects you haven't touched lately."
        case .xcode:
            return "DerivedData, device support files, old archives and simulators."
        case .docker:
            return "Build cache, unused images, stopped containers and the Docker VM disk."
        case .packageCaches:
            return "Download caches for npm, pnpm, Yarn, pip, Cargo, Gradle, Homebrew and others."
        case .ideCaches:
            return "Editor caches, logs and workspace storage for projects that no longer exist."
        case .aiModels:
            return "Ollama, Hugging Face, LM Studio and other local model weights."
        case .aiSessions:
            return "Transcripts and indexes from Claude Code, Codex, Cursor, Copilot and other AI tools."
        case .systemJunk:
            return "App caches, logs, crash reports and browser caches."
        case .appleDevices:
            return "iOS backups, firmware files and leftover macOS installers."
        case .downloads:
            return "Installers and archives in Downloads that you've probably already used."
        case .leftovers:
            return "Support files, containers and saved state from apps you've already deleted."
        case .largeFiles:
            return "The biggest files in your home folder."
        case .duplicates:
            return "Identical files, matched by SHA-256 content hash."
        case .trash:
            return "Files already in the Trash still take up space until it's emptied."
        case .custom:
            return "Locations from your own rules in ~/.spacesaver/rules.json."
        case .apps:
            return "Uninstall apps together with the files they leave in your Library."
        }
    }

    public var group: CategoryGroup {
        switch self {
        case .projectArtifacts, .xcode, .docker, .packageCaches, .ideCaches, .aiModels, .aiSessions:
            return .developer
        default:
            return .system
        }
    }

    /// Categories produced by the "Scan" pass (large files and duplicates need their own scans).
    public static let reclaimScanCategories: [CleanupCategory] = [
        .projectArtifacts, .xcode, .docker, .packageCaches, .ideCaches, .aiModels, .aiSessions,
        .systemJunk, .appleDevices, .downloads, .leftovers, .trash, .custom,
    ]
}

/// How an item gets removed.
public enum CleanupMethod: Codable, Hashable, Sendable {
    /// Move to the macOS Trash. Undoable from Activity.
    case trash
    /// Compress into the SpaceSaver vault (tar.gz + SHA-256), then move originals to Trash.
    case archiveThenTrash
    /// Run a tool's own cleanup command (docker prune, simctl delete). Not undoable.
    case command(executable: String, arguments: [String])
    /// Permanently empty the user's Trash. Not undoable.
    case emptyTrash
    /// Nothing SpaceSaver can do automatically; `instructions` explain the manual step.
    case manual(instructions: String)

    public var isUndoable: Bool {
        switch self {
        case .trash, .archiveThenTrash: return true
        default: return false
        }
    }

    public var label: String {
        switch self {
        case .trash: return "Move to Trash"
        case .archiveThenTrash: return "Archive, then move to Trash"
        case .command(let exe, let args): return ([Paths.name(exe)] + args).joined(separator: " ")
        case .emptyTrash: return "Empty Trash permanently"
        case .manual: return "Manual step"
        }
    }

    public var isActionable: Bool {
        if case .manual = self { return false }
        return true
    }
}

public struct CleanupItem: Identifiable, Codable, Hashable, Sendable {
    public var id: String
    public var category: CleanupCategory
    public var title: String
    /// Secondary text, usually the abbreviated path.
    public var subtitle: String
    public var paths: [String]
    /// Bytes freed when removed (allocated size, so APFS sparse files are counted honestly).
    public var size: Int64
    public var risk: RiskLevel
    public var method: CleanupMethod
    /// What this is, in plain English.
    public var explanation: String
    /// How to get it back if you need it.
    public var regenerate: String?
    public var lastModified: Date?
    public var tags: [String]
    /// Set when the item must not be cleaned right now (app running, active project, protected).
    public var blockedReason: String?
    /// Pre-selected in "Smart Clean".
    public var recommended: Bool
    /// Rows with the same group are shown together (e.g. a project's root path).
    public var group: String?
    public var itemCount: Int?

    public init(id: String, category: CleanupCategory, title: String, subtitle: String, paths: [String],
                size: Int64, risk: RiskLevel, method: CleanupMethod = .trash, explanation: String,
                regenerate: String? = nil, lastModified: Date? = nil, tags: [String] = [],
                blockedReason: String? = nil, recommended: Bool? = nil, group: String? = nil,
                itemCount: Int? = nil) {
        self.id = id
        self.category = category
        self.title = title
        self.subtitle = subtitle
        self.paths = paths
        self.size = size
        self.risk = risk
        self.method = method
        self.explanation = explanation
        self.regenerate = regenerate
        self.lastModified = lastModified
        self.tags = tags
        self.blockedReason = blockedReason
        self.recommended = recommended ?? (risk == .safe && blockedReason == nil && method.isActionable)
        self.group = group
        self.itemCount = itemCount
    }

    public var isSelectable: Bool { blockedReason == nil && method.isActionable }
}

extension Array where Element == CleanupItem {
    public var totalSize: Int64 { reduce(0) { $0 + $1.size } }
}

/// The result of a reclaim scan, persisted so the menu bar and CLI can show it without rescanning.
public struct ScanSummary: Codable, Sendable {
    public var date: Date
    public var items: [CleanupItem]
    public var duration: TimeInterval

    public init(date: Date, items: [CleanupItem], duration: TimeInterval) {
        self.date = date
        self.items = items
        self.duration = duration
    }

    public var recommendedSize: Int64 { items.filter { $0.recommended && $0.isSelectable }.totalSize }
}
