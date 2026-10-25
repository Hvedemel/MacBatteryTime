import AppKit

// Original vector artwork, rendered at each native icon size without external assets.
let root = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
let iconset = root.appendingPathComponent("AppIcon.iconset", isDirectory: true)
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)

func drawIcon(size: Int) throws -> Data {
    let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size,
                                  bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                  isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
    let context = NSGraphicsContext.current!.cgContext
    context.scaleBy(x: Double(size) / 1024, y: Double(size) / 1024)

    let tile = NSBezierPath(roundedRect: NSRect(x: 48, y: 48, width: 928, height: 928), xRadius: 210, yRadius: 210)
    let shadow = NSShadow()
    shadow.shadowColor = NSColor.black.withAlphaComponent(0.20)
    shadow.shadowBlurRadius = 24
    shadow.shadowOffset = NSSize(width: 0, height: -8)
    shadow.set()
    NSGradient(colors: [NSColor(calibratedRed: 0.24, green: 0.83, blue: 0.59, alpha: 1),
                        NSColor(calibratedRed: 0.035, green: 0.42, blue: 0.38, alpha: 1)])!.draw(in: tile, angle: -70)
    NSShadow().set()
    NSColor.white.withAlphaComponent(0.22).setStroke()
    tile.lineWidth = 2
    tile.stroke()

    let battery = NSBezierPath(roundedRect: NSRect(x: 211, y: 354, width: 568, height: 332), xRadius: 63, yRadius: 63)
    NSColor.white.withAlphaComponent(0.12).setFill()
    battery.fill()
    NSColor.white.withAlphaComponent(0.97).setStroke()
    battery.lineWidth = 24
    battery.stroke()
    NSColor.white.withAlphaComponent(0.85).setFill()
    NSBezierPath(roundedRect: NSRect(x: 804, y: 464, width: 25, height: 111), xRadius: 12, yRadius: 12).fill()

    let clock = NSBezierPath(ovalIn: NSRect(x: 386, y: 409, width: 220, height: 220))
    clock.lineWidth = 20
    clock.stroke()
    let hands = NSBezierPath()
    hands.move(to: NSPoint(x: 496, y: 584))
    hands.line(to: NSPoint(x: 496, y: 519))
    hands.line(to: NSPoint(x: 544, y: 484))
    hands.lineWidth = 20
    hands.lineCapStyle = .round
    hands.lineJoinStyle = .round
    hands.stroke()
    NSGraphicsContext.restoreGraphicsState()
    return bitmap.representation(using: .png, properties: [:])!
}

for base in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let name = "icon_\(base)x\(base)\(scale == 2 ? "@2x" : "").png"
        try drawIcon(size: base * scale).write(to: iconset.appendingPathComponent(name))
    }
}
try drawIcon(size: 1024).write(to: root.appendingPathComponent("AppIcon.png"))
func bigEndian32(_ value: Int) -> Data {
    Data([UInt8(truncatingIfNeeded: value >> 24), UInt8(truncatingIfNeeded: value >> 16),
          UInt8(truncatingIfNeeded: value >> 8), UInt8(truncatingIfNeeded: value)])
}
let representations = [
    ("icp4", "icon_16x16.png"), ("icp5", "icon_32x32.png"), ("icp6", "icon_32x32@2x.png"),
    ("ic07", "icon_128x128.png"), ("ic08", "icon_256x256.png"), ("ic09", "icon_512x512.png"),
    ("ic10", "icon_512x512@2x.png"), ("ic11", "icon_16x16@2x.png"), ("ic12", "icon_32x32@2x.png"),
    ("ic13", "icon_128x128@2x.png"), ("ic14", "icon_256x256@2x.png")
]
var body = Data()
for (type, name) in representations {
    let png = try Data(contentsOf: iconset.appendingPathComponent(name))
    body.append(Data(type.utf8))
    body.append(bigEndian32(png.count + 8))
    body.append(png)
}
try (Data("icns".utf8) + bigEndian32(body.count + 8) + body).write(to: root.appendingPathComponent("AppIcon.icns"))
print("Generated BatteryTime icon artwork at \(root.path)")
