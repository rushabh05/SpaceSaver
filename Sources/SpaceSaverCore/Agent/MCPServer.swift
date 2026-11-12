import Foundation

/// A Model Context Protocol server (JSON-RPC 2.0 over stdio) that lets AI coding agents ask
/// about disk space and *propose* cleanups. Agents can never delete anything: proposals become
/// pending plans that a person approves in the SpaceSaver app.
public final class MCPServer: @unchecked Sendable {
    public static let serverVersion = "1.0.0"
    static let supportedProtocols = ["2025-06-18", "2025-03-26", "2024-11-05"]

    public var env: ScanEnvironment
    public var plans: PlanStore
    public var paths: AppPaths
    /// The agent's working directory. Paths inside or above it are refused (active workspace).
    public var protectedWorkspaces: [String]
    /// How long a saved scan is reused before list_reclaim_candidates rescans.
    public var scanMaxAge: TimeInterval = 6 * 3600
    var clientName = "unknown agent"

    public init(env: ScanEnvironment = ScanEnvironment(settings: .load()), plans: PlanStore = PlanStore(),
                paths: AppPaths = .default,
                protectedWorkspaces: [String] = [FileManager.default.currentDirectoryPath]) {
        self.env = env
        self.plans = plans
        self.paths = paths
        self.protectedWorkspaces = protectedWorkspaces
            .map { ($0 as NSString).standardizingPath }
            .filter { $0 != "/" && $0 != env.home }
    }

    // MARK: Transport

    public func run() {
        while let line = readLine(strippingNewline: true) {
            guard !line.trimmingCharacters(in: .whitespaces).isEmpty else { continue }
            if let response = handle(line: line) {
                FileHandle.standardOutput.write(Data((response + "\n").utf8))
            }
        }
    }

    /// Handles one JSON-RPC message. Returns the response line, or nil for notifications.
    public func handle(line: String) -> String? {
        guard let data = line.data(using: .utf8),
              let message = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return encode(["jsonrpc": "2.0", "id": NSNull(), "error": ["code": -32700, "message": "Parse error"]])
        }
        let id = message["id"]
        let method = message["method"] as? String ?? ""
        let params = message["params"] as? [String: Any] ?? [:]
        guard let id else { return nil } // notification (e.g. notifications/initialized)

        do {
            let result = try dispatch(method: method, params: params)
            return encode(["jsonrpc": "2.0", "id": id, "result": result])
        } catch let error as RPCError {
            return encode(["jsonrpc": "2.0", "id": id, "error": ["code": error.code, "message": error.message]])
        } catch {
            return encode(["jsonrpc": "2.0", "id": id, "error": ["code": -32603, "message": error.localizedDescription]])
        }
    }

    struct RPCError: Error {
        var code: Int
        var message: String
    }

    func dispatch(method: String, params: [String: Any]) throws -> Any {
        switch method {
        case "initialize":
            if let info = params["clientInfo"] as? [String: Any], let name = info["name"] as? String {
                clientName = name.sanitizedForDisplay
            }
            let requested = params["protocolVersion"] as? String ?? Self.supportedProtocols[0]
            return [
                "protocolVersion": Self.supportedProtocols.contains(requested) ? requested : Self.supportedProtocols[0],
                "capabilities": ["tools": ["listChanged": false]],
                "serverInfo": ["name": "spacesaver", "title": "SpaceSaver", "version": Self.serverVersion],
                "instructions": "Use SpaceSaver to check free disk space before large downloads or builds, find regenerable caches, and propose cleanups. You cannot delete files: propose_cleanup creates a request the user approves in the SpaceSaver app.",
            ] as [String: Any]
        case "ping":
            return [String: Any]()
        case "tools/list":
            return ["tools": Self.toolDefinitions]
        case "tools/call":
            guard let name = params["name"] as? String else { throw RPCError(code: -32602, message: "Missing tool name") }
            let args = params["arguments"] as? [String: Any] ?? [:]
            return callTool(name, args)
        default:
            throw RPCError(code: -32601, message: "Method not found: \(method)")
        }
    }

    // MARK: Tools

    static let riskEnum = ["safe", "review", "caution"]

    static let toolDefinitions: [[String: Any]] = [
        [
            "name": "get_disk_status",
            "title": "Disk status",
            "description": "Free, used and purgeable space on the startup disk, plus when SpaceSaver last scanned.",
            "inputSchema": ["type": "object", "properties": [String: Any](), "additionalProperties": false],
            "annotations": ["readOnlyHint": true, "openWorldHint": false],
        ],
        [
            "name": "preflight_check",
            "title": "Will it fit?",
            "description": "Check whether an operation needing `required_gb` (Docker build, git clone, model download) fits on disk with headroom. If not, suggests the safest cleanups that would make room.",
            "inputSchema": [
                "type": "object",
                "properties": [
                    "required_gb": ["type": "number", "minimum": 0, "description": "Space the operation needs, in GB."],
                    "headroom_gb": ["type": "number", "minimum": 0, "default": 2, "description": "Extra space to keep free."],
                ],
                "required": ["required_gb"],
                "additionalProperties": false,
            ] as [String: Any],
            "annotations": ["readOnlyHint": true, "openWorldHint": false],
        ],
        [
            "name": "list_reclaim_candidates",
            "title": "List reclaimable space",
            "description": "Ranked list of regenerable caches and build artifacts with size, risk and how to rebuild. Uses the latest scan (rescans if older than 6 hours or refresh=true; a scan takes 10-60 s).",
            "inputSchema": [
                "type": "object",
                "properties": [
                    "category": ["type": "string", "enum": CleanupCategory.reclaimScanCategories.map(\.rawValue)],
                    "max_risk": ["type": "string", "enum": riskEnum, "default": "review"],
                    "min_size_mb": ["type": "number", "minimum": 0, "default": 50],
                    "limit": ["type": "integer", "minimum": 1, "maximum": 200, "default": 25],
                    "refresh": ["type": "boolean", "default": false],
                ],
                "additionalProperties": false,
            ] as [String: Any],
            "annotations": ["readOnlyHint": true, "openWorldHint": false],
        ],
        [
            "name": "explain_path",
            "title": "Explain a folder",
            "description": "What a file or folder is, which tool creates it, whether removing it is safe, and how it's rebuilt. Offline.",
            "inputSchema": [
                "type": "object",
                "properties": ["path": ["type": "string", "description": "Absolute or ~ path."]],
                "required": ["path"],
                "additionalProperties": false,
            ] as [String: Any],
            "annotations": ["readOnlyHint": true, "openWorldHint": false],
        ],
        [
            "name": "propose_cleanup",
            "title": "Propose a cleanup",
            "description": "Ask the user to move paths to the Trash. Nothing is deleted now: this creates a pending request the user must approve in the SpaceSaver app, and returns status pending_approval. Only paths SpaceSaver recognises as regenerable are accepted; the agent's current workspace is always refused.",
            "inputSchema": [
                "type": "object",
                "properties": [
                    "paths": ["type": "array", "items": ["type": "string"], "minItems": 1, "maxItems": 100],
                    "reason": ["type": "string", "description": "Why the space is needed. Shown to the user."],
                ],
                "required": ["paths", "reason"],
                "additionalProperties": false,
            ] as [String: Any],
            "annotations": ["readOnlyHint": false, "destructiveHint": false, "idempotentHint": false, "openWorldHint": false],
        ],
        [
            "name": "get_plan_status",
            "title": "Cleanup request status",
            "description": "Status of a request from propose_cleanup: pending, approved, rejected, executed, failed or expired.",
            "inputSchema": [
                "type": "object",
                "properties": ["plan_id": ["type": "string"]],
                "required": ["plan_id"],
                "additionalProperties": false,
            ] as [String: Any],
            "annotations": ["readOnlyHint": true, "openWorldHint": false],
        ],
    ]

    func callTool(_ name: String, _ args: [String: Any]) -> [String: Any] {
        let result: [String: Any]
        var isError = false
        do {
            switch name {
            case "get_disk_status": result = diskStatus()
            case "preflight_check": result = try preflight(args)
            case "list_reclaim_candidates": result = try candidates(args)
            case "explain_path": result = try explain(args)
            case "propose_cleanup": result = try propose(args)
            case "get_plan_status": result = try planStatus(args)
            default: throw RPCError(code: -32602, message: "Unknown tool: \(name)")
            }
        } catch let error as RPCError {
            result = ["error": error.message]
            isError = true
        } catch {
            result = ["error": error.localizedDescription]
            isError = true
        }
        audit(tool: name, args: args, ok: !isError, result: result)
        let text = (try? JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys]))
            .map { String(decoding: $0, as: UTF8.self) } ?? "{}"
        return ["content": [["type": "text", "text": text]], "structuredContent": result, "isError": isError]
    }

    func diskStatus() -> [String: Any] {
        guard let disk = DiskStatus.current() else { return ["error": "Couldn't read volume information"] }
        var out: [String: Any] = [
            "volume": disk.volumeName,
            "total_gb": gb(disk.total),
            "free_gb": gb(disk.free),
            "purgeable_gb": gb(disk.purgeable),
            "used_percent": Int(disk.usedFraction * 100),
            "summary": disk.summary,
        ]
        if let scan = LastScanStore.load(paths: paths) {
            out["last_scan"] = ISO8601DateFormatter().string(from: scan.date)
            out["safe_to_clean_gb"] = gb(scan.recommendedSize)
        }
        return out
    }

    func preflight(_ args: [String: Any]) throws -> [String: Any] {
        guard let required = (args["required_gb"] as? NSNumber)?.doubleValue, required >= 0 else {
            throw RPCError(code: -32602, message: "required_gb must be a non-negative number")
        }
        let headroom = (args["headroom_gb"] as? NSNumber)?.doubleValue ?? 2
        let check = Preflight.check(requiredBytes: Int64(required * 1e9), headroomBytes: Int64(headroom * 1e9))
        var out: [String: Any] = [
            "fits": check.fits,
            "free_gb": gb(check.freeBytes),
            "purgeable_gb": gb(check.purgeableBytes),
            "shortfall_gb": gb(check.shortfallBytes),
            "message": check.message,
        ]
        if !check.fits, let scan = LastScanStore.load(paths: paths) {
            let plan = RoomPlanner.plan(toFree: check.shortfallBytes, from: scan.items)
            out["suggested_cleanup"] = plan.items.prefix(15).map(candidateJSON)
            out["suggested_total_gb"] = gb(plan.total)
            out["next_step"] = "Call propose_cleanup with these paths; the user approves in SpaceSaver."
        }
        return out
    }

    func currentScan(refresh: Bool) -> ScanSummary {
        if !refresh, let scan = LastScanStore.load(paths: paths), Date().timeIntervalSince(scan.date) < scanMaxAge {
            return scan
        }
        let categories = Set(CleanupCategory.reclaimScanCategories).subtracting([.trash])
        let summary = ReclaimScanner(env: env).run(categories: categories)
        LastScanStore.save(summary, paths: paths)
        return summary
    }

    func candidates(_ args: [String: Any]) throws -> [String: Any] {
        let maxRisk = RiskLevel(rawValue: args["max_risk"] as? String ?? "review") ?? .review
        let minSize = Int64(((args["min_size_mb"] as? NSNumber)?.doubleValue ?? 50) * 1e6)
        let limit = min(max((args["limit"] as? NSNumber)?.intValue ?? 25, 1), 200)
        let category = (args["category"] as? String).flatMap(CleanupCategory.init(rawValue:))
        if args["category"] != nil && category == nil {
            throw RPCError(code: -32602, message: "Unknown category")
        }
        let scan = currentScan(refresh: args["refresh"] as? Bool ?? false)
        let matching = scan.items.filter {
            $0.isSelectable && $0.risk <= maxRisk && $0.size >= minSize && !$0.paths.isEmpty
                && (category == nil || $0.category == category)
                && !$0.paths.contains(where: isInWorkspace)
        }
        return [
            "scanned_at": ISO8601DateFormatter().string(from: scan.date),
            "total_gb": gb(matching.totalSize),
            "count": matching.count,
            "candidates": matching.prefix(limit).map(candidateJSON),
        ]
    }

    func candidateJSON(_ item: CleanupItem) -> [String: Any] {
        var out: [String: Any] = [
            "title": item.title.sanitizedForDisplay,
            "category": item.category.rawValue,
            "paths": item.paths.prefix(20).map { Paths.abbreviate($0, home: env.home).sanitizedForDisplay },
            "size_gb": gb(item.size),
            "risk": item.risk.rawValue,
            "what": item.explanation.sanitizedForDisplay,
        ]
        if item.paths.count > 20 { out["more_paths"] = item.paths.count - 20 }
        if let r = item.regenerate { out["rebuild"] = r.sanitizedForDisplay }
        if let d = item.lastModified { out["last_used"] = ISO8601DateFormatter().string(from: d) }
        if !item.method.isUndoable { out["note"] = "Not a file move (\(item.method.label)); the user must run it from SpaceSaver." }
        return out
    }

    func explain(_ args: [String: Any]) throws -> [String: Any] {
        guard let raw = args["path"] as? String, !raw.isEmpty else {
            throw RPCError(code: -32602, message: "path is required")
        }
        let path = (env.expand(raw) as NSString).standardizingPath
        let exp = KnowledgeBase(home: env.home).explain(path)
        var out: [String: Any] = [
            "path": Paths.abbreviate(path, home: env.home).sanitizedForDisplay,
            "title": exp.title.sanitizedForDisplay,
            "explanation": exp.summary.sanitizedForDisplay,
            "risk": exp.risk.rawValue,
            "source": exp.source,
            "exists": Paths.exists(path),
        ]
        if let r = exp.regenerate { out["rebuild"] = r }
        if Paths.exists(path) {
            out["size_gb"] = gb(DirectorySizer.measure(path).bytes)
        }
        return out
    }

    func isInWorkspace(_ path: String) -> Bool {
        protectedWorkspaces.contains { Paths.isWithin(path, $0) || Paths.isWithin($0, path) }
    }

    func propose(_ args: [String: Any]) throws -> [String: Any] {
        guard let raw = args["paths"] as? [String], !raw.isEmpty, raw.count <= 100 else {
            throw RPCError(code: -32602, message: "paths must be a list of 1-100 paths")
        }
        let reason = (args["reason"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !reason.isEmpty else { throw RPCError(code: -32602, message: "reason is required") }

        let safety = SafetyGuard(home: env.home, excluded: env.settings.excludedPaths)
        let kb = KnowledgeBase(home: env.home)
        let known = LastScanStore.load(paths: paths)?.items.flatMap(\.paths) ?? []
        var accepted: [CleanupPlan.Entry] = []
        var rejected: [[String: String]] = []

        for item in raw {
            let path = (env.expand(item) as NSString).standardizingPath
            let shown = Paths.abbreviate(path, home: env.home).sanitizedForDisplay
            do {
                let valid = try safety.validate(path)
                if isInWorkspace(valid) {
                    rejected.append(["path": shown, "reason": "Inside or above your current workspace; SpaceSaver won't clean an active project."])
                    continue
                }
                let exp = kb.explain(valid)
                let recognised = known.contains { Paths.isWithin(valid, $0) }
                    || exp.source == "Built-in rule" || exp.source == "Project artifact"
                guard recognised, exp.risk != .caution else {
                    rejected.append(["path": shown, "reason": "Not recognised as regenerable (\(exp.title)). Ask the user to review it themselves."])
                    continue
                }
                accepted.append(CleanupPlan.Entry(path: valid, size: DirectorySizer.measure(valid).bytes,
                                                  risk: exp.risk, explanation: exp.summary))
            } catch {
                rejected.append(["path": shown, "reason": error.localizedDescription])
            }
        }

        guard !accepted.isEmpty else {
            return ["status": "rejected", "accepted": [Any](), "rejected": rejected,
                    "message": "No paths could be proposed."]
        }
        let plan = try plans.create(requester: clientName, reason: reason, entries: accepted)
        return [
            "status": "pending_approval",
            "plan_id": plan.id,
            "total_gb": gb(plan.totalSize),
            "accepted": accepted.map { ["path": Paths.abbreviate($0.path, home: env.home).sanitizedForDisplay,
                                        "size_gb": gb($0.size), "risk": $0.risk.rawValue] as [String: Any] },
            "rejected": rejected,
            "message": "Waiting for the user. Ask them to open SpaceSaver › Agent Requests to approve. Nothing has been deleted. Poll get_plan_status with this plan_id.",
        ]
    }

    func planStatus(_ args: [String: Any]) throws -> [String: Any] {
        guard let id = args["plan_id"] as? String, let plan = plans.get(id) else {
            throw RPCError(code: -32602, message: "Unknown plan_id")
        }
        var out: [String: Any] = ["plan_id": plan.id, "status": plan.status.rawValue, "total_gb": gb(plan.totalSize)]
        if let decided = plan.decidedAt { out["decided_at"] = ISO8601DateFormatter().string(from: decided) }
        if let result = plan.result { out["result"] = result }
        return out
    }

    // MARK: Helpers

    func gb(_ bytes: Int64) -> Double { (Double(bytes) / 1e9 * 100).rounded() / 100 }

    func encode(_ object: [String: Any]) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.withoutEscapingSlashes]) else {
            return #"{"jsonrpc":"2.0","id":null,"error":{"code":-32603,"message":"Encoding failed"}}"#
        }
        return String(decoding: data, as: UTF8.self)
    }

    func audit(tool: String, args: [String: Any], ok: Bool, result: [String: Any]) {
        let line: [String: Any] = [
            "ts": ISO8601DateFormatter().string(from: Date()),
            "client": clientName,
            "tool": tool,
            "arguments": args,
            "ok": ok,
            "status": result["status"] ?? result["error"] ?? "ok",
        ]
        guard JSONSerialization.isValidJSONObject(line),
              let data = try? JSONSerialization.data(withJSONObject: line, options: [.sortedKeys]) else { return }
        paths.ensure()
        let file = paths.mcpAudit
        if !FileManager.default.fileExists(atPath: file) {
            FileManager.default.createFile(atPath: file, contents: nil, attributes: [.posixPermissions: 0o600])
        }
        if let handle = FileHandle(forWritingAtPath: file) {
            handle.seekToEndOfFile()
            handle.write(data + Data("\n".utf8))
            try? handle.close()
        }
    }
}
