import AppKit

let root = URL(fileURLWithPath: CommandLine.arguments[1])
let iconset = root.appendingPathComponent("AppIcon.iconset")
try? FileManager.default.removeItem(at: iconset)
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)

func shield(in rect: NSRect) -> NSBezierPath {
    let x = rect.minX
    let y = rect.minY
    let w = rect.width
    let h = rect.height
    let path = NSBezierPath()
    path.move(to: NSPoint(x: x + w * 0.50, y: y + h * 0.02))
    path.line(to: NSPoint(x: x + w * 0.96, y: y + h * 0.24))
    path.line(to: NSPoint(x: x + w * 0.96, y: y + h * 0.58))
    path.curve(
        to: NSPoint(x: x + w * 0.50, y: y + h * 0.98),
        controlPoint1: NSPoint(x: x + w * 0.96, y: y + h * 0.82),
        controlPoint2: NSPoint(x: x + w * 0.74, y: y + h * 0.98)
    )
    path.curve(
        to: NSPoint(x: x + w * 0.04, y: y + h * 0.58),
        controlPoint1: NSPoint(x: x + w * 0.26, y: y + h * 0.98),
        controlPoint2: NSPoint(x: x + w * 0.04, y: y + h * 0.82)
    )
    path.line(to: NSPoint(x: x + w * 0.04, y: y + h * 0.24))
    path.close()
    return path
}

func render(pixels: Int) -> Data {
    let size = CGFloat(pixels)
    guard let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: pixels,
        pixelsHigh: pixels,
        bitsPerSample: 8,
        samplesPerPixel: 4,
        hasAlpha: true,
        isPlanar: false,
        colorSpaceName: .deviceRGB,
        bytesPerRow: 0,
        bitsPerPixel: 0
    ) else { fatalError("bitmap") }
    rep.size = NSSize(width: size, height: size)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    NSGraphicsContext.current?.imageInterpolation = .high

    let canvas = NSRect(x: 0, y: 0, width: size, height: size)
    NSColor.clear.setFill()
    canvas.fill()

    let plate = NSBezierPath(roundedRect: canvas.insetBy(dx: size * 0.04, dy: size * 0.04), xRadius: size * 0.22, yRadius: size * 0.22)
    let gradient = NSGradient(colors: [
        NSColor(srgbRed: 0.22, green: 0.55, blue: 0.72, alpha: 1),
        NSColor(srgbRed: 0.07, green: 0.20, blue: 0.36, alpha: 1),
    ])!
    gradient.draw(in: plate, angle: 90)

    let margin = size * 0.22
    let body = shield(in: canvas.insetBy(dx: margin, dy: margin * 0.95))
    NSColor.white.withAlphaComponent(0.96).setFill()
    body.fill()

    let dotSide = size * 0.18
    let dot = NSRect(
        x: (size - dotSide) / 2,
        y: size * 0.40,
        width: dotSide,
        height: dotSide
    )
    NSColor(srgbRed: 0.13, green: 0.65, blue: 0.36, alpha: 1).setFill()
    NSBezierPath(ovalIn: dot).fill()

    NSGraphicsContext.restoreGraphicsState()
    guard let data = rep.representation(using: .png, properties: [:]) else { fatalError("png") }
    return data
}

let sizes = [16, 32, 128, 256, 512]
for size in sizes {
    try render(pixels: size).write(to: iconset.appendingPathComponent("icon_\(size)x\(size).png"))
    try render(pixels: size * 2).write(to: iconset.appendingPathComponent("icon_\(size)x\(size)@2x.png"))
}
print(iconset.path)
