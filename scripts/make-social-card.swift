// Draws the 1200×630 link-preview card used by the website (og:image) and the GitHub repo.
//
//   swift scripts/make-social-card.swift docs/assets/social-card.png docs/assets/icon-512.png
import AppKit

let args = CommandLine.arguments
let outPath = args.count > 1 ? args[1] : "docs/assets/social-card.png"
let iconPath = args.count > 2 ? args[2] : "docs/assets/icon-512.png"
let W = 1200, H = 630

func rgb(_ hex: UInt32, _ alpha: CGFloat = 1) -> NSColor {
    NSColor(srgbRed: CGFloat((hex >> 16) & 0xff) / 255, green: CGFloat((hex >> 8) & 0xff) / 255,
            blue: CGFloat(hex & 0xff) / 255, alpha: alpha)
}

guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: W, pixelsHigh: H, bitsPerSample: 8,
                                 samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                 colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { exit(1) }
rep.size = NSSize(width: W, height: H)
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
NSGraphicsContext.current?.imageInterpolation = .high
let bounds = NSRect(x: 0, y: 0, width: W, height: H)

// Background: deep navy to plum, with soft colored glows.
NSGradient(colors: [rgb(0x10153a), rgb(0x2a1242)])!.draw(in: bounds, angle: -25)
func glow(_ x: CGFloat, _ y: CGFloat, _ r: CGFloat, _ color: NSColor) {
    NSGradient(colors: [color, color.withAlphaComponent(0)])!
        .draw(fromCenter: NSPoint(x: x, y: y), radius: 0, toCenter: NSPoint(x: x, y: y), radius: r, options: [])
}
glow(170, 600, 560, rgb(0x4f82ff, 0.42))
glow(1100, 560, 520, rgb(0xb04bf0, 0.38))
glow(820, -80, 460, rgb(0xff7a8a, 0.20))

// The notch island, hanging from the top edge.
let island = NSRect(x: CGFloat(W) / 2 - 230, y: CGFloat(H) - 64, width: 460, height: 64)
let shape = NSBezierPath()
let r: CGFloat = 26, ear: CGFloat = 14
shape.move(to: NSPoint(x: island.minX - ear, y: island.maxY))
shape.curve(to: NSPoint(x: island.minX, y: island.maxY - ear),
            controlPoint1: NSPoint(x: island.minX - ear * 0.2, y: island.maxY),
            controlPoint2: NSPoint(x: island.minX, y: island.maxY - ear * 0.2))
shape.line(to: NSPoint(x: island.minX, y: island.minY + r))
shape.appendArc(withCenter: NSPoint(x: island.minX + r, y: island.minY + r), radius: r, startAngle: 180, endAngle: 270)
shape.line(to: NSPoint(x: island.maxX - r, y: island.minY))
shape.appendArc(withCenter: NSPoint(x: island.maxX - r, y: island.minY + r), radius: r, startAngle: 270, endAngle: 360)
shape.line(to: NSPoint(x: island.maxX, y: island.maxY - ear))
shape.curve(to: NSPoint(x: island.maxX + ear, y: island.maxY),
            controlPoint1: NSPoint(x: island.maxX, y: island.maxY - ear * 0.2),
            controlPoint2: NSPoint(x: island.maxX + ear * 0.2, y: island.maxY))
shape.close()
NSGraphicsContext.saveGraphicsState()
let islandShadow = NSShadow()
islandShadow.shadowColor = NSColor.black.withAlphaComponent(0.45)
islandShadow.shadowBlurRadius = 30
islandShadow.shadowOffset = NSSize(width: 0, height: -10)
islandShadow.set()
NSColor.black.setFill()
shape.fill()
NSGraphicsContext.restoreGraphicsState()

// Island content: a small ring and the headline number.
let ringCenter = NSPoint(x: island.minX + 40, y: island.midY + 2)
let track = NSBezierPath()
track.appendArc(withCenter: ringCenter, radius: 13, startAngle: 0, endAngle: 360)
track.lineWidth = 5
NSColor.white.withAlphaComponent(0.16).setStroke()
track.stroke()
let arc = NSBezierPath()
arc.appendArc(withCenter: ringCenter, radius: 13, startAngle: 90, endAngle: 90 - 300, clockwise: true)
arc.lineWidth = 5
arc.lineCapStyle = .round
rgb(0x21cc8f).setStroke()
arc.stroke()
func text(_ string: String, size: CGFloat, weight: NSFont.Weight, color: NSColor, kern: CGFloat = 0) -> NSAttributedString {
    NSAttributedString(string: string, attributes: [
        .font: NSFont.systemFont(ofSize: size, weight: weight), .foregroundColor: color, .kern: kern,
    ])
}
let islandLine = NSMutableAttributedString(attributedString: text("42.2 GB", size: 23, weight: .bold, color: rgb(0x3ddc9f)))
islandLine.append(text("  safe to clean", size: 23, weight: .medium, color: NSColor.white.withAlphaComponent(0.8)))
islandLine.draw(at: NSPoint(x: island.minX + 68, y: island.midY - 12))

// App icon with a soft shadow.
if let icon = NSImage(contentsOfFile: iconPath) {
    NSGraphicsContext.saveGraphicsState()
    let s = NSShadow()
    s.shadowColor = NSColor.black.withAlphaComponent(0.5)
    s.shadowBlurRadius = 40
    s.shadowOffset = NSSize(width: 0, height: -16)
    s.set()
    icon.draw(in: NSRect(x: 84, y: 196, width: 232, height: 232))
    NSGraphicsContext.restoreGraphicsState()
}

// Copy.
let left: CGFloat = 368, width: CGFloat = 760
text("SpaceSaver", size: 30, weight: .semibold, color: NSColor.white.withAlphaComponent(0.72))
    .draw(at: NSPoint(x: left, y: 448))
let headline = NSMutableAttributedString(attributedString:
    text("Get back the gigabytes your dev tools ", size: 58, weight: .heavy, color: .white, kern: -1.6))
headline.append(text("leave behind.", size: 58, weight: .heavy, color: rgb(0xb79cff), kern: -1.6))
let para = NSMutableParagraphStyle()
para.lineHeightMultiple = 0.92
headline.addAttribute(.paragraphStyle, value: para, range: NSRange(location: 0, length: headline.length))
headline.draw(with: NSRect(x: left, y: 300, width: width, height: 140), options: [.usesLineFragmentOrigin])
text("Free Mac app that safely clears node_modules, Xcode DerivedData, Docker build cache, package caches and AI models, with undo.",
     size: 24, weight: .regular, color: NSColor.white.withAlphaComponent(0.68))
    .draw(with: NSRect(x: left, y: 196, width: width - 20, height: 80), options: [.usesLineFragmentOrigin])

// Footer.
text("rushabh05.github.io/SpaceSaver", size: 22, weight: .medium, color: NSColor.white.withAlphaComponent(0.6))
    .draw(at: NSPoint(x: 86, y: 58))
let meta = text("Apple silicon  ·  macOS 14+  ·  Free", size: 22, weight: .medium, color: NSColor.white.withAlphaComponent(0.6))
meta.draw(at: NSPoint(x: CGFloat(W) - 86 - meta.size().width, y: 58))

NSGraphicsContext.restoreGraphicsState()
guard let png = rep.representation(using: .png, properties: [:]) else { exit(1) }
try png.write(to: URL(fileURLWithPath: outPath))
print("wrote \(outPath)")
