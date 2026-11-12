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
            NSApp.terminate(nil)
        }
    }

    static func captureWindow(_ window: NSWindow?, name: String, dir: String) {
        guard let view = window?.contentView, let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: rep)
        if let png = rep.representation(using: .png, properties: [:]) {
            try? png.write(to: URL(fileURLWithPath: Paths.join(dir, name + ".png")))
        }
    }

    static func capture(name: String, dir: String) {
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
