import Foundation

public struct Explanation: Codable, Sendable, Hashable {
    public var title: String
    public var summary: String
    public var risk: RiskLevel
    public var regenerate: String?
    /// "Built-in rule", "Project artifact", "Heuristic", "Local AI".
    public var source: String
}

/// Explains what an arbitrary path is, offline. Uses the rule catalog first, then project
/// artifact detection, then naming heuristics.
public struct KnowledgeBase {
    public var home: String
    public var rules: [LocationRule]

    public init(home: String = NSHomeDirectory(), rules: [LocationRule] = RuleCatalog.all + LocationRule.loadCustom()) {
        self.home = home
        self.rules = rules
    }

    public func explain(_ rawPath: String) -> Explanation {
        let path = (Paths.expand(rawPath, home: home) as NSString).standardizingPath
        let name = Paths.name(path)

        // 1. Rule catalog: exact match, child of a perChild rule, or inside a known location.
        var best: (rule: LocationRule, depth: Int)?
        for rule in rules {
            for pattern in rule.paths {
                let expanded = Paths.expand(pattern, home: home)
                if fnmatch(expanded, path, FNM_PATHNAME) == 0 || isInside(path, pattern: expanded) {
                    let depth = expanded.split(separator: "/").count
                    if best == nil || depth > best!.depth { best = (rule, depth) }
                }
            }
        }
        if let rule = best?.rule {
            return Explanation(title: rule.title, summary: rule.explanation, risk: rule.risk,
                               regenerate: rule.regenerate, source: "Built-in rule")
        }

        // 2. Project artifacts.
        if let rules = ArtifactRule.byName[name] {
            let siblings = Set(Paths.children(Paths.parent(path)))
            if let rule = rules.first(where: { $0.matches(siblings: siblings) }) {
                return Explanation(title: "\(rule.ecosystem) \(name)",
                                   summary: "Generated \(rule.ecosystem) folder for the project in \(Paths.abbreviate(Paths.parent(path), home: home)). Rebuilt from the project's manifest.",
                                   risk: rule.risk, regenerate: "Run `\(rule.regenerate)` in the project folder.",
                                   source: "Project artifact")
            }
        }

        // 3. Heuristics.
        return heuristic(path, name: name)
    }

    private func isInside(_ path: String, pattern: String) -> Bool {
        // Path inside a matched location, e.g. a file deep inside DerivedData.
        var dir = Paths.parent(path)
        while dir != "/" && dir.count >= 2 {
            if fnmatch(pattern, dir, FNM_PATHNAME) == 0 { return true }
            dir = Paths.parent(dir)
        }
        return false
    }

    private func heuristic(_ path: String, name: String) -> Explanation {
        let lower = name.lowercased()
        let ext = (name as NSString).pathExtension.lowercased()
        let short = Paths.abbreviate(path, home: home)

        if path.split(separator: "/").contains(".git") || name == ".git" {
            return Explanation(title: "Git repository data", summary: "Version history for a repository. Deleting it loses all local commits and branches.",
                               risk: .caution, regenerate: "Clone again from the remote (loses unpushed work).", source: "Heuristic")
        }
        if Paths.isWithin(path, home + "/Library/Containers") || Paths.isWithin(path, home + "/Library/Group Containers") {
            return Explanation(title: "Sandboxed app data", summary: "Data for a sandboxed app, including its documents and settings. Remove it by uninstalling the app instead.",
                               risk: .caution, source: "Heuristic")
        }
        if Paths.isWithin(path, home + "/Library/Application Support") {
            let app = path.dropFirst((home + "/Library/Application Support/").count).split(separator: "/").first.map(String.init) ?? name
            return Explanation(title: "App data for \(app)", summary: "Settings, databases and sometimes documents for \(app). Its Cache or logs subfolders are usually safe; the rest isn't.",
                               risk: .caution, source: "Heuristic")
        }
        if lower.contains("cache") || lower == "tmp" || lower == "temp" {
            return Explanation(title: "Cache folder", summary: "\(short) looks like a cache. Caches are normally rebuilt automatically, but check which app owns it.",
                               risk: .review, regenerate: "Usually rebuilt by the owning app.", source: "Heuristic")
        }
        if lower == "logs" || lower == "log" || ext == "log" {
            return Explanation(title: "Log files", summary: "Logs are only needed for debugging.", risk: .safe,
                               regenerate: "Not needed.", source: "Heuristic")
        }
        if ["dmg", "iso", "pkg", "xip", "img"].contains(ext) {
            return Explanation(title: "Disk image or installer", summary: "An installer or disk image. Once installed, you usually don't need it.",
                               risk: .review, regenerate: "Download again from the vendor.", source: "Heuristic")
        }
        if ["vmdk", "vdi", "qcow2", "vhdx", "utm", "pvm"].contains(ext) {
            return Explanation(title: "Virtual machine disk", summary: "A VM's virtual disk. Deleting it deletes the whole virtual machine.",
                               risk: .caution, source: "Heuristic")
        }
        if ["zip", "tar", "gz", "tgz", "7z", "rar", "xz"].contains(ext) {
            return Explanation(title: "Archive", summary: "A compressed archive. Safe to remove if you've extracted it or have a copy.",
                               risk: .review, source: "Heuristic")
        }
        if ["gguf", "safetensors", "ckpt", "pt", "pth", "onnx", "bin", "mlmodel"].contains(ext) {
            return Explanation(title: "Model weights", summary: "Machine-learning model weights. Usually downloadable again, but can be many GB.",
                               risk: .review, regenerate: "Re-download from the model's source.", source: "Heuristic")
        }
        if ["mov", "mp4", "mkv", "avi", "m4v"].contains(ext) {
            return Explanation(title: "Video", summary: "A video file. Personal media, so check before deleting.", risk: .caution, source: "Heuristic")
        }
        return Explanation(title: name, summary: "No rule matches \(short). It may be personal data or an app's working files. Review its contents before removing it.",
                           risk: .caution, source: "Heuristic")
    }
}

/// Optional local LLM explanations through Ollama. Paths are anonymized and nothing leaves the Mac.
public struct OllamaExplainer: Sendable {
    public var baseURL: String
    public var model: String

    public init(settings: AISettings) {
        baseURL = settings.ollamaURL
        model = settings.ollamaModel
    }

    public func isReachable() async -> Bool {
        guard let url = URL(string: baseURL + "/api/tags") else { return false }
        var request = URLRequest(url: url)
        request.timeoutInterval = 3
        return (try? await URLSession.shared.data(for: request)).map { ($0.1 as? HTTPURLResponse)?.statusCode == 200 } ?? false
    }

    public func explain(path: String, size: Int64, children: [String], offline: Explanation) async throws -> String {
        guard let url = URL(string: baseURL + "/api/generate") else { throw URLError(.badURL) }
        let anon = Paths.anonymize(path)
        let kids = children.prefix(25).map { $0.sanitizedForDisplay }.joined(separator: ", ")
        let prompt = """
        You are a macOS storage expert. In 3-4 short sentences, explain what this folder is, which app or tool \
        creates it, whether deleting it is safe, and how it gets rebuilt. Be concrete. Don't invent facts.

        Path: \(anon)
        Size: \(ByteFormat.string(size))
        Contains: \(kids.isEmpty ? "(not listed)" : kids)
        Offline rule says: \(offline.title): \(offline.summary)
        """
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 120
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "model": model, "prompt": prompt, "stream": false, "options": ["temperature": 0.2],
        ])
        let (data, response) = try await URLSession.shared.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200,
              let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let text = json["response"] as? String else {
            throw NSError(domain: "Ollama", code: 1, userInfo: [NSLocalizedDescriptionKey:
                "Ollama didn't answer. Is `\(model)` pulled? Try `ollama pull \(model)`."])
        }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
