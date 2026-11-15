import Foundation

/// Simulator runtimes (the iOS, watchOS, tvOS and visionOS systems that simulators boot) and their
/// dyld caches. Each runtime is 5–9 GB, and old ones pile up with every Xcode update, so they're
/// often bigger than DerivedData.
///
/// Runtimes are read from CoreSimulator's image database (`/Library/Developer/CoreSimulator/Images/images.plist`),
/// which is readable without Xcode. The images live in root-owned or SIP-protected folders
/// (`/Library/Developer/CoreSimulator/Images`, `/System/Library/AssetsV2`), so removal always goes
/// through `xcrun simctl runtime delete`. Without Xcode the items are shown with manual instructions.
public struct SimulatorRuntimeAnalyzer {
    public var env: ScanEnvironment
    public var running: RunningApps
    /// CoreSimulator's system folder.
    public var root: String
    /// `/usr/bin/xcrun` when Xcode's simctl is available, otherwise nil.
    public var simctl: String?
    /// "identifier|build" -> whether the installed Xcode can use the runtime (`simctl list runtimes -j`).
    public var availability: [String: Bool]
    /// The running macOS build, e.g. "25F71". dyld caches built for another build are stale.
    public var hostBuild: String?
    /// Runtimes or caches smaller than this are left out.
    public var minBytes: Int64 = 100_000_000

    public init(env: ScanEnvironment, running: RunningApps, root: String = "/Library/Developer/CoreSimulator",
                simctl: String?, availability: [String: Bool], hostBuild: String?) {
        self.env = env
        self.running = running
        self.root = root
        self.simctl = simctl
        self.availability = availability
        self.hostBuild = hostBuild
    }

    /// Looks up simctl, what the installed Xcode can run, and the macOS build.
    public static func live(env: ScanEnvironment, running: RunningApps) -> SimulatorRuntimeAnalyzer {
        let simctl = SimulatorAnalyzer.simctlAvailable()
        let availability = simctl.map { xcrun -> [String: Bool] in
            let result = Shell.run(xcrun, ["simctl", "list", "runtimes", "-j"], timeout: 30)
            return result.ok ? parseAvailability(Data(result.stdout.utf8)) : [:]
        } ?? [:]
        return SimulatorRuntimeAnalyzer(env: env, running: running, simctl: simctl, availability: availability,
                                        hostBuild: currentHostBuild())
    }

    public struct Runtime: Equatable, Sendable {
        public var uuid: String
        /// e.g. com.apple.CoreSimulator.SimRuntime.iOS-26-4
        public var identifier: String
        public var build: String
        /// "iOS", "watchOS", "tvOS", "visionOS"
        public var platform: String
        public var version: SemanticVersion?
        /// The disk image that holds the runtime.
        public var image: String?
        public var lastUsed: Date?

        public var name: String { version.map { "\(platform) \($0)" } ?? platform }
        var key: String { identifier + "|" + build }
    }

    // MARK: Reading

    /// Runtimes registered in CoreSimulator's image database.
    public static func runtimes(imagesPlist path: String) -> [Runtime] {
        guard let data = FileManager.default.contents(atPath: path),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let images = plist["images"] as? [[String: Any]] else { return [] }
        return images.compactMap { image -> Runtime? in
            guard let uuid = image["uuid"] as? String, let info = image["runtimeInfo"] as? [String: Any],
                  let identifier = info["bundleIdentifier"] as? String else { return nil }
            let parts = SimulatorAnalyzer.runtimeName(identifier).split(separator: " ", maxSplits: 1).map(String.init)
            let platform = parts.first ?? "Simulator"
            var version = parts.count > 1 ? SemanticVersion(parts[1]) : nil
            if version == nil, let packed = info["version"] as? Int, packed > 0 {
                // 0x1A0400 -> 26.4
                let patch = packed & 0xFF
                version = SemanticVersion("\(packed >> 16).\((packed >> 8) & 0xFF)" + (patch > 0 ? ".\(patch)" : ""))
            }
            return Runtime(uuid: uuid, identifier: identifier, build: info["build"] as? String ?? "", platform: platform,
                           version: version, image: fileURLPath(image["path"]), lastUsed: image["lastUsedAt"] as? Date)
        }
    }

    /// `{"relative": "file:///…"}` (how images.plist stores URLs) or a plain string, to a path.
    static func fileURLPath(_ value: Any?) -> String? {
        let raw = (value as? [String: Any])?["relative"] as? String ?? value as? String
        guard let raw, !raw.isEmpty else { return nil }
        if let url = URL(string: raw), url.isFileURL { return url.path }
        return raw.hasPrefix("/") ? raw : nil
    }

    /// `simctl list runtimes -j`: {"runtimes": [{"identifier", "buildversion", "isAvailable"}]}.
    public static func parseAvailability(_ data: Data) -> [String: Bool] {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let runtimes = json["runtimes"] as? [[String: Any]] else { return [:] }
        var out: [String: Bool] = [:]
        for runtime in runtimes {
            guard let id = runtime["identifier"] as? String, let available = runtime["isAvailable"] as? Bool else { continue }
            out[id + "|" + (runtime["buildversion"] as? String ?? "")] = available
        }
        return out
    }

    static func currentHostBuild() -> String? {
        // "Version 26.5 (Build 25F71)"
        let s = ProcessInfo.processInfo.operatingSystemVersionString
        guard let range = s.range(of: "Build ") else { return nil }
        return String(s[range.upperBound...].prefix { $0 != ")" })
    }

    static func allocatedSize(_ path: String) -> Int64 {
        let url = URL(fileURLWithPath: path)
        if let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .totalFileAllocatedSizeKey, .fileAllocatedSizeKey]),
           values.isDirectory != true {
            return Int64(values.totalFileAllocatedSize ?? values.fileAllocatedSize ?? 0)
        }
        return DirectorySizer.measure(path).bytes
    }

    // MARK: Items

    public func analyze() -> [CleanupItem] {
        let runtimes = Self.runtimes(imagesPlist: Paths.join(root, "Images/images.plist"))
        let busy = env.settings.activeAppGuard
            ? running.running(processes: ["Simulator", "launchd_sim"], bundleIDs: ["com.apple.iphonesimulator"]) : nil
        return runtimeItems(runtimes, busy: busy) + legacyBundleItems(busy: busy) + dyldCacheItems(installed: runtimes)
    }

    func runtimeItems(_ runtimes: [Runtime], busy: String?) -> [CleanupItem] {
        var newest: [String: SemanticVersion] = [:]
        for r in runtimes { if let v = r.version, newest[r.platform].map({ v > $0 }) ?? true { newest[r.platform] = v } }

        return runtimes.compactMap { r -> CleanupItem? in
            guard let image = r.image, Paths.exists(image) else { return nil }
            let size = Self.allocatedSize(image)
            guard size >= minBytes else { return nil }

            // The tags that decide what to do come first; rows show as many as fit.
            var tags: [String] = []
            var details = [r.name, r.lastUsed.map { "Used \(RelativeTime.age(of: $0, now: env.now))" } ?? "Never used"]
            if !r.build.isEmpty { details.append("Build \(r.build)") }
            let isNewest = r.version != nil && r.version == newest[r.platform]
            if isNewest { details.insert("Newest \(r.platform) runtime", at: 0) }
            else if let v = newest[r.platform] { details.insert("\(r.platform) \(v) is installed", at: 0) }

            var explanation = "A simulator runtime: the \(r.platform) system that simulators boot. Each one takes several GB. Simulators that use it stop working until you download it again."
            let risk: RiskLevel
            let method: CleanupMethod
            if let xcrun = simctl {
                method = .command(executable: xcrun, arguments: ["simctl", "runtime", "delete", r.uuid])
                if availability[r.key] == false {
                    tags.append("Xcode can't use it")
                    explanation += " Your installed Xcode can't run this runtime, so it's dead weight."
                    risk = .safe
                } else {
                    if !isNewest { explanation += " A newer \(r.platform) runtime is installed." }
                    risk = .review
                }
            } else {
                tags.append("Xcode not installed")
                explanation += " Xcode isn't installed, so nothing can use it right now."
                method = .manual(instructions: "macOS keeps runtimes in a protected folder, so only Apple's tools can remove them. Install Xcode, then delete it in Xcode › Settings › Components, or run `xcrun simctl runtime delete \(r.uuid)`.")
                risk = .review
            }
            tags += details
            return CleanupItem(
                id: "simruntime:\(r.uuid)", category: .xcode, title: "\(r.name) Simulator runtime",
                subtitle: Paths.abbreviate(image, home: env.home), paths: [image], size: size, risk: risk, method: method,
                explanation: explanation,
                regenerate: "Download it again in Xcode › Settings › Components (several GB).",
                lastModified: r.lastUsed, tags: tags,
                blockedReason: simctl == nil ? nil : busy.map { "\($0) is running. Quit it to delete runtimes." },
                recommended: risk == .safe && busy == nil && simctl != nil, group: "Simulator runtimes")
        }
    }

    /// Older-style runtimes installed as bundles rather than disk images.
    func legacyBundleItems(busy: String?) -> [CleanupItem] {
        let bundles = Paths.glob(Paths.join(root, "Profiles/Runtimes") + "/*.simruntime")
        guard !bundles.isEmpty else { return [] }
        let sizes = DirectorySizer.measureAll(bundles)
        return bundles.compactMap { path -> CleanupItem? in
            guard let size = sizes[path], size.bytes >= minBytes else { return nil }
            let name = (Paths.name(path) as NSString).deletingPathExtension
            return CleanupItem(
                id: "simruntime-bundle:\(path)", category: .xcode, title: "\(name) Simulator runtime (bundle)",
                subtitle: Paths.abbreviate(path, home: env.home), paths: [path], size: size.bytes, risk: .review,
                method: .manual(instructions: "Delete it in Xcode › Settings › Components, or move it to the Trash in Finder (you'll be asked for an administrator password)."),
                explanation: "An older-style simulator runtime installed as a bundle. Simulators that use it stop working until you download it again.",
                regenerate: "Download it again in Xcode › Settings › Components.",
                lastModified: size.newestDate, tags: [name, "Legacy bundle"], group: "Simulator runtimes", itemCount: size.files)
        }
    }

    /// dyld shared caches the Simulator builds per macOS build and runtime. Caches for an older
    /// macOS build, a runtime that's gone, or a Mac without Xcode are never used again.
    func dyldCacheItems(installed: [Runtime]) -> [CleanupItem] {
        let base = Paths.join(root, "Caches/dyld")
        let installedKeys = Set(installed.map { "\($0.identifier).\($0.build)" })
        var candidates: [(path: String, reason: String)] = []
        for host in Paths.children(base) where !host.hasPrefix(".") {
            for cache in Paths.children(Paths.join(base, host)) where cache.hasPrefix("com.apple.CoreSimulator.SimRuntime.") {
                let reason: String?
                if let hostBuild, host != hostBuild { reason = "Built for an earlier macOS (\(host))" }
                else if !installedKeys.contains(cache) { reason = "Its runtime is no longer installed" }
                else if simctl == nil { reason = "Xcode isn't installed" }
                else { reason = nil }
                if let reason { candidates.append((Paths.join(Paths.join(base, host), cache), reason)) }
            }
        }
        guard !candidates.isEmpty else { return [] }
        let sizes = DirectorySizer.measureAll(candidates.map(\.path))
        return candidates.compactMap { candidate -> CleanupItem? in
            guard let size = sizes[candidate.path], size.bytes >= minBytes else { return nil }
            let runtimeID = Paths.name(candidate.path).split(separator: ".").dropLast().joined(separator: ".")
            let name = SimulatorAnalyzer.runtimeName(runtimeID)
            return CleanupItem(
                id: "simdyld:\(candidate.path)", category: .xcode, title: "Simulator dyld cache · \(name)",
                subtitle: Paths.abbreviate(candidate.path, home: env.home), paths: [candidate.path], size: size.bytes,
                risk: .safe,
                method: .manual(instructions: "It's in a folder only an administrator can change. Move it to the Trash in Finder (you'll be asked for your password)."),
                explanation: "A shared-library cache the Simulator builds to boot faster. \(candidate.reason), so it won't be used again.",
                regenerate: "Rebuilt automatically the next time a simulator boots.",
                lastModified: size.newestDate,
                tags: [candidate.reason == "Xcode isn't installed" ? "Xcode not installed" : candidate.reason, name],
                group: "Simulator runtimes", itemCount: size.files)
        }
    }

    // MARK: DeviceSupport

    /// Marks the newest OS version in each DeviceSupport folder (iOS, watchOS, …) as Review: the
    /// device you plug in today most likely runs it, and Xcode copies several GB again if it's gone.
    public static func protectNewestDeviceSupport(_ items: [CleanupItem]) -> [CleanupItem] {
        let prefix = "rule:xcode.devicesupport:"
        func version(_ item: CleanupItem) -> SemanticVersion? {
            guard let path = item.paths.first else { return nil }
            // "17.5 (21F79)", "iPhone15,2 17.0 (21A329)", "16.4.1 (20E252) arm64e"
            return Paths.name(path).split(separator: " ").lazy
                .filter { !$0.contains(",") && !$0.hasPrefix("(") }
                .compactMap { SemanticVersion(String($0)) }.first
        }
        var newest: [String: SemanticVersion] = [:]
        for item in items where item.id.hasPrefix(prefix) {
            guard let v = version(item), let path = item.paths.first else { continue }
            let platform = Paths.parent(path)
            if newest[platform].map({ v > $0 }) ?? true { newest[platform] = v }
        }
        return items.map { item in
            guard item.id.hasPrefix(prefix), let path = item.paths.first, let v = version(item),
                  v == newest[Paths.parent(path)] else { return item }
            var copy = item
            copy.risk = .review
            copy.recommended = false
            copy.tags.insert("Newest version you've connected", at: 0)
            copy.explanation += " This is the newest version you've connected, so your device probably still runs it. Without it, Xcode copies several GB again the next time you plug that device in."
            return copy
        }
    }
}
