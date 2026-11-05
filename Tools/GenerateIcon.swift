import AppKit
import Foundation

let destination = URL(fileURLWithPath: CommandLine.arguments[1])
try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
for size in [16, 32, 64, 128, 256, 512, 1024] {
    let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
    let unit = CGFloat(size) / 1024
    let background = NSBezierPath(roundedRect: NSRect(x: 45 * unit, y: 45 * unit, width: 934 * unit, height: 934 * unit), xRadius: 220 * unit, yRadius: 220 * unit)
    NSGradient(starting: NSColor(calibratedRed: 0.52, green: 0.46, blue: 0.96, alpha: 1), ending: NSColor(calibratedRed: 0.31, green: 0.32, blue: 0.78, alpha: 1))!.draw(in: background, angle: -65)
    NSColor.white.withAlphaComponent(0.14).setFill()
    NSBezierPath(ovalIn: NSRect(x: 550 * unit, y: 540 * unit, width: 450 * unit, height: 450 * unit)).fill()
    NSColor.white.setFill()
    for (index, height) in [160, 290, 430, 540, 360, 230, 140].enumerated() {
        NSBezierPath(roundedRect: NSRect(x: CGFloat(247 + index * 78) * unit, y: CGFloat(512 - height / 2) * unit, width: 47 * unit, height: CGFloat(height) * unit), xRadius: 24 * unit, yRadius: 24 * unit).fill()
    }
    NSGraphicsContext.restoreGraphicsState()
    try bitmap.representation(using: .png, properties: [:])!.write(to: destination.appendingPathComponent("\(size).png"))
}
