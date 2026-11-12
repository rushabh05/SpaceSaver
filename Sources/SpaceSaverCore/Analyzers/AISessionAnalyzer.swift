import Foundation

/// Transcripts, indexes and caches written by AI coding tools. Session logs are grouped per
/// project (Claude Code) or per month (Codex); only sessions older than the age threshold and
/// not touched in the last day are included, so live sessions are never removed.
public struct AISessionAnalyzer {
    public var env: ScanEnvironment
    public var running: RunningApps

    public init(env: ScanEnvironment, running: RunningApps) {
        self.env = env
        self.running = running
    }

    public func analyze() -> [CleanupItem] {
        var items: [CleanupItem] = []
        items += claudeCode()
        items += codex()
        items += folderItems()
        return items
    }

    var cutoff: Date { env.now.addingTimeInterval(-Double(max(env.settings.aiSessionAgeDays, 1)) * 86_400) }

    func oldFiles(in dir: String, ext: String, recursive: Bool) -> [(String, DirEntry)] {
        var out: [(String, DirEntry)] = []
        let limit = Int(cutoff.timeIntervalSince1970)
        let lock = NSLock()
        ParallelWalker.walk(roots: [WalkJob(path: dir, depth: 0, context: ())], threads: 4) { job, entries, result in
            guard result.error == 0 else { return [] }
            var next: [WalkJob<Void>] = []
            var local: [(String, DirEntry)] = []
            for e in entries {
                if e.kind == .directory {
                    if recursive && e.name != "memory" {
                        next.append(WalkJob(path: Paths.join(job.path, e.name), depth: job.depth + 1, context: ()))
                    }
                } else if e.kind == .file, e.name.hasSuffix(ext), e.modified < limit {
                    local.append((Paths.join(job.path, e.name), e))
                }
            }
            lock.withLock { out.append(contentsOf: local) }
            return next
        }
        return out
    }

    func claudeCode() -> [CleanupItem] {
        let base = env.expand("~/.claude/projects")
        var items: [CleanupItem] = []
        for project in Paths.children(base) {
            let dir = Paths.join(base, project)
            guard Paths.isDirectory(dir) else { continue }
            let files = oldFiles(in: dir, ext: ".jsonl", recursive: true)
            guard !files.isEmpty else { continue }
            let size = files.reduce(Int64(0)) { $0 + $1.1.allocatedSize }
            guard size >= 1_000_000 else { continue }
            let newest = files.map(\.1.modified).max() ?? 0
            let decoded = Self.decodeClaudeProject(project, home: env.home)
            let projectExists = Paths.isDirectory(decoded)
            items.append(CleanupItem(
                id: "ai:claude:\(project)", category: .aiSessions, title: "Claude Code · \(Paths.name(decoded))",
                subtitle: Paths.abbreviate(decoded, home: env.home), paths: files.map(\.0), size: size, risk: .review,
                method: .archiveThenTrash,
                explanation: "\(files.count) Claude Code session transcripts older than \(env.settings.aiSessionAgeDays) days. They're only needed to resume or review those conversations. Project memory files are never included.",
                regenerate: "Restore the archive from the SpaceSaver vault if you need a transcript back.",
                lastModified: Date(timeIntervalSince1970: TimeInterval(newest)),
                tags: ["\(files.count) sessions"] + (projectExists ? [] : ["Project deleted"]),
                recommended: false, group: "Claude Code", itemCount: files.count))
        }
        let extras: [(String, String, String)] = [
            ("~/.claude/file-history", "Claude Code file history", "Snapshots of files Claude Code edited, used for rewind."),
            ("~/.claude/shell-snapshots", "Claude Code shell snapshots", "Captured shell environments from past sessions."),
            ("~/.claude/debug", "Claude Code debug logs", "Debug logs from past sessions."),
            ("~/.claude/paste-cache", "Claude Code paste cache", "Large pastes saved from past prompts."),
            ("~/.claude/todos", "Claude Code todo lists", "Task lists from past sessions."),
        ]
        for (path, title, text) in extras {
            items += staleFolder(path: path, title: title, explanation: text, group: "Claude Code")
        }
        return items
    }

    func codex() -> [CleanupItem] {
        let base = env.expand("~/.codex/sessions")
        let files = oldFiles(in: base, ext: ".jsonl", recursive: true)
        // sessions/YYYY/MM/DD/rollout-*.jsonl -> group by YYYY/MM
        let byMonth = Dictionary(grouping: files) { file -> String in
            let rel = file.0.dropFirst(base.count + 1).split(separator: "/")
            return rel.count >= 2 ? "\(rel[0])-\(rel[1])" : "older"
        }
        var items: [CleanupItem] = byMonth.compactMap { month, files in
            let size = files.reduce(Int64(0)) { $0 + $1.1.allocatedSize }
            guard size >= 1_000_000 else { return nil }
            let newest = files.map(\.1.modified).max() ?? 0
            return CleanupItem(
                id: "ai:codex:\(month)", category: .aiSessions, title: "Codex sessions · \(month)",
                subtitle: "~/.codex/sessions", paths: files.map(\.0), size: size, risk: .review,
                method: .archiveThenTrash,
                explanation: "\(files.count) Codex CLI rollout transcripts from \(month).",
                regenerate: "Restore the archive from the SpaceSaver vault if needed.",
                lastModified: Date(timeIntervalSince1970: TimeInterval(newest)),
                tags: ["\(files.count) sessions"], recommended: false, group: "Codex", itemCount: files.count)
        }
        items += staleFolder(path: "~/.codex/log", title: "Codex logs", explanation: "Codex CLI log files.", group: "Codex")
        return items
    }

    func folderItems() -> [CleanupItem] {
        var items: [CleanupItem] = []
        let editors = RuleCatalog.vscodeFamily
        for (folder, name, bundle) in editors {
            let global = "~/Library/Application Support/\(folder)/User/globalStorage"
            let busy = env.settings.activeAppGuard ? running.running(processes: [], bundleIDs: [bundle]) : nil
            let block = busy.map { "\($0) is running. Quit it first." }
            items += staleFolder(path: global + "/github.copilot-chat", title: "\(name) · Copilot Chat index",
                                 explanation: "GitHub Copilot Chat's workspace embeddings and chat state.",
                                 group: "GitHub Copilot", blocked: block, minMB: 20, ageGate: false)
            items += staleFolder(path: global + "/saoudrizwan.claude-dev/tasks", title: "\(name) · Cline task history",
                                 explanation: "Cline conversation histories and checkpoints.", group: "Cline & Roo", blocked: block)
            items += staleFolder(path: global + "/rooveterinaryinc.roo-cline/tasks", title: "\(name) · Roo Code task history",
                                 explanation: "Roo Code conversation histories.", group: "Cline & Roo", blocked: block)
        }
        items += staleFolder(path: "~/.codeium/windsurf/cascade", title: "Windsurf Cascade history",
                             explanation: "Windsurf's Cascade conversation history.", group: "Windsurf",
                             blocked: env.settings.activeAppGuard ? running.running(processes: ["Windsurf"], bundleIDs: []).map { "\($0) is running." } : nil)
        items += staleFolder(path: "~/.copilot/session-state", title: "Copilot CLI sessions",
                             explanation: "GitHub Copilot CLI session state.", group: "GitHub Copilot")
        items += staleFolder(path: "~/.gemini/tmp", title: "Gemini CLI sessions",
                             explanation: "Gemini CLI checkpoints and chat logs.", group: "Gemini CLI")
        items += staleFolder(path: "~/.continue/sessions", title: "Continue sessions",
                             explanation: "Continue.dev chat sessions.", group: "Continue")
        items += staleFolder(path: "~/.continue/index", title: "Continue index",
                             explanation: "Continue.dev codebase embeddings; rebuilt automatically.", group: "Continue",
                             risk: .safe, ageGate: false)
        items += staleFolder(path: "~/.cursor/ai-tracking", title: "Cursor AI tracking DB",
                             explanation: "Local tracking database Cursor uses for AI code attribution.", group: "Cursor")
        return items
    }

    func staleFolder(path: String, title: String, explanation: String, group: String,
                     blocked: String? = nil, risk: RiskLevel = .review, minMB: Double = 5,
                     ageGate: Bool = true) -> [CleanupItem] {
        let full = env.expand(path)
        guard Paths.isDirectory(full) else { return [] }
        let size = DirectorySizer.measure(full)
        guard Double(size.bytes) >= minMB * 1_000_000 else { return [] }
        if ageGate, let newest = size.newestDate, newest > env.now.addingTimeInterval(-86_400) {
            // In active use. Don't offer the whole folder while the tool may be writing to it.
            return [CleanupItem(
                id: "ai:folder:\(full)", category: .aiSessions, title: title,
                subtitle: Paths.abbreviate(full, home: env.home), paths: [full], size: size.bytes, risk: risk,
                method: .archiveThenTrash, explanation: explanation,
                lastModified: newest, tags: ["In use today"],
                blockedReason: blocked ?? "Written to in the last 24 hours. Try again when the tool is idle.",
                recommended: false, group: group, itemCount: size.files)]
        }
        return [CleanupItem(
            id: "ai:folder:\(full)", category: .aiSessions, title: title,
            subtitle: Paths.abbreviate(full, home: env.home), paths: [full], size: size.bytes, risk: risk,
            method: risk == .safe ? .trash : .archiveThenTrash, explanation: explanation,
            regenerate: risk == .safe ? "Rebuilt automatically." : "Restore from the SpaceSaver vault if needed.",
            lastModified: size.newestDate,
            tags: size.newestDate.map { ["Last used \(RelativeTime.age(of: $0, now: env.now))"] } ?? [],
            blockedReason: blocked, recommended: risk == .safe && blocked == nil, group: group,
            itemCount: size.files)]
    }

    /// Claude Code names project folders by replacing every non-alphanumeric character of the
    /// path with "-" ("/Users/a.b/My App" -> "-Users-a-b-My-App"). That's lossy, so walk the real
    /// filesystem and match each component's encoded form.
    static func decodeClaudeProject(_ name: String, home: String) -> String {
        func encode(_ s: String) -> String {
            String(s.unicodeScalars.map { CharacterSet.alphanumerics.contains($0) && $0.isASCII ? Character($0) : "-" })
        }
        // Deepest existing folder reached, plus the undecoded remainder.
        var best: (String, Substring) = ("/", name.dropFirst())
        func search(_ dir: String, _ remaining: Substring, depth: Int) -> String? {
            guard depth < 24 else { return nil }
            if dir.count > best.0.count { best = (dir, remaining) }
            let children = Paths.children(dir).filter { !$0.isEmpty }
            // Longest names first so "my-app-v2" wins over "my-app".
            for child in children.sorted(by: { $0.count > $1.count }) {
                let enc = encode(child)
                let path = Paths.join(dir, child)
                if remaining == enc[...] { return path }
                if remaining.hasPrefix(enc + "-"), Paths.isDirectory(path),
                   let found = search(path, remaining.dropFirst(enc.count + 1), depth: depth + 1) {
                    return found
                }
            }
            return nil
        }
        guard name.hasPrefix("-") else { return name }
        if let found = search("/", name.dropFirst(), depth: 0) { return found }
        // The project folder is gone (e.g. a removed worktree): keep the rest as one name.
        return Paths.join(best.0, String(best.1))
    }

    /// First user prompt in a transcript, for previews.
    public static func preview(of file: String, maxLength: Int = 160) -> String? {
        guard let handle = FileHandle(forReadingAtPath: file) else { return nil }
        defer { try? handle.close() }
        let data = (try? handle.read(upToCount: 256 * 1024)) ?? Data()
        for line in String(decoding: data, as: UTF8.self).split(separator: "\n") {
            guard line.contains("\"user\""),
                  let json = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any] else { continue }
            if let text = extractText(json), !text.isEmpty, !text.hasPrefix("<") {
                let clean = text.sanitizedForDisplay.replacingOccurrences(of: "\n", with: " ")
                return clean.count > maxLength ? String(clean.prefix(maxLength)) + "…" : clean
            }
        }
        return nil
    }

    static func extractText(_ json: [String: Any]) -> String? {
        // Claude Code: {"type":"user","message":{"role":"user","content":"..." | [{"type":"text","text":...}]}}
        // Codex: {"type":"response_item","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":...}]}}
        let message = (json["message"] as? [String: Any]) ?? (json["payload"] as? [String: Any]) ?? json
        guard (message["role"] as? String) == "user" || (json["type"] as? String) == "user" else { return nil }
        if let s = message["content"] as? String { return s }
        if let parts = message["content"] as? [[String: Any]] {
            return parts.compactMap { $0["text"] as? String }.first
        }
        return nil
    }
}

// MARK: - Secrets audit

public struct SecretFinding: Codable, Hashable, Sendable, Identifiable {
    public var kind: String
    public var file: String
    public var line: Int
    /// First and last characters only, e.g. "sk-ant-api03-…9fQx".
    public var redacted: String
    public var id: String { "\(file):\(line):\(redacted)" }
}

/// Offline regex audit for credentials that ended up in AI transcripts or logs.
public enum SecretScanner {
    struct Pattern {
        var kind: String
        var regex: NSRegularExpression
    }

    static let patterns: [Pattern] = [
        ("Anthropic API key", #"sk-ant-(?:api|admin)\d{2}-[A-Za-z0-9_\-]{40,}"#),
        ("OpenAI API key", #"sk-(?:proj|svcacct|admin)-[A-Za-z0-9_\-]{40,}|sk-[A-Za-z0-9]{48}"#),
        ("GitHub token", #"gh[pousr]_[A-Za-z0-9]{36,}|github_pat_[A-Za-z0-9_]{60,}"#),
        ("AWS access key", #"\b(?:AKIA|ASIA)[0-9A-Z]{16}\b"#),
        ("Google API key", #"AIza[0-9A-Za-z_\-]{35}"#),
        ("Slack token", #"xox[baprs]-[0-9A-Za-z\-]{10,}"#),
        ("Stripe live key", #"(?:sk|rk)_live_[0-9A-Za-z]{24,}"#),
        ("Hugging Face token", #"\bhf_[A-Za-z0-9]{34,}\b"#),
        ("Private key", #"-----BEGIN (?:RSA |EC |OPENSSH |DSA |PGP )?PRIVATE KEY-----"#),
        ("Google OAuth secret", #"GOCSPX-[A-Za-z0-9_\-]{28}"#),
        ("npm token", #"\bnpm_[A-Za-z0-9]{36}\b"#),
    ].compactMap { kind, pattern in
        (try? NSRegularExpression(pattern: pattern)).map { Pattern(kind: kind, regex: $0) }
    }

    public static func redact(_ secret: String) -> String {
        guard secret.count > 12 else { return String(repeating: "•", count: secret.count) }
        if secret.hasPrefix("-----BEGIN") { return secret }
        return "\(secret.prefix(8))…\(secret.suffix(4))"
    }

    /// Scans text, returning (kind, line number, redacted match).
    public static func scan(text: String, file: String, lineOffset: Int = 0) -> [SecretFinding] {
        var findings: [SecretFinding] = []
        let ns = text as NSString
        for pattern in patterns {
            for match in pattern.regex.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
                let value = ns.substring(with: match.range)
                let line = lineOffset + ns.substring(to: match.range.location).reduce(1) { $1 == "\n" ? $0 + 1 : $0 }
                findings.append(SecretFinding(kind: pattern.kind, file: file, line: line, redacted: redact(value)))
            }
        }
        return findings
    }

    /// Streams a file in chunks (transcripts can be hundreds of MB).
    public static func scan(file: String, cancel: CancellationFlag? = nil) -> [SecretFinding] {
        guard let handle = FileHandle(forReadingAtPath: file) else { return [] }
        defer { try? handle.close() }
        var findings: [SecretFinding] = []
        var carry = ""
        var lineOffset = 0
        while cancel?.isCancelled != true, let data = try? handle.read(upToCount: 4 << 20), !data.isEmpty {
            var text = carry + String(decoding: data, as: UTF8.self)
            // Keep the trailing partial line for the next chunk so tokens split across chunks are found.
            if let lastNewline = text.lastIndex(of: "\n") {
                carry = String(text[text.index(after: lastNewline)...])
                text = String(text[...lastNewline])
            } else if text.count > 1 << 20 {
                carry = String(text.suffix(512))
            } else {
                carry = text
                continue
            }
            findings += scan(text: text, file: file, lineOffset: lineOffset)
            lineOffset += text.reduce(0) { $1 == "\n" ? $0 + 1 : $0 }
        }
        if !carry.isEmpty { findings += scan(text: carry, file: file, lineOffset: lineOffset) }
        // One finding per distinct secret per file is enough.
        var seen = Set<String>()
        return findings.filter { seen.insert($0.kind + $0.redacted).inserted }
    }

    public static func scan(files: [String], cancel: CancellationFlag? = nil) -> [SecretFinding] {
        let lock = NSLock()
        var all: [SecretFinding] = []
        DispatchQueue.concurrentPerform(iterations: files.count) { i in
            if cancel?.isCancelled == true { return }
            var isDir: ObjCBool = false
            guard FileManager.default.fileExists(atPath: files[i], isDirectory: &isDir) else { return }
            var targets = [files[i]]
            if isDir.boolValue {
                let e = FileManager.default.enumerator(atPath: files[i])
                targets = []
                while let rel = e?.nextObject() as? String {
                    let p = Paths.join(files[i], rel)
                    if [".jsonl", ".json", ".md", ".txt", ".log"].contains(where: rel.hasSuffix) { targets.append(p) }
                }
            }
            let found = targets.flatMap { scan(file: $0, cancel: cancel) }
            lock.withLock { all += found }
        }
        return all
    }
}
