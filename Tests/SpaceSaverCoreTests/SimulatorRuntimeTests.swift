import Foundation
import Testing
@testable import SpaceSaverCore

/// A temporary CoreSimulator folder shaped like the real one: Images/images.plist (the format
/// CoreSimulator writes, taken from a Mac with an iOS 26.4 runtime) and the runtime disk images.
private func makeCoreSimulator(_ runtimes: [(uuid: String, id: String, build: String, packed: Int, lastUsed: Date?)]) throws -> String {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("coresim-\(UUID().uuidString)").path
    try FileManager.default.createDirectory(atPath: root + "/Images", withIntermediateDirectories: true)
    var images: [[String: Any]] = []
    for r in runtimes {
        let dmg = root + "/Assets/\(r.uuid)/Restore/runtime.dmg"
        try FileManager.default.createDirectory(atPath: (dmg as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        try Data(repeating: 7, count: 64 * 1024).write(to: URL(fileURLWithPath: dmg))
        var image: [String: Any] = [
            "uuid": r.uuid,
            "path": ["relative": URL(fileURLWithPath: dmg).absoluteString],
            "runtimeInfo": ["build": r.build, "bundleIdentifier": r.id, "isInternal": false,
                            "platformIdentifier": "com.apple.platform.iphonesimulator", "version": r.packed],
            "state": 5,
        ]
        if let used = r.lastUsed { image["lastUsedAt"] = used }
        images.append(image)
    }
    let data = try PropertyListSerialization.data(fromPropertyList: ["images": images, "standaloneBundles": []],
                                                  format: .binary, options: 0)
    try data.write(to: URL(fileURLWithPath: root + "/Images/images.plist"))
    return root
}

private let noApps = RunningApps(processNames: [], bundleIDs: [], appNames: [:])

@Test func readsSimulatorRuntimesFromTheImageDatabase() throws {
    let old = Date().addingTimeInterval(-200 * 86_400)
    let root = try makeCoreSimulator([
        ("351BD612-D230-4C26-9D7A-CFFDBD29846A", "com.apple.CoreSimulator.SimRuntime.iOS-26-4", "23E244", 1_704_960, Date()),
        ("0B1C2D3E-0000-4000-8000-000000000185", "com.apple.CoreSimulator.SimRuntime.iOS-18-5", "22F77", 0x120500, old),
        // No version in the identifier: falls back to the packed version number.
        ("0B1C2D3E-0000-4000-8000-0000000000AA", "com.apple.CoreSimulator.SimRuntime.watchOS", "22T572", 0x0B0501, nil),
    ])
    let runtimes = SimulatorRuntimeAnalyzer.runtimes(imagesPlist: root + "/Images/images.plist")
    #expect(runtimes.map(\.name) == ["iOS 26.4", "iOS 18.5", "watchOS 11.5.1"])
    #expect(runtimes[0].image?.hasSuffix("/Restore/runtime.dmg") == true)
    #expect(runtimes[1].lastUsed != nil && runtimes[2].lastUsed == nil)

    // Without Xcode: shown with instructions, never selectable.
    var analyzer = SimulatorRuntimeAnalyzer(env: ScanEnvironment(home: root), running: noApps, root: root,
                                            simctl: nil, availability: [:], hostBuild: "25F71")
    analyzer.minBytes = 1
    let manual = analyzer.analyze()
    #expect(manual.count == 3)
    #expect(manual.allSatisfy { !$0.isSelectable && !$0.recommended && $0.risk == .review })
    #expect(manual.allSatisfy { $0.tags.contains("Xcode not installed") })

    // With Xcode: deleted through simctl. A runtime Xcode can't use is Safe; the newest stays Review.
    analyzer.simctl = "/usr/bin/xcrun"
    analyzer.availability = ["com.apple.CoreSimulator.SimRuntime.iOS-26-4|23E244": true,
                             "com.apple.CoreSimulator.SimRuntime.iOS-18-5|22F77": false]
    let items = Dictionary(uniqueKeysWithValues: analyzer.analyze().map { ($0.title, $0) })
    let current = try #require(items["iOS 26.4 Simulator runtime"])
    let stale = try #require(items["iOS 18.5 Simulator runtime"])
    #expect(current.risk == .review && !current.recommended && current.tags.contains("Newest iOS runtime"))
    #expect(stale.risk == .safe && stale.recommended && stale.tags.contains("Xcode can't use it"))
    #expect(stale.tags.contains("iOS 26.4 is installed"))
    #expect(stale.method == .command(executable: "/usr/bin/xcrun",
                                     arguments: ["simctl", "runtime", "delete", "0B1C2D3E-0000-4000-8000-000000000185"]))

    // While the Simulator runs, nothing can be deleted.
    analyzer.running = RunningApps(processNames: ["simulator"], bundleIDs: [], appNames: [:]) // snapshot() lowercases
    #expect(analyzer.analyze().allSatisfy { $0.blockedReason != nil && !$0.recommended })
}

@Test func listsOnlyStaleSimulatorDyldCaches() throws {
    let root = try makeCoreSimulator([("351BD612-D230-4C26-9D7A-CFFDBD29846A", "com.apple.CoreSimulator.SimRuntime.iOS-26-4",
                                       "23E244", 1_704_960, Date())])
    for cache in ["25F71/com.apple.CoreSimulator.SimRuntime.iOS-26-4.23E244",   // current macOS, installed runtime
                  "24A335/com.apple.CoreSimulator.SimRuntime.iOS-26-4.23E244",  // earlier macOS
                  "25F71/com.apple.CoreSimulator.SimRuntime.iOS-17-5.21F79"] {  // runtime gone
        let dir = root + "/Caches/dyld/" + cache
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        try Data(repeating: 1, count: 32 * 1024).write(to: URL(fileURLWithPath: dir + "/dyld_sim_shared_cache_arm64e"))
    }
    var analyzer = SimulatorRuntimeAnalyzer(env: ScanEnvironment(home: root), running: noApps, root: root,
                                            simctl: "/usr/bin/xcrun", availability: [:], hostBuild: "25F71")
    analyzer.minBytes = 1
    let caches = analyzer.analyze().filter { $0.id.hasPrefix("simdyld:") }
    #expect(Set(caches.flatMap(\.tags)).isSuperset(of: ["Built for an earlier macOS (24A335)", "Its runtime is no longer installed"]))
    #expect(caches.count == 2)
    #expect(caches.allSatisfy { !$0.isSelectable && $0.risk == .safe })

    // Without Xcode, the current cache is dead weight too.
    analyzer.simctl = nil
    #expect(analyzer.analyze().filter { $0.id.hasPrefix("simdyld:") }.count == 3)
}

@Test func parsesSimctlRuntimeAvailability() {
    let json = """
    {"runtimes": [
      {"identifier": "com.apple.CoreSimulator.SimRuntime.iOS-26-4", "buildversion": "23E244", "isAvailable": true, "name": "iOS 26.4"},
      {"identifier": "com.apple.CoreSimulator.SimRuntime.iOS-17-0", "buildversion": "21A328", "isAvailable": false,
       "availabilityError": "unavailable, runtime profile not found"}
    ]}
    """
    let map = SimulatorRuntimeAnalyzer.parseAvailability(Data(json.utf8))
    #expect(map == ["com.apple.CoreSimulator.SimRuntime.iOS-26-4|23E244": true,
                    "com.apple.CoreSimulator.SimRuntime.iOS-17-0|21A328": false])
    #expect(SimulatorRuntimeAnalyzer.parseAvailability(Data("not json".utf8)).isEmpty)
}

@Test func newestDeviceSupportVersionNeedsReview() {
    func item(_ folder: String) -> CleanupItem {
        let path = "/Users/me/Library/Developer/Xcode/" + folder
        return CleanupItem(id: "rule:xcode.devicesupport:" + path, category: .xcode, title: folder, subtitle: path,
                           paths: [path], size: 3_000_000_000, risk: .safe, explanation: "Device support files.")
    }
    let items = [item("iOS DeviceSupport/17.5 (21F79)"), item("iOS DeviceSupport/iPhone15,2 18.1 (22B83)"),
                 item("iOS DeviceSupport/16.4.1 (20E252) arm64e"), item("watchOS DeviceSupport/Watch6,1 10.0 (21R355)")]
    let out = Dictionary(uniqueKeysWithValues: SimulatorRuntimeAnalyzer.protectNewestDeviceSupport(items).map { ($0.title, $0) })
    #expect(out["iOS DeviceSupport/iPhone15,2 18.1 (22B83)"]?.risk == .review)
    #expect(out["iOS DeviceSupport/iPhone15,2 18.1 (22B83)"]?.recommended == false)
    #expect(out["iOS DeviceSupport/17.5 (21F79)"]?.risk == .safe)
    #expect(out["iOS DeviceSupport/16.4.1 (20E252) arm64e"]?.recommended == true)
    #expect(out["watchOS DeviceSupport/Watch6,1 10.0 (21R355)"]?.risk == .review)
}
