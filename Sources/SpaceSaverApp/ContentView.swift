import SpaceSaverCore
import SwiftUI

struct ContentView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow
    @State private var detailWidth: CGFloat = 1000

    var body: some View {
        @Bindable var model = model
        NavigationSplitView {
            Sidebar()
                .navigationSplitViewColumnWidth(min: 210, ideal: 248, max: 300)
        } detail: {
            ZStack {
                AppBackground()
                detail
                    .id(model.section)
                    .transition(.asymmetric(insertion: .opacity.combined(with: .offset(y: 10)), removal: .opacity))
            }
            // minWidth 0: report no minimum to the split view, so a narrow window shrinks each
            // screen (which then adapts) instead of squeezing the sidebar and spilling content.
            .frame(minWidth: 0, maxWidth: .infinity, minHeight: 0, maxHeight: .infinity)
            .clipped()
            .environment(\.contentWidth, detailWidth)
            .background {
                GeometryReader { geo in
                    Color.clear
                        .onAppear { detailWidth = geo.size.width }
                        .onChange(of: geo.size.width) { _, width in detailWidth = width }
                }
            }
            .animation(Theme.spring, value: model.section)
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) { ScanChip() }
        }
        .overlay(alignment: .bottom) {
            if let toast = model.toast {
                ToastView(toast: toast)
                    .padding(.bottom, 22)
                    .transition(.move(edge: .bottom).combined(with: .opacity).combined(with: .scale(0.9)))
                    .onTapGesture { withAnimation(Theme.snappy) { model.toast = nil } }
            }
        }
        .sheet(item: $model.cleanupRequest) { request in
            CleanupSheet(request: request)
        }
        .onAppear { model.openWindowAction = openWindow }
    }

    @ViewBuilder private var detail: some View {
        switch model.section {
        case .overview: OverviewView()
        case .storageMap: StorageMapView()
        case .category(let category): CategoryView(category: category)
        case .largeFiles: LargeFilesView()
        case .duplicates: DuplicatesView()
        case .apps: AppsView()
        case .activity: ActivityView()
        case .approvals: ApprovalsView()
        }
    }
}

/// Toolbar control: a Scan button that turns into a live progress chip.
struct ScanChip: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Group {
            if model.isScanning {
                HStack(spacing: 9) {
                    ZStack {
                        Circle().stroke(Color.primary.opacity(0.12), lineWidth: 2.5)
                        Circle().trim(from: 0, to: max(model.scanFraction, 0.04))
                            .stroke(Theme.brand, style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                            .rotationEffect(.degrees(-90))
                    }
                    .frame(width: 16, height: 16)
                    .animation(Theme.spring, value: model.scanFraction)
                    Text(model.scanPhase)
                        .font(.callout).foregroundStyle(.secondary).lineLimit(1)
                        .frame(maxWidth: 210, alignment: .leading)
                        .contentTransition(.opacity)
                    Button { model.cancelScan() } label: { Image(systemName: "xmark") }
                        .buttonStyle(IconButtonStyle(size: 20))
                        .help("Stop scanning")
                }
                .padding(.leading, 10).padding(.trailing, 4).padding(.vertical, 4)
                .transition(.blurReplace)
            } else {
                Button {
                    model.startScan()
                } label: {
                    Label("Scan", systemImage: "sparkle.magnifyingglass")
                }
                .help("Find reclaimable space (⌘R)")
                .transition(.blurReplace)
            }
        }
        .animation(Theme.spring, value: model.isScanning)
    }
}

struct Sidebar: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        List(selection: Binding(get: { model.section },
                                set: { s in if let s { withAnimation(Theme.spring) { model.section = s } } })) {
            Section {
                row(.overview, "Overview", "gauge.with.dots.needle.67percent", Theme.brandColors[0], nil)
                row(.storageMap, "Storage Map", "square.grid.3x3.fill", Color(red: 0.2, green: 0.6, blue: 0.95), nil)
                row(.apps, "Apps", CleanupCategory.apps.symbol, CleanupCategory.apps.color,
                    model.apps.isEmpty ? nil : model.apps.reduce(0) { $0 + $1.totalSize })
            }
            Section("Developer") {
                ForEach(CleanupCategory.allCases.filter { $0.group == .developer }) { categoryRow($0) }
            }
            Section("Cleanup") {
                categoryRow(.systemJunk)
                categoryRow(.appleDevices)
                categoryRow(.downloads)
                categoryRow(.leftovers)
                row(.largeFiles, "Large Files", CleanupCategory.largeFiles.symbol, CleanupCategory.largeFiles.color,
                    model.largeFiles.isEmpty ? nil : model.largeFiles.reduce(0) { $0 + $1.size })
                row(.duplicates, "Duplicates", CleanupCategory.duplicates.symbol, CleanupCategory.duplicates.color,
                    model.duplicateGroups.isEmpty ? nil : model.duplicateGroups.reduce(0) { $0 + $1.reclaimable })
                categoryRow(.trash)
                if !model.items(.custom).isEmpty { categoryRow(.custom) }
            }
            Section("History") {
                row(.activity, "Activity", "clock.arrow.circlepath", .teal, nil)
                HStack(spacing: 9) {
                    tile("person.badge.shield.checkmark", .purple)
                    Text("Agent Requests")
                    Spacer()
                    if !model.pendingPlans.isEmpty {
                        Text("\(model.pendingPlans.count)")
                            .font(.caption2.weight(.bold)).foregroundStyle(.white)
                            .padding(.horizontal, 6).padding(.vertical, 1.5)
                            .background(Capsule().fill(LinearGradient(colors: [.purple, .pink], startPoint: .leading, endPoint: .trailing)))
                            .transition(.scale.combined(with: .opacity))
                    }
                }
                .tag(SidebarSection.approvals)
            }
        }
        .listStyle(.sidebar)
        .safeAreaInset(edge: .bottom) { DiskFooter().padding(10) }
        .animation(Theme.spring, value: model.pendingPlans.count)
    }

    private func tile(_ symbol: String, _ color: Color) -> some View {
        Image(systemName: symbol)
            .font(.system(size: 10.5, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: 21, height: 21)
            .background(RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(LinearGradient(colors: [color.mix(.white, 0.1), color.mix(.black, 0.1)], startPoint: .top, endPoint: .bottom)))
    }

    private func row(_ section: SidebarSection, _ title: String, _ symbol: String, _ color: Color, _ size: Int64?) -> some View {
        HStack(spacing: 9) {
            tile(symbol, color)
            Text(title)
            Spacer()
            if let size, size > 0 { sizeBadge(size) }
        }
        .tag(section)
    }

    private func categoryRow(_ category: CleanupCategory) -> some View {
        HStack(spacing: 9) {
            tile(category.symbol, category.color)
            Text(category.title).lineLimit(1)
            Spacer()
            if model.isScanning && !model.scanFinished.contains(category) {
                ProgressView().controlSize(.mini).transition(.opacity)
            } else {
                let total = model.total(category)
                if total > 0 { sizeBadge(total).transition(.opacity.combined(with: .scale(0.8))) }
            }
        }
        .tag(SidebarSection.category(category))
        .animation(Theme.spring, value: model.scanFinished.contains(category))
    }

    private func sizeBadge(_ bytes: Int64) -> some View {
        Text(ByteFormat.compact(bytes))
            .font(.caption2.weight(.medium).monospacedDigit())
            .foregroundStyle(.secondary)
            .contentTransition(.numericText(value: Double(bytes)))
    }
}

struct DiskFooter: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        if let disk = model.disk {
            let critical = disk.usedFraction > 0.9
            HStack(spacing: 10) {
                ZStack {
                    Circle().stroke(Color.primary.opacity(0.1), lineWidth: 4)
                    Circle().trim(from: 0, to: disk.usedFraction)
                        .stroke(critical ? AnyShapeStyle(Theme.danger) : AnyShapeStyle(Theme.brand),
                                style: StrokeStyle(lineWidth: 4, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                }
                .frame(width: 30, height: 30)
                VStack(alignment: .leading, spacing: 1) {
                    Text(disk.volumeName).font(.caption.weight(.semibold))
                    HStack(spacing: 3) {
                        BytesText(bytes: disk.free, font: .caption2.weight(.semibold))
                            .foregroundStyle(critical ? .red : .primary)
                        Text("free").font(.caption2).foregroundStyle(.secondary)
                    }
                }
                Spacer()
                if critical { PulseDot(color: .red) }
            }
            .padding(10)
            .glassPanel(RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
    }
}

struct ToastView: View {
    let toast: Toast

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: toast.isError ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(toast.isError ? AnyShapeStyle(Theme.danger) : AnyShapeStyle(Theme.success))
                .symbolEffect(.bounce, value: toast.id)
            Text(toast.text).font(.callout.weight(.medium)).lineLimit(3)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
        .glassPanel(Capsule())
        .frame(maxWidth: 660)
    }
}
