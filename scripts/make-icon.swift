// Renders the app icon: an ember-coloured flame on a dark squircle.
// Usage: swift scripts/make-icon.swift Resources/AppIcon.icns
import AppKit

let output = CommandLine.arguments.dropFirst().first ?? "AppIcon.icns"
let iconset = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("Smolder.iconset")
try? FileManager.default.removeItem(at: iconset)
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)

func render(_ size: CGFloat) -> NSBitmapImageRep {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size), pixelsHigh: Int(size), bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let s = size / 1024
    // macOS icon grid: 824 pt body centred in 1024, corner radius ~185
    let body = NSRect(x: 100 * s, y: 100 * s, width: 824 * s, height: 824 * s)
    let squircle = NSBezierPath(roundedRect: body, xRadius: 185 * s, yRadius: 185 * s)
    NSGradient(colors: [NSColor(srgbRed: 0.17, green: 0.15, blue: 0.15, alpha: 1), NSColor(srgbRed: 0.07, green: 0.06, blue: 0.07, alpha: 1)])!
        .draw(in: squircle, angle: -90)
    // Soft ember glow near the bottom
    NSGraphicsContext.current?.saveGraphicsState()
    squircle.addClip()
    NSGradient(colors: [NSColor(srgbRed: 1, green: 0.42, blue: 0.1, alpha: 0.35), NSColor(srgbRed: 1, green: 0.42, blue: 0.1, alpha: 0)])!
        .draw(fromCenter: NSPoint(x: 512 * s, y: 250 * s), radius: 0, toCenter: NSPoint(x: 512 * s, y: 250 * s), radius: 520 * s, options: [])
    NSGraphicsContext.current?.restoreGraphicsState()
    // Flame glyph filled with an ember gradient
    let config = NSImage.SymbolConfiguration(pointSize: 470 * s, weight: .regular)
    if let symbol = NSImage(systemSymbolName: "flame.fill", accessibilityDescription: nil)?.withSymbolConfiguration(config) {
        let glyph = symbol.size
        let rect = NSRect(x: (1024 * s - glyph.width) / 2, y: (1024 * s - glyph.height) / 2 + 10 * s, width: glyph.width, height: glyph.height)
        let mask = NSImage(size: glyph, flipped: false) { r in symbol.draw(in: r); return true }
        let fill = NSImage(size: glyph, flipped: false) { r in
            NSGradient(colors: [NSColor(srgbRed: 1, green: 0.83, blue: 0.35, alpha: 1),
                                NSColor(srgbRed: 1, green: 0.45, blue: 0.12, alpha: 1),
                                NSColor(srgbRed: 0.86, green: 0.17, blue: 0.12, alpha: 1)])!.draw(in: r, angle: -90)
            mask.draw(in: r, from: .zero, operation: .destinationIn, fraction: 1)
            return true
        }
        fill.draw(in: rect)
    }
    NSGraphicsContext.restoreGraphicsState()
    return rep
}

for base in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let px = CGFloat(base * scale)
        let name = scale == 1 ? "icon_\(base)x\(base).png" : "icon_\(base)x\(base)@2x.png"
        try render(px).representation(using: .png, properties: [:])!.write(to: iconset.appendingPathComponent(name))
    }
}
let task = Process()
task.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
task.arguments = ["-c", "icns", iconset.path, "-o", output]
try task.run(); task.waitUntilExit()
try render(1024).representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: (output as NSString).deletingPathExtension + ".png"))
print("wrote \(output)")
