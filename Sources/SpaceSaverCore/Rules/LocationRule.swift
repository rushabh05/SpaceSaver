import Foundation

/// A known location that can be cleaned. Built-in rules live in `RuleCatalog`; users can add
/// their own in ~/.spacesaver/rules.json using the same JSON shape.
public struct LocationRule: Codable, Hashable, Sendable {
    public var id: String
    public var category: CleanupCategory
    public var title: String
    /// Absolute or ~ paths; `*` and `?` wildcards allowed in any component.
    public var paths: [String]
    public var risk: RiskLevel
    public var explanation: String
    public var regenerate: String?
    /// Skip while any of these processes (case-insensitive) are running.
    public var processes: [String]?
    public var bundleIDs: [String]?
    /// List every child folder as its own item (e.g. each Hugging Face model).
    public var perChild: Bool?
    /// Catch-all rule: children already claimed by a more specific rule are skipped.
    public var generic: Bool?
    public var minSizeMB: Double?
    /// perChild only: include children untouched for at least this many days.
    public var olderThanDays: Int?
    public var recommended: Bool?

    public init(id: String, category: CleanupCategory, title: String, paths: [String], risk: RiskLevel,
                explanation: String, regenerate: String? = nil, processes: [String]? = nil,
                bundleIDs: [String]? = nil, perChild: Bool? = nil, generic: Bool? = nil,
                minSizeMB: Double? = nil, olderThanDays: Int? = nil, recommended: Bool? = nil) {
        self.id = id
        self.category = category
        self.title = title
        self.paths = paths
        self.risk = risk
        self.explanation = explanation
        self.regenerate = regenerate
        self.processes = processes
        self.bundleIDs = bundleIDs
        self.perChild = perChild
        self.generic = generic
        self.minSizeMB = minSizeMB
        self.olderThanDays = olderThanDays
        self.recommended = recommended
    }

    public static func loadCustom(_ paths: AppPaths = .default) -> [LocationRule] {
        guard let data = FileManager.default.contents(atPath: paths.customRules) else { return [] }
        let rules = (try? JSONDecoder().decode([LocationRule].self, from: data)) ?? []
        return rules.map {
            var rule = $0
            rule.id = "custom." + rule.id
            return rule
        }
    }
}

/// Turns rules into concrete, sized cleanup items.
public struct RuleEvaluator {
    public var env: ScanEnvironment
    public var running: RunningApps
    public var cancel: CancellationFlag?

    public init(env: ScanEnvironment, running: RunningApps, cancel: CancellationFlag? = nil) {
        self.env = env
        self.running = running
        self.cancel = cancel
    }

    /// Every concrete path the given rules point at (used to keep catch-all rules from double counting).
    public func claimedPaths(_ rules: [LocationRule]) -> [String] {
        rules.filter { $0.generic != true }.flatMap { rule in
            rule.paths.flatMap { Paths.glob($0, home: env.home) }
        }
    }

    private struct Candidate {
        var rule: LocationRule
        var paths: [String]
        var title: String
        var isChild: Bool
    }

    public func evaluate(_ rules: [LocationRule], claimed: [String] = []) -> [CleanupItem] {
        let excluded = env.settings.expandedExclusions(home: env.home)
        func isExcluded(_ p: String) -> Bool { excluded.contains { Paths.isWithin(p, $0) } }

        // 1. Resolve rules to candidates. perChild: one item per child folder. Wildcard in the
        //    last path component: one item per match. Otherwise: one item for all paths.
        var candidates: [Candidate] = []
        for rule in rules {
            var merged: [String] = []
            for pattern in rule.paths {
                let wildcardLeaf = Paths.name(pattern).contains("*") || Paths.name(pattern).contains("?")
                for root in Paths.glob(pattern, home: env.home) where !isExcluded(root) {
                    if rule.perChild == true {
                        for child in Paths.children(root) where child != ".DS_Store" && child != ".localized" {
                            let path = Paths.join(root, child)
                            if rule.generic == true, claimed.contains(where: {
                                Paths.isWithin($0, path) || Paths.isWithin(path, $0)
                            }) { continue }
                            if isExcluded(path) { continue }
                            candidates.append(Candidate(rule: rule, paths: [path],
                                                        title: Self.childTitle(rule: rule, path: path), isChild: true))
                        }
                    } else if wildcardLeaf {
                        candidates.append(Candidate(rule: rule, paths: [root], title: Paths.name(root), isChild: true))
                    } else {
                        merged.append(root)
                    }
                }
            }
            if !merged.isEmpty {
                candidates.append(Candidate(rule: rule, paths: merged, title: rule.title, isChild: false))
            }
        }
        if candidates.isEmpty { return [] }

        // 2. Size every path in parallel.
        let sizes = DirectorySizer.measureAll(candidates.flatMap(\.paths), cancel: cancel)

        // 3. Build items.
        var items: [CleanupItem] = []
        var seen = Set<String>()
        for candidate in candidates {
            let rule = candidate.rule
            let paths = candidate.paths.filter { seen.insert($0).inserted }
            if paths.isEmpty { continue }
            var total = DirectorySize()
            for path in paths {
                guard let size = sizes[path] else { continue }
                total.bytes += size.bytes
                total.files += size.files
                total.newest = max(total.newest, size.newest)
            }
            let minBytes = Int64((rule.minSizeMB ?? (candidate.isChild ? 5 : 1)) * 1_000_000)
            if total.bytes < minBytes { continue }
            if let days = rule.olderThanDays, let newest = total.newestDate,
               RelativeTime.days(since: newest, now: env.now) < days { continue }

            var blocked: String?
            if env.settings.activeAppGuard {
                var bundleIDs = rule.bundleIDs ?? []
                if rule.perChild == true { bundleIDs.append(Paths.name(paths[0])) }
                if let app = running.running(processes: rule.processes ?? [], bundleIDs: bundleIDs) {
                    blocked = "\(app) is running. Quit it to clean this safely."
                }
            }

            var tags: [String] = []
            if let newest = total.newestDate {
                tags.append("Last used \(RelativeTime.age(of: newest, now: env.now))")
            }
            if paths.count > 1 { tags.append("\(paths.count) locations") }
            let subtitle = paths.count == 1 ? Paths.abbreviate(paths[0], home: env.home)
                : Paths.abbreviate(Self.commonAncestor(paths), home: env.home) + " (\(paths.count) folders)"
            items.append(CleanupItem(
                id: "rule:\(rule.id):\(paths[0])",
                category: rule.category,
                title: candidate.title,
                subtitle: subtitle,
                paths: paths,
                size: total.bytes,
                risk: rule.risk,
                method: .trash,
                explanation: candidate.isChild ? "\(rule.title): \(rule.explanation)" : rule.explanation,
                regenerate: rule.regenerate,
                lastModified: total.newestDate,
                tags: tags,
                blockedReason: blocked,
                recommended: (rule.recommended ?? (rule.risk == .safe)) && blocked == nil,
                group: candidate.isChild ? rule.title : nil,
                itemCount: total.files
            ))
        }
        return items
    }

    static func commonAncestor(_ paths: [String]) -> String {
        guard var prefix = paths.first?.split(separator: "/").map(String.init) else { return "/" }
        for path in paths.dropFirst() {
            let parts = path.split(separator: "/").map(String.init)
            var i = 0
            while i < min(prefix.count, parts.count), prefix[i] == parts[i] { i += 1 }
            prefix = Array(prefix.prefix(i))
        }
        return "/" + prefix.joined(separator: "/")
    }

    static func childTitle(rule: LocationRule, path: String) -> String {
        let name = Paths.name(path)
        // Hugging Face cache: models--org--name / datasets--org--name
        for prefix in ["models--", "datasets--", "spaces--"] where name.hasPrefix(prefix) {
            let rest = name.dropFirst(prefix.count).replacingOccurrences(of: "--", with: "/")
            return rest + (prefix == "models--" ? "" : " (\(prefix.dropLast(3)))")
        }
        return AppNames.displayName(forFolder: name)
    }
}
