#!/usr/bin/env swift
import AppKit

let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let iconDir = root.appendingPathComponent("Resources/AppIcon.icon/Assets")
let icnsURL = root.appendingPathComponent("Resources/AppIcon.icns")

let barHeights: [CGFloat] = [0.34, 0.62, 0.88, 1.0, 0.88, 0.62, 0.34]

let plateColor = NSColor(srgbRed: 0x00 / 255.0, green: 0x5B / 255.0, blue: 0xAC / 255.0, alpha: 1)

func renderPNG(_ px: Int, _ draw: (CGFloat) -> Void) -> Data {
    let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8,
        samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    rep.size = NSSize(width: px, height: px)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    NSGraphicsContext.current?.imageInterpolation = .high
    draw(CGFloat(px))
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

func drawWaveform(in box: NSRect) {
    let slots = CGFloat(barHeights.count * 2 - 1)
    let barWidth = box.width / slots
    NSColor.white.setFill()
    for (index, ratio) in barHeights.enumerated() {
        let height = box.height * ratio
        let bar = NSRect(x: box.minX + CGFloat(index) * 2 * barWidth,
                         y: box.midY - height / 2,
                         width: barWidth, height: height)
        NSBezierPath(roundedRect: bar, xRadius: barWidth / 2, yRadius: barWidth / 2).fill()
    }
}

func drawGlyph(in side: CGFloat, scale: CGFloat) {
    let width = side * scale
    let height = width * 0.62
    drawWaveform(in: NSRect(x: (side - width) / 2, y: (side - height) / 2,
                            width: width, height: height))
}

try! FileManager.default.createDirectory(at: iconDir, withIntermediateDirectories: true)
let glyphPNG = renderPNG(1024) { side in drawGlyph(in: side, scale: 0.6) }
try! glyphPNG.write(to: iconDir.appendingPathComponent("glyph.png"))
print("✓ \(iconDir.path)/glyph.png")

let iconset = FileManager.default.temporaryDirectory
    .appendingPathComponent("meeting-AppIcon-\(UUID().uuidString).iconset")
try! FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
for (points, scale) in [(16, 1), (16, 2), (32, 1), (32, 2), (128, 1), (128, 2),
                        (256, 1), (256, 2), (512, 1), (512, 2)] {
    let px = points * scale
    let png = renderPNG(px) { side in
        let inset = side * 0.1
        let plate = NSRect(x: inset, y: inset, width: side - inset * 2, height: side - inset * 2)
        plateColor.setFill()
        NSBezierPath(roundedRect: plate, xRadius: plate.width * 0.224,
                     yRadius: plate.height * 0.224).fill()
        drawGlyph(in: side, scale: 0.52)
    }
    let name = scale == 1 ? "icon_\(points)x\(points).png" : "icon_\(points)x\(points)@2x.png"
    try! png.write(to: iconset.appendingPathComponent(name))
}
let iconutil = Process()
iconutil.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
iconutil.arguments = ["-c", "icns", iconset.path, "-o", icnsURL.path]
try! iconutil.run()
iconutil.waitUntilExit()
try? FileManager.default.removeItem(at: iconset)
guard iconutil.terminationStatus == 0 else { fatalError("iconutil 실패") }
print("✓ \(icnsURL.path)")
