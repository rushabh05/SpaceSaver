import AppKit
import SpaceSaverCore
import SwiftUI

/// Development aid: `SPACESAVER_SNAPSHOT=/some/dir SpaceSaver.app/Contents/MacOS/SpaceSaver`
/// renders each screen of the main window to PNG files and quits. It draws the app's own
/// window, so it needs no Screen Recording permission. Read-only: it never cleans anything.
@MainActor
enum DebugSnapshot {
    static var directory: String? { ProcessInfo.processInfo.environment["SPACESAVER_SNAPSHOT"] }

    static func runIfRequested(model: AppModel) {
        guard let dir = directory else { return }
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(3))
            // SPACESAVER_SNAPSHOT_SIZE=760x540 renders at a smaller window size.
            if let size = ProcessInfo.processInfo.environment["SPACESAVER_SNAPSHOT_SIZE"]?.split(separator: "x"),
               size.count == 2, let w = Double(size[0]), let h = Double(size[1]),
               let window = NSApp.windows.first(where: { $0.isVisible && $0.frame.width > 600 && $0.title != "SpaceSaver Island" }) {
                window.setContentSize(NSSize(width: w, height: h))
            }
            model.section = .activity // force a first full render before capturing
            try? await Task.sleep(for: .seconds(1))
            let shots: [(String, SidebarSection)] = [
                ("01-overview", .overview),
                ("02-projects", .category(.projectArtifacts)),
                ("03-ai-sessions", .category(.aiSessions)),
                ("04-system-junk", .category(.systemJunk)),
                ("05-activity", .activity),
                ("06-agents", .approvals),
                ("18-xcode", .category(.xcode)),
            ]
            for (name, section) in shots {
                model.section = section
                try? await Task.sleep(for: .seconds(1.2))
                capture(name: name, dir: dir)
            }
            model.section = .storageMap
            model.startMapScan(path: Paths.expand(ProcessInfo.processInfo.environment["SPACESAVER_SNAPSHOT_MAP"] ?? "~/Library/Developer"))
            while model.mapScanning { try? await Task.sleep(for: .milliseconds(200)) }
            try? await Task.sleep(for: .seconds(1.2))
            capture(name: "07-storage-map", dir: dir)
            model.section = .largeFiles
            try? await Task.sleep(for: .seconds(1))
            capture(name: "08-large-files", dir: dir)
            model.section = .overview
            try? await Task.sleep(for: .seconds(3))
            capture(name: "09-overview-late", dir: dir)
            // Update banner with a sample release (nothing is downloaded).
            model.update = UpdateRelease(version: "1.2.0", tag: "v1.2.0", title: "SpaceSaver 1.2.0",
                                         notes: "Faster scans and a new uninstaller.", publishedAt: Date(),
                                         dmgURL: URL(string: "https://example.com/SpaceSaver.dmg")!,
                                         signatureURL: URL(string: "https://example.com/SpaceSaver.dmg.sig")!,
                                         size: 3_400_000, pageURL: nil)
            model.updateStatus = .available
            try? await Task.sleep(for: .seconds(3))
            capture(name: "17-update-banner", dir: dir)
            model.update = nil
            model.updateStatus = .idle
            model.section = .category(.packageCaches)
            try? await Task.sleep(for: .seconds(1.2))
            capture(name: "10-package-caches", dir: dir)

            // Dynamic Island states.
            let island = IslandController.shared
            island.pinned = true
            model.peek("sparkles", .green, "Scan complete", "42.15 GB safe to clean")
            try? await Task.sleep(for: .seconds(1.2))
            captureWindow(island.islandWindow, name: "11-island-peek", dir: dir)
            model.islandPeek = nil
            island.state.hovering = true
            try? await Task.sleep(for: .seconds(1.4))
            captureWindow(island.islandWindow, name: "12-island-expanded", dir: dir)
            island.state.hovering = false
            model.cleaning = CleaningProgress(done: 3, total: 8, title: "npm cache")
            try? await Task.sleep(for: .seconds(1.2))
            captureWindow(island.islandWindow, name: "13-island-live", dir: dir)
            island.state.hovering = true
            try? await Task.sleep(for: .seconds(1.4))
            captureWindow(island.islandWindow, name: "14-island-expanded-cleaning", dir: dir)
            model.cleaning = nil
            island.state.hovering = false

            // Apps (uninstaller): wait for the inventory, then select the biggest app.
            model.section = .apps
            while !model.appsLoaded { try? await Task.sleep(for: .milliseconds(200)) }
            try? await Task.sleep(for: .seconds(1.2))
            capture(name: "15-apps", dir: dir)
            model.section = .category(.leftovers)
            try? await Task.sleep(for: .seconds(1.2))
            capture(name: "16-leftovers", dir: dir)


            NSApp.terminate(nil)
        }
    }

    /// `SPACESAVER_TOUR=/some/dir`: walks through the app with the made-up data from DemoData and
    /// saves each screen with screencapture (real window pixels, glass sidebar included), then quits.
    /// Used for marketing screenshots and videos. Needs Screen Recording permission for whatever
    /// launched it (the terminal). Nothing is scanned or cleaned: demo mode only simulates.
    static func runTourIfRequested(model: AppModel) {
        guard let dir = ProcessInfo.processInfo.environment["SPACESAVER_TOUR"], DemoMode.isOn else { return }
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(2.5))
            guard let window = mainWindow else { NSApp.terminate(nil); return }
            let original = window.frame
            // Tall enough for the whole sidebar.
            window.setContentSize(NSSize(width: 1200, height: 880))
            window.center()
            NSApp.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
            model.section = .activity
            try? await Task.sleep(for: .seconds(0.8))

            @MainActor func go(_ section: SidebarSection, focus: String? = nil, wait: Double = 1.6) async {
                model.section = section
                try? await Task.sleep(for: .seconds(0.6))
                if let focus { model.demoFocus = focus }
                try? await Task.sleep(for: .seconds(wait))
            }
            await go(.overview, wait: 3)
            shoot(window, "01-overview", dir)
            await go(.category(.projectArtifacts), focus: DemoData.focus[.projectArtifacts])
            shoot(window, "02-projects", dir)
            await go(.category(.aiSessions), focus: DemoData.focus[.aiSessions])
            shoot(window, "03-ai-sessions", dir)
            await go(.category(.agentWorktrees), focus: DemoData.focus[.agentWorktrees])
            shoot(window, "04-worktrees", dir)
            await go(.category(.xcode), focus: DemoData.focus[.xcode])
            shoot(window, "05-xcode", dir)
            await go(.apps, wait: 2)
            shoot(window, "06-apps", dir)

            // Clean the recommended items: the island's progress, then the result.
            await go(.overview, wait: 1.5)
            let island = IslandController.shared
            island.pinned = true
            model.peek("sparkles", .green, "Scan complete", "\(ByteFormat.string(model.recommendedItems.totalSize)) safe to clean")
            try? await Task.sleep(for: .seconds(1.3))
            shoot(island.islandWindow, "07-island-peek", dir)
            model.islandPeek = nil
            model.cleaning = CleaningProgress(done: 9, total: 21, title: "rust-cli › target")
            try? await Task.sleep(for: .seconds(1.3))
            shoot(island.islandWindow, "08-island-cleaning", dir)
            island.state.hovering = true
            try? await Task.sleep(for: .seconds(1.4))
            shoot(island.islandWindow, "09-island-cleaning-expanded", dir)
            island.state.hovering = false
            model.cleaning = nil
            _ = await model.simulateCleanup(model.recommendedItems.filter { $0.category.group == .developer },
                                            step: .milliseconds(1))
            try? await Task.sleep(for: .seconds(1.4))
            shoot(island.islandWindow, "10-island-cleaned", dir)
            try? await Task.sleep(for: .seconds(2.0))
            shoot(window, "11-overview-after", dir)
            window.setFrame(original, display: false)
            NSApp.terminate(nil)
        }
    }

    static var mainWindow: NSWindow? {
        NSApp.windows.first { $0.isVisible && $0.contentView != nil && $0.frame.width > 600 && $0.title != "SpaceSaver Island" }
    }

    /// Real window pixels via screencapture, with the window's shadow on a transparent background.
    static func shoot(_ window: NSWindow?, _ name: String, _ dir: String) {
        guard let window else { return }
        if window === mainWindow, !window.isKeyWindow {
            NSApp.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
            RunLoop.main.run(until: Date().addingTimeInterval(0.4))
        }
        // SPACESAVER_TOUR_EXTERNAL=1: when launched with `open` (so the window is active), the app
        // has no Screen Recording permission of its own. It asks the launching script to capture
        // instead: writes <name>.request with the window number and waits for <name>.png.
        if ProcessInfo.processInfo.environment["SPACESAVER_TOUR_EXTERNAL"] != nil {
            let request = Paths.join(dir, name + ".request"), png = Paths.join(dir, name + ".png")
            try? String(window.windowNumber).write(toFile: request, atomically: true, encoding: .utf8)
            let deadline = Date().addingTimeInterval(10)
            while !FileManager.default.fileExists(atPath: png) && Date() < deadline {
                RunLoop.main.run(until: Date().addingTimeInterval(0.1))
            }
            try? FileManager.default.removeItem(atPath: request)
            return
        }
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        task.arguments = ["-x", "-l\(window.windowNumber)", Paths.join(dir, name + ".png")]
        try? task.run()
        task.waitUntilExit()
    }

    /// SPACESAVER_SNAPSHOT_DUMP=1: writes the main window's view tree (class and frame) next to
    /// each capture, to find what is wider than the window.
    static func dumpViews(name: String, dir: String) {
        guard ProcessInfo.processInfo.environment["SPACESAVER_SNAPSHOT_DUMP"] != nil,
              let window = NSApp.windows.first(where: { $0.isVisible && $0.frame.width > 600 && $0.title != "SpaceSaver Island" }),
              let root = window.contentView else { return }
        var lines: [String] = ["window \(window.frame.size)"]
        func walk(_ view: NSView, _ depth: Int) {
            guard depth < 40 else { return }
            let f = view.convert(view.bounds, to: nil)
            lines.append(String(repeating: " ", count: depth) + "\(type(of: view)) x=\(Int(f.minX)) w=\(Int(f.width)) h=\(Int(f.height))")
            for sub in view.subviews { walk(sub, depth + 1) }
        }
        walk(root, 0)
        try? lines.joined(separator: "\n").write(toFile: Paths.join(dir, name + ".views.txt"), atomically: true, encoding: .utf8)
    }

    static func captureWindow(_ window: NSWindow?, name: String, dir: String) {
        guard let view = window?.contentView, let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: rep)
        if let png = rep.representation(using: .png, properties: [:]) {
            try? png.write(to: URL(fileURLWithPath: Paths.join(dir, name + ".png")))
        }
    }

    static func capture(name: String, dir: String) {
        dumpViews(name: name, dir: dir)
        guard let window = NSApp.windows.first(where: { $0.isVisible && $0.contentView != nil && $0.frame.width > 600
                                                        && $0.title != "SpaceSaver Island" }),
              let view = window.contentView,
              let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: rep)
        if let png = rep.representation(using: .png, properties: [:]) {
            try? png.write(to: URL(fileURLWithPath: Paths.join(dir, name + ".png")))
        }
    }
}
