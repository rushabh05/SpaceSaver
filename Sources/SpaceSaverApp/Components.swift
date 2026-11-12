import AppKit
import SpaceSaverCore
import SwiftUI

// MARK: - Palette

extension CleanupCategory {
    var color: Color {
        switch self {
        case .projectArtifacts: return Color(red: 0.36, green: 0.55, blue: 0.98)
        case .xcode: return Color(red: 0.20, green: 0.62, blue: 0.95)
        case .docker: return Color(red: 0.13, green: 0.58, blue: 0.80)
        case .packageCaches: return Color(red: 0.55, green: 0.42, blue: 0.95)
        case .ideCaches: return Color(red: 0.42, green: 0.40, blue: 0.85)
        case .aiModels: return Color(red: 0.85, green: 0.38, blue: 0.75)
        case .aiSessions: return Color(red: 0.93, green: 0.45, blue: 0.55)
        case .systemJunk: return Color(red: 0.98, green: 0.62, blue: 0.20)
        case .appleDevices: return Color(red: 0.45, green: 0.65, blue: 0.45)
        case .downloads: return Color(red: 0.20, green: 0.70, blue: 0.60)
        case .largeFiles: return Color(red: 0.90, green: 0.50, blue: 0.30)
        case .duplicates: return Color(red: 0.60, green: 0.60, blue: 0.30)
        case .trash: return Color(red: 0.55, green: 0.55, blue: 0.60)
        case .custom: return Color(red: 0.50, green: 0.55, blue: 0.65)
        }
    }
}

extension RiskLevel {
    var color: Color {
        switch self {
        case .safe: return .green
        case .review: return .orange
        case .caution: return .red
        }
    }

    var symbol: String {
        switch self {
        case .safe: return "checkmark.shield.fill"
        case .review: return "eye.fill"
        case .caution: return "exclamationmark.triangle.fill"
        }
    }
}

// MARK: - Small views

struct RiskBadge: View {
    let risk: RiskLevel
    var compact = false

    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: risk.symbol).font(.system(size: 9, weight: .bold))
            if !compact { Text(risk.title).font(.system(size: 10, weight: .semibold)) }
        }
        .padding(.horizontal, compact ? 4 : 6)
        .padding(.vertical, 2)
        .foregroundStyle(risk.color)
        .background(risk.color.opacity(0.13), in: Capsule())
        .help(risk.summary)
    }
}

struct Tag: View {
    let text: String
    var color: Color = .secondary

    var body: some View {
        Text(text)
            .font(.system(size: 10, weight: .medium))
            .lineLimit(1)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .foregroundStyle(color)
            .background(color.opacity(0.1), in: Capsule())
    }
}

struct CategoryIcon: View {
    let category: CleanupCategory
    var size: CGFloat = 28

    var body: some View {
        Image(systemName: category.symbol)
            .font(.system(size: size * 0.46, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: size, height: size)
            .background {
                RoundedRectangle(cornerRadius: size * 0.3, style: .continuous)
                    .fill(LinearGradient(colors: [category.color.mix(.white, 0.12), category.color.mix(.black, 0.12)],
                                         startPoint: .topLeading, endPoint: .bottomTrailing))
                    .overlay(RoundedRectangle(cornerRadius: size * 0.3, style: .continuous)
                        .strokeBorder(LinearGradient(colors: [.white.opacity(0.45), .white.opacity(0)], startPoint: .top, endPoint: .bottom),
                                      lineWidth: 0.8))
                    .shadow(color: category.color.opacity(0.35), radius: size * 0.14, y: size * 0.06)
            }
    }
}

extension Color {
    func mix(_ other: Color, _ amount: Double) -> Color {
        let a = NSColor(self).usingColorSpace(.deviceRGB) ?? .gray
        let b = NSColor(other).usingColorSpace(.deviceRGB) ?? .gray
        return Color(red: a.redComponent + (b.redComponent - a.redComponent) * amount,
                     green: a.greenComponent + (b.greenComponent - a.greenComponent) * amount,
                     blue: a.blueComponent + (b.blueComponent - a.blueComponent) * amount)
    }
}

struct Card<Content: View>: View {
    var padding: CGFloat = 18
    var tint: Color?
    var hoverLift = false
    @ViewBuilder var content: Content

    var body: some View {
        content
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .surface(radius: 18, tint: tint, hoverLift: hoverLift)
    }
}

/// Horizontal proportion bar that grows in when it appears.
struct ShareBar: View {
    let fraction: Double
    var color: Color = .accentColor
    var height: CGFloat = 4
    @State private var shown = false

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.primary.opacity(0.08))
                Capsule()
                    .fill(LinearGradient(colors: [color.opacity(0.75), color], startPoint: .leading, endPoint: .trailing))
                    .frame(width: max(geo.size.width * min(max(fraction, 0), 1) * (shown ? 1 : 0), fraction > 0 ? 2 : 0))
            }
        }
        .frame(height: height)
        .onAppear { withAnimation(Theme.spring.delay(0.1)) { shown = true } }
        .animation(Theme.spring, value: fraction)
    }
}

struct EmptyStateView: View {
    let symbol: String
    let title: String
    let message: String
    var action: (title: String, run: () -> Void)?
    @State private var floating = false

    var body: some View {
        VStack(spacing: 14) {
            ZStack {
                Circle().fill(Theme.brand.opacity(0.14)).frame(width: 96, height: 96)
                    .scaleEffect(floating ? 1.06 : 0.96)
                Image(systemName: symbol)
                    .font(.system(size: 38, weight: .regular))
                    .foregroundStyle(Theme.brand)
                    .offset(y: floating ? -3 : 3)
            }
            .onAppear { withAnimation(.easeInOut(duration: 2.2).repeatForever(autoreverses: true)) { floating = true } }
            Text(title).font(.title3.weight(.semibold))
            Text(message).foregroundStyle(.secondary).multilineTextAlignment(.center).frame(maxWidth: 440)
            if let action {
                Button(action: action.run) {
                    Label(action.title, systemImage: "sparkle.magnifyingglass")
                }
                .buttonStyle(PrimaryButtonStyle(large: true, shimmer: true))
                .padding(.top, 6)
            }
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .appear()
    }
}

struct SizeText: View {
    let bytes: Int64
    var font: Font = .body

    var body: some View { BytesText(bytes: bytes, font: font) }
}

// MARK: - Finder helpers

enum Finder {
    static func reveal(_ paths: [String]) {
        let urls = paths.filter(Paths.exists).map { URL(fileURLWithPath: $0) }
        if urls.isEmpty, let first = paths.first {
            NSWorkspace.shared.open(URL(fileURLWithPath: Paths.parent(first)))
        } else {
            NSWorkspace.shared.activateFileViewerSelecting(urls)
        }
    }

    static func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    static func chooseFolder(message: String = "Choose a folder") -> String? {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.message = message
        panel.directoryURL = URL(fileURLWithPath: NSHomeDirectory())
        return panel.runModal() == .OK ? panel.url?.path : nil
    }
}

extension View {
    @ViewBuilder func `if`<T: View>(_ condition: Bool, transform: (Self) -> T) -> some View {
        if condition { transform(self) } else { self }
    }
}
