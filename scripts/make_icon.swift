// FrameShare — by Anton Pushkin
// Draws the app icon into an .iconset folder. Usage: swift scripts/make_icon.swift <out.iconset>
import AppKit

let out = URL(fileURLWithPath: CommandLine.arguments[1])
try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)

func draw(_ px: Int) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let s = CGFloat(px)
    let bg = NSBezierPath(roundedRect: NSRect(x: s * 0.1, y: s * 0.1, width: s * 0.8, height: s * 0.8),
                          xRadius: s * 0.18, yRadius: s * 0.18)
    NSGradient(colors: [NSColor(srgbRed: 0.14, green: 0.16, blue: 0.24, alpha: 1),
                        NSColor(srgbRed: 0.05, green: 0.06, blue: 0.1, alpha: 1)])!.draw(in: bg, angle: -90)
    // ultrawide screen
    let screen = NSRect(x: s * 0.18, y: s * 0.38, width: s * 0.64, height: s * 0.26)
    NSColor(white: 1, alpha: 0.18).setFill()
    NSBezierPath(roundedRect: screen, xRadius: s * 0.02, yRadius: s * 0.02).fill()
    // shared zone
    let zone = NSRect(x: s * 0.38, y: s * 0.405, width: s * 0.24, height: s * 0.21)
    NSColor(srgbRed: 1, green: 0.23, blue: 0.19, alpha: 1).setStroke()
    let z = NSBezierPath(rect: zone); z.lineWidth = max(1, s * 0.022); z.stroke()
    // mirrored output
    let mirror = NSRect(x: s * 0.36, y: s * 0.17, width: s * 0.28, height: s * 0.15)
    NSColor(srgbRed: 1, green: 0.23, blue: 0.19, alpha: 0.85).setFill()
    NSBezierPath(roundedRect: mirror, xRadius: s * 0.015, yRadius: s * 0.015).fill()
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

for (name, px) in [("16x16", 16), ("16x16@2x", 32), ("32x32", 32), ("32x32@2x", 64), ("128x128", 128),
                   ("128x128@2x", 256), ("256x256", 256), ("256x256@2x", 512), ("512x512", 512), ("512x512@2x", 1024)] {
    try! draw(px).write(to: out.appendingPathComponent("icon_\(name).png"))
}
