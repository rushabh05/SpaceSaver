import AppKit
import SpaceSaverCore
import SwiftUI

// A Dynamic Island for the Mac: a black shape that grows out of the notch to show scan and
// cleanup progress, short notifications, and (on hover) a small control center.

enum IslandMode: Equatable {
    case hidden, live, peek, expanded
}

@MainActor
@Observable
final class IslandState {
    var hovering = false
    var notch = CGSize(width: 200, height: 32)
    var hasNotch = true
    var confirmingClean = false
}

@MainActor
enum IslandLayout {
    static let earWidth: CGFloat = 78
    static let expandedWidth: CGFloat = 470
    static let expandedBody: CGFloat = 146
    static let peekBody: CGFloat = 54

    static var showsFree: Bool { UserDefaults.standard.object(forKey: "islandShowsFree") as? Bool ?? false }
    static var lowDiskAlerts: Bool { UserDefaults.standard.object(forKey: "islandLowDisk") as? Bool ?? true }

    static func isLowDisk(_ model: AppModel) -> Bool {
        guard let disk = model.disk else { return false }
        return disk.free < 10_000_000_000 || disk.usedFraction > 0.95
    }

    static func hasLiveActivity(_ model: AppModel) -> Bool {
        model.isScanning || model.mapScanning || model.cleaning != nil || model.duplicatesScanning
            || (lowDiskAlerts && isLowDisk(model)) || showsFree
    }

    static func mode(_ model: AppModel, _ state: IslandState) -> IslandMode {
        if state.hovering { return .expanded }
        if model.islandPeek != nil { return .peek }
        if hasLiveActivity(model) { return .live }
        return .hidden
    }

    static func size(_ mode: IslandMode, notch: CGSize) -> CGSize {
        switch mode {
        case .hidden: return notch
        case .live: return CGSize(width: notch.width + earWidth * 2, height: notch.height)
        case .peek: return CGSize(width: max(notch.width + earWidth * 2, 400), height: notch.height + peekBody)
        case .expanded: return CGSize(width: max(expandedWidth, notch.width + 160), height: notch.height + expandedBody)
        }
    }
}

// MARK: - Controller

@MainActor
final class IslandController {
    static let shared = IslandController()

    let state = IslandState()
    private var panel: NSPanel?
    private var timer: Timer?
    private var leaveDeadline: Date?
    private weak var model: AppModel?
    private var screenObserver: NSObjectProtocol?
    /// Snapshot mode: hold the current state regardless of the pointer.
    var pinned = false

    static var isEnabled: Bool { UserDefaults.standard.object(forKey: "islandEnabled") as? Bool ?? true }
    static var expandsOnHover: Bool { UserDefaults.standard.object(forKey: "islandHover") as? Bool ?? true }

    func start(model: AppModel) {
        self.model = model
        guard Self.isEnabled, panel == nil else { return }

        let panel = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isFloatingPanel = true
        panel.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.mainMenuWindow)) + 2)
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.isMovable = false
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.title = "SpaceSaver Island"
        panel.appearance = NSAppearance(named: .darkAqua)

        let root = IslandView(state: state).environment(model)
        let host = NSHostingView(rootView: root)
        host.wantsLayer = true
        panel.contentView = host
        self.panel = panel
        reposition()
        panel.orderFrontRegardless()

        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.reposition() }
        }
        timer = Timer.scheduledTimer(withTimeInterval: 1.0 / 20, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.trackMouse() }
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        if let screenObserver { NotificationCenter.default.removeObserver(screenObserver) }
        panel?.orderOut(nil)
        panel = nil
        state.hovering = false
    }

    func setEnabled(_ on: Bool) {
        UserDefaults.standard.set(on, forKey: "islandEnabled")
        if on, let model { start(model: model) } else { stop() }
    }

    var islandWindow: NSWindow? { panel }

    /// The screen with a notch, else the main screen.
    private var screen: NSScreen? {
        NSScreen.screens.first { $0.safeAreaInsets.top > 0 } ?? NSScreen.main
    }

    private var panelSize: CGSize {
        CGSize(width: IslandLayout.expandedWidth + 60, height: state.notch.height + IslandLayout.expandedBody + 40)
    }

    func reposition() {
        guard let panel, let screen else { return }
        let top = screen.safeAreaInsets.top
        if top > 0, let left = screen.auxiliaryTopLeftArea, let right = screen.auxiliaryTopRightArea {
            state.notch = CGSize(width: screen.frame.width - left.width - right.width, height: top)
            state.hasNotch = true
        } else {
            let menuBar = screen.frame.maxY - screen.visibleFrame.maxY
            state.notch = CGSize(width: 190, height: max(menuBar, 24))
            state.hasNotch = false
        }
        let size = panelSize
        panel.setFrame(NSRect(x: screen.frame.midX - size.width / 2, y: screen.frame.maxY - size.height,
                              width: size.width, height: size.height), display: true)
    }

    private func trackMouse() {
        guard !pinned, let panel, let screen, let model else { return }
        let mouse = NSEvent.mouseLocation
        if !state.hovering && mouse.y < screen.frame.maxY - 260 { return }
        let mode = IslandLayout.mode(model, state)
        let size = IslandLayout.size(mode == .hidden && !state.hasNotch ? .live : mode, notch: state.notch)
        let margin: CGFloat = mode == .expanded ? 14 : 2
        let hot = NSRect(x: screen.frame.midX - size.width / 2 - margin, y: screen.frame.maxY - size.height - margin,
                         width: size.width + margin * 2, height: size.height + margin)
        let inside = hot.contains(mouse)

        if inside {
            leaveDeadline = nil
            if !state.hovering && Self.expandsOnHover {
                withAnimation(.spring(response: 0.44, dampingFraction: 0.78)) { state.hovering = true }
            }
        } else if state.hovering {
            if leaveDeadline == nil { leaveDeadline = Date().addingTimeInterval(0.35) }
            if let deadline = leaveDeadline, Date() > deadline {
                leaveDeadline = nil
                withAnimation(.spring(response: 0.42, dampingFraction: 0.86)) {
                    state.hovering = false
                    state.confirmingClean = false
                }
            }
        }
        if panel.ignoresMouseEvents == state.hovering { panel.ignoresMouseEvents = !state.hovering }
    }

    func collapse() {
        withAnimation(.spring(response: 0.42, dampingFraction: 0.86)) {
            state.hovering = false
            state.confirmingClean = false
        }
    }
}

// MARK: - Shape

/// The notch silhouette: concave "ears" where it meets the menu bar, rounded bottom corners.
struct NotchShape: Shape {
    var topRadius: CGFloat
    var bottomRadius: CGFloat

    var animatableData: AnimatablePair<CGFloat, CGFloat> {
        get { AnimatablePair(topRadius, bottomRadius) }
        set { topRadius = newValue.first; bottomRadius = newValue.second }
    }

    func path(in rect: CGRect) -> Path {
        let w = rect.width, h = rect.height
        let t = min(topRadius, w / 4), b = min(bottomRadius, h / 2, (w - 2 * t) / 2)
        var p = Path()
        p.move(to: CGPoint(x: 0, y: 0))
        p.addQuadCurve(to: CGPoint(x: t, y: t), control: CGPoint(x: t, y: 0))
        p.addLine(to: CGPoint(x: t, y: h - b))
        p.addQuadCurve(to: CGPoint(x: t + b, y: h), control: CGPoint(x: t, y: h))
        p.addLine(to: CGPoint(x: w - t - b, y: h))
        p.addQuadCurve(to: CGPoint(x: w - t, y: h - b), control: CGPoint(x: w - t, y: h))
        p.addLine(to: CGPoint(x: w - t, y: t))
        p.addQuadCurve(to: CGPoint(x: w, y: 0), control: CGPoint(x: w - t, y: 0))
        p.closeSubpath()
        return p
    }
}

// MARK: - Views

struct IslandView: View {
    @Environment(AppModel.self) private var model
    let state: IslandState

    var body: some View {
        let mode = IslandLayout.mode(model, state)
        let size = IslandLayout.size(mode, notch: state.notch)
        let ear: CGFloat = 9
        VStack(spacing: 0) {
            ZStack(alignment: .top) {
                NotchShape(topRadius: ear, bottomRadius: mode == .expanded ? 30 : mode == .peek ? 24 : 12)
                    .fill(Color.black)
                    .shadow(color: .black.opacity(mode == .hidden ? 0 : 0.4), radius: mode == .expanded ? 22 : 10, y: 6)
                content(mode)
                    .padding(.horizontal, ear)
            }
            .frame(width: size.width + ear * 2, height: size.height)
            .opacity(mode == .hidden ? 0 : 1)
            .environment(\.colorScheme, .dark)
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .animation(.spring(response: 0.44, dampingFraction: 0.8), value: mode)
        .animation(.spring(response: 0.44, dampingFraction: 0.8), value: model.islandPeek)
    }

    @ViewBuilder private func content(_ mode: IslandMode) -> some View {
        switch mode {
        case .hidden:
            Color.clear
        case .live:
            LiveEars(notch: state.notch)
                .transition(.blurReplace)
        case .peek:
            VStack(spacing: 0) {
                Color.clear.frame(height: state.notch.height)
                if let peek = model.islandPeek { PeekRow(peek: peek) }
            }
            .transition(.blurReplace)
        case .expanded:
            ExpandedIsland(state: state)
                .transition(.blurReplace.combined(with: .scale(0.92, anchor: .top)))
        }
    }
}

/// Status on either side of the notch while something is happening.
private struct LiveEars: View {
    @Environment(AppModel.self) private var model
    let notch: CGSize

    var body: some View {
        HStack(spacing: 0) {
            HStack { leftGlyph }.frame(width: IslandLayout.earWidth, alignment: .center)
            Spacer().frame(width: notch.width)
            HStack { rightText }.frame(width: IslandLayout.earWidth, alignment: .center)
        }
        .frame(height: notch.height)
    }

    @ViewBuilder private var leftGlyph: some View {
        if model.cleaning != nil {
            MiniRing(fraction: model.cleaning?.fraction ?? 0, colors: Theme.successColors)
        } else if model.isScanning {
            MiniRing(fraction: model.scanFraction, colors: Theme.brandColors, spinning: true)
        } else if model.mapScanning || model.duplicatesScanning {
            MiniRing(fraction: 0.3, colors: Theme.brandColors, spinning: true)
        } else if IslandLayout.isLowDisk(model) {
            Image(systemName: "externaldrive.fill.badge.exclamationmark")
                .font(.system(size: 13, weight: .semibold)).foregroundStyle(.red)
                .symbolEffect(.pulse, options: .repeat(3), isActive: true)
        } else {
            Image(systemName: "internaldrive.fill").font(.system(size: 12)).foregroundStyle(.white.opacity(0.75))
        }
    }

    @ViewBuilder private var rightText: some View {
        Group {
            if let cleaning = model.cleaning {
                Text("\(cleaning.done)/\(cleaning.total)").foregroundStyle(Theme.successColors[0])
            } else if model.isScanning {
                Text("\(Int(model.scanFraction * 100))%").foregroundStyle(Theme.brandColors[0].mix(.white, 0.3))
            } else if model.mapScanning {
                Text(compactCount(model.mapProgress.files)).foregroundStyle(.white.opacity(0.85))
            } else if model.duplicatesScanning {
                Text("dupes").foregroundStyle(.white.opacity(0.85))
            } else if let disk = model.disk {
                Text(ByteFormat.compact(disk.free)).foregroundStyle(IslandLayout.isLowDisk(model) ? .red : .white.opacity(0.85))
            }
        }
        .font(.system(size: 12, weight: .semibold, design: .rounded).monospacedDigit())
        .contentTransition(.numericText())
    }

    private func compactCount(_ n: Int) -> String {
        n >= 1_000_000 ? String(format: "%.1fM", Double(n) / 1e6) : n >= 1000 ? "\(n / 1000)k" : "\(n)"
    }
}

private struct MiniRing: View {
    var fraction: Double
    var colors: [Color]
    var spinning = false

    var body: some View {
        TimelineView(.animation(paused: !spinning)) { tl in
            let angle = spinning ? tl.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 1.2) / 1.2 * 360 : 0
            ZStack {
                Circle().stroke(.white.opacity(0.15), lineWidth: 2.6)
                Circle()
                    .trim(from: 0, to: max(fraction, spinning ? 0.25 : 0.02))
                    .stroke(LinearGradient(colors: colors, startPoint: .top, endPoint: .bottom),
                            style: StrokeStyle(lineWidth: 2.6, lineCap: .round))
                    .rotationEffect(.degrees(-90 + angle))
            }
        }
        .frame(width: 15, height: 15)
        .animation(Theme.spring, value: fraction)
    }
}

private struct PeekRow: View {
    let peek: IslandPeek

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: peek.symbol)
                .font(.system(size: 20, weight: .semibold))
                .foregroundStyle(peek.tint)
                .symbolEffect(.bounce, value: peek.id)
            VStack(alignment: .leading, spacing: 1) {
                Text(peek.title).font(.system(size: 13, weight: .semibold)).foregroundStyle(.white)
                Text(peek.subtitle).font(.system(size: 11)).foregroundStyle(.white.opacity(0.6)).lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 22)
        .frame(height: IslandLayout.peekBody - 6)
    }
}

/// The hover panel: disk ring, safe-to-clean total, live progress and quick actions.
private struct ExpandedIsland: View {
    @Environment(AppModel.self) private var model
    let state: IslandState

    var body: some View {
        VStack(spacing: 0) {
            // Band beside the notch.
            HStack {
                HStack(spacing: 6) {
                    Image(systemName: "sparkles").foregroundStyle(Theme.brand)
                    Text("SpaceSaver").foregroundStyle(.white.opacity(0.9))
                }
                Spacer()
                if let disk = model.disk {
                    Text("\(Int(disk.usedFraction * 100))% used")
                        .foregroundStyle(disk.usedFraction > 0.9 ? .red : .white.opacity(0.6))
                }
            }
            .font(.system(size: 11.5, weight: .semibold))
            .padding(.horizontal, 22)
            .frame(height: state.notch.height)

            HStack(spacing: 18) {
                diskRing
                VStack(alignment: .leading, spacing: 3) {
                    if let disk = model.disk {
                        HStack(alignment: .firstTextBaseline, spacing: 5) {
                            BytesText(bytes: disk.free, font: .system(size: 24, weight: .bold, design: .rounded))
                                .foregroundStyle(.white)
                            Text("free").font(.system(size: 12)).foregroundStyle(.white.opacity(0.55))
                        }
                        Text("of \(ByteFormat.string(disk.total))").font(.system(size: 11)).foregroundStyle(.white.opacity(0.5))
                    }
                    if model.scan != nil {
                        HStack(spacing: 5) {
                            Circle().fill(Theme.success).frame(width: 7, height: 7)
                            BytesText(bytes: model.quickCleanItems.totalSize, font: .system(size: 12, weight: .semibold))
                                .foregroundStyle(Theme.successColors[0])
                            Text("safe to clean").font(.system(size: 12)).foregroundStyle(.white.opacity(0.6))
                        }
                        .padding(.top, 3)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 22)
            .padding(.top, 6)

            activity
                .padding(.horizontal, 20)
                .padding(.top, 14)
            Spacer(minLength: 0)
        }
    }

    private var diskRing: some View {
        let disk = model.disk
        let total = Double(disk?.total ?? 1)
        let safe = Double(min(model.quickCleanItems.totalSize, disk?.used ?? 0))
        return RingGauge(segments: [
            RingSegment(id: "used", value: Double(disk?.used ?? 0) - safe, colors: Theme.brandColors),
            RingSegment(id: "safe", value: safe, colors: Theme.successColors),
        ], total: total, lineWidth: 7, scanning: model.isScanning) {
            Image(systemName: "internaldrive.fill").font(.system(size: 16)).foregroundStyle(.white.opacity(0.8))
        }
        .frame(width: 66, height: 66)
    }

    @ViewBuilder private var activity: some View {
        if let cleaning = model.cleaning {
            ProgressRow(title: "Cleaning \(cleaning.title)", fraction: cleaning.fraction, colors: Theme.successColors,
                        trailing: "\(cleaning.done)/\(cleaning.total)", stop: nil)
        } else if model.isScanning {
            ProgressRow(title: model.scanPhase, fraction: model.scanFraction, colors: Theme.brandColors,
                        trailing: "\(Int(model.scanFraction * 100))%") { model.cancelScan() }
        } else if model.mapScanning {
            ProgressRow(title: "Mapping \(Paths.abbreviate(model.mapRootPath))", fraction: nil, colors: Theme.brandColors,
                        trailing: ByteFormat.compact(model.mapProgress.bytes)) { model.cancelMapScan() }
        } else if let plan = model.pendingPlans.first {
            HStack(spacing: 10) {
                Image(systemName: "person.badge.shield.checkmark").foregroundStyle(.purple)
                Text("\(plan.requester) wants \(ByteFormat.compact(plan.totalSize))")
                    .font(.system(size: 12, weight: .medium)).foregroundStyle(.white).lineLimit(1)
                Spacer()
                Button("Review") { open(.approvals) }.buttonStyle(IslandButtonStyle(prominent: true, colors: [.purple, .indigo]))
            }
        } else {
            actions
        }
    }

    private var actions: some View {
        HStack(spacing: 8) {
            let items = model.quickCleanItems
            Button {
                if state.confirmingClean {
                    state.confirmingClean = false
                    Task { _ = await model.performCleanup(CleanupRequest(items: items, title: "Quick Clean")) { _, _, _ in } }
                } else {
                    withAnimation(Theme.bouncy) { state.confirmingClean = true }
                    Task {
                        try? await Task.sleep(for: .seconds(4))
                        withAnimation(Theme.snappy) { state.confirmingClean = false }
                    }
                }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: state.confirmingClean ? "trash.fill" : "bolt.fill")
                    Text(state.confirmingClean ? "Move \(ByteFormat.compact(items.totalSize)) to Trash?" : "Quick Clean")
                        .contentTransition(.interpolate)
                }
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(IslandButtonStyle(prominent: true, colors: state.confirmingClean ? Theme.dangerColors : Theme.successColors))
            .disabled(items.isEmpty)

            Button { model.startScan() } label: { Image(systemName: "arrow.clockwise") }
                .buttonStyle(IslandButtonStyle())
                .help("Scan again")
            Button { open(.overview) } label: { Image(systemName: "arrow.up.right") }
                .buttonStyle(IslandButtonStyle())
                .help("Open SpaceSaver")
        }
    }

    private func open(_ section: SidebarSection) {
        IslandController.shared.collapse()
        model.openMainWindow(section: section)
    }
}

private struct ProgressRow: View {
    var title: String
    var fraction: Double?
    var colors: [Color]
    var trailing: String
    var stop: (() -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack {
                Text(title).font(.system(size: 12, weight: .medium)).foregroundStyle(.white.opacity(0.85)).lineLimit(1)
                Spacer()
                Text(trailing).font(.system(size: 11.5, weight: .semibold).monospacedDigit()).foregroundStyle(.white.opacity(0.6))
                    .contentTransition(.numericText())
                if let stop {
                    Button(action: stop) { Image(systemName: "stop.fill") }.buttonStyle(IslandButtonStyle(compact: true))
                }
            }
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(.white.opacity(0.12))
                    if let fraction {
                        Capsule().fill(LinearGradient(colors: colors, startPoint: .leading, endPoint: .trailing))
                            .frame(width: max(geo.size.width * fraction, 6))
                            .shimmer()
                    } else {
                        Capsule().fill(LinearGradient(colors: colors, startPoint: .leading, endPoint: .trailing))
                            .frame(width: geo.size.width * 0.3)
                            .shimmer()
                    }
                }
            }
            .frame(height: 6)
            .animation(Theme.spring, value: fraction)
        }
    }
}

struct IslandButtonStyle: ButtonStyle {
    var prominent = false
    var colors: [Color] = Theme.successColors
    var compact = false

    func makeBody(configuration: Configuration) -> some View {
        StyledLabel(configuration: configuration, style: self)
    }

    private struct StyledLabel: View {
        let configuration: Configuration
        let style: IslandButtonStyle
        @Environment(\.isEnabled) private var isEnabled
        @State private var hovering = false

        var body: some View {
            configuration.label
                .font(.system(size: style.compact ? 9 : 12, weight: .semibold))
                .symbolRenderingMode(.monochrome)
                .foregroundStyle(.white)
                .padding(.horizontal, style.compact ? 7 : 14)
                .frame(height: style.compact ? 20 : 32)
                .background {
                    if style.prominent {
                        Capsule().fill(LinearGradient(colors: style.colors, startPoint: .leading, endPoint: .trailing))
                            .overlay(Capsule().fill(.white.opacity(hovering ? 0.15 : 0)))
                    } else {
                        Capsule().fill(.white.opacity(hovering ? 0.2 : 0.11))
                    }
                }
                .scaleEffect(configuration.isPressed ? 0.94 : hovering ? 1.03 : 1)
                .opacity(isEnabled ? 1 : 0.4)
                .animation(Theme.snappy, value: hovering)
                .animation(Theme.snappy, value: configuration.isPressed)
                .onHover { hovering = $0 && isEnabled }
                .contentShape(Capsule())
        }
    }
}
