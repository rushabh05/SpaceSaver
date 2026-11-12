import Foundation
import Testing
@testable import SpaceSaverCore

// MARK: - Fixtures

/// A throwaway directory tree under the system temp dir, removed when the test ends.
final class Sandbox {
    let root: String

    init() {
        root = (NSTemporaryDirectory() as NSString).appendingPathComponent("spacesaver-tests-\(UUID().uuidString)")
        try! FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
    }

    deinit { try? FileManager.default.removeItem(atPath: root) }

    func path(_ rel: String) -> String { (root as NSString).appendingPathComponent(rel) }

    @discardableResult
    func file(_ rel: String, bytes: Int = 0, content: String? = nil, modified: Date? = nil) -> String {
        let p = path(rel)
        try! FileManager.default.createDirectory(atPath: Paths.parent(p), withIntermediateDirectories: true)
        let data = content.map { Data($0.utf8) } ?? Data(repeating: 0x5A, count: bytes)
        FileManager.default.createFile(atPath: p, contents: data)
        if let modified { setDate(p, modified) }
        return p
    }

    @discardableResult
    func dir(_ rel: String) -> String {
        let p = path(rel)
        try! FileManager.default.createDirectory(atPath: p, withIntermediateDirectories: true)
        return p
    }

    func setDate(_ p: String, _ date: Date) {
        try? FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: p)
    }
}

/// Moves files into a fake trash folder instead of the real one.
struct FakeTrash: TrashProvider {
    let dir: String
    func trash(_ path: String) throws -> String {
        let dest = Paths.join(dir, UUID().uuidString + "-" + Paths.name(path))
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        try FileManager.default.moveItem(atPath: path, toPath: dest)
        return dest
    }
}

func duBytes(_ path: String) -> Int64 {
    let r = Shell.run("/usr/bin/du", ["-sk", path])
    return (Int64(r.stdout.split(separator: "\t").first ?? "0") ?? 0) * 1024
}

// MARK: - Formatting

@Test func parsesSizeStrings() {
    #expect(ByteFormat.parse("1.5GB") == 1_500_000_000)
    #expect(ByteFormat.parse("512 MB") == 512_000_000)
    #expect(ByteFormat.parse("100M") == 100_000_000)
    #expect(ByteFormat.parse("4.096kB") == 4096)
    #expect(ByteFormat.parse("0B") == 0)
    #expect(ByteFormat.parse("1GiB") == 1_073_741_824)
    #expect(ByteFormat.parse("lots") == nil)
}

@Test func stripsControlCharactersAndANSI() {
    let hostile = "evil\u{1B}[31mname\u{07}\u{202E}txt.exe"
    #expect(hostile.sanitizedForDisplay == "evilnametxt.exe")
}

// MARK: - Scanning

@Test func bulkReaderMatchesStat() throws {
    let sb = Sandbox()
    sb.file("a.bin", bytes: 10_000)
    sb.file("b.txt", content: "hello")
    sb.dir("sub")
    try FileManager.default.createSymbolicLink(atPath: sb.path("link"), withDestinationPath: sb.path("a.bin"))

    let entries = Dictionary(uniqueKeysWithValues: BulkReader.entries(sb.root).map { ($0.name, $0) })
    #expect(entries.count == 4)
    #expect(entries["sub"]?.kind == .directory)
    #expect(entries["link"]?.kind == .symlink)
    #expect(entries["a.bin"]?.logicalSize == 10_000)
    var st = stat()
    stat(sb.path("a.bin"), &st)
    #expect(entries["a.bin"]?.allocatedSize == Int64(st.st_blocks) * 512)
    #expect(entries["a.bin"]?.fileID == st.st_ino)
}

@Test func treeScannerTotalsMatchDu() {
    let sb = Sandbox()
    for i in 0..<30 { sb.file("deep/level\(i % 3)/f\(i).bin", bytes: 3000 * (i + 1)) }
    sb.file("big.bin", bytes: 3_000_000)
    sb.file("x/y/z/small.txt", content: "tiny")

    var options = TreeScanner.Options(root: sb.root)
    options.keepFilesAtLeast = 2_000_000
    options.largeFileThreshold = 2_500_000
    let scanner = TreeScanner(options: options)
    let tree = scanner.scan()

    #expect(tree.size == duBytes(sb.root) - Int64(DirectorySizer.measure(sb.root).bytes - tree.size))
    #expect(tree.size == DirectorySizer.measure(sb.root).bytes)
    #expect(tree.fileCount == 32)
    #expect(tree.children.first?.name == "big.bin") // sorted largest first
    #expect(scanner.largeFiles.map(\.path) == [sb.path("big.bin")])
    // Small files are folded into one aggregate node per folder.
    let level0 = tree.find(path: sb.path("deep/level0"))
    #expect(level0?.children.count == 1)
    #expect(level0?.children.first?.kind == .aggregate)
    #expect(tree.find(path: sb.path("x/y/z"))?.fileCount == 1)
}

@Test func directorySizerCountsHardLinksOnce() throws {
    let sb = Sandbox()
    sb.file("data.bin", bytes: 1_000_000)
    try FileManager.default.linkItem(atPath: sb.path("data.bin"), toPath: sb.path("hardlink.bin"))
    let size = DirectorySizer.measure(sb.root)
    #expect(size.files == 1)
    #expect(size.bytes == duBytes(sb.root) - duBytes(sb.root) % 4096 || size.bytes <= duBytes(sb.root))
}

@Test func globExpandsWildcards() {
    let sb = Sandbox()
    sb.dir("Caches/Chrome-1")
    sb.dir("Caches/Chrome-2")
    sb.dir("Caches/Firefox")
    #expect(Paths.glob(sb.path("Caches/Chrome*")).count == 2)
    #expect(Paths.glob(sb.path("Caches/*")).count == 3)
    #expect(Paths.glob(sb.path("Missing/*")).isEmpty)
}

// MARK: - Treemap-independent helpers

@Test func roomPlannerPrefersSafeItems() {
    func item(_ id: String, _ gb: Double, _ risk: RiskLevel) -> CleanupItem {
        CleanupItem(id: id, category: .packageCaches, title: id, subtitle: "", paths: ["/tmp/\(id)"],
                    size: Int64(gb * 1e9), risk: risk, explanation: "")
    }
    let items = [item("a", 5, .review), item("b", 3, .safe), item("c", 2, .safe), item("d", 50, .caution)]
    let plan = RoomPlanner.plan(toFree: 4_000_000_000, from: items)
    #expect(plan.items.map(\.id) == ["b", "c"])
    #expect(plan.satisfied)
    let big = RoomPlanner.plan(toFree: 9_000_000_000, from: items)
    #expect(big.items.map(\.id) == ["b", "c", "a"])
    #expect(!RoomPlanner.plan(toFree: 60_000_000_000, from: items).satisfied) // never picks caution
}

// MARK: - Safety

@Test func safetyGuardBlocksProtectedPaths() throws {
    let sb = Sandbox()
    let home = sb.dir("home")
    sb.dir("home/Documents")
    sb.dir("home/.ssh")
    sb.file("home/.ssh/id_ed25519", content: "key")
    sb.dir("home/proj/.git/objects")
    sb.dir("home/proj/node_modules")
    sb.dir("home/.claude/projects/p/memory")
    sb.file("home/.claude/projects/p/s.jsonl", content: "{}")
    try FileManager.default.createSymbolicLink(atPath: sb.path("home/sneaky"), withDestinationPath: sb.path("home/.ssh"))
    let guardian = SafetyGuard(home: home, excluded: ["~/proj/keep"])

    #expect(throws: SafetyError.self) { try guardian.validate("relative/path") }
    #expect(throws: SafetyError.self) { try guardian.validate(home) }
    #expect(throws: SafetyError.self) { try guardian.validate(home + "/Documents") }
    #expect(throws: SafetyError.self) { try guardian.validate(home + "/.ssh/id_ed25519") }
    #expect(throws: SafetyError.self) { try guardian.validate(home + "/sneaky/id_ed25519") } // symlinked parent
    #expect(throws: SafetyError.self) { try guardian.validate(home + "/proj/.git/objects") }
    #expect(throws: SafetyError.self) { try guardian.validate(home + "/.claude/projects/p") } // holds memory
    #expect(throws: SafetyError.self) { try guardian.validate(home + "/missing") }
    #expect(throws: SafetyError.self) { try guardian.validate("/System/Library") }
    #expect((try? guardian.validate(home + "/proj/node_modules")) != nil)
    #expect((try? guardian.validate(home + "/.claude/projects/p/s.jsonl")) != nil)

    sb.dir("home/proj/keep")
    #expect(throws: SafetyError.self) { try guardian.validate(home + "/proj/keep") }
    #expect(throws: SafetyError.self) { try guardian.validate(home + "/proj") } // contains an excluded path
}

// MARK: - Projects

@Test func projectAnalyzerFindsDormantArtifacts() throws {
    let sb = Sandbox()
    let home = sb.dir("home")
    let old = Date().addingTimeInterval(-200 * 86_400)
    let recent = Date().addingTimeInterval(-2 * 86_400)

    // Dormant Node project with a lockfile and git history.
    sb.file("home/code/old-app/package.json", content: "{}", modified: old)
    sb.file("home/code/old-app/package-lock.json", content: "{}", modified: old)
    sb.file("home/code/old-app/node_modules/lodash/index.js", bytes: 2_000_000)
    sb.dir("home/code/old-app/.git/logs")
    let ts = Int(old.timeIntervalSince1970)
    sb.file("home/code/old-app/.git/logs/HEAD", content: "0000 1111 Dev <dev@example.com> \(ts) +0000\tcommit: init\n", modified: old)
    sb.setDate(sb.path("home/code/old-app"), old)

    // Active Rust project.
    sb.file("home/code/live/Cargo.toml", content: "[package]", modified: recent)
    sb.file("home/code/live/target/debug/app", bytes: 3_000_000)

    // Folder called "build" with no marker must be ignored.
    sb.file("home/code/notes/build/report.pdf", bytes: 2_000_000)

    // Orphaned node_modules.
    sb.file("home/code/ghost/node_modules/x/index.js", bytes: 1_500_000)

    var settings = Settings()
    settings.projectRoots = [home + "/code"]
    settings.dormantDays = 45
    let items = ProjectAnalyzer(env: ScanEnvironment(home: home, settings: settings)).analyze()
    let byPath = Dictionary(uniqueKeysWithValues: items.map { ($0.paths[0], $0) })

    let oldItem = try #require(byPath[sb.path("home/code/old-app/node_modules")])
    #expect(oldItem.risk == .safe)
    #expect(oldItem.recommended)
    #expect(oldItem.tags.contains("package-lock.json"))
    #expect(oldItem.regenerate?.contains("npm ci") == true)

    let live = try #require(byPath[sb.path("home/code/live/target")])
    #expect(live.risk == .review)          // active project
    #expect(!live.recommended)
    #expect(live.tags.contains("No lockfile"))

    #expect(byPath[sb.path("home/code/notes/build")] == nil)
    #expect(byPath[sb.path("home/code/ghost/node_modules")]?.tags.contains("Orphaned") == true)
}

@Test func readsLastGitActivityFromReflog() {
    let sb = Sandbox()
    sb.file("repo/.git/logs/HEAD", content: """
    0000 aaaa A U Thor <a@b.c> 1700000000 +0100\tcommit (initial): first
    aaaa bbbb A U Thor <a@b.c> 1710000000 -0500\tcheckout: moving from main to dev

    """)
    let date = ProjectAnalyzer.lastGitActivity(gitDir: sb.path("repo/.git"))
    #expect(date == Date(timeIntervalSince1970: 1_710_000_000))
}

@Test func decodesClaudeProjectFolderNames() {
    let sb = Sandbox()
    sb.dir("Users/a.b/My Projects/web-app")
    let encoded = "-" + sb.path("Users/a.b/My Projects/web-app").dropFirst()
        .map { $0.isLetter || $0.isNumber ? String($0) : "-" }.joined()
    #expect(AISessionAnalyzer.decodeClaudeProject(encoded, home: sb.root) == sb.path("Users/a.b/My Projects/web-app"))
}

// MARK: - Rules

@Test func ruleEvaluatorSizesAndSkipsClaimedChildren() {
    let sb = Sandbox()
    let home = sb.dir("home")
    sb.file("home/Library/Caches/Homebrew/bottle.tar.gz", bytes: 3_000_000)
    sb.file("home/Library/Caches/com.example.app/blob", bytes: 12_000_000)
    sb.file("home/Library/Caches/tiny/blob", bytes: 1000)

    let env = ScanEnvironment(home: home, settings: Settings())
    let evaluator = RuleEvaluator(env: env, running: .none)
    let rules = RuleCatalog.rules(for: .packageCaches) + RuleCatalog.rules(for: .systemJunk)
    let claimed = evaluator.claimedPaths(rules)
    let items = evaluator.evaluate(rules, claimed: claimed)

    let brew = items.filter { $0.title == "Homebrew downloads" }
    #expect(brew.count == 1)
    #expect(brew.first?.size ?? 0 >= 3_000_000)
    // The catch-all "App caches" rule must not list Homebrew a second time.
    #expect(!items.contains { $0.category == .systemJunk && $0.paths.contains(sb.path("home/Library/Caches/Homebrew")) })
    #expect(items.contains { $0.paths == [sb.path("home/Library/Caches/com.example.app")] })
    #expect(!items.contains { $0.paths.contains(sb.path("home/Library/Caches/tiny")) }) // under min size
}

@Test func runningAppsBlockTheirCaches() {
    let sb = Sandbox()
    let home = sb.dir("home")
    sb.file("home/Library/Developer/Xcode/DerivedData/App-abc/Build/x", bytes: 2_000_000)
    let running = RunningApps(processNames: ["xcode"], bundleIDs: [], appNames: [:])
    let items = RuleEvaluator(env: ScanEnvironment(home: home), running: running)
        .evaluate(RuleCatalog.rules(for: .xcode))
    let derived = items.first { $0.title == "Xcode DerivedData" }
    #expect(derived?.blockedReason != nil)
    #expect(derived?.recommended == false)
    #expect(derived?.isSelectable == false)
}

@Test func deduplicatePrefersSpecificCategory() {
    let a = CleanupItem(id: "a", category: .systemJunk, title: "Caches", subtitle: "", paths: ["/x/Caches/pip"],
                        size: 10, risk: .safe, explanation: "")
    let b = CleanupItem(id: "b", category: .packageCaches, title: "pip", subtitle: "", paths: ["/x/Caches/pip"],
                        size: 10, risk: .safe, explanation: "")
    let result = ReclaimScanner.deduplicate([a, b])
    #expect(result.map(\.id) == ["b"])
}

@Test func knowledgeBaseExplainsKnownPaths() {
    let sb = Sandbox()
    let home = sb.dir("home")
    sb.file("home/app/package.json", content: "{}")
    sb.dir("home/app/node_modules")
    let kb = KnowledgeBase(home: home, rules: RuleCatalog.all)
    #expect(kb.explain("~/Library/Developer/Xcode/DerivedData").title == "Xcode DerivedData")
    #expect(kb.explain("~/Library/Developer/Xcode/DerivedData/Foo-abc/Index").title == "Xcode DerivedData")
    #expect(kb.explain(home + "/app/node_modules").source == "Project artifact")
    #expect(kb.explain("~/Movies/holiday.mov").risk == .caution)
}

// MARK: - Analyzers

@Test func downloadsFlagsInstalledInstallers() {
    let sb = Sandbox()
    let home = sb.dir("home")
    let old = Date().addingTimeInterval(-90 * 86_400)
    sb.file("home/Downloads/Thing.dmg", bytes: 2_000_000, modified: old)
    sb.file("home/Downloads/fresh.zip", bytes: 2_000_000)
    sb.file("home/Downloads/notes.txt", bytes: 2_000_000, modified: old)
    var settings = Settings()
    settings.downloadsAgeDays = 30
    // Age comes from the "date added" to Downloads, which is now for all of these.
    let today = DownloadsAnalyzer(env: ScanEnvironment(home: home, settings: settings)).analyze()
    #expect(today.isEmpty)
    let later = DownloadsAnalyzer(env: ScanEnvironment(home: home, settings: settings,
                                                       now: Date().addingTimeInterval(60 * 86_400))).analyze()
    #expect(Set(later.map(\.title)) == ["Thing.dmg", "fresh.zip"]) // a small .txt isn't an installer or archive
}

@Test func parsesDockerDF() {
    let output = """
    {"Active":"2","Reclaimable":"1.2GB (50%)","Size":"2.4GB","TotalCount":"5","Type":"Images"}
    {"Active":"0","Reclaimable":"512MB","Size":"512MB","TotalCount":"14","Type":"Build Cache"}
    """
    let rows = DockerAnalyzer.parseDF(output)
    #expect(rows.count == 2)
    #expect(rows[0].reclaimableBytes == 1_200_000_000)
    #expect(rows[1].reclaimableBytes == 512_000_000)
    #expect(CleanupEngine.reclaimedFromOutput("Deleted build cache objects:\nabc\n\nTotal reclaimed space: 1.5GB") == 1_500_000_000)
}

@Test func ollamaCountsOnlyExclusiveBlobs() throws {
    let sb = Sandbox()
    let home = sb.dir("home")
    let models = "home/.ollama/models"
    func manifest(_ digests: [String]) -> String {
        let layers = digests.map { #"{"digest":"\#($0)","size":1}"# }.joined(separator: ",")
        return #"{"schemaVersion":2,"layers":[\#(layers)]}"#
    }
    sb.file("\(models)/manifests/registry.ollama.ai/library/llama3/latest", content: manifest(["sha256:aaa", "sha256:shared"]))
    sb.file("\(models)/manifests/registry.ollama.ai/library/mistral/7b", content: manifest(["sha256:bbb", "sha256:shared"]))
    sb.file("\(models)/blobs/sha256-aaa", bytes: 20_000_000)
    sb.file("\(models)/blobs/sha256-bbb", bytes: 15_000_000)
    sb.file("\(models)/blobs/sha256-shared", bytes: 30_000_000)
    let items = OllamaAnalyzer(env: ScanEnvironment(home: home)).analyze()
    let llama = try #require(items.first { $0.title == "llama3:latest" })
    #expect(llama.paths.contains(sb.path("\(models)/blobs/sha256-aaa")))
    #expect(!llama.paths.contains(sb.path("\(models)/blobs/sha256-shared")))
    #expect(llama.size < 25_000_000)
}

@Test func findsDuplicatesButNotHardLinks() throws {
    let sb = Sandbox()
    sb.file("a/one.bin", content: String(repeating: "x", count: 50_000))
    sb.file("b/two.bin", content: String(repeating: "x", count: 50_000))
    sb.file("Downloads/three.bin", content: String(repeating: "x", count: 50_000))
    sb.file("c/same-size-different.bin", content: String(repeating: "y", count: 50_000))
    try FileManager.default.linkItem(atPath: sb.path("a/one.bin"), toPath: sb.path("a/hardlink.bin"))

    let groups = DuplicateFinder(roots: [sb.root], minSize: 10_000).find(home: sb.root)
    #expect(groups.count == 1)
    let group = try #require(groups.first)
    #expect(group.files.count == 3)
    #expect(group.reclaimable == 100_000)
    #expect(!group.files[group.keep].path.contains("/Downloads/")) // keeps the copy outside Downloads
}

@Test func secretScannerFindsAndRedactsKeys() {
    let sb = Sandbox()
    let fakeAnthropic = "sk-ant-api03-" + String(repeating: "A1b2", count: 20)
    let fakeGitHub = "ghp_" + String(repeating: "Z9", count: 18)
    let file = sb.file("session.jsonl", content: """
    {"type":"user","message":{"role":"user","content":"deploy with key \(fakeAnthropic)"}}
    {"type":"assistant","message":{"content":"ok"}}
    {"type":"user","message":{"role":"user","content":"token \(fakeGitHub) and AKIAABCDEFGHIJKLMNOP"}}
    """)
    let findings = SecretScanner.scan(file: file)
    #expect(Set(findings.map(\.kind)) == ["Anthropic API key", "GitHub token", "AWS access key"])
    #expect(findings.first { $0.kind == "GitHub token" }?.line == 3)
    #expect(findings.allSatisfy { !$0.redacted.contains(String(repeating: "A1b2", count: 5)) })
    #expect(AISessionAnalyzer.preview(of: file)?.hasPrefix("deploy with key") == true)
}

// MARK: - Cleanup, undo, archive

@Test func cleanupTrashesAndRestores() throws {
    let sb = Sandbox()
    let home = sb.dir("home")
    let target = sb.file("home/proj/node_modules/pkg/index.js", bytes: 5000)
    let folder = Paths.parent(Paths.parent(target))
    let engine = CleanupEngine(safety: SafetyGuard(home: home), log: ActivityLog(file: sb.path("activity.json")),
                               trash: FakeTrash(dir: sb.path("trash")), paths: AppPaths(base: sb.path("data")))
    let item = CleanupItem(id: "x", category: .projectArtifacts, title: "proj › node_modules", subtitle: "",
                           paths: [folder], size: 5000, risk: .safe, explanation: "")
    let blocked = CleanupItem(id: "y", category: .systemJunk, title: "busy", subtitle: "", paths: [home + "/proj"],
                              size: 1, risk: .safe, explanation: "", blockedReason: "App running")

    let report = engine.clean([item, blocked], source: "test")
    #expect(!Paths.exists(folder))
    #expect(report.entries.count == 1)
    #expect(report.skipped.count == 1)
    #expect(Paths.exists(home + "/proj")) // blocked item untouched

    let entry = try #require(engine.log.entries().first)
    #expect(entry.canRestore)
    #expect(try engine.restore(entry.id) == 1)
    #expect(Paths.exists(target))
    #expect(engine.log.entries().first?.status == .restored)
}

@Test func cleanupRefusesProtectedPaths() {
    let sb = Sandbox()
    let home = sb.dir("home")
    sb.file("home/.ssh/id_rsa", content: "secret")
    let engine = CleanupEngine(safety: SafetyGuard(home: home), log: ActivityLog(file: sb.path("a.json")),
                               trash: FakeTrash(dir: sb.path("trash")), paths: AppPaths(base: sb.path("data")))
    let item = CleanupItem(id: "z", category: .custom, title: "ssh", subtitle: "", paths: [home + "/.ssh/id_rsa"],
                           size: 6, risk: .safe, explanation: "")
    let report = engine.clean([item], source: "test")
    #expect(Paths.exists(home + "/.ssh/id_rsa"))
    #expect(report.entries.first?.status == .failed)
}

@Test func archiveIsVerifiedBeforeRemoval() throws {
    let sb = Sandbox()
    let a = sb.file("logs/a.jsonl", content: "{\"x\":1}\n")
    let b = sb.file("logs/b.jsonl", content: "{\"y\":2}\n")
    let result = try Archiver.archive([a, b], name: "Test sessions", vault: sb.path("vault"))
    #expect(Paths.exists(result.path))
    #expect(result.sha256.count == 64)
    #expect(Paths.exists(result.path + ".json"))
    let listing = Shell.run("/usr/bin/tar", ["-tzf", result.path]).stdout
    #expect(listing.contains("a.jsonl") && listing.contains("b.jsonl"))
}

// MARK: - History

@Test func growthReportsDeepestChange() {
    let old = ScanSnapshot(root: "/r", date: Date(timeIntervalSince1970: 0), total: 10_000_000_000,
                           folders: ["/r": 10_000_000_000, "/r/Library": 6_000_000_000,
                                     "/r/Library/Developer": 3_000_000_000, "/r/Movies": 4_000_000_000])
    let new = ScanSnapshot(root: "/r", date: Date(), total: 15_000_000_000,
                           folders: ["/r": 15_000_000_000, "/r/Library": 11_000_000_000,
                                     "/r/Library/Developer": 8_000_000_000, "/r/Movies": 4_000_000_000])
    let growth = HistoryStore.growth(from: old, to: new)
    #expect(growth.first?.path == "/r/Library/Developer")
    #expect(growth.first?.delta == 5_000_000_000)
    #expect(!growth.contains { $0.path == "/r/Movies" })
}

// MARK: - MCP

@Test func mcpServerHandshakeAndTools() throws {
    let sb = Sandbox()
    let home = sb.dir("home")
    let server = MCPServer(env: ScanEnvironment(home: home), plans: PlanStore(directory: sb.path("plans")),
                           paths: AppPaths(base: sb.path("data")), protectedWorkspaces: [sb.path("home/work")])

    func call(_ json: String) throws -> [String: Any] {
        let line = try #require(server.handle(line: json))
        return try #require(try JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any])
    }

    let initialize = try call(#"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","clientInfo":{"name":"test-agent"}}}"#)
    let result = try #require(initialize["result"] as? [String: Any])
    #expect(result["protocolVersion"] as? String == "2025-06-18")
    #expect(server.handle(line: #"{"jsonrpc":"2.0","method":"notifications/initialized"}"#) == nil)

    let list = try call(#"{"jsonrpc":"2.0","id":2,"method":"tools/list"}"#)
    let tools = ((list["result"] as? [String: Any])?["tools"] as? [[String: Any]])?.compactMap { $0["name"] as? String } ?? []
    #expect(tools.contains("propose_cleanup") && tools.contains("preflight_check"))

    let unknown = try call(#"{"jsonrpc":"2.0","id":3,"method":"nope"}"#)
    #expect((unknown["error"] as? [String: Any])?["code"] as? Int == -32601)

    // Proposals: protected path, active workspace and unknown paths are refused; a known cache is accepted.
    sb.file("home/.ssh/id_rsa", content: "k")
    sb.file("home/work/node_modules/x.js", bytes: 10)
    sb.file("home/work/package.json", content: "{}")
    sb.file("home/Library/Developer/Xcode/DerivedData/Foo/x", bytes: 4096)
    sb.file("home/Documents/thesis.docx", bytes: 10)
    let propose = try call("""
    {"jsonrpc":"2.0","id":4,"method":"tools/call","params":{"name":"propose_cleanup","arguments":{
    "reason":"need space","paths":["~/.ssh/id_rsa","\(home)/work/node_modules","~/Documents/thesis.docx","~/Library/Developer/Xcode/DerivedData"]}}}
    """)
    let content = try #require((propose["result"] as? [String: Any])?["structuredContent"] as? [String: Any])
    #expect(content["status"] as? String == "pending_approval")
    #expect((content["accepted"] as? [Any])?.count == 1)
    #expect((content["rejected"] as? [Any])?.count == 3)
    let planID = try #require(content["plan_id"] as? String)
    #expect(Paths.exists(home + "/Library/Developer/Xcode/DerivedData")) // nothing deleted

    let status = try call(#"{"jsonrpc":"2.0","id":5,"method":"tools/call","params":{"name":"get_plan_status","arguments":{"plan_id":"\#(planID)"}}}"#)
    let statusContent = (status["result"] as? [String: Any])?["structuredContent"] as? [String: Any]
    #expect(statusContent?["status"] as? String == "pending")
    #expect(PlanStore(directory: sb.path("plans")).pending().first?.requester == "test-agent")
    #expect(PlanStore(directory: sb.path("plans")).get("../../etc/passwd") == nil)
}

@Test func schedulerPlistUsesLaunchdWeekdays() {
    var schedule = ScheduleSettings()
    schedule.frequency = .weekly
    schedule.weekday = 1 // Sunday
    schedule.hour = 9
    let plist = Scheduler.plist(cliPath: "/x/spacesaver", schedule: schedule, logPath: "/tmp/log")
    let interval = plist["StartCalendarInterval"] as? [String: Int]
    #expect(interval?["Weekday"] == 0)
    #expect(interval?["Hour"] == 9)
    #expect((plist["ProgramArguments"] as? [String]) == ["/x/spacesaver", "auto"])
}

@Test func settingsDecodeToleratesMissingKeys() throws {
    let data = Data(#"{"dormantDays": 90, "unknownKey": true}"#.utf8)
    let settings = try JSONDecoder().decode(Settings.self, from: data)
    #expect(settings.dormantDays == 90)
    #expect(settings.largeFileThresholdMB == 100)
}
