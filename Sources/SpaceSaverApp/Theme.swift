import AppKit
import SpaceSaverCore
import SwiftUI

// MARK: - Tokens

enum Theme {
    static let brandColors = [Color(red: 0.31, green: 0.51, blue: 1.00), Color(red: 0.56, green: 0.37, blue: 0.98)]
    static let successColors = [Color(red: 0.13, green: 0.80, blue: 0.56), Color(red: 0.07, green: 0.63, blue: 0.78)]
    static let dangerColors = [Color(red: 1.00, green: 0.36, blue: 0.36), Color(red: 0.96, green: 0.52, blue: 0.20)]

    static let brand = LinearGradient(colors: brandColors, startPoint: .topLeading, endPoint: .bottomTrailing)
    static let success = LinearGradient(colors: successColors, startPoint: .topLeading, endPoint: .bottomTrailing)
    static let danger = LinearGradient(colors: dangerColors, startPoint: .topLeading, endPoint: .bottomTrailing)

    static let spring = Animation.spring(response: 0.42, dampingFraction: 0.82)
    static let bouncy = Animation.spring(response: 0.38, dampingFraction: 0.62)
    static let snappy = Animation.snappy(duration: 0.22)

    static let surface = Color(nsColor: .controlBackgroundColor)
    static let canvas = Color(nsColor: .windowBackgroundColor)
}

// MARK: - Surfaces

/// Content card: solid surface, hairline border, soft shadow. Optional tint wash and hover lift.
struct SurfaceModifier: ViewModifier {
    var radius: CGFloat = 16
    var tint: Color?
    var hoverLift = false
    @State private var hovering = false

    func body(content: Content) -> some View {
        content
            .background {
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .fill(Theme.surface)
                    .overlay {
                        if let tint {
                            RoundedRectangle(cornerRadius: radius, style: .continuous)
                                .fill(LinearGradient(colors: [tint.opacity(hovering ? 0.16 : 0.09), tint.opacity(0.0)],
                                                     startPoint: .topLeading, endPoint: .bottomTrailing))
                        }
                    }
            }
            .overlay {
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .strokeBorder((hovering ? (tint ?? .accentColor).opacity(0.55) : Color.primary.opacity(0.08)), lineWidth: 1)
            }
            .shadow(color: .black.opacity(hovering ? 0.12 : 0.05), radius: hovering ? 16 : 8, y: hovering ? 8 : 3)
            .offset(y: hovering ? -2 : 0)
            .onHover { h in
                guard hoverLift else { return }
                withAnimation(Theme.snappy) { hovering = h }
            }
    }
}

extension View {
    func surface(radius: CGFloat = 16, tint: Color? = nil, hoverLift: Bool = false) -> some View {
        modifier(SurfaceModifier(radius: radius, tint: tint, hoverLift: hoverLift))
    }

    /// Floating chrome (action bars, chips, toasts): Liquid Glass on macOS 26, material before that.
    @ViewBuilder func glassPanel<S: Shape>(_ shape: S, tint: Color? = nil, interactive: Bool = false) -> some View {
        if #available(macOS 26.0, *) {
            self.glassEffect(Glass.regular.tint(tint?.opacity(0.35)).interactive(interactive), in: shape)
        } else {
            self.background(.regularMaterial, in: shape)
                .overlay(shape.stroke(Color.primary.opacity(0.08), lineWidth: 1))
                .shadow(color: .black.opacity(0.12), radius: 14, y: 6)
        }
    }

    func appear(delay: Double = 0, offset: CGFloat = 14) -> some View {
        modifier(AppearModifier(delay: delay, offset: offset))
    }

    func shimmer(_ active: Bool = true) -> some View { modifier(ShimmerModifier(active: active)) }
}

/// Fades and slides content in once, optionally staggered.
struct AppearModifier: ViewModifier {
    var delay: Double
    var offset: CGFloat
    @State private var shown = false

    func body(content: Content) -> some View {
        content
            .opacity(shown ? 1 : 0)
            .offset(y: shown ? 0 : offset)
            .scaleEffect(shown ? 1 : 0.985, anchor: .top)
            .onAppear { withAnimation(Theme.spring.delay(delay)) { shown = true } }
    }
}

/// A moving highlight, used on call-to-action buttons and while scanning.
struct ShimmerModifier: ViewModifier {
    var active: Bool

    func body(content: Content) -> some View {
        content.overlay {
            if active {
                TimelineView(.animation) { timeline in
                    let period = 2.6
                    let t = timeline.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: period) / period
                    GeometryReader { geo in
                        let band = geo.size.width * 0.35
                        LinearGradient(colors: [.clear, .white.opacity(0.32), .clear], startPoint: .leading, endPoint: .trailing)
                            .frame(width: band)
                            .offset(x: -band + (geo.size.width + band * 2) * t)
                            .blendMode(.plusLighter)
                    }
                }
                .mask(content)
                .allowsHitTesting(false)
            }
        }
    }
}

// MARK: - Buttons

/// Gradient capsule with glow, hover lift and press squish.
struct PrimaryButtonStyle: ButtonStyle {
    var colors: [Color] = Theme.brandColors
    var large = false
    var shimmer = false

    func makeBody(configuration: Configuration) -> some View {
        StyledLabel(configuration: configuration, style: self)
    }

    private struct StyledLabel: View {
        let configuration: Configuration
        let style: PrimaryButtonStyle
        @Environment(\.isEnabled) private var isEnabled
        @State private var hovering = false

        var body: some View {
            configuration.label
                .font(style.large ? .system(size: 14, weight: .semibold) : .system(size: 12.5, weight: .semibold))
                .symbolRenderingMode(.monochrome)
                .foregroundStyle(.white)
                .padding(.horizontal, style.large ? 20 : 14)
                .padding(.vertical, style.large ? 11 : 7)
                .background {
                    Capsule()
                        .fill(LinearGradient(colors: style.colors, startPoint: .topLeading, endPoint: .bottomTrailing))
                        .overlay(Capsule().fill(.white.opacity(hovering ? 0.12 : 0)))
                        .overlay(Capsule().strokeBorder(
                            LinearGradient(colors: [.white.opacity(0.45), .white.opacity(0.05)], startPoint: .top, endPoint: .bottom),
                            lineWidth: 1))
                }
                .shimmer(style.shimmer && isEnabled)
                .clipShape(Capsule())
                .shadow(color: (style.colors.first ?? .blue).opacity(isEnabled ? (hovering ? 0.5 : 0.3) : 0),
                        radius: hovering ? 14 : 8, y: hovering ? 6 : 3)
                .scaleEffect(configuration.isPressed ? 0.95 : (hovering ? 1.025 : 1))
                .saturation(isEnabled ? 1 : 0)
                .opacity(isEnabled ? 1 : 0.5)
                .animation(Theme.snappy, value: hovering)
                .animation(.spring(response: 0.25, dampingFraction: 0.6), value: configuration.isPressed)
                .onHover { hovering = $0 && isEnabled }
                .contentShape(Capsule())
        }
    }
}

/// Quiet tinted capsule for secondary actions.
struct SoftButtonStyle: ButtonStyle {
    var tint: Color = .accentColor
    var compact = false

    func makeBody(configuration: Configuration) -> some View {
        StyledLabel(configuration: configuration, style: self)
    }

    private struct StyledLabel: View {
        let configuration: Configuration
        let style: SoftButtonStyle
        @Environment(\.isEnabled) private var isEnabled
        @State private var hovering = false

        var body: some View {
            configuration.label
                .font(.system(size: style.compact ? 11.5 : 12.5, weight: .medium))
                .foregroundStyle(style.tint)
                .padding(.horizontal, style.compact ? 10 : 13)
                .padding(.vertical, style.compact ? 4 : 7)
                .background(Capsule().fill(style.tint.opacity(configuration.isPressed ? 0.24 : hovering ? 0.17 : 0.1)))
                .scaleEffect(configuration.isPressed ? 0.96 : 1)
                .opacity(isEnabled ? 1 : 0.45)
                .animation(Theme.snappy, value: hovering)
                .animation(Theme.snappy, value: configuration.isPressed)
                .onHover { hovering = $0 && isEnabled }
                .contentShape(Capsule())
        }
    }
}

/// Round icon button with a hover halo.
struct IconButtonStyle: ButtonStyle {
    var size: CGFloat = 28
    var tint: Color = .secondary

    func makeBody(configuration: Configuration) -> some View {
        StyledLabel(configuration: configuration, style: self)
    }

    private struct StyledLabel: View {
        let configuration: Configuration
        let style: IconButtonStyle
        @State private var hovering = false

        var body: some View {
            configuration.label
                .font(.system(size: style.size * 0.45, weight: .semibold))
                .foregroundStyle(hovering ? Color.primary : style.tint)
                .frame(width: style.size, height: style.size)
                .background(Circle().fill(Color.primary.opacity(hovering ? 0.1 : 0)))
                .scaleEffect(configuration.isPressed ? 0.88 : 1)
                .animation(Theme.snappy, value: hovering)
                .animation(Theme.snappy, value: configuration.isPressed)
                .onHover { hovering = $0 }
                .contentShape(Circle())
        }
    }
}

extension View {
    /// System glass buttons on macOS 26, soft tinted capsules before that.
    @ViewBuilder func glassButton(prominent: Bool = false, tint: Color = .accentColor) -> some View {
        if #available(macOS 26.0, *) {
            if prominent { self.buttonStyle(.glassProminent).tint(tint) } else { self.buttonStyle(.glass) }
        } else {
            self.buttonStyle(SoftButtonStyle(tint: tint))
        }
    }
}

// MARK: - Animated values

/// Byte counts that roll smoothly when they change.
struct BytesText: View {
    let bytes: Int64
    var font: Font = .body

    var body: some View {
        Text(ByteFormat.string(bytes))
            .font(font.monospacedDigit())
            .contentTransition(.numericText(value: Double(bytes)))
            .animation(Theme.spring, value: bytes)
    }
}

// MARK: - Ring gauge

struct RingSegment: Identifiable {
    var id: String
    var value: Double
    var colors: [Color]
}

/// Multi-segment donut that sweeps in on appear, with an optional radar sweep while scanning.
struct RingGauge<Center: View>: View {
    var segments: [RingSegment]
    var total: Double
    var lineWidth: CGFloat = 18
    var scanning = false
    @ViewBuilder var center: Center
    @State private var progress: Double = 0

    var body: some View {
        ZStack {
            Circle().stroke(Color.primary.opacity(0.07), lineWidth: lineWidth)
            ForEach(Array(placed.enumerated()), id: \.element.segment.id) { _, item in
                Circle()
                    .trim(from: item.start * progress, to: max(item.start, item.end - gap) * progress)
                    .stroke(AngularGradient(colors: item.segment.colors, center: .center,
                                            startAngle: .degrees(item.start * 360), endAngle: .degrees(item.end * 360)),
                            style: StrokeStyle(lineWidth: lineWidth, lineCap: .butt))
                    .rotationEffect(.degrees(-90))
            }
            if scanning {
                TimelineView(.animation) { tl in
                    let angle = tl.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 1.6) / 1.6 * 360
                    Circle()
                        .trim(from: 0, to: 0.22)
                        .stroke(AngularGradient(colors: [.white.opacity(0), .white.opacity(0.85)], center: .center,
                                                startAngle: .degrees(0), endAngle: .degrees(80)),
                                style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                        .rotationEffect(.degrees(angle - 90))
                        .blendMode(.plusLighter)
                }
            }
            center
        }
        .padding(lineWidth / 2)
        .onAppear { withAnimation(.spring(response: 1.1, dampingFraction: 0.86).delay(0.15)) { progress = 1 } }
    }

    private var gap: Double { 0.004 }

    private var placed: [(segment: RingSegment, start: Double, end: Double)] {
        var start = 0.0
        var out: [(RingSegment, Double, Double)] = []
        let denominator = max(total, 1)
        for s in segments where s.value > 0 {
            let fraction = min(s.value / denominator, 1 - start)
            out.append((s, start, start + fraction))
            start += fraction
        }
        return out
    }
}

// MARK: - Checkbox

struct CheckCircle: View {
    let isOn: Bool
    var tint: Color = .accentColor
    var disabled = false

    var body: some View {
        ZStack {
            Circle()
                .strokeBorder(isOn ? Color.clear : Color.secondary.opacity(disabled ? 0.25 : 0.5), lineWidth: 1.5)
                .background(Circle().fill(isOn ? AnyShapeStyle(LinearGradient(colors: [tint, tint.opacity(0.75)], startPoint: .top, endPoint: .bottom)) : AnyShapeStyle(.clear)))
            Image(systemName: "checkmark")
                .font(.system(size: 9.5, weight: .heavy))
                .foregroundStyle(.white)
                .scaleEffect(isOn ? 1 : 0.2)
                .opacity(isOn ? 1 : 0)
        }
        .frame(width: 19, height: 19)
        .animation(.spring(response: 0.3, dampingFraction: 0.55), value: isOn)
    }
}

// MARK: - Success animation

struct CheckShape: Shape {
    func path(in r: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: r.minX, y: r.midY + r.height * 0.05))
        p.addLine(to: CGPoint(x: r.minX + r.width * 0.36, y: r.maxY))
        p.addLine(to: CGPoint(x: r.maxX, y: r.minY))
        return p
    }
}

/// Green disc that pops in, draws a checkmark, and throws a small burst of particles.
struct SuccessBadge: View {
    var size: CGFloat = 76
    @State private var popped = false
    @State private var drawn = false
    @State private var burstStart: Date?

    var body: some View {
        ZStack {
            if let burstStart { ParticleBurst(start: burstStart, radius: size * 1.05) }
            Circle()
                .fill(Theme.success)
                .frame(width: size, height: size)
                .shadow(color: Theme.successColors[0].opacity(0.5), radius: 18, y: 6)
                .scaleEffect(popped ? 1 : 0.3)
            CheckShape()
                .trim(from: 0, to: drawn ? 1 : 0)
                .stroke(.white, style: StrokeStyle(lineWidth: size * 0.085, lineCap: .round, lineJoin: .round))
                .frame(width: size * 0.4, height: size * 0.3)
        }
        .frame(width: size * 2.2, height: size * 2.2)
        .onAppear {
            withAnimation(Theme.bouncy) { popped = true }
            withAnimation(.easeOut(duration: 0.35).delay(0.2)) { drawn = true }
            burstStart = Date()
        }
    }
}

struct ParticleBurst: View {
    let start: Date
    var radius: CGFloat = 80
    private let particles: [(angle: Double, speed: Double, size: Double, hue: Double)] = (0..<22).map { i in
        (Double(i) / 22 * 2 * .pi + Double.random(in: -0.15...0.15), Double.random(in: 0.65...1.0),
         Double.random(in: 3...6.5), [0.38, 0.47, 0.58, 0.12, 0.75].randomElement()!)
    }

    var body: some View {
        TimelineView(.animation) { tl in
            let t = min(tl.date.timeIntervalSince(start) / 1.1, 1)
            Canvas { ctx, size in
                let c = CGPoint(x: size.width / 2, y: size.height / 2)
                let eased = 1 - pow(1 - t, 3)
                for p in particles {
                    let d = radius * p.speed * eased
                    let pt = CGPoint(x: c.x + cos(p.angle) * d, y: c.y + sin(p.angle) * d + 18 * t * t)
                    let s = p.size * (1 - t * 0.6)
                    ctx.opacity = 1 - t
                    ctx.fill(Path(ellipseIn: CGRect(x: pt.x - s / 2, y: pt.y - s / 2, width: s, height: s)),
                             with: .color(Color(hue: p.hue, saturation: 0.75, brightness: 0.95)))
                }
            }
        }
        .allowsHitTesting(false)
    }
}

// MARK: - Live dot

struct PulseDot: View {
    var color: Color = .green
    @State private var pulsing = false

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: 7, height: 7)
            .background(Circle().fill(color.opacity(0.45)).scaleEffect(pulsing ? 2.6 : 1).opacity(pulsing ? 0 : 1))
            .onAppear { withAnimation(.easeOut(duration: 1.3).repeatForever(autoreverses: false)) { pulsing = true } }
    }
}

/// Soft colored glows behind the window content.
struct AppBackground: View {
    var body: some View {
        ZStack {
            Theme.canvas
            RadialGradient(colors: [Theme.brandColors[0].opacity(0.10), .clear], center: .topLeading, startRadius: 0, endRadius: 650)
            RadialGradient(colors: [Theme.brandColors[1].opacity(0.07), .clear], center: .bottomTrailing, startRadius: 0, endRadius: 700)
        }
        .ignoresSafeArea()
    }
}
