import AppKit

let output = URL(fileURLWithPath: CommandLine.arguments[1])
try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)

func drawIcon(size: Int) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let scale = CGFloat(size) / 1024
    let transform = AffineTransform(scale: scale)
    (transform as NSAffineTransform).concat()
    let body = NSBezierPath(roundedRect: NSRect(x: 62, y: 62, width: 900, height: 900), xRadius: 206, yRadius: 206)
    NSColor(red: 0.12, green: 0.24, blue: 0.4, alpha: 1).setFill(); body.fill()
    let film = NSBezierPath(roundedRect: NSRect(x: 185, y: 260, width: 654, height: 505), xRadius: 36, yRadius: 36)
    NSColor(red: 0.9, green: 0.95, blue: 1, alpha: 1).setFill(); film.fill()
    NSColor(red: 0.23, green: 0.49, blue: 0.83, alpha: 1).setFill()
    NSBezierPath(roundedRect: NSRect(x: 249, y: 353, width: 526, height: 319), xRadius: 12, yRadius: 12).fill()
    NSColor(red: 0.12, green: 0.24, blue: 0.4, alpha: 1).setFill()
    for column in 0..<7 {
        for row in [291, 704] { NSBezierPath(roundedRect: NSRect(x: 229 + column * 84, y: row, width: 39, height: 30), xRadius: 6, yRadius: 6).fill() }
    }
    NSColor.white.setStroke()
    let frame = NSBezierPath(); frame.lineWidth = 14; frame.lineCapStyle = .round; frame.lineJoinStyle = .round
    for (x, y, sx, sy) in [(335.0, 424.0, 1.0, 1.0), (689.0, 424.0, -1.0, 1.0), (335.0, 601.0, 1.0, -1.0), (689.0, 601.0, -1.0, -1.0)] {
        frame.move(to: NSPoint(x: x, y: y + sy * 52)); frame.line(to: NSPoint(x: x, y: y)); frame.line(to: NSPoint(x: x + sx * 52, y: y))
    }
    frame.stroke()
    NSColor(red: 0.85, green: 0.33, blue: 0.48, alpha: 1).setFill()
    NSBezierPath(ovalIn: NSRect(x: 641, y: 161, width: 239, height: 239)).fill()
    let heart = NSBezierPath()
    heart.move(to: NSPoint(x: 760, y: 218))
    heart.curve(to: NSPoint(x: 691, y: 309), controlPoint1: NSPoint(x: 705, y: 258), controlPoint2: NSPoint(x: 691, y: 278))
    heart.curve(to: NSPoint(x: 760, y: 327), controlPoint1: NSPoint(x: 691, y: 350), controlPoint2: NSPoint(x: 739, y: 359))
    heart.curve(to: NSPoint(x: 829, y: 309), controlPoint1: NSPoint(x: 783, y: 359), controlPoint2: NSPoint(x: 829, y: 350))
    heart.curve(to: NSPoint(x: 760, y: 218), controlPoint1: NSPoint(x: 829, y: 278), controlPoint2: NSPoint(x: 815, y: 258))
    heart.close(); NSColor.white.setFill(); heart.fill()
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}
for size in [16, 32, 128, 256, 512] {
    try drawIcon(size: size).write(to: output.appendingPathComponent("icon_\(size)x\(size).png"))
    try drawIcon(size: size * 2).write(to: output.appendingPathComponent("icon_\(size)x\(size)@2x.png"))
}
