// Renders Resources/AppIcon.icns: TALKK yellow tile with a black display and
// a Dock pinned to its bottom edge. Run: swift tools/make-icon.swift
import AppKit

let yellow = NSColor(srgbRed: 0xE4/255.0, green: 0xFF/255.0, blue: 0x07/255.0, alpha: 1)
let ink = NSColor(srgbRed: 0.05, green: 0.05, blue: 0.05, alpha: 1)

func render(_ px: Int) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px,
                               bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let s = CGFloat(px) / 1024

    // macOS icon grid: 824pt body centred in 1024 with a ~185pt corner radius.
    let tile = NSRect(x: 100 * s, y: 100 * s, width: 824 * s, height: 824 * s)
    yellow.setFill()
    NSBezierPath(roundedRect: tile, xRadius: 185 * s, yRadius: 185 * s).fill()

    // Display outline.
    let screen = NSRect(x: 232 * s, y: 300 * s, width: 560 * s, height: 400 * s)
    let outline = NSBezierPath(roundedRect: screen, xRadius: 36 * s, yRadius: 36 * s)
    outline.lineWidth = 40 * s
    ink.setStroke()
    outline.stroke()

    // Stand.
    ink.setFill()
    NSBezierPath(rect: NSRect(x: 482 * s, y: 222 * s, width: 60 * s, height: 78 * s)).fill()
    NSBezierPath(roundedRect: NSRect(x: 392 * s, y: 196 * s, width: 240 * s, height: 40 * s),
                 xRadius: 20 * s, yRadius: 20 * s).fill()

    // Dock bar with three app dots, sitting on the bottom edge.
    let dock = NSRect(x: 352 * s, y: 348 * s, width: 320 * s, height: 72 * s)
    NSBezierPath(roundedRect: dock, xRadius: 24 * s, yRadius: 24 * s).fill()
    yellow.setFill()
    for i in 0..<3 {
        let cx = (432 + CGFloat(i) * 80) * s
        NSBezierPath(ovalIn: NSRect(x: cx - 18 * s, y: 366 * s, width: 36 * s, height: 36 * s)).fill()
    }

    // Pin above the Dock.
    ink.setFill()
    NSBezierPath(ovalIn: NSRect(x: 462 * s, y: 520 * s, width: 100 * s, height: 100 * s)).fill()
    let needle = NSBezierPath()
    needle.move(to: NSPoint(x: 494 * s, y: 530 * s))
    needle.line(to: NSPoint(x: 530 * s, y: 530 * s))
    needle.line(to: NSPoint(x: 512 * s, y: 436 * s))
    needle.close()
    needle.fill()

    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

let root = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : ".")
let iconset = root.appendingPathComponent("build/AppIcon.iconset")
try? FileManager.default.removeItem(at: iconset)
try! FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
for base in [16, 32, 128, 256, 512] {
    try! render(base).write(to: iconset.appendingPathComponent("icon_\(base)x\(base).png"))
    try! render(base * 2).write(to: iconset.appendingPathComponent("icon_\(base)x\(base)@2x.png"))
}
try! render(1024).write(to: root.appendingPathComponent("build/AppIcon-preview.png"))
