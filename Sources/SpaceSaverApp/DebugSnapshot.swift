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
