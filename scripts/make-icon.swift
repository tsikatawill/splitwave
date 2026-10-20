// Draws the app icon and writes Resources/AppIcon.icns (plus docs/icon.png for the website).
//   swift scripts/make-icon.swift
import AppKit

func render(_ size: Int) -> NSBitmapImageRep {
    let s = CGFloat(size)
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                               bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    // macOS icon grid: the shape fills ~80% of the canvas, with room for the system's shadow.
    let inset = s * 0.1
    let rect = NSRect(x: inset, y: inset, width: s - 2 * inset, height: s - 2 * inset)
    let shape = NSBezierPath(roundedRect: rect, xRadius: rect.width * 0.225, yRadius: rect.width * 0.225)
    NSGradient(starting: NSColor(red: 0.56, green: 0.52, blue: 0.93, alpha: 1),
               ending: NSColor(red: 0.33, green: 0.29, blue: 0.72, alpha: 1))!.draw(in: shape, angle: -90)
    // Three bars on the left, three on the right: one sound, split two ways.
    let heights: [CGFloat] = [0.22, 0.42, 0.30, 0.52, 0.36, 0.20]
    let bar = rect.width * 0.075, gap = rect.width * 0.06
    let total = CGFloat(heights.count) * bar + CGFloat(heights.count - 1) * gap + gap
    var x = rect.midX - total / 2
    for (i, h) in heights.enumerated() {
        if i == 3 { x += gap }
        let height = rect.height * h
        NSColor.white.withAlphaComponent(i < 3 ? 1 : 0.8).setFill()
        NSBezierPath(roundedRect: NSRect(x: x, y: rect.midY - height / 2, width: bar, height: height),
                     xRadius: bar / 2, yRadius: bar / 2).fill()
        x += bar + gap
    }
    NSGraphicsContext.restoreGraphicsState()
    return rep
}

let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let iconset = FileManager.default.temporaryDirectory.appendingPathComponent("AppIcon.iconset")
try? FileManager.default.removeItem(at: iconset)
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
for base in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let name = scale == 1 ? "icon_\(base)x\(base).png" : "icon_\(base)x\(base)@2x.png"
        try render(base * scale).representation(using: .png, properties: [:])!.write(to: iconset.appendingPathComponent(name))
    }
}
let task = Process()
task.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
task.arguments = ["-c", "icns", iconset.path, "-o", root.appendingPathComponent("Resources/AppIcon.icns").path]
try task.run()
task.waitUntilExit()
try FileManager.default.createDirectory(at: root.appendingPathComponent("docs"), withIntermediateDirectories: true)
try render(512).representation(using: .png, properties: [:])!.write(to: root.appendingPathComponent("docs/icon.png"))
print(task.terminationStatus == 0 ? "Wrote Resources/AppIcon.icns and docs/icon.png" : "iconutil failed")
