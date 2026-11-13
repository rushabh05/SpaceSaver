import Charts
import SpaceSaverCore
import SwiftUI

struct OverviewView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.contentWidth) private var width

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                header.appear()
                if !model.hasFullDiskAccess { FullDiskAccessBanner().appear(delay: 0.04) }
                if !model.pendingPlans.isEmpty { PendingPlansBanner().appear(delay: 0.06) }
                if model.update != nil { UpdateBanner().appear(delay: 0.08) }

                HeroCard().appear(delay: 0.05)

                AdaptiveStack(stacked: width < 860) {
                    SmartCleanCard().frame(maxWidth: .infinity)
                    if model.scan != nil && !model.isScanning {
                        MakeRoomCard().frame(maxWidth: width < 860 ? .infinity : 320)
                    }
                }
                .appear(delay: 0.1)

                if model.scan != nil || model.isScanning {
                    categoryGrid
                }
                if !model.activity.isEmpty { recentActivity.appear(delay: 0.2) }
            }
            .padding(.horizontal, width < 640 ? 18 : 28)
            .padding(.vertical, 22)
            .frame(maxWidth: 1240)
            .frame(maxWidth: .infinity)
        }
        .scrollContentBackground(.hidden)
        .navigationTitle("Overview")
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 4) {
                Text(greeting).font(.system(size: 26, weight: .bold, design: .rounded))
                Text(subtitle).foregroundStyle(.secondary)
            }
            Spacer()
        }
    }

    private var greeting: String {
        let hour = Calendar.current.component(.hour, from: Date())
        return hour < 12 ? "Good morning" : hour < 18 ? "Good afternoon" : "Good evening"
    }

    private var subtitle: String {
        if model.isScanning { return "Looking through caches, projects and logs…" }
        guard let disk = model.disk else { return "" }
        if let scan = model.scan {
            return "\(ByteFormat.string(model.recommendedItems.totalSize)) can go safely. Last checked \(RelativeTime.string(since: scan.date))."
        }
        return disk.usedFraction > 0.9 ? "Your disk is almost full. Let's find some room." : "Let's see what's taking up space."
    }

    private var categoryGrid: some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(Array(CategoryGroup.allCases.enumerated()), id: \.element) { groupIndex, group in
                Text(group == .developer ? "Developer" : "System & Files")
                    .font(.title3.weight(.semibold))
                    .padding(.top, 8)
                    .appear(delay: 0.12 + Double(groupIndex) * 0.1)
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 230), spacing: 14)], spacing: 14) {
                    let categories = CleanupCategory.reclaimScanCategories.filter { $0.group == group && $0 != .custom }
                    ForEach(Array(categories.enumerated()), id: \.element) { index, category in
                        CategoryTile(category: category)
                            .appear(delay: 0.14 + Double(groupIndex) * 0.1 + Double(index) * 0.035)
                    }
                }
            }
        }
    }

    private var recentActivity: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Recent Activity").font(.title3.weight(.semibold))
                Spacer()
                Button("Show All") { withAnimation(Theme.spring) { model.section = .activity } }
                    .buttonStyle(SoftButtonStyle(compact: true))
            }
            Card(padding: 6) {
                VStack(spacing: 0) {
                    let recent = Array(model.activity.prefix(4))
                    ForEach(recent) { entry in
                        ActivityRow(entry: entry).padding(.horizontal, 12).padding(.vertical, 8)
                        if entry.id != recent.last?.id { Divider().padding(.horizontal, 12) }
                    }
                }
            }
        }
    }
}

// MARK: - Hero

private struct HeroCard: View {
    @Environment(AppModel.self) private var model
    @Environment(\.contentWidth) private var width

    var body: some View {
        let stacked = width < 760
        Card(padding: 24) {
            if let disk = model.disk {
                AdaptiveStack(stacked: stacked, spacing: stacked ? 20 : 34, alignment: .center) {
                    ring(disk).frame(width: stacked ? 180 : 214, height: stacked ? 180 : 214)
                        .frame(maxWidth: stacked ? .infinity : nil)
                    VStack(alignment: .leading, spacing: 16) {
                        HStack(spacing: 8) {
                            Image(systemName: "internaldrive.fill").foregroundStyle(.secondary)
                            Text(disk.volumeName).font(.headline)
                            Tag(text: disk.format)
                            if model.snapshotsCount > 0 {
                                Tag(text: "\(model.snapshotsCount) local snapshots", color: .blue)
                                    .help("Time Machine local snapshots. macOS removes them when space runs low, or run: tmutil thinlocalsnapshots / 999999999999 4")
                            }
                            Spacer()
                        }
                        legend(disk)
                        if model.samples.count >= 2 { trend }
                    }
                }
            } else {
                ProgressView().frame(maxWidth: .infinity, minHeight: 200)
            }
        }
    }

    private func numbers(_ disk: DiskStatus) -> (safe: Int64, review: Int64, other: Int64) {
        let safe = min(model.recommendedItems.totalSize, disk.used)
        let all = min(model.scan?.items.filter(\.isSelectable).totalSize ?? 0, disk.used)
        let review = max(all - safe, 0)
        return (safe, review, max(disk.used - safe - review, 0))
    }

    private func ring(_ disk: DiskStatus) -> some View {
        let n = numbers(disk)
        let critical = disk.usedFraction > 0.9
        return RingGauge(segments: [
            RingSegment(id: "used", value: Double(n.other), colors: critical ? [Theme.brandColors[0], Theme.brandColors[1]] : Theme.brandColors),
            RingSegment(id: "review", value: Double(n.review), colors: [.orange, Color(red: 1, green: 0.75, blue: 0.3)]),
            RingSegment(id: "safe", value: Double(n.safe), colors: Theme.successColors),
        ], total: Double(disk.total), lineWidth: 20, scanning: model.isScanning) {
            VStack(spacing: 2) {
                BytesText(bytes: disk.free, font: .system(size: 30, weight: .bold, design: .rounded))
                    .foregroundStyle(critical ? AnyShapeStyle(Theme.danger) : AnyShapeStyle(.primary))
                Text("free of \(ByteFormat.compact(disk.total))").font(.caption).foregroundStyle(.secondary)
                Text("\(Int(disk.usedFraction * 100))% used")
                    .font(.caption2.weight(.semibold))
                    .padding(.horizontal, 8).padding(.vertical, 3)
                    .background(Capsule().fill((critical ? Color.red : .accentColor).opacity(0.12)))
                    .foregroundStyle(critical ? .red : .accentColor)
                    .padding(.top, 4)
            }
        }
    }

    private func legend(_ disk: DiskStatus) -> some View {
        let n = numbers(disk)
        let total = Double(max(disk.total, 1))
        return VStack(spacing: 9) {
            legendRow("Used by files", n.other, Double(n.other) / total, Theme.brandColors[0])
            if model.scan != nil {
                legendRow("Needs review", n.review, Double(n.review) / total, .orange)
                legendRow("Safe to clean", n.safe, Double(n.safe) / total, Theme.successColors[0])
            }
            legendRow("Free", disk.free, Double(disk.free) / total, .gray)
            if disk.purgeable > 100_000_000 {
                legendRow("Purgeable by macOS", disk.purgeable, Double(disk.purgeable) / total, .teal)
            }
        }
    }

    private func legendRow(_ label: String, _ bytes: Int64, _ fraction: Double, _ color: Color) -> some View {
        HStack(spacing: 10) {
            Circle().fill(color).frame(width: 8, height: 8)
            Text(label).font(.callout).foregroundStyle(.secondary).lineLimit(1)
                .frame(minWidth: 90, idealWidth: 140, maxWidth: 140, alignment: .leading)
            ShareBar(fraction: fraction, color: color, height: 6).frame(minWidth: 40)
            BytesText(bytes: bytes, font: .callout.weight(.semibold)).lineLimit(1).frame(width: 84, alignment: .trailing)
        }
    }

    private var trend: some View {
        let cutoff = Date().addingTimeInterval(-30 * 86_400)
        let points = model.samples.filter { $0.date > cutoff }
        let span = (points.last?.date ?? Date()).timeIntervalSince(points.first?.date ?? Date())
        return VStack(alignment: .leading, spacing: 4) {
            Text("Free space history").font(.caption.weight(.medium)).foregroundStyle(.secondary)
            Chart(points, id: \.date) { s in
                AreaMark(x: .value("Date", s.date), y: .value("Free", Double(s.free) / 1e9))
                    .foregroundStyle(LinearGradient(colors: [Theme.brandColors[0].opacity(0.35), Theme.brandColors[1].opacity(0.02)],
                                                    startPoint: .top, endPoint: .bottom))
                    .interpolationMethod(.monotone)
                LineMark(x: .value("Date", s.date), y: .value("Free", Double(s.free) / 1e9))
                    .foregroundStyle(Theme.brand)
                    .lineStyle(StrokeStyle(lineWidth: 2, lineCap: .round))
                    .interpolationMethod(.monotone)
            }
            .chartYAxis { AxisMarks(position: .leading, values: .automatic(desiredCount: 3)) { v in
                AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5, dash: [3]))
                AxisValueLabel { if let d = v.as(Double.self) { Text("\(Int(d)) GB").font(.caption2) } }
            } }
            .chartXAxis { AxisMarks(values: .automatic(desiredCount: 4)) { _ in
                AxisValueLabel(format: span < 2 * 86_400 ? .dateTime.hour().minute() : .dateTime.month().day())
            } }
            .frame(height: 74)
        }
    }
}

// MARK: - Smart clean

private struct SmartCleanCard: View {
    @Environment(AppModel.self) private var model
    @Environment(\.contentWidth) private var width
    @State private var hoverButton = false

    /// The card's own width: full width when the Overview stacks it, otherwise beside Make Room.
    private var cardWidth: CGFloat { width < 860 ? width - 56 : width - 56 - 338 }
    private var sideBySide: Bool { cardWidth >= 640 }

    var body: some View {
        Card(padding: 22, tint: Theme.successColors[0]) {
            if model.isScanning {
                scanning
            } else if model.scan != nil {
                ready
            } else {
                firstRun
            }
        }
        .animation(Theme.spring, value: model.isScanning)
    }

    private var ready: some View {
        let items = model.recommendedItems
        return AdaptiveStack(stacked: !sideBySide, spacing: 22, alignment: .center) {
            VStack(alignment: .leading, spacing: 10) {
                Label("Smart Clean", systemImage: "wand.and.stars")
                    .font(.headline).foregroundStyle(Theme.success)
                BytesText(bytes: items.totalSize, font: .system(size: 42, weight: .bold, design: .rounded))
                    .lineLimit(1).minimumScaleFactor(0.6)
                    .foregroundStyle(Theme.success)
                Text("\(items.count) regenerable items: caches, dormant projects' build folders and installers you've used. Running apps and active projects are skipped.")
                    .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 10) {
                    Button {
                        model.requestCleanup(items, title: "Smart Clean \(ByteFormat.string(items.totalSize))?")
                    } label: {
                        Label("Review & Clean", systemImage: "sparkles")
                    }
                    .buttonStyle(PrimaryButtonStyle(colors: Theme.successColors, large: true, shimmer: true))
                    .disabled(items.isEmpty)
                    .keyboardShortcut(.return, modifiers: .command)
                    Button("Rescan") { model.startScan() }.buttonStyle(SoftButtonStyle(tint: .secondary))
                }
                .padding(.top, 4)
            }
            if sideBySide { Spacer(minLength: 0) }
            breakdown(items)
        }
    }

    /// Mini bar chart of where the recommended space comes from.
    private func breakdown(_ items: [CleanupItem]) -> some View {
        let byCategory = Dictionary(grouping: items, by: \.category).map { ($0.key, $0.value.totalSize) }
            .sorted { $0.1 > $1.1 }.prefix(5)
        let maxValue = Double(byCategory.first?.1 ?? 1)
        return VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(byCategory), id: \.0) { category, size in
                HStack(spacing: 8) {
                    Image(systemName: category.symbol).font(.caption).foregroundStyle(category.color).frame(width: 16)
                    Text(category.title).font(.caption).foregroundStyle(.secondary).frame(width: 118, alignment: .leading).lineLimit(1)
                    ShareBar(fraction: Double(size) / maxValue, color: category.color, height: 5).frame(width: 90)
                    Text(ByteFormat.compact(size)).font(.caption.monospacedDigit().weight(.medium)).frame(width: 58, alignment: .trailing)
                }
            }
        }
        .frame(width: 310)
    }

    private var scanning: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                PulseDot(color: Theme.brandColors[0])
                Text("Scanning").font(.headline)
                Text(model.scanPhase).foregroundStyle(.secondary).lineLimit(1).contentTransition(.opacity)
                Spacer()
                Button("Stop") { model.cancelScan() }.buttonStyle(SoftButtonStyle(tint: .red, compact: true))
            }
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 190), spacing: 10, alignment: .leading)], alignment: .leading, spacing: 9) {
                ForEach(CleanupCategory.reclaimScanCategories.filter { $0 != .custom }) { category in
                    let done = model.scanFinished.contains(category)
                    HStack(spacing: 8) {
                        ZStack {
                            if done {
                                Image(systemName: "checkmark.circle.fill").foregroundStyle(Theme.success)
                                    .transition(.scale.combined(with: .opacity))
                            } else {
                                ProgressView().controlSize(.mini).transition(.opacity)
                            }
                        }
                        .frame(width: 16)
                        Text(category.title).font(.callout).foregroundStyle(done ? .primary : .secondary)
                        if done, model.total(category) > 0 {
                            Text(ByteFormat.compact(model.total(category))).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                                .transition(.opacity)
                        }
                    }
                    .animation(Theme.bouncy, value: done)
                }
            }
            ProgressView(value: model.scanFraction).tint(Theme.brandColors[0])
                .animation(Theme.spring, value: model.scanFraction)
        }
    }

    private var firstRun: some View {
        HStack(spacing: 24) {
            ZStack {
                Circle().fill(Theme.brand.opacity(0.15)).frame(width: 110, height: 110)
                Image(systemName: "sparkle.magnifyingglass").font(.system(size: 44)).foregroundStyle(Theme.brand)
                    .symbolEffect(.pulse)
            }
            VStack(alignment: .leading, spacing: 10) {
                Text("Find what's filling your disk").font(.title2.weight(.bold))
                Text("SpaceSaver checks developer caches, build folders, AI models and logs, app caches and old downloads. Scanning only reads. Nothing is removed until you confirm.")
                    .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                Button {
                    model.startScan()
                } label: {
                    Label("Scan This Mac", systemImage: "sparkle.magnifyingglass")
                }
                .buttonStyle(PrimaryButtonStyle(large: true, shimmer: true))
                .padding(.top, 4)
            }
        }
    }
}

private struct MakeRoomCard: View {
    @Environment(AppModel.self) private var model
    @State private var gb: Double = 20

    var body: some View {
        let plan = model.roomPlan(gb: gb)
        Card(padding: 20) {
            VStack(alignment: .leading, spacing: 12) {
                Label("Make room for…", systemImage: "arrow.down.right.and.arrow.up.left")
                    .font(.headline)
                HStack(alignment: .firstTextBaseline) {
                    Text("\(Int(gb))").font(.system(size: 34, weight: .bold, design: .rounded).monospacedDigit())
                        .contentTransition(.numericText(value: gb))
                        .animation(Theme.snappy, value: gb)
                    Text("GB").font(.title3.weight(.semibold)).foregroundStyle(.secondary)
                }
                Slider(value: $gb, in: 5...150, step: 5).tint(Theme.brandColors[0])
                HStack(spacing: 6) {
                    Image(systemName: plan.satisfied ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                        .foregroundStyle(plan.satisfied ? .green : .orange)
                        .contentTransition(.symbolEffect(.replace))
                    Text(plan.satisfied ? "\(plan.items.count) items, safest first" : "Only \(ByteFormat.compact(plan.total)) without risky items")
                        .font(.caption).foregroundStyle(.secondary)
                        .contentTransition(.numericText())
                }
                Button {
                    model.requestCleanup(plan.items, title: plan.satisfied
                        ? "Free \(ByteFormat.string(plan.total)) for \(Int(gb)) GB?"
                        : "Only \(ByteFormat.string(plan.total)) available without risky items. Clean it?")
                } label: {
                    Text("Plan \(ByteFormat.compact(plan.total))").frame(maxWidth: .infinity)
                        .contentTransition(.numericText())
                }
                .buttonStyle(PrimaryButtonStyle())
                .disabled(plan.items.isEmpty)
            }
        }
        .animation(Theme.snappy, value: plan.items.count)
    }
}

// MARK: - Tiles and banners

struct CategoryTile: View {
    @Environment(AppModel.self) private var model
    let category: CleanupCategory

    var body: some View {
        let items = model.items(category)
        let total = model.total(category)
        let safe = items.filter { $0.recommended && $0.isSelectable }.totalSize
        let done = model.scanFinished.contains(category) || !model.isScanning
        Button {
            withAnimation(Theme.spring) { model.section = .category(category) }
        } label: {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    CategoryIcon(category: category, size: 34)
                    Spacer()
                    if !done {
                        ProgressView().controlSize(.small)
                    } else if safe > 0 {
                        Text("\(ByteFormat.compact(safe)) safe")
                            .font(.caption2.weight(.semibold))
                            .padding(.horizontal, 7).padding(.vertical, 3)
                            .background(Capsule().fill(Color.green.opacity(0.13)))
                            .foregroundStyle(.green)
                    }
                }
                Text(category.title).font(.headline).foregroundStyle(.primary)
                if total > 0 {
                    BytesText(bytes: total, font: .system(size: 22, weight: .bold, design: .rounded)).foregroundStyle(.primary)
                } else {
                    Text(done ? "Nothing found" : "Scanning…").font(.system(size: 15, weight: .medium)).foregroundStyle(.tertiary)
                        .frame(height: 28, alignment: .leading)
                }
                ShareBar(fraction: total > 0 ? Double(safe) / Double(total) : 0, color: .green, height: 4)
                Text(items.isEmpty ? category.blurb : "\(items.count) item\(items.count == 1 ? "" : "s") · \(Int(total > 0 ? Double(safe) / Double(total) * 100 : 0))% safe")
                    .font(.caption).foregroundStyle(.secondary).lineLimit(2, reservesSpace: true)
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .surface(radius: 16, tint: category.color, hoverLift: true)
            .contentShape(RoundedRectangle(cornerRadius: 16))
        }
        .buttonStyle(.plain)
    }
}

struct FullDiskAccessBanner: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: "lock.shield.fill").font(.title2).foregroundStyle(.orange)
                .symbolEffect(.pulse, options: .repeating)
            VStack(alignment: .leading, spacing: 2) {
                Text("Grant Full Disk Access for a complete scan").font(.headline)
                Text("Without it, macOS hides the Trash, Mail downloads, iOS backups and some app caches.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            Spacer()
            Button("Check Again") { model.refreshDisk() }.buttonStyle(SoftButtonStyle(tint: .secondary))
            Button("Open Settings") { NSWorkspace.shared.open(Permissions.fullDiskAccessSettingsURL) }
                .buttonStyle(PrimaryButtonStyle(colors: [.orange, Color(red: 1, green: 0.55, blue: 0.2)]))
        }
        .padding(16)
        .surface(radius: 16, tint: .orange)
    }
}

struct PendingPlansBanner: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let pending = model.pendingPlans
        HStack(spacing: 14) {
            Image(systemName: "person.badge.shield.checkmark.fill").font(.title2).foregroundStyle(.purple)
                .symbolEffect(.bounce, value: pending.count)
            VStack(alignment: .leading, spacing: 2) {
                Text("\(pending.count) cleanup request\(pending.count == 1 ? "" : "s") from AI agents").font(.headline)
                Text("\(pending.first?.requester ?? "An agent") wants to free \(ByteFormat.string(pending.reduce(0) { $0 + $1.totalSize })). Nothing happens until you approve.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            Spacer()
            Button("Review") { withAnimation(Theme.spring) { model.section = .approvals } }
                .buttonStyle(PrimaryButtonStyle(colors: [.purple, .pink]))
        }
        .padding(16)
        .surface(radius: 16, tint: .purple)
    }
}
