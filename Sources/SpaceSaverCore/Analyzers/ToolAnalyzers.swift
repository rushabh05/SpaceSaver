import Foundation

// MARK: - iOS Simulators

/// Lists simulator devices with their runtime and last boot, flagging ones whose runtime is gone.
public struct SimulatorAnalyzer {
    public var env: ScanEnvironment
    public var running: RunningApps

    public init(env: ScanEnvironment, running: RunningApps) {
        self.env = env
        self.running = running
    }

    public func analyze() -> [CleanupItem] {
        let devicesDir = env.expand("~/Library/Developer/CoreSimulator/Devices")
        let udids = Paths.children(devicesDir).filter { $0.count == 36 }
        guard !udids.isEmpty else { return [] }
        let installedRuntimes = Self.installedRuntimes()
        let simctl = Self.simctlAvailable()
        let busy = env.settings.activeAppGuard
            ? running.running(processes: ["Simulator", "launchd_sim"], bundleIDs: ["com.apple.iphonesimulator"]) : nil

        let paths = udids.map { Paths.join(devicesDir, $0) }
        let sizes = DirectorySizer.measureAll(paths)
        var items: [CleanupItem] = []
        for (udid, path) in zip(udids, paths) {
            guard let size = sizes[path], size.bytes >= 20_000_000 else { continue }
            let plist = NSDictionary(contentsOfFile: path + "/device.plist") as? [String: Any] ?? [:]
            let name = plist["name"] as? String ?? "Simulator"
            let runtimeID = plist["runtime"] as? String ?? ""
            let runtime = Self.runtimeName(runtimeID)
            let lastBoot = plist["lastBootedAt"] as? Date
            let lastUsed = lastBoot ?? size.newestDate
            let unavailable = !installedRuntimes.isEmpty && !runtimeID.isEmpty && !installedRuntimes.contains(runtimeID)

            var tags = [runtime]
            if unavailable { tags.append("Runtime missing") }
            if let lastUsed { tags.append("Used \(RelativeTime.age(of: lastUsed, now: env.now))") }
            if lastBoot == nil { tags.append("Never booted") }
            let idle = lastUsed.map { RelativeTime.days(since: $0, now: env.now) } ?? 999
            let risk: RiskLevel = unavailable || idle > 120 ? .safe : .review

            let method: CleanupMethod = simctl.map { .command(executable: $0, arguments: ["simctl", "delete", udid]) } ?? .trash
            items.append(CleanupItem(
                id: "sim:\(udid)", category: .xcode, title: "\(name) · \(runtime)",
                subtitle: Paths.abbreviate(path, home: env.home), paths: [path], size: size.bytes, risk: risk,
                method: method,
                explanation: unavailable
                    ? "A simulator for a runtime that's no longer installed. It can't boot, so its data is dead weight."
                    : "A simulator device and its installed apps and data.",
                regenerate: "Create a new simulator in Xcode › Window › Devices and Simulators.",
                lastModified: lastUsed, tags: tags,
                blockedReason: busy.map { "\($0) is running. Quit it to delete simulators." },
                recommended: risk == .safe && busy == nil, group: "Simulators", itemCount: size.files))
        }
        return items
    }

    static func simctlAvailable() -> String? {
        let r = Shell.run("/usr/bin/xcrun", ["--find", "simctl"], timeout: 10)
        return r.ok ? "/usr/bin/xcrun" : nil
    }

    static func installedRuntimes() -> Set<String> {
        var ids = Set<String>()
        let locations = [
            "/Library/Developer/CoreSimulator/Profiles/Runtimes",
            "/Library/Developer/CoreSimulator/Volumes",
        ]
        for base in locations {
            for bundle in Paths.glob(base + "/*.simruntime") + Paths.glob(base + "/*/Library/Developer/CoreSimulator/Profiles/Runtimes/*.simruntime") {
                if let info = NSDictionary(contentsOfFile: bundle + "/Contents/Info.plist"),
                   let id = info["CFBundleIdentifier"] as? String {
                    ids.insert(id)
                }
            }
        }
        return ids
    }

    static func runtimeName(_ id: String) -> String {
        // com.apple.CoreSimulator.SimRuntime.iOS-17-2 -> iOS 17.2
        guard let last = id.split(separator: ".").last else { return "Unknown runtime" }
        let parts = last.split(separator: "-")
        guard let os = parts.first else { return String(last) }
        return parts.count > 1 ? "\(os) \(parts.dropFirst().joined(separator: "."))" : String(os)
    }
}

// MARK: - Docker

public struct DockerAnalyzer {
    public var env: ScanEnvironment

    public init(env: ScanEnvironment) { self.env = env }

    public static func dockerBinary() -> String? {
        Shell.which("docker", extra: ["/Applications/Docker.app/Contents/Resources/bin",
                                      "/Applications/OrbStack.app/Contents/MacOS/xbin"])
    }

    public struct DFRow: Decodable {
        public var type: String
        public var totalCount: String
        public var active: String
        public var size: String
        public var reclaimable: String

        enum CodingKeys: String, CodingKey {
            case type = "Type", totalCount = "TotalCount", active = "Active", size = "Size", reclaimable = "Reclaimable"
        }

        public var reclaimableBytes: Int64 {
            // "1.2GB (50%)" -> 1.2GB
            ByteFormat.parse(String(reclaimable.split(separator: " ").first ?? "")) ?? 0
        }
    }

    public static func parseDF(_ output: String) -> [DFRow] {
        output.split(separator: "\n").compactMap { line in
            try? JSONDecoder().decode(DFRow.self, from: Data(line.utf8))
        }
    }

    public func analyze() -> [CleanupItem] {
        var items: [CleanupItem] = []
        // The VM disk image that holds everything Docker Desktop stores.
        let vmDisks = [
            "~/Library/Containers/com.docker.docker/Data/vms/0/data/Docker.raw",
            "~/Library/Containers/com.docker.docker/Data/vms/0/Docker.raw",
            "~/.colima/_lima/colima/diffdisk",
            "~/.orbstack/data/data.img",
        ].map(env.expand).filter(Paths.exists)
        for disk in vmDisks {
            let size = DirectorySizer.measure(disk)
            guard size.bytes > 0 else { continue }
            items.append(CleanupItem(
                id: "docker:vm:\(disk)", category: .docker, title: "Docker VM disk image",
                subtitle: Paths.abbreviate(disk, home: env.home), paths: [disk], size: size.bytes, risk: .caution,
                method: .manual(instructions: "Prune images and build cache below, then shrink the disk in Docker Desktop › Settings › Resources › Virtual disk limit (or run `docker system prune`). Never delete this file directly: it holds all images, containers and volumes."),
                explanation: "The virtual disk that holds every image, container, volume and build cache. macOS reports it under System Data. It only shrinks after pruning.",
                tags: ["Managed by Docker"], blockedReason: "Clean the items below instead; this file is managed by Docker.",
                recommended: false, group: "Docker storage"))
        }

        guard let docker = Self.dockerBinary() else { return items }
        let df = Shell.run(docker, ["system", "df", "--format", "{{json .}}"], timeout: 20)
        guard df.ok else {
            items.append(CleanupItem(
                id: "docker:offline", category: .docker, title: "Docker isn't running",
                subtitle: "Start Docker to see reclaimable images and build cache", paths: [], size: 0, risk: .safe,
                method: .manual(instructions: "Open Docker Desktop (or start colima/OrbStack), then scan again."),
                explanation: "SpaceSaver asks the Docker engine what it can safely prune. The engine isn't reachable right now.",
                blockedReason: "Docker engine not reachable", recommended: false))
            return items
        }
        let rows = Self.parseDF(df.stdout)
        func row(_ type: String) -> DFRow? { rows.first { $0.type.lowercased().hasPrefix(type) } }

        if let build = row("build"), build.reclaimableBytes > 0 {
            items.append(CleanupItem(
                id: "docker:buildcache", category: .docker, title: "Build cache",
                subtitle: "docker builder prune", paths: [], size: build.reclaimableBytes, risk: .safe,
                method: .command(executable: docker, arguments: ["builder", "prune", "-f"]),
                explanation: "BuildKit layers from previous builds that no running container or image needs.",
                regenerate: "Layers are rebuilt on the next docker build (slower first build).",
                tags: ["\(build.totalCount) entries"], group: "Docker engine"))
        }
        if let containers = row("containers"), containers.reclaimableBytes > 0 {
            items.append(CleanupItem(
                id: "docker:containers", category: .docker, title: "Stopped containers",
                subtitle: "docker container prune", paths: [], size: containers.reclaimableBytes, risk: .review,
                method: .command(executable: docker, arguments: ["container", "prune", "-f"]),
                explanation: "Containers that have exited. Anything written inside them (not in a volume) is lost. Running containers are never touched.",
                regenerate: "Recreate with docker run / docker compose up.",
                tags: ["\(containers.totalCount) total, \(containers.active) running"], group: "Docker engine"))
        }
        if let images = row("images"), images.reclaimableBytes > 0 {
            items.append(CleanupItem(
                id: "docker:images", category: .docker, title: "Unused images",
                subtitle: "docker image prune -a", paths: [], size: images.reclaimableBytes, risk: .review,
                method: .command(executable: docker, arguments: ["image", "prune", "-a", "-f"]),
                explanation: "Images not used by any container, including tagged base images. Images used by containers (even stopped ones) are kept.",
                regenerate: "Pulled or rebuilt again when needed.",
                tags: ["\(images.totalCount) images, \(images.active) in use"], group: "Docker engine"))
        }
        if let volumes = row("local volumes"), volumes.reclaimableBytes > 0 {
            items.append(CleanupItem(
                id: "docker:volumes", category: .docker, title: "Unused volumes",
                subtitle: "docker volume prune", paths: [], size: volumes.reclaimableBytes, risk: .caution,
                method: .command(executable: docker, arguments: ["volume", "prune", "-f"]),
                explanation: "Volumes no container references. These often hold database data. Deleting them is permanent.",
                regenerate: "Can't be recreated. Seed data again or restore from a backup.",
                tags: ["\(volumes.totalCount) volumes"], recommended: false, group: "Docker engine"))
        }
        return items
    }
}

// MARK: - Ollama

/// Per-model sizes for Ollama, counting only blobs no other model shares.
public struct OllamaAnalyzer {
    public var env: ScanEnvironment

    public init(env: ScanEnvironment) { self.env = env }

    struct Manifest: Decodable {
        struct Layer: Decodable {
            var digest: String
            var size: Int64
        }
        var config: Layer?
        var layers: [Layer]
    }

    public func analyze() -> [CleanupItem] {
        let base = ProcessInfo.processInfo.environment["OLLAMA_MODELS"] ?? env.expand("~/.ollama/models")
        let manifestsDir = base + "/manifests"
        guard Paths.isDirectory(manifestsDir) else { return [] }

        // manifests/<registry>/<namespace>/<model>/<tag>
        var manifests: [(name: String, path: String, digests: [String])] = []
        let enumerator = FileManager.default.enumerator(atPath: manifestsDir)
        while let rel = enumerator?.nextObject() as? String {
            let full = Paths.join(manifestsDir, rel)
            guard !Paths.isDirectory(full),
                  let data = FileManager.default.contents(atPath: full),
                  let manifest = try? JSONDecoder().decode(Manifest.self, from: data) else { continue }
            let parts = rel.split(separator: "/").map(String.init)
            guard parts.count >= 4 else { continue }
            let (registry, namespace, model, tag) = (parts[0], parts[1], parts[2], parts[3])
            let name = registry == "registry.ollama.ai" && namespace == "library"
                ? "\(model):\(tag)" : "\(namespace)/\(model):\(tag)"
            let digests = (manifest.layers + (manifest.config.map { [$0] } ?? [])).map(\.digest)
            manifests.append((name, full, digests))
        }

        var refCount: [String: Int] = [:]
        for m in manifests { for d in Set(m.digests) { refCount[d, default: 0] += 1 } }

        return manifests.compactMap { m in
            let exclusive = Set(m.digests).filter { refCount[$0] == 1 }
            let blobPaths = exclusive.map { base + "/blobs/" + $0.replacingOccurrences(of: ":", with: "-") }
                .filter(Paths.exists)
            let size = blobPaths.reduce(Int64(0)) { $0 + DirectorySizer.measure($1).bytes }
            guard size > 10_000_000 else { return nil }
            let modified = Paths.modificationDate(m.path)
            return CleanupItem(
                id: "ollama:\(m.name)", category: .aiModels, title: m.name, subtitle: "Ollama model",
                paths: [m.path] + blobPaths, size: size, risk: .review,
                explanation: "An Ollama model. Only weight files no other model shares are counted and removed.",
                regenerate: "`ollama pull \(m.name)`", lastModified: modified,
                tags: modified.map { ["Pulled \(RelativeTime.age(of: $0, now: env.now)) ago"] } ?? [],
                recommended: false, group: "Ollama models")
        }
    }
}

// MARK: - Editor workspace storage

/// VS Code-family editors keep a folder of state (and AI chat history) per workspace forever,
/// even after the project folder is deleted. Those orphans are pure waste.
public struct WorkspaceStorageAnalyzer {
    public var env: ScanEnvironment

    public init(env: ScanEnvironment) { self.env = env }

    public func analyze() -> [CleanupItem] {
        var items: [CleanupItem] = []
        for (folder, name, _) in RuleCatalog.vscodeFamily {
            let dir = env.expand("~/Library/Application Support/\(folder)/User/workspaceStorage")
            let entries = Paths.children(dir)
            guard !entries.isEmpty else { continue }
            var orphanPaths: [String] = []
            for entry in entries {
                let path = Paths.join(dir, entry)
                guard let data = FileManager.default.contents(atPath: path + "/workspace.json"),
                      let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }
                let uri = (json["folder"] as? String) ?? (json["workspace"] as? String) ?? ""
                guard uri.hasPrefix("file://"), let url = URL(string: uri) else { continue }
                if !Paths.exists(url.path) { orphanPaths.append(path) }
            }
            guard !orphanPaths.isEmpty else { continue }
            let sizes = DirectorySizer.measureAll(orphanPaths)
            let total = sizes.values.reduce(Int64(0)) { $0 + $1.bytes }
            guard total > 1_000_000 else { continue }
            items.append(CleanupItem(
                id: "workspace:\(folder)", category: .ideCaches, title: "\(name) storage for deleted projects",
                subtitle: Paths.abbreviate(dir, home: env.home) + " (\(orphanPaths.count) workspaces)",
                paths: orphanPaths, size: total, risk: .safe,
                explanation: "Per-workspace state, search indexes and AI chat history for \(orphanPaths.count) project folders that no longer exist on disk.",
                regenerate: "Not needed: the projects are gone.",
                tags: ["\(orphanPaths.count) orphaned"], itemCount: orphanPaths.count))
        }
        return items
    }
}

// MARK: - Downloads

public struct DownloadsAnalyzer {
    public var env: ScanEnvironment

    public init(env: ScanEnvironment) { self.env = env }

    static let installerExtensions: Set<String> = ["dmg", "pkg", "mpkg", "iso", "xip", "exe", "msi", "appimage", "deb", "rpm", "img"]
    static let archiveExtensions: Set<String> = ["zip", "tar", "gz", "tgz", "bz2", "xz", "7z", "rar", "zst"]

    public func analyze() -> [CleanupItem] {
        let dir = env.expand("~/Downloads")
        let minAge = env.settings.downloadsAgeDays
        let installedApps = Self.installedAppNames()
        var items: [CleanupItem] = []
        let entries = BulkReader.entries(dir)
        let names = Set(entries.map(\.name))

        for entry in entries where !entry.name.hasPrefix(".") {
            let path = Paths.join(dir, entry.name)
            let ext = (entry.name as NSString).pathExtension.lowercased()
            let base = Self.normalized((entry.name as NSString).deletingPathExtension)
            let addedOrModified = entry.added > 0 ? entry.added : entry.modified
            let date = Date(timeIntervalSince1970: TimeInterval(addedOrModified))
            let age = RelativeTime.days(since: date, now: env.now)
            guard age >= minAge else { continue }

            if ext == "app" {
                let size = DirectorySizer.measure(path).bytes
                guard size >= 1_000_000 else { continue }
                let installed = ["/Applications", env.expand("~/Applications")].contains {
                    Paths.exists(Paths.join($0, entry.name))
                }
                items.append(CleanupItem(
                    id: "downloads:\(path)", category: .downloads, title: entry.name,
                    subtitle: Paths.abbreviate(path, home: env.home), paths: [path], size: size,
                    risk: installed ? .safe : .review,
                    explanation: installed
                        ? "A copy of an app that's also installed in Applications. This copy in Downloads isn't the one you run."
                        : "An app that was never moved to Applications. If you use it, move it there instead.",
                    regenerate: "Download it again from the vendor.", lastModified: date,
                    tags: ["Downloaded \(RelativeTime.age(of: date, now: env.now)) ago"] + (installed ? ["App installed"] : []),
                    group: "Installers"))
                continue
            }
            let isInstaller = Self.installerExtensions.contains(ext)
            let isArchive = Self.archiveExtensions.contains(ext) || entry.name.lowercased().hasSuffix(".tar.gz")
            let size = entry.isDirectory ? DirectorySizer.measure(path).bytes : entry.allocatedSize
            if !(isInstaller || isArchive) && size < 50_000_000 { continue }
            if size < 1_000_000 { continue }

            var tags = ["Downloaded \(RelativeTime.age(of: date, now: env.now)) ago"]
            var risk: RiskLevel = .review
            var explanation: String
            if isInstaller {
                let installed = installedApps.contains { !$0.isEmpty && (base.hasPrefix($0) || $0.hasPrefix(base)) && min(base.count, $0.count) >= 4 }
                if installed {
                    tags.append("App installed")
                    risk = .safe
                    explanation = "An installer for an app that's already in Applications."
                } else {
                    explanation = "An installer or disk image. You can usually download it again from the vendor."
                }
            } else if isArchive {
                let stem = entry.name.replacingOccurrences(of: ".tar.gz", with: "")
                let extracted = names.contains((stem as NSString).deletingPathExtension) || names.contains(stem)
                if extracted && !entry.isDirectory {
                    tags.append("Already extracted")
                    risk = .safe
                    explanation = "An archive whose extracted folder is right next to it."
                } else {
                    explanation = "A compressed archive you downloaded."
                }
            } else {
                risk = .caution
                explanation = "A large file in Downloads you haven't touched in a while."
            }
            items.append(CleanupItem(
                id: "downloads:\(path)", category: .downloads, title: entry.name,
                subtitle: Paths.abbreviate(path, home: env.home), paths: [path], size: size, risk: risk,
                explanation: explanation, regenerate: isInstaller ? "Download it again from the vendor." : nil,
                lastModified: date, tags: tags,
                group: isInstaller ? "Installers" : isArchive ? "Archives" : "Other large files"))
        }
        return items
    }

    static func normalized(_ s: String) -> String {
        s.lowercased().filter { $0.isLetter }
    }

    static func installedAppNames() -> [String] {
        let dirs = ["/Applications", Paths.expand("~/Applications"), "/Applications/Utilities"]
        return dirs.flatMap(Paths.children).filter { $0.hasSuffix(".app") }
            .map { normalized(($0 as NSString).deletingPathExtension) }
    }
}

// MARK: - Trash

public struct TrashAnalyzer {
    public var env: ScanEnvironment

    public init(env: ScanEnvironment) { self.env = env }

    public func analyze() -> [CleanupItem] {
        let trash = env.expand("~/.Trash")
        let fd = open(trash, O_RDONLY | O_DIRECTORY)
        if fd < 0 {
            return [CleanupItem(
                id: "trash:noaccess", category: .trash, title: "Trash size unknown",
                subtitle: "Grant Full Disk Access to measure the Trash", paths: [], size: 0, risk: .safe,
                method: .manual(instructions: "System Settings › Privacy & Security › Full Disk Access › enable SpaceSaver."),
                explanation: "macOS only lets apps with Full Disk Access look inside the Trash.",
                blockedReason: "Needs Full Disk Access", recommended: false)]
        }
        close(fd)
        let size = DirectorySizer.measure(trash)
        guard size.bytes > 1_000_000 else { return [] }
        return [CleanupItem(
            id: "trash:user", category: .trash, title: "Items in Trash", subtitle: "~/.Trash",
            paths: [trash], size: size.bytes, risk: .caution, method: .emptyTrash,
            explanation: "Files you've deleted still use disk space until the Trash is emptied. Emptying is permanent.",
            regenerate: "Can't be undone.", lastModified: size.newestDate,
            tags: ["\(size.files) files"], recommended: false, itemCount: size.files)]
    }
}
