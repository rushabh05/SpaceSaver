import Foundation
import IOKit.ps

public struct DiskStatus: Codable, Hashable, Sendable {
    public var volumeName: String
    public var format: String
    public var total: Int64
    /// Truly free bytes right now.
    public var free: Int64
    /// Free plus space macOS can purge on demand (local snapshots, purgeable caches).
    public var availableForImportantUsage: Int64
    public var mountPoint: String

    public var used: Int64 { max(total - free, 0) }
    public var purgeable: Int64 { max(availableForImportantUsage - free, 0) }
    public var usedFraction: Double { total > 0 ? Double(used) / Double(total) : 0 }

    public static func current(path: String = "/") -> DiskStatus? {
        let url = URL(fileURLWithPath: path)
        let keys: Set<URLResourceKey> = [
            .volumeTotalCapacityKey, .volumeAvailableCapacityKey, .volumeAvailableCapacityForImportantUsageKey,
            .volumeNameKey, .volumeLocalizedFormatDescriptionKey, .volumeURLKey,
        ]
        guard let values = try? url.resourceValues(forKeys: keys) else { return nil }
        let total = Int64(values.volumeTotalCapacity ?? 0)
        let free = Int64(values.volumeAvailableCapacity ?? 0)
        let important = values.volumeAvailableCapacityForImportantUsage ?? free
        return DiskStatus(volumeName: values.volumeName ?? "Macintosh HD",
                          format: values.volumeLocalizedFormatDescription ?? "APFS",
                          total: total, free: free, availableForImportantUsage: max(important, free),
                          mountPoint: values.volume?.path ?? "/")
    }

    public var summary: String {
        "\(ByteFormat.string(free)) free of \(ByteFormat.string(total)) (\(Int(usedFraction * 100))% used)"
    }
}

/// Time Machine local snapshots: a common hidden chunk of "System Data".
public enum LocalSnapshots {
    public static func list(volume: String = "/") -> [String] {
        let result = Shell.run("/usr/bin/tmutil", ["listlocalsnapshots", volume], timeout: 15)
        guard result.ok else { return [] }
        return result.stdout.split(separator: "\n").map(String.init)
            .filter { $0.hasPrefix("com.apple.TimeMachine") }
    }
}

public enum PowerStatus {
    public static var isOnBattery: Bool {
        guard let blob = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let type = IOPSGetProvidingPowerSourceType(blob)?.takeUnretainedValue() as String?
        else { return false }
        return type == kIOPSBatteryPowerValue
    }

    public static var isLowPowerMode: Bool { ProcessInfo.processInfo.isLowPowerModeEnabled }
}

public enum Permissions {
    /// Full Disk Access check: the TCC database is only readable with FDA.
    public static var hasFullDiskAccess: Bool {
        let probes = [
            Paths.expand("~/Library/Application Support/com.apple.TCC/TCC.db"),
            Paths.expand("~/Library/Safari/Bookmarks.plist"),
        ]
        for path in probes where FileManager.default.fileExists(atPath: path) {
            let fd = open(path, O_RDONLY)
            if fd >= 0 {
                close(fd)
                return true
            }
            return false
        }
        return false
    }

    public static let fullDiskAccessSettingsURL =
        URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles")!
}
