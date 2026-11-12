import SpaceSaverCore
import SwiftUI

// MARK: - Squarified treemap layout (Bruls, Huizing & van Wijk)

enum Treemap {
    /// Lays out `values` (largest first) inside `rect`, returning one rect per value.
    static func squarify(_ values: [Double], in rect: CGRect) -> [CGRect] {
        var result = [CGRect](repeating: .zero, count: values.count)
        let total = values.reduce(0, +)
        guard total > 0, rect.width > 1, rect.height > 1 else { return result }
        let scale = Double(rect.width * rect.height) / total
        let areas = values.map { $0 * scale }
        var remaining = rect
        var start = 0

        func worst(_ sum: Double, _ minA: Double, _ maxA: Double, _ side: Double) -> Double {
            let s2 = side * side, sum2 = sum * sum
            return max(s2 * maxA / sum2, sum2 / (s2 * minA))
        }

        while start < areas.count {
            if areas[start] <= 0 { start += 1; continue }
            let side = Double(min(remaining.width, remaining.height))
            var end = start + 1
            var sum = areas[start], minA = areas[start], maxA = areas[start]
            var best = worst(sum, minA, maxA, side)
            while end < areas.count, areas[end] > 0 {
                let a = areas[end]
                let candidate = worst(sum + a, min(minA, a), max(maxA, a), side)
                if candidate > best { break }
                sum += a; minA = min(minA, a); maxA = max(maxA, a); best = candidate
                end += 1
            }
            let thickness = CGFloat(sum / side)
            if remaining.width >= remaining.height {
                var y = remaining.minY
                for i in start..<end {
                    let h = CGFloat(areas[i]) / thickness
                    result[i] = CGRect(x: remaining.minX, y: y, width: thickness, height: h)
                    y += h
                }
                remaining = CGRect(x: remaining.minX + thickness, y: remaining.minY,
                                   width: max(remaining.width - thickness, 0), height: remaining.height)
            } else {
                var x = remaining.minX
                for i in start..<end {
                    let w = CGFloat(areas[i]) / thickness
                    result[i] = CGRect(x: x, y: remaining.minY, width: w, height: thickness)
                    x += w
                }
                remaining = CGRect(x: remaining.minX, y: remaining.minY + thickness,
                                   width: remaining.width, height: max(remaining.height - thickness, 0))
            }
            start = end
        }
        return result
    }

    struct Tile {
        var rect: CGRect
        var node: FileNode
        var depth: Int
        var color: Color
        var showsLabel: Bool
    }

    static let palette: [Color] = [
        Color(hue: 0.60, saturation: 0.55, brightness: 0.90), Color(hue: 0.08, saturation: 0.60, brightness: 0.95),
        Color(hue: 0.38, saturation: 0.50, brightness: 0.78), Color(hue: 0.78, saturation: 0.45, brightness: 0.88),
        Color(hue: 0.52, saturation: 0.60, brightness: 0.80), Color(hue: 0.95, saturation: 0.50, brightness: 0.92),
        Color(hue: 0.14, saturation: 0.65, brightness: 0.92), Color(hue: 0.68, saturation: 0.40, brightness: 0.85),
        Color(hue: 0.45, saturation: 0.45, brightness: 0.75), Color(hue: 0.02, saturation: 0.45, brightness: 0.85),
    ]

    static func tiles(for node: FileNode, in bounds: CGRect) -> [Tile] {
        var tiles: [Tile] = []
        let children = Array(node.children.prefix(250).filter { $0.size > 0 })
        let rects = squarify(children.map { Double($0.size) }, in: bounds)
        for (i, (child, rect)) in zip(children, rects).enumerated() where rect.width >= 1 && rect.height >= 1 {
            let base = child.kind == .aggregate ? Color.gray.opacity(0.55) : palette[i % palette.count]
            tiles.append(Tile(rect: rect, node: child, depth: 0, color: base,
                              showsLabel: rect.width > 54 && rect.height > 30))
            // One nested level for folders big enough to read.
            guard child.isDirectory, rect.width > 70, rect.height > 52, !child.children.isEmpty else { continue }
            let inner = rect.insetBy(dx: 3, dy: 3).offsetBy(dx: 0, dy: 8).insetBy(dx: 0, dy: 8)
            let grandchildren = Array(child.children.prefix(60).filter { $0.size > 0 })
            let innerRects = squarify(grandchildren.map { Double($0.size) }, in: CGRect(
                x: inner.minX, y: inner.minY, width: inner.width, height: inner.height))
            for (j, (g, r)) in zip(grandchildren, innerRects).enumerated() where r.width >= 2 && r.height >= 2 {
                let shade = g.kind == .aggregate ? Color.gray.opacity(0.35)
                    : base.opacity(0.55 + 0.35 * Double((j % 4)) / 4)
                tiles.append(Tile(rect: r, node: g, depth: 1, color: shade, showsLabel: r.width > 64 && r.height > 26))
            }
        }
        return tiles
    }
}

struct TreemapView: View {
    let node: FileNode
    @Binding var hovered: FileNode?
    var onOpen: (FileNode) -> Void

    @State private var tiles: [Treemap.Tile] = []
    @State private var size: CGSize = .zero

    var body: some View {
        GeometryReader { geo in
            Canvas { context, _ in
                for tile in tiles {
                    let path = Path(roundedRect: tile.rect.insetBy(dx: 0.75, dy: 0.75), cornerRadius: tile.depth == 0 ? 5 : 3)
                    context.fill(path, with: .color(tile.color))
                    if tile.node === hovered {
                        context.stroke(path, with: .color(.white), lineWidth: 2.5)
                    }
                    if tile.showsLabel {
                        let name = Text(tile.node.displayName).font(.system(size: tile.depth == 0 ? 11 : 10, weight: tile.depth == 0 ? .semibold : .regular))
                            .foregroundColor(.white)
                        let sizeLabel = Text(ByteFormat.compact(tile.node.size)).font(.system(size: 9.5).monospacedDigit())
                            .foregroundColor(.white.opacity(0.85))
                        var c = context
                        c.clip(to: Path(tile.rect.insetBy(dx: 4, dy: 2)))
                        c.draw(name, at: CGPoint(x: tile.rect.minX + 5, y: tile.rect.minY + 3), anchor: .topLeading)
                        if tile.depth == 1 || tile.node.children.isEmpty {
                            c.draw(sizeLabel, at: CGPoint(x: tile.rect.minX + 5, y: tile.rect.minY + 16), anchor: .topLeading)
                        } else {
                            c.draw(sizeLabel, at: CGPoint(x: tile.rect.maxX - 5, y: tile.rect.minY + 3), anchor: .topTrailing)
                        }
                    }
                }
            }
            .onAppear { relayout(geo.size) }
            .onChange(of: geo.size) { _, s in relayout(s) }
            .onChange(of: node) { _, _ in relayout(geo.size) }
            .onContinuousHover { phase in
                switch phase {
                case .active(let p): hovered = hit(p)
                case .ended: hovered = nil
                }
            }
            .onTapGesture(count: 1, coordinateSpace: .local) { p in
                if let n = hit(p) { onOpen(n.depth1Parent(in: node) ?? n) }
            }
        }
    }

    private func relayout(_ s: CGSize) {
        size = s
        tiles = Treemap.tiles(for: node, in: CGRect(origin: .zero, size: s))
    }

    private func hit(_ p: CGPoint) -> FileNode? {
        tiles.last { $0.rect.contains(p) }?.node
    }
}

private extension FileNode {
    /// For a click on a nested tile, open the nested folder itself if it's a folder; otherwise its parent tile.
    func depth1Parent(in root: FileNode) -> FileNode? {
        if isDirectory { return self }
        return parent === root ? nil : parent
    }
}

// MARK: - Storage map screen

struct StorageMapView: View {
    @Environment(AppModel.self) private var model
    @State private var hovered: FileNode?
    @State private var showChanges = false
    @State private var selectedChild: FileNode?

    var body: some View {
        VStack(spacing: 0) {
            topBar
            Divider()
            if model.mapScanning {
                scanningView
            } else if let current = model.mapCurrent {
                breadcrumb(current)
                Divider()
                HSplitView {
                    TreemapView(node: current, hovered: $hovered) { open($0) }
                        .id(current.id)
                        .transition(.asymmetric(insertion: .scale(scale: 0.94).combined(with: .opacity), removal: .opacity))
                        .padding(8)
                        .frame(minWidth: 420)
                        .contextMenu { nodeMenu(hovered) }
                    childList(current).frame(minWidth: 260, idealWidth: 320, maxWidth: 420)
                }
                Divider()
                statusBar(current)
            } else {
                EmptyStateView(symbol: "square.grid.3x3.square", title: "See where your space goes",
                               message: "Scan a folder to get an interactive map of everything in it. Click a block to zoom in. SpaceSaver remembers each scan and shows what grew since the last one.",
                               action: ("Scan Home Folder", { model.startMapScan(path: NSHomeDirectory()) }))
            }
        }
        .navigationTitle("Storage Map")
        .sheet(isPresented: $showChanges) { GrowthSheet() }
    }

    private var topBar: some View {
        HStack(spacing: 10) {
            Menu {
                Button("Home Folder") { model.startMapScan(path: NSHomeDirectory()) }
                Button("Macintosh HD") { model.startMapScan(path: "/") }
                Button("Developer Folder (~/Library/Developer)") { model.startMapScan(path: Paths.expand("~/Library/Developer")) }
                Divider()
                Button("Choose Folder…") {
                    if let p = Finder.chooseFolder(message: "Choose a folder to map") { model.startMapScan(path: p) }
                }
            } label: {
                Label(Paths.abbreviate(model.mapRootPath), systemImage: "folder")
            }
            .fixedSize()
            .disabled(model.mapScanning)
            if model.mapScanning {
                Button("Stop") { model.cancelMapScan() }.buttonStyle(SoftButtonStyle(tint: .red))
            } else {
                Button { model.startMapScan() } label: { Label("Rescan", systemImage: "arrow.clockwise") }
                    .buttonStyle(SoftButtonStyle())
            }
            Spacer()
            if let date = model.previousSnapshotDate, !model.mapScanning {
                Button {
                    showChanges = true
                } label: {
                    Label("Changes since \(date.formatted(date: .abbreviated, time: .omitted))", systemImage: "chart.line.uptrend.xyaxis")
                }
                .disabled(model.growth.isEmpty)
            }
            if let root = model.mapRoot, !model.mapScanning {
                Text("\(ByteFormat.string(root.size)) · \(root.fileCount.formatted()) files · \(String(format: "%.1f", model.mapDuration))s")
                    .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 10)
    }

    private var scanningView: some View {
        VStack(spacing: 14) {
            RingGauge(segments: [RingSegment(id: "found", value: 1, colors: Theme.brandColors)], total: 1,
                      lineWidth: 10, scanning: true) {
                Image(systemName: "square.grid.3x3.fill").font(.system(size: 26)).foregroundStyle(Theme.brand)
            }
            .frame(width: 110, height: 110)
            Text("Mapping \(Paths.abbreviate(model.mapRootPath))…").font(.title3.weight(.semibold))
            HStack(spacing: 22) {
                stat("\(model.mapProgress.files.formatted())", "files")
                stat("\(model.mapProgress.directories.formatted())", "folders")
                stat(ByteFormat.string(model.mapProgress.bytes), "found")
            }
            Text(Paths.abbreviate(model.mapProgress.current)).font(.caption.monospaced()).foregroundStyle(.secondary)
                .lineLimit(1).truncationMode(.middle).frame(maxWidth: 520)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func stat(_ value: String, _ label: String) -> some View {
        VStack {
            Text(value).font(.title2.weight(.semibold).monospacedDigit())
            Text(label).font(.caption).foregroundStyle(.secondary)
        }
    }

    private func breadcrumb(_ current: FileNode) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 2) {
                if current.parent != nil {
                    Button { model.mapCurrent = current.parent } label: { Image(systemName: "chevron.backward") }
                        .buttonStyle(.borderless).keyboardShortcut(.upArrow, modifiers: .command)
                        .padding(.trailing, 6)
                }
                ForEach(current.ancestors, id: \.id) { node in
                    Button(node.displayName) { model.mapCurrent = node }
                        .buttonStyle(.borderless)
                        .fontWeight(node === current ? .semibold : .regular)
                    if node !== current { Image(systemName: "chevron.right").font(.caption2).foregroundStyle(.tertiary) }
                }
            }
            .padding(.horizontal, 16).padding(.vertical, 6)
        }
    }

    private func childList(_ current: FileNode) -> some View {
        List(current.children.prefix(300), id: \.id, selection: $selectedChild) { child in
            HStack(spacing: 8) {
                Image(systemName: child.kind == .aggregate ? "doc.on.doc" : child.isDirectory ? (child.isPackage ? "shippingbox" : "folder.fill") : "doc")
                    .foregroundStyle(child.isDirectory ? Color.accentColor : .secondary).frame(width: 16)
                VStack(alignment: .leading, spacing: 3) {
                    HStack {
                        Text(child.displayName).lineLimit(1).truncationMode(.middle)
                        if child.isDenied { Image(systemName: "lock.fill").font(.caption2).foregroundStyle(.orange).help("No permission to read") }
                        Spacer()
                        SizeText(bytes: child.size, font: .caption.weight(.semibold))
                    }
                    ShareBar(fraction: current.size > 0 ? Double(child.size) / Double(current.size) : 0, height: 3)
                }
            }
            .tag(child)
            .contentShape(Rectangle())
            .onTapGesture(count: 2) { open(child) }
            .contextMenu { nodeMenu(child) }
        }
        .listStyle(.inset)
    }

    private func statusBar(_ current: FileNode) -> some View {
        let node = hovered ?? selectedChild ?? current
        let explanation = node.kind == .aggregate ? nil : KnowledgeBase().explain(node.path)
        return HStack(spacing: 10) {
            Text(node.kind == .aggregate ? "\(node.name) in \(Paths.abbreviate(node.parent?.path ?? ""))" : Paths.abbreviate(node.path))
                .font(.caption.monospaced()).lineLimit(1).truncationMode(.middle)
            Spacer()
            if let explanation, explanation.source != "Heuristic" || explanation.risk != .caution {
                RiskBadge(risk: explanation.risk, compact: true)
                Text(explanation.title).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            SizeText(bytes: node.size, font: .caption.weight(.semibold))
        }
        .padding(.horizontal, 16).padding(.vertical, 7)
        .background(.bar)
    }

    @ViewBuilder private func nodeMenu(_ node: FileNode?) -> some View {
        if let node, node.kind != .aggregate {
            Button(node.isDirectory ? "Open" : "Show") { open(node) }
            Button("Reveal in Finder") { Finder.reveal([node.path]) }
            Button("Copy Path") { Finder.copy(node.path) }
            if model.settings.ai.ollamaEnabled {
                Button("Explain with Local AI") {
                    model.explainWithAI(path: node.path, size: node.size)
                    model.show("Asking the local model about \(node.displayName)…")
                }
            }
            Divider()
            Button("Move to Trash…", role: .destructive) { model.trashNode(node) }
                .disabled(!SafetyGuard(excluded: model.settings.excludedPaths).isAllowed(node.path))
        }
    }

    private func open(_ node: FileNode) {
        if node.isDirectory && !node.children.isEmpty {
            withAnimation(.snappy(duration: 0.2)) { model.mapCurrent = node }
            selectedChild = nil
        } else if node.kind != .aggregate {
            selectedChild = node
        }
    }
}

struct GrowthSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 4) {
                Text("What changed").font(.title2.weight(.semibold))
                if let date = model.previousSnapshotDate {
                    Text("Since the scan on \(date.formatted(date: .abbreviated, time: .shortened))").foregroundStyle(.secondary)
                }
            }
            .padding(20)
            Divider()
            List(model.growth) { entry in
                HStack {
                    Image(systemName: entry.delta > 0 ? "arrow.up.right" : "arrow.down.right")
                        .foregroundStyle(entry.delta > 0 ? .red : .green)
                    VStack(alignment: .leading) {
                        Text(Paths.name(entry.path)).fontWeight(.medium)
                        Text(Paths.abbreviate(entry.path)).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                    }
                    Spacer()
                    VStack(alignment: .trailing) {
                        Text((entry.delta > 0 ? "+" : "−") + ByteFormat.string(abs(entry.delta)))
                            .font(.callout.weight(.semibold).monospacedDigit())
                            .foregroundStyle(entry.delta > 0 ? .red : .green)
                        Text("\(ByteFormat.compact(entry.before)) → \(ByteFormat.compact(entry.after))")
                            .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                    }
                }
                .contextMenu { Button("Reveal in Finder") { Finder.reveal([entry.path]) } }
            }
            .frame(minHeight: 300)
            HStack { Spacer(); Button("Done") { dismiss() }.keyboardShortcut(.defaultAction) }.padding(16)
        }
        .frame(width: 560)
    }
}
