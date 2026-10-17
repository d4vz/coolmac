import AppKit

// Generates AppIcon.iconset PNGs: dark rounded tile, gauge ring,
// and a 4-blade fan in the middle. Run via scripts/build-app.sh.
let outDir = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "AppIcon.iconset"
try? FileManager.default.createDirectory(atPath: outDir, withIntermediateDirectories: true)

func render(size: Int) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size,
                               bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                               isPlanar: false, colorSpaceName: .deviceRGB,
                               bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let s = CGFloat(size)
    let scale = s / 1024

    // Background: dark rounded tile with a subtle purple gradient.
    let bg = NSBezierPath(roundedRect: NSRect(x: 60 * scale, y: 60 * scale, width: 904 * scale, height: 904 * scale),
                          xRadius: 200 * scale, yRadius: 200 * scale)
    NSGradient(colors: [NSColor(calibratedRed: 0.13, green: 0.12, blue: 0.22, alpha: 1),
                        NSColor(calibratedRed: 0.05, green: 0.05, blue: 0.10, alpha: 1)])?
        .draw(in: bg, angle: -90)

    // Gauge ring.
    let center = NSPoint(x: 512 * scale, y: 512 * scale)
    let ringRect = NSRect(x: center.x - 330 * scale, y: center.y - 330 * scale,
                          width: 660 * scale, height: 660 * scale)
    let track = NSBezierPath(ovalIn: ringRect)
    track.lineWidth = 56 * scale
    NSColor.white.withAlphaComponent(0.14).setStroke()
    track.stroke()
    let gauge = NSBezierPath()
    gauge.appendArc(withCenter: center, radius: 330 * scale, startAngle: 90, endAngle: -140, clockwise: true)
    gauge.lineWidth = 56 * scale
    gauge.lineCapStyle = .round
    NSColor(calibratedRed: 0.78, green: 0.35, blue: 0.85, alpha: 1).setStroke()
    gauge.stroke()

    // Fan blades.
    NSColor.white.setFill()
    for i in 0..<4 {
        let angle = CGFloat(i) * 90
        let blade = NSBezierPath()
        let r0: CGFloat = 62 * scale, r1: CGFloat = 218 * scale
        let a = angle * .pi / 180, spread: CGFloat = 0.62
        blade.move(to: NSPoint(x: center.x + r0 * cos(a), y: center.y + r0 * sin(a)))
        blade.line(to: NSPoint(x: center.x + r1 * cos(a + spread * 0.4), y: center.y + r1 * sin(a + spread * 0.4)))
        blade.curve(to: NSPoint(x: center.x + r0 * cos(a + spread), y: center.y + r0 * sin(a + spread)),
                    controlPoint1: NSPoint(x: center.x + r1 * cos(a + spread), y: center.y + r1 * sin(a + spread)),
                    controlPoint2: NSPoint(x: center.x + (r0 + 40 * scale) * cos(a + spread), y: center.y + (r0 + 40 * scale) * sin(a + spread)))
        blade.close()
        blade.fill()
    }
    let hub = NSBezierPath(ovalIn: NSRect(x: center.x - 58 * scale, y: center.y - 58 * scale,
                                          width: 116 * scale, height: 116 * scale))
    hub.fill()

    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

for (name, px) in [("icon_16x16", 16), ("icon_16x16@2x", 32), ("icon_32x32", 32),
                   ("icon_32x32@2x", 64), ("icon_128x128", 128), ("icon_128x128@2x", 256),
                   ("icon_256x256", 256), ("icon_256x256@2x", 512),
                   ("icon_512x512", 512), ("icon_512x512@2x", 1024)] {
    try! render(size: px).write(to: URL(fileURLWithPath: "\(outDir)/\(name).png"))
}
print("iconset written to \(outDir)")
