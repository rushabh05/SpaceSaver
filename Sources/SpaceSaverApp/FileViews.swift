import SpaceSaverCore
import SwiftUI

// MARK: - Large files

struct LargeFilesView: View {
    @Environment(AppModel.self) private var model
    @State private var selection = Set<String>()
    @State private var kind: Kind = .all
    @State private var sortOrder = [KeyPathComparator(\LargeFile.size, order: .reverse)]

    enum Kind: String, CaseIterable {
        case all = "All", video = "Video", images = "Disk Images", archives = "Archives", vms = "VMs & Models", other = "Other"

        func matches(_ path: String) -> Bool {
            let ext = (path as NSString).pathExtension.lowercased()
            switch self {
            case .all: return true
            case .video: return ["mov", "mp4", "mkv", "avi", "m4v", "webm", "mxf", "braw"].contains(ext)
            case .images: return ["dmg", "iso", "img", "pkg", "xip", "sparseimage", "ipsw"].contains(ext)
            case .archives: return ["zip", "tar", "gz", "tgz", "7z", "rar", "xz", "zst", "bz2"].contains(ext)
            case .vms: return ["vmdk", "vdi", "qcow2", "raw", "vhdx", "img", "gguf", "safetensors", "bin", "ckpt", "pt"].contains(ext)
            case .other: return Kind.allCases.dropFirst().dropLast().allSatisfy { !$0.matches(path) }
            }
        }
    }

    var body: some View {
        let files = model.largeFiles.filter { kind.matches($0.path) }.sorted(using: sortOrder)
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                CategoryIcon(category: .largeFiles, size: 34)
                VStack(alignment: .leading) {
                    Text("Large Files").font(.title2.weight(.semibold))
                    Text("Files over \(model.settings.largeFileThresholdMB) MB in \(Paths.abbreviate(model.largeFilesRoot ?? NSHomeDirectory())). Usually your own data, so check each one.")
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if model.mapScanning {
                    ProgressView().controlSize(.small)
                    Text("\(model.mapProgress.files.formatted()) files").font(.caption).foregroundStyle(.secondary)
                } else {
                    Button(model.largeFiles.isEmpty ? "Scan Home Folder" : "Rescan") {
                        model.startMapScan(path: model.largeFilesRoot ?? NSHomeDirectory())
                    }
                }
            }
            .padding(20)
            Picker("Kind", selection: $kind) { ForEach(Kind.allCases, id: \.self) { Text($0.rawValue) } }
                .pickerStyle(.segmented).labelsHidden().padding(.horizontal, 20).padding(.bottom, 10)
            Divider()
            if model.largeFiles.isEmpty && !model.mapScanning {
                EmptyStateView(symbol: "doc.zipper", title: "No large-file scan yet",
                               message: "SpaceSaver finds large files while it builds the storage map. Scanning your home folder usually takes under a minute.",
                               action: ("Scan Home Folder", { model.startMapScan(path: NSHomeDirectory()) }))
            } else {
                Table(files, selection: $selection, sortOrder: $sortOrder) {
                    TableColumn("Name", value: \.path) { f in
                        HStack {
                            Image(nsImage: NSWorkspace.shared.icon(forFile: f.path)).resizable().frame(width: 16, height: 16)
                            Text(Paths.name(f.path)).lineLimit(1)
                        }
                    }
                    TableColumn("Size", value: \.size) { f in SizeText(bytes: f.size) }.width(90)
                    TableColumn("Modified", value: \.modified) { f in
                        Text(f.modified.formatted(date: .abbreviated, time: .omitted)).foregroundStyle(.secondary)
                    }.width(110)
                    TableColumn("Location") { f in
                        Text(Paths.abbreviate(Paths.parent(f.path))).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                    }
                }
                .contextMenu(forSelectionType: String.self) { ids in
                    Button("Reveal in Finder") { Finder.reveal(Array(ids)) }
                    Button("Move to Trash…") { trash(ids) }
                } primaryAction: { ids in Finder.reveal(Array(ids)) }
                Divider()
                HStack {
                    Text("\(files.count) files · \(ByteFormat.string(files.reduce(0) { $0 + $1.size }))").foregroundStyle(.secondary)
                    Spacer()
                    if !selection.isEmpty {
                        Button("Reveal") { Finder.reveal(Array(selection)) }
                    }
                    Button("Move to Trash…") { trash(selection) }
                        .buttonStyle(PrimaryButtonStyle()).disabled(selection.isEmpty)
                }
                .padding(.horizontal, 20).padding(.vertical, 10).background(.bar)
            }
        }
        .navigationTitle("Large Files")
    }

    private func trash(_ ids: Set<String>) {
        let kb = KnowledgeBase()
        let items = model.largeFiles.filter { ids.contains($0.path) }.map { f -> CleanupItem in
            let exp = kb.explain(f.path)
            return CleanupItem(id: "large:\(f.path)", category: .largeFiles, title: Paths.name(f.path),
                               subtitle: Paths.abbreviate(f.path), paths: [f.path], size: f.size,
                               risk: max(exp.risk, .review), explanation: exp.summary, lastModified: f.modified)
        }
        model.requestCleanup(items)
        selection.subtract(ids)
    }
}

// MARK: - Duplicates

struct DuplicatesView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        let included = model.duplicateGroups.filter { model.duplicateIncluded.contains($0.id) }
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                CategoryIcon(category: .duplicates, size: 34)
                VStack(alignment: .leading) {
                    Text("Duplicates").font(.title2.weight(.semibold))
                    Text("Byte-identical files (SHA-256). One copy of each set is always kept.").foregroundStyle(.secondary)
                }
                Spacer()
                Menu {
                    ForEach(model.duplicateRoots, id: \.self) { root in
                        Button("Remove \(Paths.abbreviate(root))") { model.duplicateRoots.removeAll { $0 == root } }
                    }
                    Divider()
                    Button("Add Folder…") {
                        if let p = Finder.chooseFolder() { model.duplicateRoots.append(p) }
                    }
                } label: {
                    Label(model.duplicateRoots.map { Paths.abbreviate($0) }.joined(separator: ", "), systemImage: "folder")
                }
                .fixedSize().disabled(model.duplicatesScanning)
                if model.duplicatesScanning {
                    Button("Stop") { model.cancelDuplicateScan() }
                } else {
                    Button(model.duplicatesScanned ? "Rescan" : "Find Duplicates") { model.startDuplicateScan() }
                        .buttonStyle(PrimaryButtonStyle()).disabled(model.duplicateRoots.isEmpty)
                }
            }
            .padding(20)
            Divider()
            if model.duplicatesScanning {
                VStack(spacing: 10) {
                    ProgressView()
                    Text(model.duplicateProgress.phase).font(.headline)
                    Text(model.duplicateProgress.candidates > 0
                         ? "Hashed \(model.duplicateProgress.hashed) of \(model.duplicateProgress.candidates) candidates (\(ByteFormat.string(model.duplicateProgress.bytesHashed)))"
                         : "\(model.duplicateProgress.filesSeen.formatted()) files over \(model.settings.duplicateMinSizeMB) MB")
                        .foregroundStyle(.secondary).monospacedDigit()
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if model.duplicateGroups.isEmpty {
                EmptyStateView(symbol: "doc.on.doc", title: model.duplicatesScanned ? "No duplicates found" : "Find duplicate files",
                               message: model.duplicatesScanned ? "Every file over \(model.settings.duplicateMinSizeMB) MB is unique."
                                   : "Compares files over \(model.settings.duplicateMinSizeMB) MB by size, then by content hash. iCloud files that aren't downloaded are skipped so nothing gets downloaded.",
                               action: model.duplicatesScanned ? nil : ("Find Duplicates", { model.startDuplicateScan() }))
            } else {
                List {
                    ForEach($model.duplicateGroups) { $group in
                        DuplicateGroupRow(group: $group)
                    }
                }
                .listStyle(.inset)
                Divider()
                HStack {
                    Toggle("Select all", isOn: Binding(
                        get: { model.duplicateIncluded.count == model.duplicateGroups.count },
                        set: { model.duplicateIncluded = $0 ? Set(model.duplicateGroups.map(\.id)) : [] }))
                    Spacer()
                    Text("\(included.reduce(0) { $0 + $1.files.count - 1 }) copies · \(ByteFormat.string(included.reduce(0) { $0 + $1.reclaimable }))")
                        .foregroundStyle(.secondary)
                    Button("Remove Copies…") {
                        model.requestCleanup(DuplicateFinder.items(for: included), title: "Remove \(ByteFormat.string(included.reduce(0) { $0 + $1.reclaimable })) of duplicates?")
                    }
                    .buttonStyle(PrimaryButtonStyle()).disabled(included.isEmpty)
                }
                .padding(.horizontal, 20).padding(.vertical, 10).background(.bar)
            }
        }
        .navigationTitle("Duplicates")
    }
}

struct DuplicateGroupRow: View {
    @Environment(AppModel.self) private var model
    @Binding var group: DuplicateGroup
    @State private var expanded = false

    var body: some View {
        DisclosureGroup(isExpanded: $expanded) {
            ForEach(Array(group.files.enumerated()), id: \.element.id) { index, file in
                HStack(spacing: 8) {
                    Button {
                        group.keep = index
                    } label: {
                        Image(systemName: index == group.keep ? "largecircle.fill.circle" : "circle")
                            .foregroundStyle(index == group.keep ? Color.green : Color.secondary)
                    }
                    .buttonStyle(.plain).help("Keep this copy")
                    Text(index == group.keep ? "Keep" : "Remove").font(.caption.weight(.semibold))
                        .foregroundStyle(index == group.keep ? .green : .orange).frame(width: 50, alignment: .leading)
                    Text(Paths.abbreviate(file.path)).lineLimit(1).truncationMode(.middle)
                    Spacer()
                    Text(file.modified.formatted(date: .abbreviated, time: .omitted)).font(.caption).foregroundStyle(.secondary)
                    Button { Finder.reveal([file.path]) } label: { Image(systemName: "magnifyingglass") }.buttonStyle(.borderless)
                }
            }
        } label: {
            HStack {
                Toggle("", isOn: Binding(
                    get: { model.duplicateIncluded.contains(group.id) },
                    set: { if $0 { model.duplicateIncluded.insert(group.id) } else { model.duplicateIncluded.remove(group.id) } }))
                    .toggleStyle(.checkbox).labelsHidden()
                Image(nsImage: NSWorkspace.shared.icon(forFile: group.files[group.keep].path)).resizable().frame(width: 18, height: 18)
                Text(Paths.name(group.files[group.keep].path)).fontWeight(.medium).lineLimit(1)
                Tag(text: "\(group.files.count) × \(ByteFormat.compact(group.size))")
                Spacer()
                SizeText(bytes: group.reclaimable, font: .callout.weight(.semibold))
            }
        }
    }
}

// MARK: - Activity

struct ActivityView: View {
    @Environment(AppModel.self) private var model
    @State private var vaultSize: Int64 = 0

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 14) {
                Image(systemName: "clock.arrow.circlepath").font(.title).foregroundStyle(.secondary)
                VStack(alignment: .leading) {
                    Text("Activity").font(.title2.weight(.semibold))
                    Text("Everything SpaceSaver, the CLI, the scheduler and approved agents have cleaned. Trash items restore to where they came from.")
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }
            .padding(20)
            HStack(spacing: 12) {
                Card(padding: 12) {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Held in Trash").font(.caption).foregroundStyle(.secondary)
                            SizeText(bytes: model.heldInTrash, font: .title3.weight(.semibold))
                        }
                        Spacer()
                        Button("Free Now") { model.purge() }.buttonStyle(SoftButtonStyle(tint: .red)).disabled(model.heldInTrash == 0)
                            .help("Permanently delete items SpaceSaver moved to the Trash. Nothing else in the Trash is touched.")
                    }
                }
                Card(padding: 12) {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Archive vault").font(.caption).foregroundStyle(.secondary)
                            SizeText(bytes: vaultSize, font: .title3.weight(.semibold))
                        }
                        Spacer()
                        Button("Show in Finder") { Finder.reveal([model.paths.vault]) }.buttonStyle(SoftButtonStyle())
                    }
                }
            }
            .padding(.horizontal, 20).padding(.bottom, 14)
            Divider()
            if model.activity.isEmpty {
                EmptyStateView(symbol: "clock", title: "Nothing cleaned yet", message: "Cleanups show up here with one-click restore.")
            } else {
                List(model.activity) { entry in
                    ActivityRow(entry: entry, showActions: true)
                }
                .listStyle(.inset)
            }
        }
        .navigationTitle("Activity")
        .task {
            model.refreshActivity()
            vaultSize = await Task.detached { Archiver.vaultSize(AppPaths.default.vault) }.value
        }
    }
}

struct ActivityRow: View {
    @Environment(AppModel.self) private var model
    let entry: ActivityEntry
    var showActions = false

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: entry.category.symbol).foregroundStyle(entry.category.color).frame(width: 20)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(entry.title).fontWeight(.medium).lineLimit(1)
                    Tag(text: entry.source.hasPrefix("agent") ? "agent" : entry.source,
                        color: entry.source.hasPrefix("agent") ? .purple : .secondary)
                    statusTag
                }
                Text("\(entry.date.formatted(date: .abbreviated, time: .shortened)) · \(entry.method)")
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                if let output = entry.commandOutput, showActions, !output.isEmpty {
                    Text(output).font(.caption2.monospaced()).foregroundStyle(.tertiary).lineLimit(2)
                }
                ForEach(entry.errors.prefix(2), id: \.self) { Text($0).font(.caption).foregroundStyle(.red).lineLimit(1) }
            }
            Spacer()
            SizeText(bytes: entry.bytes, font: .callout.weight(.semibold))
            if showActions {
                if entry.canRestore {
                    Button { model.restore(entry) } label: { Label("Restore", systemImage: "arrow.uturn.backward") }
                        .buttonStyle(SoftButtonStyle(compact: true))
                    Button { model.purge(ids: [entry.id]) } label: { Image(systemName: "trash.slash") }
                        .help("Delete permanently now")
                }
                if let archive = entry.archivePath, Paths.exists(archive) {
                    Button { Finder.reveal([archive]) } label: { Image(systemName: "archivebox") }.help("Show archive")
                }
            }
        }
        .padding(.vertical, 3)
    }

    @ViewBuilder private var statusTag: some View {
        switch entry.status {
        case .completed: if entry.canRestore { Tag(text: "in Trash", color: .blue) }
        case .partial: Tag(text: "partial", color: .orange)
        case .failed: Tag(text: "failed", color: .red)
        case .restored: Tag(text: "restored", color: .green)
        case .purged: Tag(text: "deleted", color: .secondary)
        }
    }
}

// MARK: - Agent requests

struct ApprovalsView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 14) {
                Image(systemName: "person.badge.shield.checkmark").font(.title).foregroundStyle(.purple)
                VStack(alignment: .leading) {
                    Text("Agent Requests").font(.title2.weight(.semibold))
                    Text("AI agents connected through MCP can only propose cleanups. Nothing moves until you approve it here.")
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Refresh") { model.refreshPlans() }.buttonStyle(SoftButtonStyle())
            }
            .padding(20)
            Divider()
            if model.plans.isEmpty {
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        EmptyStateView(symbol: "tray", title: "No requests yet",
                                       message: "Connect Claude Code, Cursor or Codex to SpaceSaver's MCP server so agents can check disk space before big downloads and ask you to free room.")
                            .frame(height: 220)
                        MCPSetupView()
                    }
                    .padding(20)
                }
            } else {
                List {
                    let pending = model.plans.filter { $0.status == .pending }
                    if !pending.isEmpty {
                        Section("Waiting for you") { ForEach(pending) { PlanCard(plan: $0) } }
                    }
                    Section("History") {
                        ForEach(model.plans.filter { $0.status != .pending }) { plan in
                            HStack {
                                Text(plan.requester).fontWeight(.medium)
                                Text(plan.reason).foregroundStyle(.secondary).lineLimit(1)
                                Spacer()
                                Tag(text: plan.status.rawValue, color: plan.status == .executed ? .green : plan.status == .rejected ? .red : .secondary)
                                SizeText(bytes: plan.totalSize, font: .callout)
                                Text(plan.created.formatted(date: .abbreviated, time: .shortened)).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
                .listStyle(.inset)
            }
        }
        .navigationTitle("Agent Requests")
        .task { model.refreshPlans() }
    }
}

struct PlanCard: View {
    @Environment(AppModel.self) private var model
    let plan: CleanupPlan

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Image(systemName: "sparkles").foregroundStyle(.purple)
                Text(plan.requester).font(.headline)
                Text("wants to free \(ByteFormat.string(plan.totalSize))").foregroundStyle(.secondary)
                RiskBadge(risk: plan.highestRisk)
                Spacer()
                Text(RelativeTime.string(since: plan.created)).font(.caption).foregroundStyle(.secondary)
            }
            Text("“\(plan.reason)”").italic()
            VStack(alignment: .leading, spacing: 4) {
                ForEach(plan.entries, id: \.path) { e in
                    HStack {
                        RiskBadge(risk: e.risk, compact: true)
                        Text(Paths.abbreviate(e.path)).font(.callout.monospaced()).lineLimit(1).truncationMode(.middle)
                        Spacer()
                        SizeText(bytes: e.size, font: .callout)
                    }
                    .help(e.explanation)
                }
            }
            .padding(10)
            .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 8))
            HStack {
                Spacer()
                Button("Reject") { model.reject(plan) }.buttonStyle(SoftButtonStyle(tint: .red))
                Button("Review & Approve…") { model.approve(plan) }.buttonStyle(PrimaryButtonStyle(colors: [.purple, .pink]))
            }
        }
        .padding(.vertical, 8)
    }
}
