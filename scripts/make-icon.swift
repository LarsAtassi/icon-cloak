// Draws the IconCloak app icon and writes Resources/AppIcon.icns.
// Usage: swift scripts/make-icon.swift   (run from the repository root)
//
// The icon shows a menu bar: "»" on the left, the icons it hides fading out, the "|"
// boundary, and the icons that stay visible, on a macOS-style squircle.
import AppKit

let canvas: CGFloat = 1024

func color(_ hex: UInt32, _ alpha: CGFloat = 1) -> NSColor {
    NSColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
}

/// A superellipse ("squircle") close to Apple's continuous-corner icon shape. macOS 26+ shows
/// icons in their own frame when the outline doesn't match its mask, so no custom shadow either:
/// the system adds its own.
func squircle(in rect: NSRect, exponent n: CGFloat = 5) -> NSBezierPath {
    let path = NSBezierPath()
    let a = rect.width / 2, b = rect.height / 2
    let steps = 720
    for i in 0...steps {
        let t = CGFloat(i) / CGFloat(steps) * 2 * .pi
        let c = cos(t), s = sin(t)
        let x = pow(abs(c), 2 / n) * a * (c < 0 ? -1 : 1)
        let y = pow(abs(s), 2 / n) * b * (s < 0 ? -1 : 1)
        let p = NSPoint(x: rect.midX + x, y: rect.midY + y)
        i == 0 ? path.move(to: p) : path.line(to: p)
    }
    path.close()
    return path
}

func drawIcon() {
    // macOS icon grid: 824 pt squircle centered in a 1024 pt canvas.
    let tile = NSRect(x: 100, y: 100, width: 824, height: 824)
    let tilePath = squircle(in: tile)

    // Background gradient: deep indigo to violet.
    NSGradient(colors: [color(0x5B4FE0), color(0x2B2A7A)])!.draw(in: tilePath, angle: -90)

    // Subtle top highlight.
    NSGraphicsContext.saveGraphicsState()
    tilePath.addClip()
    NSGradient(colors: [color(0xFFFFFF, 0.18), color(0xFFFFFF, 0)])!
        .draw(in: NSRect(x: tile.minX, y: tile.midY, width: tile.width, height: tile.height / 2), angle: -90)
    NSGraphicsContext.restoreGraphicsState()

    // Everything below is drawn 10% larger around the center, so it stays legible at small sizes.
    NSGraphicsContext.saveGraphicsState()
    let zoom = NSAffineTransform()
    zoom.translateX(by: canvas / 2, yBy: canvas / 2)
    zoom.scale(by: 1.06)
    zoom.translateX(by: -canvas / 2, yBy: -canvas / 2)
    zoom.concat()

    // The menu bar: a light pill across the middle.
    let bar = NSRect(x: 168, y: 432, width: 688, height: 160)
    let barPath = NSBezierPath(roundedRect: bar, xRadius: 80, yRadius: 80)
    NSGraphicsContext.saveGraphicsState()
    let barShadow = NSShadow()
    barShadow.shadowColor = color(0x000000, 0.25)
    barShadow.shadowOffset = NSSize(width: 0, height: -8)
    barShadow.shadowBlurRadius = 20
    barShadow.set()
    color(0xF4F3FF).setFill()
    barPath.fill()
    NSGraphicsContext.restoreGraphicsState()

    let midY = bar.midY
    let ink = color(0x2B2A7A)

    // "»" on the left.
    let chevron = NSBezierPath()
    chevron.lineWidth = 22
    chevron.lineCapStyle = .round
    chevron.lineJoinStyle = .round
    for dx in [CGFloat(0), 46] {
        chevron.move(to: NSPoint(x: 232 + dx, y: midY + 38))
        chevron.line(to: NSPoint(x: 270 + dx, y: midY))
        chevron.line(to: NSPoint(x: 232 + dx, y: midY - 38))
    }
    color(0x5B4FE0).setStroke()
    chevron.stroke()

    // Hidden icons, fading out ("cloaked").
    for (i, alpha) in [CGFloat(0.28), 0.16, 0.08].enumerated() {
        let x = 378 + CGFloat(i) * 92
        ink.withAlphaComponent(alpha).setFill()
        NSBezierPath(roundedRect: NSRect(x: x, y: midY - 30, width: 60, height: 60), xRadius: 16, yRadius: 16).fill()
    }

    // "|" boundary.
    ink.withAlphaComponent(0.35).setFill()
    NSBezierPath(roundedRect: NSRect(x: 660, y: midY - 42, width: 10, height: 84), xRadius: 5, yRadius: 5).fill()

    // Visible icons.
    ink.setFill()
    NSBezierPath(roundedRect: NSRect(x: 702, y: midY - 30, width: 60, height: 60), xRadius: 16, yRadius: 16).fill()
    NSBezierPath(ovalIn: NSRect(x: 782, y: midY - 22, width: 44, height: 44)).fill()
    NSGraphicsContext.restoreGraphicsState()
}

func render(size: Int) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                               bytesPerRow: 0, bitsPerPixel: 0)!
    rep.size = NSSize(width: canvas, height: canvas)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    NSGraphicsContext.current?.imageInterpolation = .high
    drawIcon()
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

let fm = FileManager.default
let iconset = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("AppIcon.iconset")
try? fm.removeItem(at: iconset)
try! fm.createDirectory(at: iconset, withIntermediateDirectories: true)
// No 1x 16/32 px images: macOS 26+ frames those small renderings in a gray tile, but it
// scales the @2x images down cleanly.
for base in [16, 32, 128, 256, 512] {
    if base > 32 { try! render(size: base).write(to: iconset.appendingPathComponent("icon_\(base)x\(base).png")) }
    try! render(size: base * 2).write(to: iconset.appendingPathComponent("icon_\(base)x\(base)@2x.png"))
}
try! fm.createDirectory(at: URL(fileURLWithPath: "Resources"), withIntermediateDirectories: true)
try! render(size: 1024).write(to: URL(fileURLWithPath: "Resources/AppIcon-1024.png"))

let iconutil = Process()
iconutil.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
iconutil.arguments = ["-c", "icns", iconset.path, "-o", "Resources/AppIcon.icns"]
try! iconutil.run()
iconutil.waitUntilExit()
print(iconutil.terminationStatus == 0 ? "Wrote Resources/AppIcon.icns" : "iconutil failed")
