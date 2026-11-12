import Foundation

/// Human-readable byte sizes and parsing of size strings ("1.5GB", "512 MB", "100M").
public enum ByteFormat {
    public static func string(_ bytes: Int64) -> String {
        if bytes <= 0 { return "Zero KB" }
        return ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    public static func compact(_ bytes: Int64) -> String {
        let units = ["B", "KB", "MB", "GB", "TB", "PB"]
        var value = Double(max(bytes, 0))
        var unit = 0
        while value >= 1000, unit < units.count - 1 {
            value /= 1000
            unit += 1
        }
        if unit == 0 { return "\(Int(value)) B" }
        return value >= 100 ? String(format: "%.0f %@", value, units[unit])
            : String(format: "%.1f %@", value, units[unit])
    }

    /// Parses sizes like "1.2GB", "512MB", "100M", "4.096kB", "0B". Decimal (1000) units,
    /// matching Finder and Docker. "GiB"/"MiB" use binary units.
    public static func parse(_ text: String) -> Int64? {
        let s = text.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: " ", with: "")
        guard !s.isEmpty else { return nil }
        var numberEnd = s.startIndex
        while numberEnd < s.endIndex, s[numberEnd].isNumber || s[numberEnd] == "." {
            numberEnd = s.index(after: numberEnd)
        }
        guard let number = Double(s[s.startIndex..<numberEnd]) else { return nil }
        let unit = s[numberEnd...].lowercased()
        let multiplier: Double
        switch unit {
        case "", "b": multiplier = 1
        case "k", "kb": multiplier = 1e3
        case "m", "mb": multiplier = 1e6
        case "g", "gb": multiplier = 1e9
        case "t", "tb": multiplier = 1e12
        case "kib": multiplier = 1024
        case "mib": multiplier = 1024 * 1024
        case "gib": multiplier = 1024 * 1024 * 1024
        case "tib": multiplier = 1024 * 1024 * 1024 * 1024
        default: return nil
        }
        return Int64(number * multiplier)
    }
}

public enum RelativeTime {
    /// "3 days ago", "11 months ago".
    public static func string(since date: Date, now: Date = Date()) -> String {
        if abs(now.timeIntervalSince(date)) < 60 { return "just now" }
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full
        return formatter.localizedString(for: date, relativeTo: now)
    }

    /// Compact age: "3d", "11mo", "2y".
    public static func age(of date: Date, now: Date = Date()) -> String {
        let days = Int(now.timeIntervalSince(date) / 86_400)
        if days < 1 { return "today" }
        if days < 60 { return "\(days)d" }
        if days < 730 { return "\(days / 30)mo" }
        return "\(days / 365)y"
    }

    public static func days(since date: Date, now: Date = Date()) -> Int {
        Int(now.timeIntervalSince(date) / 86_400)
    }
}

extension String {
    /// Removes ANSI escape sequences and control characters. File and folder names are
    /// attacker-controllable, so anything we hand to an AI agent or terminal goes through this.
    public var sanitizedForDisplay: String {
        var out = ""
        out.reserveCapacity(count)
        var iterator = unicodeScalars.makeIterator()
        while let scalar = iterator.next() {
            if scalar == "\u{1B}" { // ESC: skip a CSI sequence
                if let next = iterator.next(), next == "[" {
                    while let c = iterator.next(), !(0x40...0x7E).contains(c.value) {}
                }
                continue
            }
            if scalar.properties.generalCategory == .control || scalar.properties.generalCategory == .format {
                continue
            }
            out.unicodeScalars.append(scalar)
        }
        return out
    }
}
