import Foundation

public struct ScheduleSettings: Codable, Hashable, Sendable {
    public enum Frequency: String, Codable, CaseIterable, Sendable {
        case daily, weekly
    }

    public var enabled = false
    public var frequency: Frequency = .weekly
    /// 1 = Sunday ... 7 = Saturday (launchd convention minus one is handled by the scheduler).
    public var weekday = 2
    public var hour = 11
    public var minute = 0
    /// Only clean when free space falls below this many GB. 0 = always.
    public var onlyBelowFreeGB = 0
    public var skipOnBattery = true
    public var categories: [CleanupCategory] = [.systemJunk, .xcode, .packageCaches, .projectArtifacts]
    /// Permanently remove SpaceSaver-cleaned items from the Trash after the retention window.
    public var purgeExpiredTrash = true

    public init() {}
}

public struct AISettings: Codable, Hashable, Sendable {
    public var ollamaEnabled = false
    public var ollamaURL = "http://127.0.0.1:11434"
    public var ollamaModel = "llama3.2"

    public init() {}
}

/// Settings shared by the app, the CLI and the scheduled agent (~/.spacesaver/settings.json).
public struct Settings: Codable, Hashable, Sendable {
    /// Folders searched for code projects.
    public var projectRoots: [String] = ["~"]
    /// Never scanned, never cleaned.
    public var excludedPaths: [String] = []
    /// A project with no git or file activity for this many days is "dormant".
    public var dormantDays = 45
    public var largeFileThresholdMB = 100
    public var downloadsAgeDays = 30
    public var aiSessionAgeDays = 21
    public var duplicateMinSizeMB = 1
    /// SpaceSaver-cleaned items stay restorable in the Trash this long.
    public var trashRetentionDays = 7
    /// Skip caches belonging to running apps (Xcode, Docker, browsers...).
    public var activeAppGuard = true
    /// Check GitHub once a day for a newer signed release.
    public var autoCheckUpdates = true
    public var schedule = ScheduleSettings()
    public var ai = AISettings()

    public init() {}

    public init(from decoder: Decoder) throws {
        // Tolerant decoding: unknown or missing keys fall back to defaults, so older
        // settings files keep working after upgrades.
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = Settings()
        projectRoots = (try? c.decode([String].self, forKey: .projectRoots)) ?? d.projectRoots
        excludedPaths = (try? c.decode([String].self, forKey: .excludedPaths)) ?? d.excludedPaths
        dormantDays = (try? c.decode(Int.self, forKey: .dormantDays)) ?? d.dormantDays
        largeFileThresholdMB = (try? c.decode(Int.self, forKey: .largeFileThresholdMB)) ?? d.largeFileThresholdMB
        downloadsAgeDays = (try? c.decode(Int.self, forKey: .downloadsAgeDays)) ?? d.downloadsAgeDays
        aiSessionAgeDays = (try? c.decode(Int.self, forKey: .aiSessionAgeDays)) ?? d.aiSessionAgeDays
        duplicateMinSizeMB = (try? c.decode(Int.self, forKey: .duplicateMinSizeMB)) ?? d.duplicateMinSizeMB
        trashRetentionDays = (try? c.decode(Int.self, forKey: .trashRetentionDays)) ?? d.trashRetentionDays
        activeAppGuard = (try? c.decode(Bool.self, forKey: .activeAppGuard)) ?? d.activeAppGuard
        autoCheckUpdates = (try? c.decode(Bool.self, forKey: .autoCheckUpdates)) ?? d.autoCheckUpdates
        schedule = (try? c.decode(ScheduleSettings.self, forKey: .schedule)) ?? d.schedule
        ai = (try? c.decode(AISettings.self, forKey: .ai)) ?? d.ai
    }

    public static func load(_ paths: AppPaths = .default) -> Settings {
        JSONStore.load(Settings.self, from: paths.settings) ?? Settings()
    }

    public func save(_ paths: AppPaths = .default) throws {
        paths.ensure()
        try JSONStore.save(self, to: paths.settings)
    }

    public func expandedExclusions(home: String) -> [String] {
        excludedPaths.map { Paths.expand($0, home: home) }
    }
}
