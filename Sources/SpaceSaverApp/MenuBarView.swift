import SpaceSaverCore
import SwiftUI

struct MenuBarView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow
    @State private var confirming = false
    @State private var result: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 8) {
                Image(systemName: "sparkles").foregroundStyle(Theme.brand)
                Text("SpaceSaver").font(.headline)
                Spacer()
                if let disk = model.disk {
                    Text(disk.volumeName).font(.caption).foregroundStyle(.secondary)
                }
            }

            if let disk = model.disk { diskSummary(disk) }

            if let cleaning = model.cleaning {
                progress("Cleaning \(cleaning.title)", cleaning.fraction, Theme.successColors)
            } else if model.isScanning {
                progress(model.scanPhase, model.scanFraction, Theme.brandColors)
            } else if model.scan != nil {
                quickClean
            } else {
                Button { model.startScan() } label: {
                    Label("Scan This Mac", systemImage: "sparkle.magnifyingglass").frame(maxWidth: .infinity)
                }
                .buttonStyle(PrimaryButtonStyle(large: true, shimmer: true))
            }

            if let result {
                Label(result, systemImage: "checkmark.circle.fill").font(.caption).foregroundStyle(.green)
                    .transition(.blurReplace)
            }

            if !model.pendingPlans.isEmpty {
                Button { open(.approvals) } label: {
                    HStack {
                        Image(systemName: "person.badge.shield.checkmark.fill").foregroundStyle(.purple)
                        Text("\(model.pendingPlans.count) agent request\(model.pendingPlans.count == 1 ? "" : "s") waiting")
                        Spacer()
                        Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary)
                    }
                    .padding(10)
                    .surface(radius: 10, tint: .purple)
                }
                .buttonStyle(.plain)
            }
            if model.heldInTrash > 0 {
                HStack {
                    Image(systemName: "trash").foregroundStyle(.secondary)
                    Text("\(ByteFormat.string(model.heldInTrash)) in Trash from cleanups").font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button("Free") { model.purge() }.buttonStyle(SoftButtonStyle(tint: .red, compact: true))
                }
            }

            Divider()
            HStack(spacing: 4) {
                Button { open(.overview) } label: { Label("Open SpaceSaver", systemImage: "macwindow") }
                    .buttonStyle(SoftButtonStyle(compact: true))
                Spacer()
                Button { model.startScan() } label: { Image(systemName: "arrow.clockwise") }
                    .buttonStyle(IconButtonStyle()).disabled(model.isScanning).help("Scan again")
                Button { NSApp.terminate(nil) } label: { Image(systemName: "power") }
                    .buttonStyle(IconButtonStyle()).help("Quit SpaceSaver")
            }
        }
        .padding(16)
        .frame(width: 320)
        .animation(Theme.spring, value: model.isScanning)
        .animation(Theme.spring, value: model.cleaning)
        .animation(Theme.spring, value: result)
        .task { model.start() }
    }

    private func diskSummary(_ disk: DiskStatus) -> some View {
        let safe = min(model.quickCleanItems.totalSize, disk.used)
        let critical = disk.usedFraction > 0.9
        return HStack(spacing: 16) {
            RingGauge(segments: [
                RingSegment(id: "used", value: Double(disk.used - safe), colors: critical ? Theme.dangerColors : Theme.brandColors),
                RingSegment(id: "safe", value: Double(safe), colors: Theme.successColors),
            ], total: Double(disk.total), lineWidth: 8, scanning: model.isScanning) {
                Text("\(Int(disk.usedFraction * 100))%").font(.system(size: 13, weight: .bold, design: .rounded))
            }
            .frame(width: 70, height: 70)
            VStack(alignment: .leading, spacing: 3) {
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    BytesText(bytes: disk.free, font: .system(size: 24, weight: .bold, design: .rounded))
                        .foregroundStyle(critical ? AnyShapeStyle(Theme.danger) : AnyShapeStyle(.primary))
                    Text("free").foregroundStyle(.secondary)
                }
                Text("of \(ByteFormat.string(disk.total))").font(.caption).foregroundStyle(.secondary)
                if safe > 0 {
                    HStack(spacing: 4) {
                        Circle().fill(Theme.success).frame(width: 6, height: 6)
                        BytesText(bytes: safe, font: .caption.weight(.semibold)).foregroundStyle(.green)
                        Text("safe to clean").font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    private var quickClean: some View {
        let items = model.quickCleanItems
        return VStack(alignment: .leading, spacing: 6) {
            Button {
                if confirming { run(items) } else {
                    withAnimation(Theme.bouncy) { confirming = true }
                    Task {
                        try? await Task.sleep(for: .seconds(4))
                        withAnimation(Theme.snappy) { confirming = false }
                    }
                }
            } label: {
                Label(confirming ? "Move \(ByteFormat.compact(items.totalSize)) to Trash?" : "Quick Clean \(ByteFormat.compact(items.totalSize))",
                      systemImage: confirming ? "trash.fill" : "wand.and.stars")
                    .frame(maxWidth: .infinity)
                    .contentTransition(.interpolate)
            }
            .buttonStyle(PrimaryButtonStyle(colors: confirming ? Theme.dangerColors : Theme.successColors, large: true))
            .disabled(items.isEmpty)
            Text(confirming ? "Click again to confirm. Restorable from Activity."
                 : "Safe items only, moved to the Trash. Scanned \(RelativeTime.string(since: model.scan?.date ?? Date())).")
                .font(.caption2).foregroundStyle(.tertiary)
                .contentTransition(.opacity)
        }
    }

    private func progress(_ title: String, _ fraction: Double, _ colors: [Color]) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack {
                Text(title).font(.callout).lineLimit(1)
                Spacer()
                Text("\(Int(fraction * 100))%").font(.callout.monospacedDigit().weight(.semibold))
                    .contentTransition(.numericText(value: fraction))
            }
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.primary.opacity(0.08))
                    Capsule().fill(LinearGradient(colors: colors, startPoint: .leading, endPoint: .trailing))
                        .frame(width: max(geo.size.width * fraction, 6))
                        .shimmer()
                }
            }
            .frame(height: 7)
            .animation(Theme.spring, value: fraction)
        }
    }

    private func run(_ items: [CleanupItem]) {
        confirming = false
        result = nil
        Task {
            let report = await model.performCleanup(CleanupRequest(items: items, title: "Quick Clean")) { _, _, _ in }
            result = "Moved \(ByteFormat.string(report.bytesCleaned)) to the Trash."
                + (report.errors.isEmpty ? "" : " \(report.errors.count) skipped.")
        }
    }

    private func open(_ section: SidebarSection) {
        model.openWindowAction = openWindow
        model.openMainWindow(section: section)
    }
}
