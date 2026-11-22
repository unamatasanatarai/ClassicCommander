#!/usr/bin/env swift
// Rebuilds AppIcon.icns from Resources/AppIcon.png.
// Usage: swift scripts/generate_icons.swift [ResourcesDir]

import AppKit

let label = "st"
let outDir = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "Resources"

func italicBoldFont(size: CGFloat) -> NSFont {
    let base = NSFont.systemFont(ofSize: size, weight: .bold)
    let desc = base.fontDescriptor.withSymbolicTraits([.bold, .italic])
    return NSFont(descriptor: desc, size: size) ?? base
}

/// Draws a rounded badge with centred italic text into a bitmap of `pixels` x `pixels`.
func renderBadge(pixels: Int, inset: CGFloat, radius: CGFloat, fontSize: CGFloat,
                 yOffset: CGFloat, bg: NSColor, fg: NSColor) -> Data {
    let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    rep.size = NSSize(width: pixels, height: pixels)

    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)

    let rect = NSRect(x: 0, y: 0, width: pixels, height: pixels)
    bg.setFill()
    NSBezierPath(roundedRect: rect.insetBy(dx: inset, dy: inset), xRadius: radius, yRadius: radius).fill()

    let str = NSAttributedString(string: label, attributes: [
        .font: italicBoldFont(size: fontSize),
        .foregroundColor: fg,
    ])
    let s = str.size()
    str.draw(at: NSPoint(x: (rect.width - s.width) / 2, y: (rect.height - s.height) / 2 + yOffset))

    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

func write(_ data: Data, _ name: String) {
    let url = URL(fileURLWithPath: outDir).appendingPathComponent(name)
    try! data.write(to: url)
    print("wrote \(url.path)")
}

// App icon: Resources/AppIcon.png is the hand-supplied source of truth (256 px); only the
// .icns is derived from it. Sizes above the source are left out rather than upscaled.
let source = URL(fileURLWithPath: outDir).appendingPathComponent("AppIcon.png")
let iconset = FileManager.default.temporaryDirectory.appendingPathComponent("AppIcon-\(UUID().uuidString).iconset")
try! FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
let sourceImage = NSImage(contentsOf: source)!
let sourcePixels = Int(sourceImage.representations.map(\.pixelsWide).max() ?? 256)

func resized(_ pixels: Int) -> Data {
    let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    rep.size = NSSize(width: pixels, height: pixels)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    NSGraphicsContext.current?.imageInterpolation = .high
    sourceImage.draw(in: NSRect(x: 0, y: 0, width: pixels, height: pixels))
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

for base in [16, 32, 128, 256, 512] {
    for scale in [1, 2] where base * scale <= sourcePixels {
        let suffix = scale == 2 ? "@2x" : ""
        try! resized(base * scale).write(to: iconset.appendingPathComponent("icon_\(base)x\(base)\(suffix).png"))
    }
}
let icns = URL(fileURLWithPath: outDir).appendingPathComponent("AppIcon.icns")
let iconutil = Process()
iconutil.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
iconutil.arguments = ["-c", "icns", iconset.path, "-o", icns.path]
try! iconutil.run()
iconutil.waitUntilExit()
try? FileManager.default.removeItem(at: iconset)
precondition(iconutil.terminationStatus == 0, "iconutil failed")
print("wrote \(icns.path) from \(source.lastPathComponent) (\(sourcePixels) px)")

// The menu bar icon (a floppy disk) is drawn in code: StatusBarController.floppyIcon.
