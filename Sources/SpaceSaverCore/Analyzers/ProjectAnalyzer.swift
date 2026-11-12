import Foundation

/// A build or dependency folder inside a project, recognised by its name plus a marker file
/// next to it (so a random folder called "build" is never flagged).
public struct ArtifactRule: Sendable {
    public var directory: String
    public var markers: [String]
    public var lockfiles: [String]
    public var regenerate: String
    public var ecosystem: String
    public var risk: RiskLevel

    public init(_ directory: String, markers: [String], lockfiles: [String] = [], regenerate: String,
                ecosystem: String, risk: RiskLevel = .safe) {
        self.directory = directory
        self.markers = markers
        self.lockfiles = lockfiles
        self.regenerate = regenerate
        self.ecosystem = ecosystem
        self.risk = risk
    }

    static let jsLocks = ["package-lock.json", "yarn.lock", "pnpm-lock.yaml", "bun.lockb", "bun.lock", "npm-shrinkwrap.json"]
    static let pyMarkers = ["requirements.txt", "pyproject.toml", "Pipfile", "setup.py", "setup.cfg"]
    static let gradle = ["build.gradle", "build.gradle.kts", "settings.gradle", "settings.gradle.kts"]

    public static let all: [ArtifactRule] = [
        ArtifactRule("node_modules", markers: ["package.json"], lockfiles: jsLocks, regenerate: "npm install", ecosystem: "Node.js"),
        ArtifactRule(".next", markers: ["package.json"], regenerate: "next build", ecosystem: "Next.js"),
        ArtifactRule(".nuxt", markers: ["package.json"], regenerate: "nuxt build", ecosystem: "Nuxt"),
        ArtifactRule(".output", markers: ["nuxt.config.ts", "nuxt.config.js"], regenerate: "nuxt build", ecosystem: "Nuxt"),
        ArtifactRule(".svelte-kit", markers: ["package.json"], regenerate: "vite build", ecosystem: "SvelteKit"),
        ArtifactRule(".turbo", markers: ["package.json", "turbo.json"], regenerate: "turbo run build", ecosystem: "Turborepo"),
        ArtifactRule(".parcel-cache", markers: ["package.json"], regenerate: "parcel build", ecosystem: "Parcel"),
        ArtifactRule(".angular", markers: ["angular.json"], regenerate: "ng build", ecosystem: "Angular"),
        ArtifactRule(".docusaurus", markers: ["package.json"], regenerate: "docusaurus build", ecosystem: "Docusaurus"),
        ArtifactRule(".astro", markers: ["package.json"], regenerate: "astro build", ecosystem: "Astro"),
        ArtifactRule(".vercel", markers: ["package.json"], regenerate: "vercel build", ecosystem: "Vercel"),
        ArtifactRule(".nx", markers: ["nx.json"], regenerate: "nx build", ecosystem: "Nx"),
        ArtifactRule(".expo", markers: ["app.json", "app.config.js", "app.config.ts"], regenerate: "expo start", ecosystem: "Expo"),
        ArtifactRule("coverage", markers: ["package.json"], regenerate: "npm test -- --coverage", ecosystem: "Test coverage"),
        ArtifactRule("storybook-static", markers: ["package.json"], regenerate: "build-storybook", ecosystem: "Storybook"),
        ArtifactRule("dist", markers: ["package.json"], regenerate: "npm run build", ecosystem: "JS build output", risk: .review),
        ArtifactRule("target", markers: ["Cargo.toml"], lockfiles: ["Cargo.lock"], regenerate: "cargo build", ecosystem: "Rust"),
        ArtifactRule("target", markers: ["pom.xml"], regenerate: "mvn package", ecosystem: "Maven"),
        ArtifactRule(".build", markers: ["Package.swift"], lockfiles: ["Package.resolved"], regenerate: "swift build", ecosystem: "SwiftPM"),
        ArtifactRule("DerivedData", markers: ["*.xcodeproj", "*.xcworkspace"], regenerate: "Build in Xcode", ecosystem: "Xcode"),
        ArtifactRule("Pods", markers: ["Podfile"], lockfiles: ["Podfile.lock"], regenerate: "pod install", ecosystem: "CocoaPods"),
        ArtifactRule(".gradle", markers: gradle, regenerate: "./gradlew build", ecosystem: "Gradle"),
        ArtifactRule("build", markers: gradle, regenerate: "./gradlew build", ecosystem: "Gradle"),
        ArtifactRule(".cxx", markers: gradle, regenerate: "./gradlew build", ecosystem: "Android NDK"),
        ArtifactRule(".venv", markers: pyMarkers, lockfiles: ["poetry.lock", "uv.lock", "Pipfile.lock", "requirements.txt", "pdm.lock"],
                     regenerate: "uv sync / pip install -r requirements.txt", ecosystem: "Python venv", risk: .review),
        ArtifactRule("venv", markers: pyMarkers, lockfiles: ["poetry.lock", "uv.lock", "Pipfile.lock", "requirements.txt"],
                     regenerate: "python -m venv venv && pip install -r requirements.txt", ecosystem: "Python venv", risk: .review),
        ArtifactRule(".tox", markers: ["tox.ini", "pyproject.toml"], regenerate: "tox", ecosystem: "tox"),
        ArtifactRule(".pytest_cache", markers: pyMarkers + ["pytest.ini"], regenerate: "pytest", ecosystem: "pytest"),
        ArtifactRule(".mypy_cache", markers: pyMarkers, regenerate: "mypy", ecosystem: "mypy"),
        ArtifactRule(".ruff_cache", markers: pyMarkers + ["ruff.toml"], regenerate: "ruff", ecosystem: "Ruff"),
        ArtifactRule("vendor", markers: ["composer.json"], lockfiles: ["composer.lock"], regenerate: "composer install", ecosystem: "PHP Composer"),
        ArtifactRule("bin", markers: ["*.csproj", "*.fsproj"], regenerate: "dotnet build", ecosystem: ".NET"),
        ArtifactRule("obj", markers: ["*.csproj", "*.fsproj"], regenerate: "dotnet build", ecosystem: ".NET"),
        ArtifactRule(".dart_tool", markers: ["pubspec.yaml"], lockfiles: ["pubspec.lock"], regenerate: "dart pub get", ecosystem: "Dart/Flutter"),
        ArtifactRule("build", markers: ["pubspec.yaml"], regenerate: "flutter build", ecosystem: "Flutter"),
        ArtifactRule(".terraform", markers: ["main.tf", "versions.tf", "providers.tf"], lockfiles: [".terraform.lock.hcl"],
                     regenerate: "terraform init", ecosystem: "Terraform"),
        ArtifactRule("_build", markers: ["mix.exs"], regenerate: "mix compile", ecosystem: "Elixir"),
        ArtifactRule("deps", markers: ["mix.exs"], lockfiles: ["mix.lock"], regenerate: "mix deps.get", ecosystem: "Elixir"),
        ArtifactRule(".stack-work", markers: ["stack.yaml"], regenerate: "stack build", ecosystem: "Haskell"),
        ArtifactRule("dist-newstyle", markers: ["cabal.project", "*.cabal"], regenerate: "cabal build", ecosystem: "Haskell"),
        ArtifactRule(".zig-cache", markers: ["build.zig"], regenerate: "zig build", ecosystem: "Zig"),
        ArtifactRule("zig-cache", markers: ["build.zig"], regenerate: "zig build", ecosystem: "Zig"),
        ArtifactRule("zig-out", markers: ["build.zig"], regenerate: "zig build", ecosystem: "Zig"),
        ArtifactRule("elm-stuff", markers: ["elm.json"], regenerate: "elm make", ecosystem: "Elm"),
        ArtifactRule("cmake-build-debug", markers: ["CMakeLists.txt"], regenerate: "cmake --build", ecosystem: "CMake"),
        ArtifactRule("cmake-build-release", markers: ["CMakeLists.txt"], regenerate: "cmake --build", ecosystem: "CMake"),
    ]

    static let byName: [String: [ArtifactRule]] = Dictionary(grouping: all, by: \.directory)

    func matches(siblings: Set<String>) -> Bool {
        markers.contains { marker in
            if marker.hasPrefix("*") {
                let suffix = String(marker.dropFirst())
                return siblings.contains { $0.hasSuffix(suffix) }
            }
            return siblings.contains(marker)
        }
    }
}

/// A code project found while walking the project roots.
public struct DevProject: Sendable, Hashable {
    public var path: String
    public var lastActivity: Date?
    public var gitRoot: String?
    public var lastCommit: Date?
}

/// Walks project roots looking for regenerable build/dependency folders and decides,
/// per project, whether it's dormant enough to clean.
public struct ProjectAnalyzer {
    public var env: ScanEnvironment
    public var cancel: CancellationFlag?

    public init(env: ScanEnvironment, cancel: CancellationFlag? = nil) {
        self.env = env
        self.cancel = cancel
    }

    struct Found {
        var artifact: String
        var projectRoot: String
        var rule: ArtifactRule
        var hasLockfile: Bool
        var lockfileName: String?
        var rootModified: Int
        var orphan: Bool
    }

    /// Folders under the home root we never descend into: system data, media libraries, and
    /// places covered by other analyzers.
    var skippedHomeFolders: Set<String> {
        let h = env.home
        return [h + "/Library", h + "/.Trash", h + "/Pictures", h + "/Music", h + "/Movies", h + "/Applications",
                h + "/.cache", h + "/.npm", h + "/.cargo", h + "/.rustup", h + "/.gradle", h + "/.m2",
                h + "/.nvm", h + "/.pyenv", h + "/go/pkg", h + "/.docker", h + "/.orbstack", h + "/.ollama",
                h + "/.local", h + "/.vscode", h + "/.cursor", h + "/.windsurf", h + "/.claude", h + "/.codex",
                h + "/miniconda3", h + "/anaconda3", h + "/opt", h + "/.android", h + "/.pub-cache"]
    }

    public func analyze() -> [CleanupItem] {
        let roots = env.settings.projectRoots.map { env.expand($0) }.filter { Paths.isDirectory($0) }
        let excluded = env.settings.expandedExclusions(home: env.home)
        let skip = skippedHomeFolders
        let maxDepth = 12
        let lock = NSLock()
        var found: [Found] = []

        let jobs = roots.map { WalkJob(path: $0, depth: 0, context: ()) }
        ParallelWalker.walk(roots: jobs, cancel: cancel) { job, entries, result in
            guard result.error == 0 else { return [] }
            let names = Set(entries.map(\.name))
            var rootModified = 0
            for e in entries where e.kind == .file { rootModified = max(rootModified, e.modified) }

            var next: [WalkJob<Void>] = []
            var local: [Found] = []
            for entry in entries where entry.kind == .directory {
                let name = entry.name
                let path = Paths.join(job.path, name)
                if let rules = ArtifactRule.byName[name] {
                    if let rule = rules.first(where: { $0.matches(siblings: names) }) {
                        let lock = rule.lockfiles.first { names.contains($0) }
                        local.append(Found(artifact: path, projectRoot: job.path, rule: rule,
                                           hasLockfile: lock != nil, lockfileName: lock,
                                           rootModified: rootModified, orphan: false))
                        continue
                    }
                    if name == "node_modules" {
                        // node_modules with no package.json beside it: left behind by a deleted project.
                        local.append(Found(artifact: path, projectRoot: job.path, rule: rules[0], hasLockfile: false,
                                           lockfileName: nil, rootModified: rootModified, orphan: true))
                        continue
                    }
                }
                if name.hasPrefix(".") || name == "node_modules" || Paths.isPackage(name) { continue }
                if job.depth >= maxDepth || skip.contains(path) { continue }
                if excluded.contains(where: { Paths.isWithin(path, $0) }) { continue }
                next.append(WalkJob(path: path, depth: job.depth + 1, context: ()))
            }
            if !local.isEmpty { lock.withLock { found.append(contentsOf: local) } }
            return next
        }

        if found.isEmpty { return [] }

        // Size every artifact folder in parallel.
        let sizes = DirectorySizer.measureAll(found.map(\.artifact), cancel: cancel)
        var activityCache: [String: DevProject] = [:]
        var items: [CleanupItem] = []

        for f in found {
            guard let size = sizes[f.artifact], size.bytes >= 1_000_000 else { continue }
            let project = activityCache[f.projectRoot] ?? projectActivity(f.projectRoot, rootModified: f.rootModified)
            activityCache[f.projectRoot] = project
            items.append(makeItem(f, size: size, project: project))
        }
        return items
    }

    func makeItem(_ f: Found, size: DirectorySize, project: DevProject) -> CleanupItem {
        let dormantDays = env.settings.dormantDays
        let idleDays = project.lastActivity.map { RelativeTime.days(since: $0, now: env.now) }
        let isDormant = idleDays.map { $0 >= dormantDays } ?? true
        var risk = f.rule.risk
        var tags: [String] = [f.rule.ecosystem]
        var notes: [String] = []

        if f.orphan {
            tags.append("Orphaned")
            notes.append("There's no package.json next to it, so the project it belonged to is gone.")
        } else if let idle = idleDays, let last = project.lastActivity {
            if isDormant {
                tags.append("Dormant \(RelativeTime.age(of: last, now: env.now))")
            } else {
                let age = RelativeTime.age(of: last, now: env.now)
                tags.append(age == "today" ? "Active today" : "Active \(age) ago")
                risk = max(risk, .review)
                notes.append("You worked on this project \(idle == 0 ? "today" : "\(idle) days ago"). Cleaning it means a rebuild next time you open it.")
            }
        }
        if project.gitRoot != nil { tags.append("git") }
        if !f.rule.lockfiles.isEmpty && !f.orphan {
            if let lock = f.lockfileName {
                tags.append(lock)
            } else {
                tags.append("No lockfile")
                risk = max(risk, .review)
                notes.append("No lockfile, so reinstalling may resolve different dependency versions.")
            }
        }

        var regenerate = f.rule.regenerate
        if f.rule.directory == "node_modules", let lock = f.lockfileName {
            switch lock {
            case "yarn.lock": regenerate = "yarn install"
            case "pnpm-lock.yaml": regenerate = "pnpm install"
            case "bun.lockb", "bun.lock": regenerate = "bun install"
            default: regenerate = "npm ci"
            }
        }

        let explanation = (f.orphan
            ? "A node_modules folder whose project no longer exists."
            : "\(f.rule.ecosystem) \(Paths.name(f.artifact)) folder for \(Paths.name(f.projectRoot)). It's generated from the project's manifest and can be rebuilt.")
            + (notes.isEmpty ? "" : " " + notes.joined(separator: " "))

        return CleanupItem(
            id: "project:\(f.artifact)",
            category: .projectArtifacts,
            title: "\(Paths.name(f.projectRoot)) › \(Paths.name(f.artifact))",
            subtitle: Paths.abbreviate(f.artifact, home: env.home),
            paths: [f.artifact],
            size: size.bytes,
            risk: risk,
            explanation: explanation,
            regenerate: "Run `\(regenerate)` in \(Paths.abbreviate(f.projectRoot, home: env.home))",
            lastModified: project.lastActivity,
            tags: tags,
            recommended: risk == .safe && (isDormant || f.orphan),
            group: Paths.abbreviate(f.projectRoot, home: env.home),
            itemCount: size.files
        )
    }

    /// Latest sign of life: last git commit/checkout, git index writes, or edits to files at the project root.
    func projectActivity(_ root: String, rootModified: Int) -> DevProject {
        var project = DevProject(path: root)
        var latest = rootModified
        if let git = Self.findGitDir(from: root, stopAt: env.home) {
            project.gitRoot = git
            if let commit = Self.lastGitActivity(gitDir: git) {
                project.lastCommit = commit
                latest = max(latest, Int(commit.timeIntervalSince1970))
            }
            if let index = Paths.modificationDate(git + "/index") {
                latest = max(latest, Int(index.timeIntervalSince1970))
            }
        }
        project.lastActivity = latest > 0 ? Date(timeIntervalSince1970: TimeInterval(latest)) : nil
        return project
    }

    /// Finds the .git directory for `path` (handles worktrees where .git is a file).
    static func findGitDir(from path: String, stopAt: String) -> String? {
        var dir = path
        for _ in 0..<8 {
            let dotGit = Paths.join(dir, ".git")
            if Paths.isDirectory(dotGit) { return dotGit }
            if Paths.exists(dotGit), let text = try? String(contentsOfFile: dotGit, encoding: .utf8),
               text.hasPrefix("gitdir:") {
                let target = text.dropFirst(7).trimmingCharacters(in: .whitespacesAndNewlines)
                return target.hasPrefix("/") ? target : Paths.join(dir, target)
            }
            if dir == stopAt || dir == "/" { break }
            dir = Paths.parent(dir)
        }
        return nil
    }

    /// Reads the timestamp of the newest reflog entry (commit, checkout, pull...) without spawning git.
    static func lastGitActivity(gitDir: String) -> Date? {
        let log = gitDir + "/logs/HEAD"
        guard let handle = FileHandle(forReadingAtPath: log) else {
            return Paths.modificationDate(gitDir + "/HEAD")
        }
        defer { try? handle.close() }
        let end = (try? handle.seekToEnd()) ?? 0
        let chunk: UInt64 = 4096
        try? handle.seek(toOffset: end > chunk ? end - chunk : 0)
        let data = (try? handle.readToEnd()) ?? Data()
        let text = String(decoding: data, as: UTF8.self)
        guard let line = text.split(separator: "\n").last else { return nil }
        // "<old> <new> Name <email> <unix-ts> <tz>\t<message>"
        let header = line.split(separator: "\t").first ?? line[...]
        guard let emailEnd = header.lastIndex(of: ">") else { return nil }
        let parts = header[header.index(after: emailEnd)...].split(separator: " ")
        guard let ts = parts.first, let seconds = TimeInterval(ts) else { return nil }
        return Date(timeIntervalSince1970: seconds)
    }
}
