import Foundation

/// Git worktrees that Claude Code creates in `<repo>/.claude/worktrees/<name>`.
///
/// A worktree shares its repository's history, so removing the folder never loses commits or
/// branches; only uncommitted changes inside it would be lost. Those are checked with
/// `git status` and such worktrees are marked Caution. Worktrees touched in the last day are
/// treated as in use.
public struct WorktreeAnalyzer: Sendable {
    public var env: ScanEnvironment
    public var inUseHours: Double = 24
    public var safeAfterDays: Double = 7
    /// Extra repository roots to check besides the ones Claude Code has been used in.
    public var extraRoots: [String] = []

    public init(env: ScanEnvironment, extraRoots: [String] = []) {
        self.env = env
        self.extraRoots = extraRoots
    }

    public struct Worktree: Sendable, Equatable {
        public var path: String
        public var repo: String
        public var name: String
        /// The repository's `.git/worktrees/<name>` folder, from the worktree's `.git` file.
        public var gitDir: String?
        /// The worktree's repository was moved or deleted, so git no longer knows about it.
        public var detached: Bool
    }

    public func analyze() -> [CleanupItem] {
        let trees = findWorktrees()
        guard !trees.isEmpty else { return [] }
        let sizes = DirectorySizer.measureAll(trees.map(\.path))
        let git = Shell.which("git")
        return trees.compactMap { tree in
            let measured = sizes[tree.path] ?? DirectorySize()
            return item(for: tree, size: measured, git: git)
        }
    }

    /// Places Claude Code has run: its project folders (~/.claude/projects, whose names decode
    /// lossily), the exact project paths in ~/.claude.json, and `extraRoots`.
    func startingPoints() -> [String] {
        var points = Set<String>()
        for name in Paths.children(env.expand("~/.claude/projects")) where name.hasPrefix("-") {
            var path = AISessionAnalyzer.decodeClaudeProject(name, home: env.home)
            // Sessions run inside a worktree decode to the worktree; use its repository.
            if let range = path.range(of: "/.claude/worktrees/") { path = String(path[..<range.lowerBound]) }
            points.insert(path)
        }
        if let data = FileManager.default.contents(atPath: env.expand("~/.claude.json")),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let projects = json["projects"] as? [String: Any] {
            points.formUnion(projects.keys.filter { $0.hasPrefix("/") })
        }
        for root in extraRoots { points.insert(env.expand(root)) }
        // Never search from the home folder itself or above it; that would walk everything.
        return points.filter { $0 != env.home && Paths.isWithin($0, env.home) || extraRoots.map(env.expand).contains($0) }.sorted()
    }

    /// Repositories that contain `.claude/worktrees`, searched a few levels below each starting
    /// point because decoded project names can stop short of the real folder.
    func candidateRepos(depth: Int = 3) -> [String] {
        var found = Set<String>()
        var visited = Set<String>()
        func search(_ dir: String, _ depth: Int) {
            guard visited.insert(dir).inserted else { return }
            if Paths.isDirectory(Paths.join(dir, ".claude/worktrees")) { found.insert(dir) }
            guard depth > 0 else { return }
            for child in Paths.children(dir) where !child.hasPrefix(".") && child != "node_modules" && child != "Library"
                && !Paths.isPackage(child) {
                let path = Paths.join(dir, child)
                var isDir: ObjCBool = false
                guard let attrs = try? FileManager.default.attributesOfItem(atPath: path),
                      attrs[.type] as? FileAttributeType == .typeDirectory,
                      FileManager.default.fileExists(atPath: path, isDirectory: &isDir), isDir.boolValue else { continue }
                search(path, depth - 1)
            }
        }
        for point in startingPoints() { search(point, depth) }
        return found.sorted()
    }

    public func findWorktrees() -> [Worktree] {
        var out: [Worktree] = []
        var seen = Set<String>()
        for repo in candidateRepos() {
            let container = Paths.join(repo, ".claude/worktrees")
            guard Paths.isDirectory(container) else { continue }
            for name in Paths.children(container) where !name.hasPrefix(".") {
                let path = Paths.join(container, name)
                guard Paths.isDirectory(path), seen.insert(path).inserted else { continue }
                let gitDir = Self.gitDir(of: path)
                out.append(Worktree(path: path, repo: repo, name: name, gitDir: gitDir,
                                    detached: gitDir.map { !Paths.exists($0) } ?? true))
            }
        }
        return out
    }

    /// Reads "gitdir: <path>" from a worktree's `.git` file.
    static func gitDir(of worktree: String) -> String? {
        let file = Paths.join(worktree, ".git")
        guard !Paths.isDirectory(file), let text = try? String(contentsOfFile: file, encoding: .utf8),
              text.hasPrefix("gitdir:") else { return nil }
        let raw = text.dropFirst("gitdir:".count).trimmingCharacters(in: .whitespacesAndNewlines)
        return raw.hasPrefix("/") ? raw : Paths.join(worktree, raw)
    }

    /// Branch checked out in the worktree, from its HEAD file.
    static func branch(gitDir: String?) -> String? {
        guard let gitDir, let head = try? String(contentsOfFile: Paths.join(gitDir, "HEAD"), encoding: .utf8) else { return nil }
        let line = head.trimmingCharacters(in: .whitespacesAndNewlines)
        return line.hasPrefix("ref: refs/heads/") ? String(line.dropFirst("ref: refs/heads/".count)) : nil
    }

    /// Number of uncommitted changes, or nil if git couldn't tell.
    static func uncommittedChanges(_ worktree: String, git: String?) -> Int? {
        guard let git else { return nil }
        let result = Shell.run(git, ["-C", worktree, "status", "--porcelain", "--untracked-files=normal"], timeout: 30)
        guard result.ok else { return nil }
        return result.stdout.split(separator: "\n").filter { !$0.isEmpty }.count
    }

    func item(for tree: Worktree, size: DirectorySize, git: String?) -> CleanupItem? {
        let modified = size.newestDate ?? (try? FileManager.default.attributesOfItem(atPath: tree.path)[.modificationDate] as? Date) ?? nil
        let age = modified.map { env.now.timeIntervalSince($0) } ?? .infinity
        let repoName = Paths.name(tree.repo)
        var tags: [String] = []
        var blocked: String?
        let risk: RiskLevel
        var explanation = "A git worktree that Claude Code created for a task in \(repoName). It's a second checkout of the repository; its commits and branch live in the repository itself, so removing the folder doesn't lose them."

        if let branch = Self.branch(gitDir: tree.gitDir) { tags.append(branch) }

        if age < inUseHours * 3600 {
            blocked = "Changed in the last day, so an agent may still be using it"
        }

        if tree.detached {
            tags.append("Repository moved")
            explanation += " Its repository has moved or been deleted, so git no longer tracks this worktree."
            risk = .review
        } else if let changes = Self.uncommittedChanges(tree.path, git: git) {
            if changes > 0 {
                tags.append("\(changes) uncommitted change\(changes == 1 ? "" : "s")")
                explanation += " It has uncommitted changes, which would be lost. Commit or copy them first."
                risk = .caution
            } else {
                tags.append("No uncommitted changes")
                risk = age > safeAfterDays * 86_400 ? .safe : .review
            }
        } else {
            tags.append("Status unknown")
            risk = .review
        }

        return CleanupItem(
            id: "worktree:" + tree.path, category: .agentWorktrees, title: "\(repoName) · \(tree.name)",
            subtitle: Paths.abbreviate(tree.path, home: env.home), paths: [tree.path], size: size.bytes, risk: risk,
            explanation: explanation,
            regenerate: "Recreate it with `git worktree add` if you need it. Afterwards, `git worktree prune` in \(repoName) tidies git's record of it.",
            lastModified: modified, tags: tags, blockedReason: blocked, group: tree.repo, itemCount: size.files)
    }
}
