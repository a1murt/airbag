// Draws Airbag's app icon and writes Resources/AppIcon.icns (run: swift Scripts/make-icon.swift).
import AppKit

func draw(size: CGFloat) -> NSBitmapImageRep {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size), pixelsHigh: Int(size), bitsPerSample: 8, samplesPerPixel: 4,
                               hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let s = size
    // macOS icon grid: 824/1024 body with a soft shadow.
    let inset = s * 100 / 1024
    let body = NSRect(x: inset, y: inset * 1.1, width: s - 2 * inset, height: s - 2 * inset)
    let radius = body.width * 0.225
    let shadow = NSShadow()
    shadow.shadowColor = NSColor.black.withAlphaComponent(0.28)
    shadow.shadowBlurRadius = s * 0.025
    shadow.shadowOffset = NSSize(width: 0, height: -s * 0.012)
    NSGraphicsContext.saveGraphicsState()
    shadow.set()
    let path = NSBezierPath(roundedRect: body, xRadius: radius, yRadius: radius)
    NSColor(red: 0.07, green: 0.24, blue: 0.55, alpha: 1).setFill()
    path.fill()
    NSGraphicsContext.restoreGraphicsState()
    let gradient = NSGradient(colors: [NSColor(red: 0.13, green: 0.55, blue: 0.86, alpha: 1), NSColor(red: 0.05, green: 0.20, blue: 0.52, alpha: 1)])!
    gradient.draw(in: path, angle: -70)
    // Top highlight.
    NSGraphicsContext.saveGraphicsState()
    path.addClip()
    NSGradient(colors: [NSColor.white.withAlphaComponent(0.22), NSColor.white.withAlphaComponent(0)])!
        .draw(in: NSRect(x: body.minX, y: body.midY, width: body.width, height: body.height / 2), angle: -90)
    NSGraphicsContext.restoreGraphicsState()
    // Shield.
    let shieldSize = body.width * 0.62
    let conf = NSImage.SymbolConfiguration(pointSize: shieldSize, weight: .semibold)
        .applying(NSImage.SymbolConfiguration(paletteColors: [.white]))
    if let shield = NSImage(systemSymbolName: "shield.fill", accessibilityDescription: nil)?.withSymbolConfiguration(conf) {
        let r = NSRect(x: body.midX - shield.size.width / 2, y: body.midY - shield.size.height / 2 + body.height * 0.01, width: shield.size.width, height: shield.size.height)
        shield.draw(in: r)
        // Undo arrow inside the shield.
        let arrowConf = NSImage.SymbolConfiguration(pointSize: shieldSize * 0.42, weight: .bold)
            .applying(NSImage.SymbolConfiguration(paletteColors: [NSColor(red: 0.08, green: 0.33, blue: 0.70, alpha: 1)]))
        if let arrow = NSImage(systemSymbolName: "arrow.counterclockwise", accessibilityDescription: nil)?.withSymbolConfiguration(arrowConf) {
            arrow.draw(in: NSRect(x: r.midX - arrow.size.width / 2, y: r.midY - arrow.size.height / 2 + r.height * 0.04, width: arrow.size.width, height: arrow.size.height))
        }
    }
    NSGraphicsContext.restoreGraphicsState()
    return rep
}

let root = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : FileManager.default.currentDirectoryPath)
let iconset = root.appendingPathComponent("Resources/AppIcon.iconset")
try? FileManager.default.removeItem(at: iconset)
try! FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
for base in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let px = CGFloat(base * scale)
        let name = "icon_\(base)x\(base)\(scale == 2 ? "@2x" : "").png"
        try! draw(size: px).representation(using: .png, properties: [:])!.write(to: iconset.appendingPathComponent(name))
    }
}
try! draw(size: 1024).representation(using: .png, properties: [:])!.write(to: root.appendingPathComponent("Resources/AppIcon-1024.png"))
let p = Process()
p.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
p.arguments = ["-c", "icns", iconset.path, "-o", root.appendingPathComponent("Resources/AppIcon.icns").path]
try! p.run(); p.waitUntilExit()
try? FileManager.default.removeItem(at: iconset)
print("wrote Resources/AppIcon.icns (status \(p.terminationStatus))")
