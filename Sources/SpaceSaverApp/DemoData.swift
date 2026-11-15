import Foundation
import SpaceSaverCore
import SwiftUI

/// `SPACESAVER_DEMO=1` (or `SPACESAVER_TOUR=<dir>`): the app shows made-up sample data instead of
/// scanning this Mac, for screenshots and videos that mustn't show anyone's real files. In demo mode
/// nothing is scanned, cleaned, restored, purged or uninstalled; cleaning is only simulated.
enum DemoMode {
    static let isOn: Bool = {
        let env = ProcessInfo.processInfo.environment
        return env["SPACESAVER_DEMO"] != nil || env["SPACESAVER_TOUR"] != nil
    }()
}

@MainActor
extension AppModel {
    func loadDemo() {
        let now = Date()
        scan = DemoData.scan(now: now)
        selection = Set(scan?.items.filter { $0.recommended && $0.isSelectable }.map(\.id) ?? [])
        disk = DemoData.disk(free: DemoData.freeBytes)
        samples = DemoData.samples(now: now)
        hasFullDiskAccess = true
        apps = DemoData.apps(now: now)
        appsLoaded = true
    }

    /// Plays the cleaning progress for `items`, then drops them from the sample results. Touches no files.
    func simulateCleanup(_ items: [CleanupItem], step: Duration = .milliseconds(140)) async -> Int64 {
        let usable = items.filter(\.isSelectable)
        for (i, item) in usable.enumerated() {
            cleaning = CleaningProgress(done: i, total: usable.count, title: item.title)
            try? await Task.sleep(for: step)
        }
        cleaning = nil
        let ids = Set(usable.map(\.id))
        let bytes = usable.totalSize
        if var scan {
            scan.items.removeAll { ids.contains($0.id) }
            withAnimation(Theme.spring) { self.scan = scan }
        }
        selection.subtract(ids)
        if let current = disk { disk = DemoData.disk(free: current.free + bytes) }
        peek("checkmark.circle.fill", .green, "Cleaned \(ByteFormat.string(bytes))",
             "In the Trash for \(settings.trashRetentionDays) days. Restorable.")
        show("Moved \(ByteFormat.string(bytes)) to the Trash. Put it back any time from Activity.")
        return bytes
    }
}

enum DemoData {
    static let gb: Double = 1_000_000_000
    static let totalBytes: Int64 = 494_384_795_648
    static let freeBytes: Int64 = 21_400_000_000

    /// The item each category view opens with in the tour.
    static let focus: [CleanupCategory: String] = [
        .projectArtifacts: "demo:rust-cli-target",
        .aiSessions: "demo:claude-sessions",
        .agentWorktrees: "demo:wt-storefront-1",
        .xcode: "demo:deriveddata",
    ]

    private static var home: String { NSHomeDirectory() }

    private static func item(_ id: String, _ category: CleanupCategory, _ title: String, _ relative: String,
                             gb size: Double, _ risk: RiskLevel, days: Double, tags: [String], _ explanation: String,
                             regenerate: String? = nil, method: CleanupMethod = .trash, blocked: String? = nil,
                             recommended: Bool? = nil, group: String? = nil, files: Int? = nil, now: Date) -> CleanupItem {
        let path = relative.hasPrefix("/") ? relative : home + "/" + relative
        return CleanupItem(
            id: "demo:" + id, category: category, title: title, subtitle: Paths.abbreviate(path),
            paths: [path], size: Int64(size * gb), risk: risk, method: method, explanation: explanation,
            regenerate: regenerate, lastModified: now.addingTimeInterval(-days * 86_400), tags: tags,
            blockedReason: blocked, recommended: recommended, group: group.map { "~/" + $0 }, itemCount: files)
    }

    static func scan(now: Date) -> ScanSummary {
        func p(_ id: String, _ project: String, _ folder: String, gb: Double, days: Double, kind: String,
               regenerate: String, blocked: String? = nil) -> CleanupItem {
            item(id, .projectArtifacts, "\(project) › \(folder)", "Projects/\(project)/\(folder)", gb: gb, .safe,
                 days: days, tags: [kind, "Active \(Int(days))d ago", "git"],
                 "\(kind) output for \(project). Nothing in the project has changed for \(Int(days)) days.",
                 regenerate: regenerate, blocked: blocked, group: "Projects/\(project)", files: Int(gb * 41_000), now: now)
        }
        func wt(_ id: String, _ repo: String, _ name: String, branch: String, gb: Double, days: Double,
                changes: Int, risk: RiskLevel) -> CleanupItem {
            var explanation = "A git worktree that Claude Code created for a task in \(repo). Its commits and branch live in the repository itself, so removing the folder doesn't lose them."
            if changes > 0 { explanation += " It has uncommitted changes, which would be lost. Commit or copy them first." }
            return item(id, .agentWorktrees, "\(repo) · \(name)", "Projects/\(repo)/.claude/worktrees/\(name)", gb: gb, risk,
                        days: days, tags: [branch, changes > 0 ? "\(changes) uncommitted changes" : "No uncommitted changes"],
                        explanation, regenerate: "Recreate it with `git worktree add` if you need it.",
                        group: "Projects/\(repo)", files: Int(gb * 30_000), now: now)
        }

        var items: [CleanupItem] = [
            p("storefront-node", "storefront-web", "node_modules", gb: 1.84, days: 94, kind: "Node.js", regenerate: "Run `npm install` in storefront-web."),
            p("storefront-next", "storefront-web", ".next", gb: 0.61, days: 94, kind: "Next.js", regenerate: "Rebuilt by `next build` or `next dev`."),
            p("rust-cli-target", "rust-cli", "target", gb: 3.12, days: 63, kind: "Cargo", regenerate: "Rebuilt by `cargo build`."),
            p("ml-venv", "ml-experiments", ".venv", gb: 2.31, days: 141, kind: "Python venv", regenerate: "`python -m venv .venv` then `pip install -r requirements.txt`."),
            p("landing-node", "landing-page", "node_modules", gb: 0.50, days: 210, kind: "Node.js", regenerate: "Run `npm install` in landing-page."),
            p("mobile-node", "mobile-app", "node_modules", gb: 1.12, days: 2, kind: "Node.js", regenerate: "Run `npm install` in mobile-app.",
              blocked: "Changed 2 days ago, so you're probably still working on it"),

            item("deriveddata", .xcode, "Xcode DerivedData", "Library/Developer/Xcode/DerivedData", gb: 8.74, .safe, days: 3,
                 tags: ["Xcode", "37 projects"], "Intermediate build products and indexes. Xcode rebuilds them the next time you build.",
                 regenerate: "Rebuilt automatically on the next build.", files: 412_000, now: now),
            item("devicesupport", .xcode, "iOS DeviceSupport 17.5", "Library/Developer/Xcode/iOS DeviceSupport/17.5 (21F79)", gb: 5.21, .review,
                 days: 188, tags: ["Xcode", "Unused 188d"], "Debug symbols copied from an iPhone running iOS 17.5. Xcode copies them again if you connect a device on that version.",
                 regenerate: "Re-copied when you connect a device running iOS 17.5.", now: now),
            item("simulators", .xcode, "Unavailable simulators", "Library/Developer/CoreSimulator/Devices", gb: 6.08, .review, days: 220,
                 tags: ["Simulator", "11 devices"], "Simulators for iOS versions no longer installed. Xcode can't run them.",
                 method: .command(executable: "/usr/bin/xcrun", arguments: ["simctl", "delete", "unavailable"]), now: now),

            item("docker-cache", .docker, "Docker build cache", "Library/Containers/com.docker.docker", gb: 6.80, .review, days: 35,
                 tags: ["Docker", "Builder cache"], "Layers cached by docker build. Builds are slower until the cache refills.",
                 method: .command(executable: "/usr/local/bin/docker", arguments: ["builder", "prune", "-f"]), now: now),

            item("npm-cache", .packageCaches, "npm cache", ".npm/_cacache", gb: 2.93, .safe, days: 1, tags: ["npm"],
                 "Packages npm downloaded before. npm fetches them again when needed.", regenerate: "Refilled by `npm install`.", now: now),
            item("brew-cache", .packageCaches, "Homebrew downloads", "Library/Caches/Homebrew", gb: 1.62, .safe, days: 6, tags: ["Homebrew"],
                 "Bottles and source archives from past installs and upgrades.", regenerate: "Re-downloaded by `brew install` if needed.", now: now),
            item("pip-cache", .packageCaches, "pip cache", "Library/Caches/pip", gb: 0.84, .safe, days: 12, tags: ["pip"],
                 "Wheels pip downloaded before.", regenerate: "Refilled by `pip install`.", now: now),
            item("gradle-cache", .packageCaches, "Gradle caches", ".gradle/caches", gb: 2.41, .review, days: 48, tags: ["Gradle"],
                 "Dependencies and build caches for Gradle projects. The next build re-downloads them.", now: now),
            item("cargo-registry", .packageCaches, "Cargo registry", ".cargo/registry", gb: 1.20, .review, days: 20, tags: ["Cargo"],
                 "Crate sources and the registry index.", now: now),

            item("vscode-ws", .ideCaches, "VS Code · storage for deleted projects", "Library/Application Support/Code/User/workspaceStorage", gb: 0.92, .safe,
                 days: 75, tags: ["VS Code", "64 folders"], "Workspace state for folders that no longer exist.", now: now),

            item("ollama", .aiModels, "Ollama · llama3.1:8b", ".ollama/models", gb: 4.92, .review, days: 96, tags: ["Ollama", "Unused 96d"],
                 "A local model's weights. `ollama pull` downloads it again.", now: now),
            item("hf", .aiModels, "Hugging Face · stable-diffusion-xl", ".cache/huggingface/hub", gb: 6.94, .review, days: 131,
                 tags: ["Hugging Face", "Unused 131d"], "Model files cached by Hugging Face libraries.", now: now),

            item("claude-sessions", .aiSessions, "Claude Code · sessions for deleted projects", ".claude/projects", gb: 0.86, .safe, days: 58,
                 tags: ["Claude Code", "212 sessions"], "Transcripts of Claude Code sessions in folders that no longer exist.", files: 212, now: now),
            item("cursor-history", .aiSessions, "Cursor · old workspace history", "Library/Application Support/Cursor/User/workspaceStorage", gb: 1.41, .safe,
                 days: 70, tags: ["Cursor", "38 folders"], "Chat and index data for workspaces that no longer exist.", now: now),
            item("codex-logs", .aiSessions, "Codex · session logs older than 90 days", ".codex/sessions", gb: 0.32, .review, days: 104,
                 tags: ["Codex", "96 sessions"], "Session transcripts. Remove them if you won't need to look back.", now: now),

            wt("wt-storefront-1", "storefront-web", "agent-3f9c2a1", branch: "claude/fix-checkout", gb: 1.42, days: 12, changes: 0, risk: .safe),
            wt("wt-storefront-2", "storefront-web", "agent-b71e04d", branch: "claude/new-header", gb: 0.98, days: 9, changes: 3, risk: .caution),
            wt("wt-rust-1", "rust-cli", "agent-5d2210c", branch: "claude/parallel-scan", gb: 2.07, days: 4, changes: 0, risk: .review),
            wt("wt-rust-2", "rust-cli", "agent-9a01e7f", branch: "claude/bench", gb: 1.88, days: 26, changes: 0, risk: .safe),

            item("spotify", .systemJunk, "Spotify cache", "Library/Caches/com.spotify.client", gb: 2.14, .safe, days: 1, tags: ["Cache"],
                 "Songs and artwork Spotify cached for streaming.", regenerate: "Refilled as you listen.", now: now),
            item("chrome", .systemJunk, "Google Chrome cache", "Library/Caches/Google/Chrome", gb: 1.33, .safe, days: 1, tags: ["Browser cache"],
                 "Web pages and images Chrome cached.", regenerate: "Refilled as you browse.", now: now),
            item("logs", .systemJunk, "Logs", "Library/Logs", gb: 0.41, .safe, days: 30, tags: ["Logs"], "Log files apps wrote while running.", now: now),
            item("crashes", .systemJunk, "Crash reports", "Library/Logs/DiagnosticReports", gb: 0.12, .safe, days: 40, tags: ["Diagnostics"],
                 "Reports from apps that crashed.", now: now),

            item("iphone-backup", .appleDevices, "iPhone backup · Alex's iPhone 13", "Library/Application Support/MobileSync/Backup/00008110-001A",
                 gb: 18.2, .caution, days: 402, tags: ["Backed up 13 months ago"],
                 "A local backup of an iPhone. If it's your only backup, keep it.", now: now),
            item("installer", .appleDevices, "Install macOS Sequoia", "/Applications/Install macOS Sequoia.app", gb: 13.36, .review, days: 160,
                 tags: ["Installer"], "A full macOS installer. You can download it again from the App Store.", now: now),

            item("xip", .downloads, "Xcode_16.2.xip", "Downloads/Xcode_16.2.xip", gb: 3.92, .review, days: 180, tags: ["Archive", "180 days old"],
                 "An installer archive you've probably already used.", now: now),
            item("docker-dmg", .downloads, "Docker.dmg", "Downloads/Docker.dmg", gb: 0.69, .review, days: 122, tags: ["Disk image", "122 days old"],
                 "An installer you've probably already used.", now: now),

            item("ps-left", .leftovers, "Adobe Photoshop 2023", "Library/Application Support/Adobe/Adobe Photoshop 2023", gb: 2.63, .review, days: 240,
                 tags: ["App deleted", "Support files"], "Files left behind by an app that's no longer installed.", now: now),
            item("zoom-left", .leftovers, "Zoom", "Library/Application Support/zoom.us", gb: 0.34, .review, days: 300,
                 tags: ["App deleted", "Support files"], "Files left behind by an app that's no longer installed.", now: now),

            item("trash", .trash, "Trash", ".Trash", gb: 3.41, .review, days: 5, tags: ["148 items"],
                 "Files already in the Trash still take up space until it's emptied.", method: .emptyTrash, recommended: false, now: now),
        ]
        items.sort { $0.size > $1.size }
        return ScanSummary(date: now.addingTimeInterval(-90), items: items, duration: 38)
    }

    private static func decode<T: Decodable>(_ type: T.Type, _ object: Any) -> T? {
        guard let data = try? JSONSerialization.data(withJSONObject: object) else { return nil }
        return try? JSONDecoder().decode(type, from: data)
    }

    static func disk(free: Int64) -> DiskStatus? {
        decode(DiskStatus.self, ["volumeName": "Macintosh HD", "format": "APFS", "total": totalBytes, "free": free,
                                 "availableForImportantUsage": free + 6_500_000_000, "mountPoint": "/"])
    }

    /// Free space shrinking over the last month.
    static func samples(now: Date) -> [DiskSample] {
        (0..<30).compactMap { day -> DiskSample? in
            let free = Double(freeBytes) + Double(29 - day) * 1.9 * gb + (day % 3 == 0 ? 2.5 * gb : 0)
            return decode(DiskSample.self, ["date": now.addingTimeInterval(Double(day - 29) * 86_400).timeIntervalSinceReferenceDate,
                                            "total": totalBytes, "free": Int64(free)])
        }
    }

    static func apps(now: Date) -> [AppRecord] {
        func app(_ name: String, _ id: String, version: String, gb size: Double, days: Double?,
                 leftovers: [(String, String, Double)]) -> AppRecord? {
            let path = "/Applications/\(name).app"
            let left: [[String: Any]] = leftovers.map { ["path": home + "/" + $0.0, "kind": $0.1, "size": Int64($0.2 * gb)] }
            var dict: [String: Any] = ["path": path, "name": name, "bundleID": id, "version": version,
                                       "size": Int64(size * gb), "fromAppStore": false, "hasSystemExtension": false,
                                       "leftovers": left]
            if let days { dict["lastUsed"] = now.addingTimeInterval(-days * 86_400).timeIntervalSinceReferenceDate }
            return decode(AppRecord.self, dict)
        }
        return [
            app("GarageBand", "com.apple.garageband10", version: "10.4.11", gb: 1.92, days: 214,
                leftovers: [("Library/Application Support/GarageBand", "Application Support", 2.84),
                            ("Library/Caches/com.apple.garageband10", "Cache", 0.21)]),
            app("Unity Hub", "com.unity3d.unityhub", version: "3.10.0", gb: 0.62, days: 163,
                leftovers: [("Library/Application Support/UnityHub", "Application Support", 1.37),
                            ("Library/Caches/com.unity3d.unityhub", "Cache", 0.18)]),
            app("Docker", "com.docker.docker", version: "4.36.0", gb: 2.11, days: 35,
                leftovers: [("Library/Containers/com.docker.docker", "Sandbox container", 0.94)]),
            app("Postman", "com.postmanlabs.mac", version: "11.20.0", gb: 0.58, days: 97,
                leftovers: [("Library/Application Support/Postman", "Application Support", 0.41)]),
            app("Keynote", "com.apple.iWork.Keynote", version: "14.3", gb: 0.71, days: 260,
                leftovers: [("Library/Containers/com.apple.iWork.Keynote", "Sandbox container", 0.12)]),
            app("Obsidian", "md.obsidian", version: "1.7.7", gb: 0.31, days: 3,
                leftovers: [("Library/Application Support/obsidian", "Application Support", 0.05)]),
            app("Slack", "com.tinyspeck.slackmacgap", version: "4.41.105", gb: 0.49, days: 0.2,
                leftovers: [("Library/Application Support/Slack", "Application Support", 0.88)]),
        ].compactMap { $0 }.sorted { $0.totalSize > $1.totalSize }
    }
}
