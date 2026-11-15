// Renders the SpaceSaver promo video from the demo screens that scripts/capture-tour.sh saves.
//
//   swiftc -O scripts/make-video.swift -o build/make-video
//   build/make-video <screens-dir> <icon-png> <out-dir> [16x9|1x1|9x16 ...]
//
// Frames are drawn with Core Graphics and piped to ffmpeg (brew install ffmpeg). Output: H.264 MP4s
// with a silent AAC track, 30 fps, captions burned in (social feeds autoplay muted).
import AppKit
import Foundation

// MARK: - Storyboard

/// Normalized rectangle in a screenshot (0...1 on both axes, origin top-left).
struct NR { var x, y, w, h: Double }

enum Kind {
    case hook
    /// file, then the camera's start and end for wide canvases, then for the tall canvas.
    case shot(String, NR, NR, NR, NR)
    case island
    case end
}

struct Scene {
    var kind: Kind
    var duration: Double
    var title: String = ""
    var subtitle: String = ""
}

let full = NR(x: 0, y: 0, w: 1, h: 1)
let scenes: [Scene] = [
    Scene(kind: .hook, duration: 3.2),
    Scene(kind: .shot("01-overview", full, NR(x: 0.236, y: 0.05, w: 0.72, h: 0.755),
                      NR(x: 0.25, y: 0.12, w: 0.46, h: 0.72), NR(x: 0.255, y: 0.40, w: 0.36, h: 0.46)),
          duration: 4.4, title: "One scan. Everything you can safely delete.",
          subtitle: "Every item is labelled Safe, Review or Caution."),
    Scene(kind: .shot("02-projects", full, NR(x: 0.236, y: 0.07, w: 0.50, h: 0.524),
                      NR(x: 0.24, y: 0.10, w: 0.47, h: 0.72), NR(x: 0.24, y: 0.18, w: 0.40, h: 0.52)),
          duration: 4.0, title: "Old build folders? Gone.",
          subtitle: "node_modules, target and .venv in projects you haven't touched in months."),
    Scene(kind: .shot("04-worktrees", full, NR(x: 0.236, y: 0.06, w: 0.62, h: 0.65),
                      NR(x: 0.24, y: 0.10, w: 0.47, h: 0.68), NR(x: 0.24, y: 0.17, w: 0.40, h: 0.46)),
          duration: 4.0, title: "Cleans up after your AI agents.",
          subtitle: "Old Claude Code worktrees, plus Cursor and Codex history."),
    Scene(kind: .shot("05-xcode", NR(x: 0.36, y: 0.05, w: 0.62, h: 0.72), NR(x: 0.478, y: 0.05, w: 0.4775, h: 0.50),
                      NR(x: 0.60, y: 0.06, w: 0.38, h: 0.62), NR(x: 0.70, y: 0.07, w: 0.28, h: 0.46)),
          duration: 3.8, title: "It tells you what it's deleting.",
          subtitle: "What each item is, and how to get it back."),
    Scene(kind: .shot("06-apps", full, NR(x: 0.236, y: 0.07, w: 0.62, h: 0.65),
                      NR(x: 0.23, y: 0.09, w: 0.50, h: 0.62), NR(x: 0.715, y: 0.11, w: 0.26, h: 0.52)),
          duration: 4.0, title: "Uninstall apps completely.",
          subtitle: "Including the files they leave in your Library."),
    Scene(kind: .island, duration: 4.6, title: "Progress lives in your notch.",
          subtitle: "Files go to the Trash first, so you can put them back."),
    Scene(kind: .shot("11-overview-after", full, NR(x: 0.236, y: 0.18, w: 0.72, h: 0.755),
                      NR(x: 0.25, y: 0.15, w: 0.44, h: 0.50), NR(x: 0.255, y: 0.17, w: 0.21, h: 0.34)),
          duration: 3.6, title: "Back to 50 GB free.", subtitle: "From 21 GB, in one click."),
    Scene(kind: .end, duration: 4.2),
]

// MARK: - Formats and layout

enum Layout { case side, square, tall }

struct Format {
    var name: String
    var width: Int
    var height: Int
    var layout: Layout
}

let allFormats: [String: Format] = [
    "16x9": Format(name: "16x9", width: 1920, height: 1080, layout: .side),
    "1x1": Format(name: "1x1", width: 1080, height: 1080, layout: .square),
    "9x16": Format(name: "9x16", width: 1080, height: 1920, layout: .tall),
]

struct Frame {
    var caption: CGRect
    var area: CGRect
    var titleSize: CGFloat
    var subtitleSize: CGFloat
    var brand: CGPoint?
    var brandSize: CGFloat
}

func frame(for f: Format) -> Frame {
    switch f.layout {
    case .side:
        return Frame(caption: CGRect(x: 104, y: 0, width: 520, height: 1080), area: CGRect(x: 664, y: 64, width: 1216, height: 952),
                     titleSize: 62, subtitleSize: 30, brand: CGPoint(x: 104, y: 984), brandSize: 30)
    case .square:
        return Frame(caption: CGRect(x: 64, y: 118, width: 952, height: 170), area: CGRect(x: 36, y: 318, width: 1008, height: 732),
                     titleSize: 50, subtitleSize: 26, brand: CGPoint(x: 64, y: 50), brandSize: 30)
    case .tall:
        return Frame(caption: CGRect(x: 72, y: 250, width: 936, height: 330), area: CGRect(x: 36, y: 620, width: 1008, height: 1080),
                     titleSize: 68, subtitleSize: 34, brand: CGPoint(x: 72, y: 150), brandSize: 36)
    }
}

// MARK: - Drawing helpers (top-left origin)

func ease(_ t: Double) -> Double {
    let x = min(max(t, 0), 1)
    return x < 0.5 ? 4 * x * x * x : 1 - pow(-2 * x + 2, 3) / 2
}

func easeOut(_ t: Double) -> Double {
    let x = min(max(t, 0), 1)
    return 1 - pow(1 - x, 3)
}

func color(_ hex: UInt32, _ alpha: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
}

func loadImage(_ path: String) -> CGImage {
    guard let src = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil),
          let img = CGImageSourceCreateImageAtIndex(src, 0, nil) else {
        FileHandle.standardError.write("Can't read \(path)\n".data(using: .utf8)!)
        exit(1)
    }
    return img
}

func draw(_ img: CGImage, in rect: CGRect, _ ctx: CGContext) {
    ctx.saveGState()
    ctx.translateBy(x: rect.minX, y: rect.maxY)
    ctx.scaleBy(x: 1, y: -1)
    ctx.interpolationQuality = .high
    ctx.draw(img, in: CGRect(origin: .zero, size: rect.size))
    ctx.restoreGState()
}

/// Draws wrapped text; returns its height. `measure` skips drawing.
@discardableResult
func text(_ string: String, size: CGFloat, weight: NSFont.Weight, color c: NSColor, in rect: CGRect,
          align: NSTextAlignment = .left, lineSpacing: CGFloat = 0, measure: Bool = false, kern: CGFloat = 0) -> CGFloat {
    let style = NSMutableParagraphStyle()
    style.alignment = align
    style.lineSpacing = lineSpacing
    let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: size, weight: weight), .foregroundColor: c,
                                                .paragraphStyle: style, .kern: kern]
    let s = NSAttributedString(string: string, attributes: attrs)
    let bounds = s.boundingRect(with: CGSize(width: rect.width, height: 10_000), options: [.usesLineFragmentOrigin, .usesFontLeading])
    if !measure { s.draw(with: CGRect(x: rect.minX, y: rect.minY, width: rect.width, height: ceil(bounds.height) + 4),
                         options: [.usesLineFragmentOrigin, .usesFontLeading]) }
    return ceil(bounds.height)
}

func roundedRect(_ r: CGRect, _ radius: CGFloat) -> CGPath {
    CGPath(roundedRect: r, cornerWidth: radius, cornerHeight: radius, transform: nil)
}

// MARK: - Renderer

final class Renderer {
    let f: Format
    let fr: Frame
    let ctx: CGContext
    let images: [String: CGImage]
    let icon: CGImage
    let k: CGFloat
    let W: CGFloat, H: CGFloat

    init(format: Format, images: [String: CGImage], icon: CGImage) {
        f = format
        fr = frame(for: format)
        self.images = images
        self.icon = icon
        W = CGFloat(format.width)
        H = CGFloat(format.height)
        k = min(W, H) / 1080
        ctx = CGContext(data: nil, width: format.width, height: format.height, bitsPerComponent: 8, bytesPerRow: format.width * 4,
                        space: CGColorSpace(name: CGColorSpace.sRGB)!,
                        bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)!
        ctx.translateBy(x: 0, y: H)
        ctx.scaleBy(x: 1, y: -1)
        NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: true)
    }

    var pixels: UnsafeMutableRawPointer { ctx.data! }

    func background(_ time: Double) {
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        let base = CGGradient(colorsSpace: space, colors: [color(0x0A0E22), color(0x17113A)] as CFArray, locations: [0, 1])!
        ctx.setFillColor(color(0x0A0E22))
        ctx.fill(CGRect(x: 0, y: 0, width: W, height: H))
        ctx.drawLinearGradient(base, start: .zero, end: CGPoint(x: W * 0.3, y: H),
                               options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
        func glow(_ hex: UInt32, _ alpha: CGFloat, _ cx: CGFloat, _ cy: CGFloat, _ r: CGFloat) {
            let g = CGGradient(colorsSpace: space, colors: [color(hex, alpha), color(hex, 0)] as CFArray, locations: [0, 1])!
            ctx.drawRadialGradient(g, startCenter: CGPoint(x: cx, y: cy), startRadius: 0, endCenter: CGPoint(x: cx, y: cy),
                                   endRadius: r, options: [])
        }
        let drift = CGFloat(sin(time * 0.35))
        glow(0x3B6BFF, 0.42, W * (0.18 + 0.04 * drift), H * 0.12, max(W, H) * 0.62)
        glow(0x9B5CF6, 0.36, W * (0.86 - 0.04 * drift), H * 0.92, max(W, H) * 0.6)
        glow(0x22C3A6, 0.14, W * 0.6, H * (0.4 + 0.05 * drift), max(W, H) * 0.35)
    }

    func brand(alpha: CGFloat) {
        guard let p = fr.brand, alpha > 0 else { return }
        ctx.saveGState()
        ctx.setAlpha(alpha)
        let s = fr.brandSize
        draw(icon, in: CGRect(x: p.x, y: p.y - s * 0.5, width: s * 1.25, height: s * 1.25), ctx)
        text("SpaceSaver", size: s * 0.72, weight: .semibold, color: NSColor(white: 1, alpha: 0.9),
             in: CGRect(x: p.x + s * 1.55, y: p.y - s * 0.22, width: 400, height: s * 1.4))
        ctx.restoreGState()
    }

    func caption(_ scene: Scene, t: Double) {
        let a = CGFloat(easeOut((t - 0.15) / 0.5))
        guard a > 0 else { return }
        let dy = (1 - a) * 22 * k
        let rect = fr.caption
        let titleH = text(scene.title, size: fr.titleSize, weight: .bold, color: .white, in: rect, lineSpacing: 2, measure: true)
        let subH = text(scene.subtitle, size: fr.subtitleSize, weight: .medium, color: .white, in: rect, lineSpacing: 3, measure: true)
        let gap = fr.subtitleSize * 0.7
        let total = titleH + gap + subH
        var y = f.layout == .side ? rect.midY - total / 2 - 30 : rect.minY
        ctx.saveGState()
        ctx.setAlpha(a)
        ctx.translateBy(x: 0, y: dy)
        text(scene.title, size: fr.titleSize, weight: .bold, color: .white, in: CGRect(x: rect.minX, y: y, width: rect.width, height: titleH + 8),
             lineSpacing: 2)
        y += titleH + gap
        ctx.setAlpha(a * 0.72)
        text(scene.subtitle, size: fr.subtitleSize, weight: .medium, color: NSColor(red: 0.84, green: 0.86, blue: 1, alpha: 1),
             in: CGRect(x: rect.minX, y: y, width: rect.width, height: subH + 8), lineSpacing: 3)
        ctx.restoreGState()
    }

    func shot(_ file: String, _ a: NR, _ b: NR, t: Double, duration: Double) {
        guard let img = images[file] else { return }
        let iw = CGFloat(img.width), ih = CGFloat(img.height)
        let p = ease(min(max((t - 0.35) / (duration - 0.6), 0), 1))
        func mix(_ x: Double, _ y: Double) -> CGFloat { CGFloat(x + (y - x) * p) }
        let cam = CGRect(x: mix(a.x, b.x) * iw, y: mix(a.y, b.y) * ih, width: mix(a.w, b.w) * iw, height: mix(a.h, b.h) * ih)
        let area = fr.area
        let s = min(area.width / cam.width, area.height / cam.height)
        let enter = CGFloat(easeOut(t / 0.6))
        let dy = (1 - enter) * 50 * k
        let rect = CGRect(x: area.midX - cam.midX * s, y: area.midY - cam.midY * s + dy, width: iw * s, height: ih * s)
        ctx.saveGState()
        ctx.addPath(roundedRect(area.insetBy(dx: -2, dy: -2), 26 * k))
        ctx.clip()
        draw(img, in: rect, ctx)
        ctx.restoreGState()
    }

    func island(t: Double, duration: Double) {
        let area = fr.area
        let enter = CGFloat(easeOut(t / 0.6))
        let screenH = f.layout == .side ? area.height * 0.62 : area.height * (f.layout == .tall ? 0.44 : 0.58)
        var screen = CGRect(x: area.minX, y: area.minY + (area.height - screenH) * (f.layout == .side ? 0.35 : 0.2), width: area.width,
                            height: screenH)
        screen.origin.y += (1 - enter) * 50 * k
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        // A Mac screen: bezel, wallpaper, menu bar.
        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: 20 * k), blur: 60 * k, color: color(0x000000, 0.5))
        ctx.addPath(roundedRect(screen.insetBy(dx: -14 * k, dy: -14 * k), 34 * k))
        ctx.setFillColor(color(0x0B0B0F))
        ctx.fillPath()
        ctx.restoreGState()
        ctx.saveGState()
        ctx.addPath(roundedRect(screen, 22 * k))
        ctx.clip()
        let wall = CGGradient(colorsSpace: space, colors: [color(0x6E8BFF), color(0xA57BFF), color(0xF29BD4)] as CFArray,
                              locations: [0, 0.55, 1])!
        ctx.drawLinearGradient(wall, start: CGPoint(x: screen.minX, y: screen.minY), end: CGPoint(x: screen.maxX, y: screen.maxY), options: [])
        let bar = CGRect(x: screen.minX, y: screen.minY, width: screen.width, height: 30 * k)
        ctx.setFillColor(color(0xFFFFFF, 0.28))
        ctx.fill(bar)
        // The three island states, top-anchored at the notch.
        let states: [(String, Double)] = [("07-island-peek", 0), ("09-island-cleaning-expanded", 1.5), ("10-island-cleaned", 3.0)]
        for (i, (name, start)) in states.enumerated() {
            guard let img = images[name] else { continue }
            let next = i + 1 < states.count ? states[i + 1].1 : 1e9
            let fadeIn = i == 0 ? 1 : easeOut((t - start) / 0.3)
            let fadeOut = 1 - easeOut((t - next) / 0.3)
            let alpha = CGFloat(min(fadeIn, fadeOut))
            guard alpha > 0 else { continue }
            let scale = (screen.width * (f.layout == .tall ? 0.8 : 0.6)) / 476 // island art is 2x; 476 pt is the expanded width
            let w = CGFloat(img.width) / 2 * scale, h = CGFloat(img.height) / 2 * scale
            ctx.saveGState()
            ctx.setAlpha(alpha)
            draw(img, in: CGRect(x: screen.midX - w / 2, y: screen.minY, width: w, height: h), ctx)
            ctx.restoreGState()
        }
        ctx.restoreGState()
    }

    func hook(t: Double) {
        let a1 = CGFloat(easeOut((t - 0.1) / 0.5))
        let cx = W / 2
        let titleSize: CGFloat = f.layout == .side ? 92 : 84 * k
        let line1Y = H * (f.layout == .tall ? 0.36 : 0.30)
        ctx.saveGState()
        ctx.setAlpha(a1)
        text("Your Mac is full.\nAgain.", size: titleSize, weight: .heavy, color: .white,
             in: CGRect(x: 60, y: line1Y + (1 - a1) * 24, width: W - 120, height: 400), align: .center, lineSpacing: 0)
        ctx.restoreGState()
        // A disk bar filling up to 95%.
        let barW = min(W * 0.62, 900 * k), barH = 26 * k
        let barY = line1Y + titleSize * 2.6 + 30 * k
        let bar = CGRect(x: cx - barW / 2, y: barY, width: barW, height: barH)
        let a2 = CGFloat(easeOut((t - 0.5) / 0.4))
        let fill = 0.95 * ease((t - 0.6) / 1.2)
        ctx.saveGState()
        ctx.setAlpha(a2)
        ctx.addPath(roundedRect(bar, barH / 2))
        ctx.setFillColor(color(0xFFFFFF, 0.12))
        ctx.fillPath()
        let fillRect = CGRect(x: bar.minX, y: bar.minY, width: max(barH, bar.width * CGFloat(fill)), height: barH)
        ctx.addPath(roundedRect(fillRect, barH / 2))
        ctx.clip()
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        let grad = CGGradient(colorsSpace: space, colors: [color(0x5B8CFF), color(0xF59E0B), color(0xEF4444)] as CFArray,
                              locations: [0, 0.7, 1])!
        ctx.drawLinearGradient(grad, start: CGPoint(x: bar.minX, y: 0), end: CGPoint(x: bar.maxX, y: 0), options: [])
        ctx.restoreGState()
        ctx.saveGState()
        ctx.setAlpha(a2)
        let pct = Int((fill * 100).rounded())
        text("Macintosh HD", size: 26 * k, weight: .semibold, color: NSColor(white: 1, alpha: 0.75),
             in: CGRect(x: bar.minX, y: bar.maxY + 14 * k, width: barW / 2, height: 40 * k))
        text("\(pct)% used", size: 26 * k, weight: .bold,
             color: pct > 85 ? NSColor(red: 1, green: 0.45, blue: 0.42, alpha: 1) : NSColor(white: 1, alpha: 0.75),
             in: CGRect(x: bar.midX, y: bar.maxY + 14 * k, width: barW / 2, height: 40 * k), align: .right)
        ctx.restoreGState()
        let a3 = CGFloat(easeOut((t - 1.9) / 0.5))
        ctx.saveGState()
        ctx.setAlpha(a3)
        text("Let's find what's safe to delete.", size: 40 * k, weight: .semibold, color: NSColor(red: 0.8, green: 0.84, blue: 1, alpha: 1),
             in: CGRect(x: 60, y: bar.maxY + 110 * k + (1 - a3) * 16, width: W - 120, height: 120 * k), align: .center)
        ctx.restoreGState()
    }

    func end(t: Double) {
        let a = CGFloat(easeOut(t / 0.6))
        let iconS = 230 * k
        let top = H * (f.layout == .tall ? 0.30 : 0.18)
        ctx.saveGState()
        ctx.setAlpha(a)
        let scale = 0.92 + 0.08 * a
        let iconRect = CGRect(x: W / 2 - iconS * scale / 2, y: top + (1 - a) * 30, width: iconS * scale, height: iconS * scale)
        ctx.setShadow(offset: CGSize(width: 0, height: 18 * k), blur: 50 * k, color: color(0x000000, 0.45))
        draw(icon, in: iconRect, ctx)
        ctx.setShadow(offset: .zero, blur: 0, color: nil)
        var y = top + iconS + 36 * k
        text("SpaceSaver", size: 96 * k, weight: .heavy, color: .white, in: CGRect(x: 40, y: y, width: W - 80, height: 130 * k), align: .center)
        y += 122 * k
        text("The free, open-source disk cleaner for Mac", size: 38 * k, weight: .medium,
             color: NSColor(red: 0.84, green: 0.86, blue: 1, alpha: 0.85), in: CGRect(x: 60, y: y, width: W - 120, height: 120 * k), align: .center)
        y += (f.layout == .side ? 86 : 120) * k
        let url = "rushabh05.github.io/SpaceSaver"
        let urlSize = 34 * k
        let urlW = NSAttributedString(string: url, attributes: [.font: NSFont.systemFont(ofSize: urlSize, weight: .semibold)]).size().width
        let pill = CGRect(x: W / 2 - urlW / 2 - 34 * k, y: y, width: urlW + 68 * k, height: urlSize * 2)
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        ctx.saveGState()
        ctx.addPath(roundedRect(pill, pill.height / 2))
        ctx.clip()
        let grad = CGGradient(colorsSpace: space, colors: [color(0x4F7CFF), color(0x8B5CF6)] as CFArray, locations: [0, 1])!
        ctx.drawLinearGradient(grad, start: CGPoint(x: pill.minX, y: 0), end: CGPoint(x: pill.maxX, y: 0), options: [])
        ctx.restoreGState()
        text(url, size: urlSize, weight: .semibold, color: .white,
             in: CGRect(x: pill.minX, y: pill.minY + urlSize * 0.42, width: pill.width, height: urlSize * 1.4), align: .center)
        y += pill.height + 40 * k
        text("Apple silicon · macOS 14 or later · Screens show sample data", size: 22 * k, weight: .medium,
             color: NSColor(white: 1, alpha: 0.5), in: CGRect(x: 60, y: y, width: W - 120, height: 60 * k), align: .center)
        ctx.restoreGState()
    }

    func render(scene: Scene, t: Double) {
        background(t)
        let fadeIn = easeOut(t / 0.35)
        let fadeOut = 1 - ease((t - (scene.duration - 0.3)) / 0.3)
        let alpha = CGFloat(min(fadeIn, fadeOut))
        ctx.saveGState()
        ctx.setAlpha(alpha)
        ctx.beginTransparencyLayer(auxiliaryInfo: nil)
        switch scene.kind {
        case .hook:
            hook(t: t)
        case .end:
            end(t: t)
        case .shot(let file, let wa, let wb, let ta, let tb):
            if f.layout == .tall { shot(file, ta, tb, t: t, duration: scene.duration) } else { shot(file, wa, wb, t: t, duration: scene.duration) }
            caption(scene, t: t)
            brand(alpha: 0.85)
        case .island:
            island(t: t, duration: scene.duration)
            caption(scene, t: t)
            brand(alpha: 0.85)
        }
        ctx.endTransparencyLayer()
        ctx.restoreGState()
    }
}

// MARK: - Main

let args = CommandLine.arguments
guard args.count >= 4 else {
    print("usage: make-video <screens-dir> <icon-png> <out-dir> [16x9|1x1|9x16 ...]")
    exit(2)
}
let screens = args[1], iconPath = args[2], outDir = args[3]
let wanted = args.count > 4 ? Array(args[4...]) : ["16x9", "1x1", "9x16"]
try? FileManager.default.createDirectory(atPath: outDir, withIntermediateDirectories: true)

var images: [String: CGImage] = [:]
for name in ["01-overview", "02-projects", "04-worktrees", "05-xcode", "06-apps", "07-island-peek",
             "09-island-cleaning-expanded", "10-island-cleaned", "11-overview-after"] {
    images[name] = loadImage("\(screens)/\(name).png")
}
let icon = loadImage(iconPath)
let fps = 30.0
let ffmpeg = ["/opt/homebrew/bin/ffmpeg", "/usr/local/bin/ffmpeg"].first { FileManager.default.isExecutableFile(atPath: $0) }
guard let ffmpeg else { print("ffmpeg not found (brew install ffmpeg)"); exit(1) }

for key in wanted {
    guard let format = allFormats[key] else { print("unknown format \(key)"); continue }
    let out = "\(outDir)/SpaceSaver-\(format.name).mp4"
    let renderer = Renderer(format: format, images: images, icon: icon)
    let proc = Process()
    proc.executableURL = URL(fileURLWithPath: ffmpeg)
    proc.arguments = ["-hide_banner", "-loglevel", "error", "-y",
                      "-f", "rawvideo", "-pix_fmt", "bgra", "-s", "\(format.width)x\(format.height)", "-r", "30", "-i", "-",
                      "-f", "lavfi", "-i", "anullsrc=r=48000:cl=stereo",
                      "-shortest", "-c:v", "libx264", "-preset", "slow", "-crf", "18", "-pix_fmt", "yuv420p",
                      "-profile:v", "high", "-level", "4.2", "-c:a", "aac", "-b:a", "128k", "-movflags", "+faststart", out]
    let pipe = Pipe()
    proc.standardInput = pipe
    try proc.run()
    let bytes = format.width * format.height * 4
    var frames = 0
    for scene in scenes {
        let n = Int((scene.duration * fps).rounded())
        for i in 0..<n {
            renderer.render(scene: scene, t: Double(i) / fps)
            pipe.fileHandleForWriting.write(Data(bytes: renderer.pixels, count: bytes))
            frames += 1
        }
    }
    try pipe.fileHandleForWriting.close()
    proc.waitUntilExit()
    print("✓ \(out)  \(frames) frames, \(String(format: "%.1f", Double(frames) / fps))s")
}
