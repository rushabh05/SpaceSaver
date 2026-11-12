import Foundation

/// Installs a per-user LaunchAgent that runs `spacesaver auto` on a schedule, so scheduled
/// cleaning works even when the app is closed.
public enum Scheduler {
    public static let label = "com.spacesaver.autoclean"

    public static var plistPath: String { Paths.expand("~/Library/LaunchAgents/\(label).plist") }
    public static var isInstalled: Bool { FileManager.default.fileExists(atPath: plistPath) }

    public static func plist(cliPath: String, schedule: ScheduleSettings, logPath: String) -> [String: Any] {
        var interval: [String: Int] = ["Hour": schedule.hour, "Minute": schedule.minute]
        if schedule.frequency == .weekly {
            // launchd: 0 and 7 are Sunday. Our weekday is 1 = Sunday ... 7 = Saturday.
            interval["Weekday"] = (schedule.weekday - 1 + 7) % 7
        }
        return [
            "Label": label,
            "ProgramArguments": [cliPath, "auto"],
            "StartCalendarInterval": interval,
            "StandardOutPath": logPath,
            "StandardErrorPath": logPath,
            "RunAtLoad": false,
            "ProcessType": "Background",
            "LowPriorityIO": true,
            "Nice": 10,
        ]
    }

    public static func install(cliPath: String, schedule: ScheduleSettings, paths: AppPaths = .default) throws {
        paths.ensure()
        let dict = plist(cliPath: cliPath, schedule: schedule, logPath: paths.autoLog)
        let data = try PropertyListSerialization.data(fromPropertyList: dict, format: .xml, options: 0)
        try FileManager.default.createDirectory(atPath: Paths.parent(plistPath), withIntermediateDirectories: true)
        let domain = "gui/\(getuid())"
        Shell.run("/bin/launchctl", ["bootout", "\(domain)/\(label)"], timeout: 15)
        try data.write(to: URL(fileURLWithPath: plistPath), options: .atomic)
        let result = Shell.run("/bin/launchctl", ["bootstrap", domain, plistPath], timeout: 15)
        if !result.ok {
            throw NSError(domain: "Scheduler", code: Int(result.status),
                          userInfo: [NSLocalizedDescriptionKey: "launchctl: \(result.stderr.trimmingCharacters(in: .whitespacesAndNewlines))"])
        }
    }

    public static func uninstall() {
        Shell.run("/bin/launchctl", ["bootout", "gui/\(getuid())/\(label)"], timeout: 15)
        try? FileManager.default.removeItem(atPath: plistPath)
    }
}

/// What `spacesaver auto` does: check the guards, scan the chosen categories, clean only
/// recommended safe items, purge expired Trash entries, and log everything.
public struct AutoCleaner {
    public var settings: Settings
    public var paths: AppPaths

    public init(settings: Settings = .load(), paths: AppPaths = .default) {
        self.settings = settings
        self.paths = paths
    }

    public struct Outcome: Sendable {
        public var ran: Bool
        public var message: String
        public var bytes: Int64
    }

    public func run(force: Bool = false) -> Outcome {
        let schedule = settings.schedule
        if !schedule.enabled && !force {
            return Outcome(ran: false, message: "Scheduled cleaning is off.", bytes: 0)
        }
        if schedule.skipOnBattery && !force && (PowerStatus.isOnBattery || PowerStatus.isLowPowerMode) {
            return Outcome(ran: false, message: "Skipped: running on battery.", bytes: 0)
        }
        let disk = DiskStatus.current()
        if let disk { HistoryStore(paths: paths).recordSample(disk) }
        if schedule.onlyBelowFreeGB > 0, let disk, !force,
           disk.free > Int64(schedule.onlyBelowFreeGB) * 1_000_000_000 {
            return Outcome(ran: false, message: "Skipped: \(ByteFormat.string(disk.free)) free is above the \(schedule.onlyBelowFreeGB) GB trigger.", bytes: 0)
        }

        var env = ScanEnvironment(settings: settings)
        env.settings.activeAppGuard = true // never optional for unattended runs
        let summary = ReclaimScanner(env: env).run(categories: Set(schedule.categories))
        LastScanStore.save(summary, paths: paths)
        let picks = summary.items.filter { $0.recommended && $0.isSelectable && $0.risk == .safe && $0.method.isUndoable }
        let engine = CleanupEngine(safety: SafetyGuard(excluded: settings.excludedPaths), log: ActivityLog(paths: paths),
                                   paths: paths)
        let report = engine.clean(picks, source: "schedule")
        var purged: Int64 = 0
        if schedule.purgeExpiredTrash {
            purged = engine.purge(olderThanDays: settings.trashRetentionDays)
        }
        var message = "Cleaned \(picks.count) items (\(ByteFormat.string(report.bytesCleaned))) to the Trash."
        if purged > 0 { message += " Permanently removed \(ByteFormat.string(purged)) cleaned more than \(settings.trashRetentionDays) days ago." }
        if !report.errors.isEmpty { message += " \(report.errors.count) errors." }
        return Outcome(ran: true, message: message, bytes: report.bytesCleaned)
    }
}
