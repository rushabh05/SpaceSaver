// Draws the SpaceSaver app icon (1024×1024 PNG) with CoreGraphics.
// Usage: swift scripts/make-icon.swift <output.png>
import AppKit

let size: CGFloat = 1024
let output = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "AppIcon.png"

let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size), pixelsHigh: Int(size), bitsPerSample: 8,
                           samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                           bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
let ctx = NSGraphicsContext.current!.cgContext

// Squircle background with the standard macOS icon inset.
let inset: CGFloat = 100
let tile = CGRect(x: inset, y: inset, width: size - inset * 2, height: size - inset * 2)
let tilePath = CGPath(roundedRect: tile, cornerWidth: 185, cornerHeight: 185, transform: nil)

ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -14), blur: 30, color: NSColor.black.withAlphaComponent(0.35).cgColor)
ctx.addPath(tilePath)
ctx.setFillColor(NSColor.black.cgColor)
ctx.fillPath()
ctx.restoreGState()

ctx.saveGState()
ctx.addPath(tilePath)
ctx.clip()
let bg = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: [
    NSColor(calibratedRed: 0.10, green: 0.14, blue: 0.32, alpha: 1).cgColor,
    NSColor(calibratedRed: 0.17, green: 0.30, blue: 0.62, alpha: 1).cgColor,
] as CFArray, locations: [0, 1])!
ctx.drawLinearGradient(bg, start: CGPoint(x: 0, y: tile.minY), end: CGPoint(x: 0, y: tile.maxY), options: [])
ctx.restoreGState()

// Donut of storage segments: most of the ring is "used", one bright green slice is "reclaimed".
let center = CGPoint(x: size / 2, y: size / 2 + 6)
let radius: CGFloat = 250
let width: CGFloat = 92
let segments: [(Double, NSColor)] = [
    (0.30, NSColor(calibratedRed: 0.42, green: 0.60, blue: 1.00, alpha: 1)),
    (0.18, NSColor(calibratedRed: 0.63, green: 0.47, blue: 1.00, alpha: 1)),
    (0.14, NSColor(calibratedRed: 1.00, green: 0.62, blue: 0.30, alpha: 1)),
    (0.10, NSColor(calibratedRed: 0.95, green: 0.42, blue: 0.62, alpha: 1)),
    (0.24, NSColor(calibratedRed: 0.27, green: 0.90, blue: 0.62, alpha: 1)),
]
var angle = CGFloat.pi / 2
let gap: CGFloat = 0.03
ctx.setLineCap(.butt)
ctx.setLineWidth(width)
for (fraction, color) in segments {
    let sweep = CGFloat(fraction) * 2 * .pi
    ctx.setStrokeColor(color.cgColor)
    ctx.addArc(center: center, radius: radius, startAngle: angle - gap, endAngle: angle - sweep + gap, clockwise: true)
    ctx.strokePath()
    angle -= sweep
}

// Sparkle in the middle: "cleaned".
func sparkle(at p: CGPoint, r: CGFloat, color: NSColor) {
    let path = CGMutablePath()
    let k: CGFloat = 0.22
    path.move(to: CGPoint(x: p.x, y: p.y + r))
    path.addQuadCurve(to: CGPoint(x: p.x + r, y: p.y), control: CGPoint(x: p.x + r * k, y: p.y + r * k))
    path.addQuadCurve(to: CGPoint(x: p.x, y: p.y - r), control: CGPoint(x: p.x + r * k, y: p.y - r * k))
    path.addQuadCurve(to: CGPoint(x: p.x - r, y: p.y), control: CGPoint(x: p.x - r * k, y: p.y - r * k))
    path.addQuadCurve(to: CGPoint(x: p.x, y: p.y + r), control: CGPoint(x: p.x - r * k, y: p.y + r * k))
    ctx.addPath(path)
    ctx.setFillColor(color.cgColor)
    ctx.fillPath()
}
ctx.saveGState()
ctx.setShadow(offset: .zero, blur: 40, color: NSColor(calibratedRed: 0.3, green: 1, blue: 0.7, alpha: 0.6).cgColor)
sparkle(at: center, r: 120, color: .white)
ctx.restoreGState()
sparkle(at: CGPoint(x: center.x + 105, y: center.y + 100), r: 38, color: NSColor.white.withAlphaComponent(0.9))

NSGraphicsContext.restoreGraphicsState()
let png = rep.representation(using: .png, properties: [:])!
try! png.write(to: URL(fileURLWithPath: output))
print("Wrote \(output)")
