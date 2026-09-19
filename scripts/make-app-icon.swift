import AppKit
import Foundation

// BatteryControl app icon generator.
// Draws a macOS-style icon: rounded squircle, blue→teal gradient,
// a battery with an 80% fill and a charge-limit line, and a lightning bolt.
// Output: icon_512x512@2x.png (and 512/256/128/64/32/16 derivatives) in /tmp/bc-icon.

let root = "/tmp/bc-icon"
try? FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)

let size = CGFloat(1024)
let rect = NSRect(x: 0, y: 0, width: size, height: size)

let image = NSImage(size: rect.size)
image.lockFocus()
guard let ctx = NSGraphicsContext.current?.cgContext else {
    fputs("no graphics context\n", stderr)
    exit(1)
}
ctx.setShouldAntialias(true)

// MARK: - Background squircle (macOS icon grid: ~824/1024 corner radius)

let s = size / 1024.0
let bgRect = CGRect(x: 100 * s, y: 100 * s, width: 824 * s, height: 824 * s)
let squircle = NSBezierPath(roundedRect: bgRect, xRadius: 185 * s, yRadius: 185 * s)
squircle.windingRule = .evenOdd
squircle.addClip()

// Vertical gradient: deep blue → teal.
let gradient = NSGradient(starting: NSColor(calibratedRed: 0.10, green: 0.26, blue: 0.60, alpha: 1),
                          ending: NSColor(calibratedRed: 0.06, green: 0.55, blue: 0.55, alpha: 1))!
gradient.draw(in: bgRect, angle: -90)

// Subtle top sheen for depth.
let sheen = NSGradient(colors: [
    NSColor(white: 1.0, alpha: 0.18),
    NSColor(white: 1.0, alpha: 0.0),
])!
sheen.draw(in: CGRect(x: bgRect.minX, y: bgRect.midY - 10 * s, width: bgRect.width, height: bgRect.height / 2), angle: -90)

// MARK: - Battery body

// Centered, landscape battery. macOS grid keeps content inside ~824 box.
let bodyW = 520 * s
let bodyH = 240 * s
let bodyX = (size - bodyW) / 2 - 20 * s // leave room for the terminal cap on the right
let bodyY = (size - bodyH) / 2
let bodyRect = CGRect(x: bodyX, y: bodyY, width: bodyW, height: bodyH)
let bodyPath = NSBezierPath(roundedRect: bodyRect, xRadius: 56 * s, yRadius: 56 * s)

// Terminal cap (nub) on the right.
let capW = 44 * s
let capH = 92 * s
let capRect = CGRect(x: bodyRect.maxX + 14 * s, y: bodyY + (bodyH - capH) / 2, width: capW, height: capH)
let capPath = NSBezierPath(roundedRect: capRect, xRadius: 16 * s, yRadius: 16 * s)

// White outline (10% of body height, macOS-friendly weight).
ctx.saveGState()
let outlineWidth = 26 * s
NSColor.white.setStroke()
bodyPath.lineWidth = outlineWidth
bodyPath.stroke()
capPath.lineWidth = outlineWidth
capPath.stroke()
ctx.restoreGState()

// MARK: - Charge fill (80%) inside the outline

let inset = 30 * s
let innerRect = bodyRect.insetBy(dx: inset, dy: inset)
let fillFraction = CGFloat(0.80)
let fillRect = CGRect(x: innerRect.minX, y: innerRect.minY,
                      width: innerRect.width * fillFraction, height: innerRect.height)
let fillPath = NSBezierPath(roundedRect: fillRect, xRadius: 30 * s, yRadius: 30 * s)
let fillGradient = NSGradient(starting: NSColor(calibratedRed: 0.55, green: 0.93, blue: 0.40, alpha: 1),
                              ending: NSColor(calibratedRed: 0.20, green: 0.78, blue: 0.45, alpha: 1))!
fillGradient.draw(in: fillPath, angle: -90)

// Charge-limit line at 80% (thin white notch on the right edge of the fill).
ctx.saveGState()
let limitX = innerRect.minX + innerRect.width * fillFraction
let limitLine = NSBezierPath()
limitLine.move(to: CGPoint(x: limitX, y: innerRect.minY - 6 * s))
limitLine.line(to: CGPoint(x: limitX, y: innerRect.maxY + 6 * s))
NSColor(white: 1.0, alpha: 0.95).setStroke()
limitLine.lineWidth = 10 * s
limitLine.lineCapStyle = .round
limitLine.stroke()
ctx.restoreGState()

// MARK: - Lightning bolt over the fill

let bolt = NSBezierPath()
let cx = innerRect.midX
let cy = innerRect.midY
let u = innerRect.height // unit scale
// Proportions kept within the battery interior (max ±0.42u vertically).
bolt.move(to: CGPoint(x: cx + 0.08 * u, y: cy + 0.42 * u))
bolt.line(to: CGPoint(x: cx - 0.22 * u, y: cy - 0.02 * u))
bolt.line(to: CGPoint(x: cx - 0.04 * u, y: cy - 0.02 * u))
bolt.line(to: CGPoint(x: cx - 0.10 * u, y: cy - 0.42 * u))
bolt.line(to: CGPoint(x: cx + 0.22 * u, y: cy + 0.06 * u))
bolt.line(to: CGPoint(x: cx + 0.04 * u, y: cy + 0.06 * u))
bolt.close()
NSColor(white: 1.0, alpha: 0.98).setFill()
bolt.fill()
// Soft shadow under the bolt for separation.
ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -3 * s), blur: 10 * s,
              color: NSColor(calibratedWhite: 0, alpha: 0.35).cgColor)
bolt.fill()
ctx.restoreGState()

image.unlockFocus()

// MARK: - Export all required sizes

guard let tiff = image.tiffRepresentation,
      let rep = NSBitmapImageRep(data: tiff) else {
    fputs("failed to get bitmap rep\n", stderr)
    exit(1)
}

let outputs: [(String, Int)] = [
    ("icon_512x512@2x.png", 1024),
    ("icon_512x512.png", 512),
    ("icon_256x256@2x.png", 512),
    ("icon_256x256.png", 256),
    ("icon_128x128@2x.png", 256),
    ("icon_128x128.png", 128),
    ("icon_32x32@2x.png", 64),
    ("icon_32x32.png", 32),
    ("icon_16x16@2x.png", 32),
    ("icon_16x16.png", 16),
]

func scaledPNG(_ src: NSImage, pixels: Int) -> Data? {
    guard let scaled = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: pixels,
        pixelsHigh: pixels,
        bitsPerSample: 8,
        samplesPerPixel: 4,
        hasAlpha: true,
        isPlanar: false,
        colorSpaceName: .calibratedRGB,
        bytesPerRow: 0,
        bitsPerPixel: 0
    ) else { return nil }
    scaled.size = NSSize(width: pixels, height: pixels)
    guard let ctx = NSGraphicsContext(bitmapImageRep: scaled) else { return nil }
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = ctx
    src.draw(in: NSRect(x: 0, y: 0, width: pixels, height: pixels),
             from: NSRect(x: 0, y: 0, width: src.size.width, height: src.size.height),
             operation: .copy, fraction: 1.0)
    NSGraphicsContext.restoreGraphicsState()
    return scaled.representation(using: NSBitmapImageRep.FileType.png, properties: [:])
}

for (name, pixels) in outputs {
    guard let png = scaledPNG(image, pixels: pixels) else {
        fputs("scale/encode failed for \(name)\n", stderr)
        exit(1)
    }
    try png.write(to: URL(fileURLWithPath: "\(root)/\(name)"))
    print("wrote \(name) (\(pixels)px)")
}
print("done")
