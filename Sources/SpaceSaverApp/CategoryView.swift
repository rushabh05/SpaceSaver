import SpaceSaverCore
import SwiftUI

struct CategoryView: View {
    @Environment(AppModel.self) private var model
    let category: CleanupCategory

    enum Sort: String, CaseIterable { case size = "Size", name = "Name", age = "Last Used" }
    enum RiskFilter: String, CaseIterable { case all = "All", safe = "Safe", review = "Review", caution = "Caution" }

    @State private var sort: Sort = .size
    @State private var riskFilter: RiskFilter = .all
    @State private var search = ""
    @State private var focused: String?
    @State private var showInspector = true

    var body: some View {
        let all = model.items(category)
        let visible = filtered(all)
        VStack(spacing: 0) {
            header(all)
            Divider()
            if model.scan == nil && !model.isScanning {
                EmptyStateView(symbol: category.symbol, title: category.title, message: category.blurb,
                               action: ("Scan", { model.startScan() }))
            } else if all.isEmpty {
                if model.isScanning && !model.scanFinished.contains(category) {
                    VStack(spacing: 10) {
                        ProgressView()
                        Text("Scanning \(category.title)…").foregroundStyle(.secondary)
                    }.frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    EmptyStateView(symbol: "checkmark.circle", title: "Nothing to clean here",
                                   message: "SpaceSaver didn't find anything in \(category.title) worth removing.")
                }
            } else {
                list(visible)
                    .safeAreaInset(edge: .bottom) {
                        actionBar(all)
                            .padding(.horizontal, 20)
                            .padding(.bottom, 14)
                    }
            }
        }
        .animation(Theme.spring, value: visible.map(\.id))
        .navigationTitle(category.title)
        .inspector(isPresented: $showInspector) {
            Group {
                if let id = focused, let item = all.first(where: { $0.id == id }) {
                    ItemInspector(item: item)
                } else {
                    EmptyStateView(symbol: "sidebar.right", title: "No selection", message: "Select an item to see what it is and how to get it back.")
                }
            }
            .inspectorColumnWidth(min: 280, ideal: 320, max: 420)
        }
        .toolbar {
            ToolbarItem {
                Button { showInspector.toggle() } label: { Label("Inspector", systemImage: "sidebar.right") }
            }
        }
        .onChange(of: category) { focused = nil }
    }

    private func filtered(_ items: [CleanupItem]) -> [CleanupItem] {
        var list = items
        switch riskFilter {
        case .all: break
        case .safe: list = list.filter { $0.risk == .safe }
        case .review: list = list.filter { $0.risk == .review }
        case .caution: list = list.filter { $0.risk == .caution }
        }
        if !search.isEmpty {
            list = list.filter { $0.title.localizedCaseInsensitiveContains(search) || $0.subtitle.localizedCaseInsensitiveContains(search) }
        }
        switch sort {
        case .size: list.sort { $0.size > $1.size }
        case .name: list.sort { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
        case .age: list.sort { ($0.lastModified ?? .distantFuture) < ($1.lastModified ?? .distantFuture) }
        }
        return list
    }

    // MARK: Header

    private func header(_ all: [CleanupItem]) -> some View {
        let selectable = all.filter(\.isSelectable)
        let safe = all.filter { $0.recommended && $0.isSelectable }.totalSize
        return VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .center, spacing: 16) {
                CategoryIcon(category: category, size: 50)
                VStack(alignment: .leading, spacing: 4) {
                    Text(category.title).font(.system(size: 24, weight: .bold, design: .rounded))
                    Text(category.blurb).foregroundStyle(.secondary).lineLimit(2)
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 3) {
                    BytesText(bytes: selectable.totalSize, font: .system(size: 26, weight: .bold, design: .rounded))
                    HStack(spacing: 6) {
                        if safe > 0 {
                            Text("\(ByteFormat.compact(safe)) safe").font(.caption.weight(.semibold)).foregroundStyle(.green)
                        }
                        Text("\(all.count) item\(all.count == 1 ? "" : "s")").font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            HStack(spacing: 10) {
                Picker("Risk", selection: $riskFilter) {
                    ForEach(RiskFilter.allCases, id: \.self) { Text($0.rawValue) }
                }
                .pickerStyle(.segmented).labelsHidden().frame(width: 270)
                Menu {
                    Picker("Sort by", selection: $sort) {
                        ForEach(Sort.allCases, id: \.self) { Text($0.rawValue) }
                    }
                    .pickerStyle(.inline)
                } label: {
                    Label("Sort: \(sort.rawValue)", systemImage: "arrow.up.arrow.down")
                }
                .menuStyle(.borderlessButton).fixedSize()
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary).font(.caption)
                    TextField("Filter", text: $search).textFieldStyle(.plain)
                    if !search.isEmpty {
                        Button { search = "" } label: { Image(systemName: "xmark.circle.fill") }
                            .buttonStyle(.plain).foregroundStyle(.secondary)
                    }
                }
                .padding(.horizontal, 10).padding(.vertical, 5)
                .background(Capsule().fill(Color.primary.opacity(0.06)))
                .frame(maxWidth: 220)
                Spacer()
                if category == .aiSessions {
                    Button {
                        model.auditSecrets(all.filter { !$0.paths.isEmpty })
                    } label: {
                        HStack(spacing: 6) {
                            if model.auditing { ProgressView().controlSize(.mini) } else { Image(systemName: "key.viewfinder") }
                            Text("Audit for Secrets")
                        }
                    }
                    .buttonStyle(SoftButtonStyle(tint: .red))
                    .disabled(model.auditing)
                    .help("Scan these logs offline for API keys and tokens")
                }
                Button { model.startScan(categories: [category]) } label: {
                    Label("Rescan", systemImage: "arrow.clockwise")
                }
                .buttonStyle(SoftButtonStyle())
                .disabled(model.isScanning)
            }
        }
        .padding(.horizontal, 24)
        .padding(.top, 20)
        .padding(.bottom, 14)
    }

    // MARK: List

    private func list(_ items: [CleanupItem]) -> some View {
        let groups = Dictionary(grouping: items) { $0.group ?? "" }
        let groupNames = groups.keys.sorted { a, b in
            (groups[a]?.totalSize ?? 0) > (groups[b]?.totalSize ?? 0)
        }
        let useSections = groupNames.count > 1 || (groupNames.first.map { !$0.isEmpty } ?? false)
        return List(selection: $focused) {
            if useSections {
                ForEach(groupNames, id: \.self) { name in
                    let rows = groups[name] ?? []
                    Section {
                        ForEach(rows) { ItemRow(item: $0).tag($0.id) }
                    } header: {
                        HStack {
                            Text(name.isEmpty ? "Other" : name)
                            Spacer()
                            Text(ByteFormat.string(rows.filter(\.isSelectable).totalSize)).monospacedDigit()
                            Button(allSelected(rows) ? "Deselect" : "Select All") { toggleAll(rows) }
                                .buttonStyle(.link).font(.caption)
                        }
                    }
                }
            } else {
                ForEach(items) { ItemRow(item: $0).tag($0.id) }
            }
        }
        .listStyle(.inset)
        .scrollContentBackground(.hidden)
    }

    private func allSelected(_ rows: [CleanupItem]) -> Bool {
        let selectable = rows.filter(\.isSelectable)
        return !selectable.isEmpty && selectable.allSatisfy { model.selection.contains($0.id) }
    }

    private func toggleAll(_ rows: [CleanupItem]) {
        let ids = rows.filter(\.isSelectable).map(\.id)
        if allSelected(rows) { model.selection.subtract(ids) } else { model.selection.formUnion(ids) }
    }

    // MARK: Action bar

    private func actionBar(_ all: [CleanupItem]) -> some View {
        let selected = all.filter { model.selection.contains($0.id) && $0.isSelectable }
        return HStack(spacing: 14) {
            Menu {
                Button("Recommended") {
                    model.selection.subtract(all.map(\.id))
                    model.selection.formUnion(all.filter { $0.recommended && $0.isSelectable }.map(\.id))
                }
                Button("All Safe") { model.selection.formUnion(all.filter { $0.risk == .safe && $0.isSelectable }.map(\.id)) }
                Button("All") { model.selection.formUnion(all.filter(\.isSelectable).map(\.id)) }
                Divider()
                Button("None") { model.selection.subtract(all.map(\.id)) }
            } label: {
                Label("Select", systemImage: "checklist")
            }
            .menuStyle(.borderlessButton).fixedSize()
            Spacer()
            if selected.isEmpty {
                Text("Select items to clean").foregroundStyle(.secondary).transition(.opacity)
            } else {
                HStack(spacing: 6) {
                    Text("\(selected.count) selected").foregroundStyle(.secondary)
                        .contentTransition(.numericText(value: Double(selected.count)))
                    BytesText(bytes: selected.totalSize, font: .headline)
                }
                .transition(.opacity.combined(with: .move(edge: .trailing)))
            }
            Button {
                model.requestCleanup(selected)
            } label: {
                Label("Clean", systemImage: "trash")
            }
            .buttonStyle(PrimaryButtonStyle(colors: selected.contains { $0.risk == .caution } ? Theme.dangerColors : Theme.brandColors))
            .disabled(selected.isEmpty)
            .keyboardShortcut(.delete, modifiers: .command)
        }
        .padding(.leading, 16).padding(.trailing, 8).padding(.vertical, 8)
        .glassPanel(Capsule())
        .animation(Theme.spring, value: selected.count)
    }
}

struct ItemRow: View {
    @Environment(AppModel.self) private var model
    let item: CleanupItem
    @State private var hovering = false

    var body: some View {
        let selected = model.selection.contains(item.id)
        let findings = model.secretFindings[item.id]
        HStack(spacing: 12) {
            Button {
                if selected { model.selection.remove(item.id) } else { model.selection.insert(item.id) }
            } label: {
                CheckCircle(isOn: selected, tint: item.risk == .caution ? .orange : .accentColor, disabled: !item.isSelectable)
            }
            .buttonStyle(.plain)
            .disabled(!item.isSelectable)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(item.title).fontWeight(.medium).lineLimit(1)
                    RiskBadge(risk: item.risk, compact: true)
                    if let findings, !findings.isEmpty {
                        Tag(text: "\(findings.count) secret\(findings.count == 1 ? "" : "s")", color: .red)
                    }
                }
                HStack(spacing: 6) {
                    Text(item.subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                    ForEach(item.tags.prefix(3), id: \.self) { Tag(text: $0) }
                }
                if let blocked = item.blockedReason {
                    Label(blocked, systemImage: "pause.circle").font(.caption).foregroundStyle(.orange)
                }
            }
            Spacer(minLength: 12)
            VStack(alignment: .trailing, spacing: 3) {
                SizeText(bytes: item.size, font: .callout.weight(.semibold))
                if let date = item.lastModified {
                    Text(RelativeTime.age(of: date)).font(.caption2).foregroundStyle(.tertiary)
                }
            }
            .frame(minWidth: 80, alignment: .trailing)
        }
        .padding(.vertical, 5)
        .padding(.horizontal, 6)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous)
            .fill(selected ? Color.accentColor.opacity(0.07) : Color.primary.opacity(hovering ? 0.04 : 0)))
        .opacity(item.isSelectable ? 1 : 0.6)
        .onHover { h in withAnimation(Theme.snappy) { hovering = h } }
        .animation(Theme.snappy, value: selected)
        .contextMenu {
            Button("Reveal in Finder") { Finder.reveal(item.paths) }
            Button("Copy Path") { Finder.copy(item.paths.first ?? "") }
            Divider()
            Button("Always Ignore This Location") { if let p = item.paths.first { model.exclude(p) } }
        }
    }
}

struct ItemInspector: View {
    @Environment(AppModel.self) private var model
    let item: CleanupItem

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                VStack(alignment: .leading, spacing: 6) {
                    CategoryIcon(category: item.category, size: 36)
                    Text(item.title).font(.title3.weight(.semibold)).textSelection(.enabled)
                    SizeText(bytes: item.size, font: .title.weight(.bold))
                    if let count = item.itemCount { Text("\(count.formatted()) files").font(.caption).foregroundStyle(.secondary) }
                }
                HStack { RiskBadge(risk: item.risk); Text(item.risk.summary).font(.caption).foregroundStyle(.secondary) }
                if let blocked = item.blockedReason {
                    Label(blocked, systemImage: "pause.circle.fill").foregroundStyle(.orange).font(.callout)
                }

                section("What is it?") { Text(item.explanation).textSelection(.enabled) }
                if let regen = item.regenerate { section("Getting it back") { Text(regen).textSelection(.enabled) } }
                section("Removal") {
                    Label(item.method.label, systemImage: item.method.isUndoable ? "arrow.uturn.backward.circle" : "exclamationmark.octagon")
                        .foregroundStyle(item.method.isUndoable ? Color.secondary : Color.red)
                    if case .manual(let instructions) = item.method { Text(instructions).font(.callout) }
                }
                if !item.tags.isEmpty {
                    FlowTags(tags: item.tags)
                }
                if let date = item.lastModified {
                    section("Last used") { Text("\(date.formatted(date: .abbreviated, time: .shortened)) (\(RelativeTime.string(since: date)))") }
                }

                if let findings = model.secretFindings[item.id] {
                    section(findings.isEmpty ? "Secrets audit: clean" : "Credentials found") {
                        if findings.isEmpty {
                            Label("No API keys or tokens found.", systemImage: "checkmark.shield").foregroundStyle(.green)
                        } else {
                            Text("Rotate these keys, then archive or delete the logs.").font(.caption).foregroundStyle(.red)
                            ForEach(findings.prefix(30)) { f in
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(f.kind).font(.caption.weight(.semibold))
                                    Text("\(f.redacted)  ·  \(Paths.name(f.file)):\(f.line)").font(.caption.monospaced()).foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                }
                if item.category == .aiSessions, item.paths.count > 0, item.paths.allSatisfy({ $0.hasSuffix(".jsonl") }) {
                    let previews = item.paths.prefix(3).compactMap { AISessionAnalyzer.preview(of: $0) }
                    if !previews.isEmpty {
                        section("Conversation previews") {
                            ForEach(previews, id: \.self) { Text("“\($0)”").font(.caption).foregroundStyle(.secondary) }
                        }
                    }
                }

                if let path = item.paths.first {
                    if let ai = model.aiExplanations[path] {
                        section("Local AI explanation") { Text(ai).textSelection(.enabled) }
                    }
                    if model.settings.ai.ollamaEnabled {
                        Button {
                            model.explainWithAI(path: path, size: item.size)
                        } label: {
                            if model.explaining.contains(path) { ProgressView().controlSize(.small) } else {
                                Label("Explain with Local AI", systemImage: "brain")
                            }
                        }
                    }
                }

                section(item.paths.count == 1 ? "Location" : "\(item.paths.count) locations") {
                    ForEach(item.paths.prefix(12), id: \.self) { p in
                        Text(Paths.abbreviate(p)).font(.caption.monospaced()).textSelection(.enabled).lineLimit(2)
                    }
                    if item.paths.count > 12 { Text("and \(item.paths.count - 12) more").font(.caption).foregroundStyle(.secondary) }
                }
                HStack {
                    if !item.paths.isEmpty {
                        Button("Reveal in Finder") { Finder.reveal(item.paths) }
                    }
                    Button("Clean…") { model.requestCleanup([item]) }.disabled(!item.isSelectable)
                }
            }
            .padding(18)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func section<C: View>(_ title: String, @ViewBuilder content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title).font(.caption.weight(.semibold)).foregroundStyle(.secondary).textCase(.uppercase)
            content()
        }
    }
}

struct FlowTags: View {
    let tags: [String]

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack { ForEach(tags, id: \.self) { Tag(text: $0) } }
            VStack(alignment: .leading) { ForEach(tags, id: \.self) { Tag(text: $0) } }
        }
    }
}
