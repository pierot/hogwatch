// Generates AppIcon.icns. Run once (or after design changes):
//   swift gen_icon.swift
import AppKit

let master: CGFloat = 1024
let inset: CGFloat = 100   // Apple icon-grid margin around the squircle
let radius: CGFloat = 185

// SF Symbols render as templates (black); composite the tint on top.
func tinted(_ image: NSImage, _ color: NSColor) -> NSImage {
    let out = NSImage(size: image.size)
    out.lockFocus()
    image.draw(in: NSRect(origin: .zero, size: image.size))
    color.set()
    NSRect(origin: .zero, size: image.size).fill(using: .sourceAtop)
    out.unlockFocus()
    return out
}

func drawMaster() -> NSImage {
    let img = NSImage(size: NSSize(width: master, height: master))
    img.lockFocus()

    let rect = NSRect(x: inset, y: inset, width: master - inset * 2, height: master - inset * 2)
    let squircle = NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius)
    NSGradient(colors: [
        NSColor(calibratedRed: 0.98, green: 0.55, blue: 0.12, alpha: 1),
        NSColor(calibratedRed: 0.82, green: 0.20, blue: 0.08, alpha: 1),
    ])!.draw(in: squircle, angle: -90)

    let config = NSImage.SymbolConfiguration(pointSize: 440, weight: .medium)
    if let symbol = NSImage(systemSymbolName: "cpu", accessibilityDescription: nil)?
        .withSymbolConfiguration(config) {
        let white = tinted(symbol, .white)
        let target: CGFloat = 540
        let scale = target / max(white.size.width, white.size.height)
        let w = white.size.width * scale
        let h = white.size.height * scale
        white.draw(in: NSRect(x: (master - w) / 2, y: (master - h) / 2, width: w, height: h))
    }

    img.unlockFocus()
    return img
}

func writePNG(_ image: NSImage, px: Int, to url: URL) throws {
    let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
    )!
    rep.size = NSSize(width: px, height: px)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    image.draw(in: NSRect(x: 0, y: 0, width: px, height: px),
               from: .zero, operation: .copy, fraction: 1)
    NSGraphicsContext.restoreGraphicsState()
    try rep.representation(using: .png, properties: [:])!.write(to: url)
}

let fm = FileManager.default
let iconset = URL(fileURLWithPath: "AppIcon.iconset")
try? fm.removeItem(at: iconset)
try fm.createDirectory(at: iconset, withIntermediateDirectories: true)

let image = drawMaster()
for size in [16, 32, 128, 256, 512] {
    try writePNG(image, px: size, to: iconset.appendingPathComponent("icon_\(size)x\(size).png"))
    try writePNG(image, px: size * 2, to: iconset.appendingPathComponent("icon_\(size)x\(size)@2x.png"))
}

let iconutil = Process()
iconutil.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
iconutil.arguments = ["-c", "icns", "AppIcon.iconset", "-o", "AppIcon.icns"]
try iconutil.run()
iconutil.waitUntilExit()
guard iconutil.terminationStatus == 0 else {
    fatalError("iconutil failed")
}
try fm.removeItem(at: iconset)
print("Wrote AppIcon.icns")
