import Foundation
import Testing
@testable import SpaceSaverCore

// MARK: - Versions

@Test func semanticVersionsCompareNumerically() throws {
    let v = { (s: String) in try #require(SemanticVersion(s)) }
    #expect(try v("v1.10.0") > v("1.9.9"))
    #expect(try v("1.0") == v("1.0.0"))
    #expect(try v("2.0.0-beta.1") == v("2.0.0"))
    #expect(try v("1.0.1") > v("v1.0.0"))
    #expect(SemanticVersion("latest") == nil)
    #expect(SemanticVersion("1..2") == nil)
}

@Test func findsEnclosingAppBundle() throws {
    let sb = Sandbox()
    let app = fakeApp(in: sb, at: "Apps/SpaceSaver.app", version: "1.2.3", sign: false)
    let found = try #require(InstalledApp.enclosing(executable: app + "/Contents/Helpers/spacesaver"))
    #expect(found.version == "1.2.3")
    #expect(found.bundleID == "com.spacesaver.app")
    #expect(InstalledApp.enclosing(executable: sb.path("not-an-app/bin/tool")) == nil)
}

// MARK: - Signatures

@Test func signaturesVerifyAndRejectTampering() throws {
    let sb = Sandbox()
    let file = URL(fileURLWithPath: sb.file("update.dmg", bytes: 300_000))
    let keys = UpdateSigner.generateKeyPair()
    let signature = try UpdateSigner.sign(file: file, privateKey: keys.privateKey)
    #expect(UpdateSigner.verify(file: file, signature: signature, publicKey: keys.publicKey))
    #expect(try UpdateSigner.publicKey(forPrivateKey: keys.privateKey) == keys.publicKey)

    let other = UpdateSigner.generateKeyPair()
    #expect(!UpdateSigner.verify(file: file, signature: signature, publicKey: other.publicKey))
    #expect(!UpdateSigner.verify(file: file, signature: "not base64!", publicKey: keys.publicKey))

    let handle = try FileHandle(forWritingTo: file)
    try handle.seek(toOffset: 1234)
    handle.write(Data([0x00, 0x01]))
    try handle.close()
    #expect(!UpdateSigner.verify(file: file, signature: signature, publicKey: keys.publicKey))
}

// MARK: - Feed

@Test func parsesGitHubReleaseFeed() throws {
    let json = releaseJSON(tag: "v1.4.0", dmg: "https://example.com/SpaceSaver.dmg", sig: "https://example.com/SpaceSaver.dmg.sig")
    let release = try UpdateChecker.parseGitHubRelease(Data(json.utf8))
    #expect(release.version == "1.4.0")
    #expect(release.dmgURL.absoluteString == "https://example.com/SpaceSaver.dmg")
    #expect(release.size == 3_300_000)
    #expect(release.summary == "Faster scans and a new uninstaller.")

    let noSig = releaseJSON(tag: "v1.4.0", dmg: "https://example.com/SpaceSaver.dmg", sig: nil)
    #expect(throws: UpdateError.missingAsset("SpaceSaver.dmg.sig")) {
        try UpdateChecker.parseGitHubRelease(Data(noSig.utf8))
    }
}

@Test func checkReportsOnlyNewerReleases() async throws {
    let sb = Sandbox()
    let feed = sb.file("latest.json", content: releaseJSON(tag: "v1.1.0", dmg: "file:///x.dmg", sig: "file:///x.dmg.sig"))
    let config = UpdateConfig(feedURL: URL(fileURLWithPath: feed), publicKey: "k")
    #expect(try await UpdateChecker.check(current: "1.0.0", config: config)?.version == "1.1.0")
    #expect(try await UpdateChecker.check(current: "1.1.0", config: config) == nil)
    #expect(try await UpdateChecker.check(current: "1.2", config: config) == nil)
}

// MARK: - End to end

@Test func installsSignedUpdateAndRejectsBadOnes() async throws {
    let sb = Sandbox()
    let installed = try #require(InstalledApp(bundleURL: URL(fileURLWithPath: fakeApp(in: sb, at: "Apps/SpaceSaver.app", version: "1.0.0"))))
    let keys = UpdateSigner.generateKeyPair()

    // A signed 1.0.1 release on a file:// "server".
    let newApp = fakeApp(in: sb, at: "release/stage/SpaceSaver.app", version: "1.0.1")
    let dmg = sb.path("release/SpaceSaver.dmg")
    let made = Shell.run("/usr/bin/hdiutil", ["create", "-volname", "SpaceSaver", "-srcfolder", Paths.parent(newApp),
                                              "-format", "UDZO", "-ov", dmg], timeout: 120)
    try #require(made.ok, "hdiutil create failed: \(made.stderr)")
    let sigPath = sb.file("release/SpaceSaver.dmg.sig", content: try UpdateSigner.sign(file: URL(fileURLWithPath: dmg), privateKey: keys.privateKey))
    let release = UpdateRelease(version: "1.0.1", tag: "v1.0.1", title: "1.0.1", notes: "", publishedAt: nil,
                                dmgURL: URL(fileURLWithPath: dmg), signatureURL: URL(fileURLWithPath: sigPath),
                                size: 1, pageURL: nil)

    // Wrong key: refused before anything is mounted.
    let impostor = UpdateInstaller(publicKey: UpdateSigner.generateKeyPair().publicKey, workDir: URL(fileURLWithPath: sb.path("work-bad")))
    await #expect(throws: UpdateError.badSignature) { try await impostor.download(release) }

    // Right key: download, stage, swap.
    let installer = UpdateInstaller(publicKey: keys.publicKey, workDir: URL(fileURLWithPath: sb.path("work")))
    let local = try await installer.download(release)
    #expect(throws: (any Error).self) { try installer.stage(dmg: local, expectedVersion: "9.9.9") }
    let staged = try installer.stage(dmg: local, expectedVersion: "1.0.1")
    try installer.install(staged: staged, over: installed, waitForPID: nil, relaunch: false)

    let after = try #require(InstalledApp(bundleURL: installed.url))
    #expect(after.version == "1.0.1")
    #expect(Paths.exists(sb.path("work/previous-1.0.0.app")))
    let verify = Shell.run("/usr/bin/codesign", ["--verify", "--deep", "--strict", installed.url.path])
    #expect(verify.ok)
}

@Test func stageRejectsAnotherAppsBundle() async throws {
    let sb = Sandbox()
    let keys = UpdateSigner.generateKeyPair()
    let other = fakeApp(in: sb, at: "release/stage/SpaceSaver.app", version: "2.0.0", bundleID: "com.example.evil")
    let dmg = sb.path("release/SpaceSaver.dmg")
    try #require(Shell.run("/usr/bin/hdiutil", ["create", "-srcfolder", Paths.parent(other), "-format", "UDZO", "-ov", dmg],
                           timeout: 120).ok)
    let installer = UpdateInstaller(publicKey: keys.publicKey, workDir: URL(fileURLWithPath: sb.path("work")))
    #expect(throws: UpdateError.invalidBundle("bundle ID com.example.evil")) {
        try installer.stage(dmg: URL(fileURLWithPath: dmg), expectedVersion: "2.0.0")
    }
}

// MARK: - Helpers

/// A minimal app bundle with a real (copied) executable, ad-hoc signed unless `sign` is false.
@discardableResult
func fakeApp(in sb: Sandbox, at rel: String, version: String, bundleID: String = "com.spacesaver.app",
             sign: Bool = true) -> String {
    let app = sb.dir(rel)
    sb.dir(rel + "/Contents/MacOS")
    sb.dir(rel + "/Contents/Helpers")
    try? FileManager.default.copyItem(atPath: "/usr/bin/true", toPath: app + "/Contents/MacOS/SpaceSaver")
    let plist: [String: Any] = [
        "CFBundleIdentifier": bundleID, "CFBundleShortVersionString": version, "CFBundleVersion": "1",
        "CFBundleExecutable": "SpaceSaver", "CFBundlePackageType": "APPL", "CFBundleName": "SpaceSaver",
    ]
    let data = try! PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
    FileManager.default.createFile(atPath: app + "/Contents/Info.plist", contents: data)
    if sign { Shell.run("/usr/bin/codesign", ["--force", "--sign", "-", app]) }
    return app
}

func releaseJSON(tag: String, dmg: String, sig: String?) -> String {
    var assets = [#"{"name":"SpaceSaver.dmg","browser_download_url":"\#(dmg)","size":3300000}"#]
    if let sig { assets.append(#"{"name":"SpaceSaver.dmg.sig","browser_download_url":"\#(sig)","size":88}"#) }
    return #"""
    {"tag_name":"\#(tag)","name":"SpaceSaver \#(tag)","html_url":"https://github.com/rushabh05/SpaceSaver/releases/tag/\#(tag)",
     "published_at":"2026-11-12T10:00:00Z","body":"Faster scans and a **new** uninstaller.\n\nMore details.",
     "assets":[\#(assets.joined(separator: ","))]}
    """#
}

// MARK: - Apps and leftovers

@Test func leftoverNamingAndBundleIDShape() {
    #expect(LeftoverAnalyzer.friendlyName("com.spotify.client") == "Spotify")
    #expect(LeftoverAnalyzer.friendlyName("com.adobe.Acrobat.Pro") == "Acrobat Pro")
    #expect(LeftoverAnalyzer.friendlyName("org.mozilla.firefox") == "Firefox")
    #expect(LeftoverAnalyzer.looksLikeBundleID("com.betazeta.jot"))
    #expect(!LeftoverAnalyzer.looksLikeBundleID("Google"))
    #expect(!LeftoverAnalyzer.looksLikeBundleID("group.com.example.shared"))
    #expect(!LeftoverAnalyzer.looksLikeBundleID("My App.data.files"))
}

@Test func appInventoryFindsLeftoversAndBlocksRunningApps() throws {
    let sb = Sandbox()
    let home = sb.path("home")
    fakeApp(in: sb, at: "home/Applications/Notely.app", version: "3.1", bundleID: "com.example.notely", sign: false)
    sb.file("home/Library/Application Support/com.example.notely/db.sqlite", bytes: 50_000)
    sb.file("home/Library/Caches/com.example.notely/cache.bin", bytes: 20_000)
    sb.file("home/Library/Containers/com.example.other/data", bytes: 10_000) // someone else's
    fakeApp(in: sb, at: "home/Applications/Safari Clone.app", version: "1", bundleID: "com.apple.SafariClone", sign: false)

    let inventory = AppInventory(env: ScanEnvironment(home: home), roots: [home + "/Applications"])
    let apps = inventory.load()
    #expect(apps.map(\.bundleID) == ["com.example.notely"]) // Apple's are never listed
    let notely = try #require(apps.first)
    #expect(Set(notely.leftovers.map(\.kind)) == ["Application Support", "Cache"])
    #expect(notely.leftoverSize >= 70_000)

    let all = Set(notely.leftovers.map(\.path))
    let items = inventory.uninstallItems(notely, leftovers: all, running: RunningApps(processNames: [], bundleIDs: [], appNames: [:]))
    #expect(items.count == 3)
    #expect(items.allSatisfy { $0.isSelectable && $0.category == .apps && !$0.recommended })
    let running = RunningApps(processNames: [], bundleIDs: ["com.example.notely"], appNames: [:])
    #expect(inventory.uninstallItems(notely, leftovers: all, running: running).allSatisfy { $0.blockedReason != nil })
}

@Test func leftoverAnalyzerOnlyFlagsOldOrphans() throws {
    let sb = Sandbox()
    let home = sb.path("home")
    let old = Date().addingTimeInterval(-90 * 86_400)
    // Orphan: its app is gone and it's old.
    sb.file("home/Library/Containers/com.gone.editor/Data/big.bin", bytes: 2_000_000, modified: old)
    sb.file("home/Library/Saved Application State/com.gone.editor.savedState/window.data", bytes: 10_000, modified: old)
    // Same vendor as an installed app: left alone.
    sb.file("home/Library/Application Support/com.keep.helper/cache.bin", bytes: 2_000_000, modified: old)
    // Recently used: left alone.
    sb.file("home/Library/Application Support/com.fresh.tool/state.bin", bytes: 2_000_000)
    // Apple's: left alone.
    sb.file("home/Library/Containers/com.apple.Notes/data.bin", bytes: 2_000_000, modified: old)
    for dir in ["Library/Containers/com.gone.editor", "Library/Containers/com.gone.editor/Data",
                "Library/Saved Application State/com.gone.editor.savedState", "Library/Application Support/com.keep.helper",
                "Library/Containers/com.apple.Notes"] {
        sb.setDate(sb.path("home/" + dir), old)
    }

    let analyzer = LeftoverAnalyzer(env: ScanEnvironment(home: home), running: RunningApps(processNames: [], bundleIDs: [], appNames: [:]))
    let items = analyzer.analyze(installedIDs: ["com.keep.app"])
    #expect(items.map(\.id) == ["leftovers:com.gone.editor"])
    let item = try #require(items.first)
    #expect(item.paths.count == 2)
    #expect(item.risk == .review) // contains a sandbox container
    #expect(!item.recommended)
    #expect(item.title == "Editor")
}

// MARK: - Agent worktrees

@Test func worktreeAnalyzerJudgesCleanDirtyAndMovedWorktrees() throws {
    let sb = Sandbox()
    let home = sb.path("home")
    let repo = sb.dir("home/code/app")
    let git = try #require(Shell.which("git"))
    func run(_ args: [String], in dir: String = repo) {
        Shell.run(git, ["-C", dir, "-c", "user.name=T", "-c", "user.email=t@example.com"] + args)
    }
    run(["init", "-q"])
    sb.file("home/code/app/README.md", content: "hi")
    run(["add", "."])
    run(["commit", "-qm", "init"])
    run(["worktree", "add", "-q", "-b", "clean-task", repo + "/.claude/worktrees/clean-task"])
    run(["worktree", "add", "-q", "-b", "dirty-task", repo + "/.claude/worktrees/dirty-task"])
    sb.file("home/code/app/.claude/worktrees/dirty-task/notes.txt", content: "unsaved work")
    // A worktree whose repository has moved away.
    sb.file("home/code/app/.claude/worktrees/orphan/.git", content: "gitdir: /nonexistent/repo/.git/worktrees/orphan\n")
    sb.file("home/code/app/.claude/worktrees/orphan/file.txt", bytes: 1000)

    var analyzer = WorktreeAnalyzer(env: ScanEnvironment(home: home, now: Date().addingTimeInterval(30 * 86_400)),
                                    extraRoots: [repo])
    analyzer.safeAfterDays = 7
    let items = Dictionary(uniqueKeysWithValues: analyzer.analyze().map { ($0.title, $0) })
    let clean = try #require(items["app · clean-task"])
    #expect(clean.risk == .safe && clean.recommended && clean.tags.contains("clean-task"))
    let dirty = try #require(items["app · dirty-task"])
    #expect(dirty.risk == .caution && !dirty.recommended)
    #expect(dirty.tags.contains("1 uncommitted change"))
    let orphan = try #require(items["app · orphan"])
    #expect(orphan.tags.contains("Repository moved") && orphan.risk == .review)

    // Touched just now: treated as in use.
    let fresh = WorktreeAnalyzer(env: ScanEnvironment(home: home), extraRoots: [repo]).analyze()
    #expect(fresh.allSatisfy { $0.blockedReason != nil })
}
