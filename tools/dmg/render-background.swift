import AppKit

// A build-time asset renderer, not a UI automation script. Finder renders the
// actual draggable app and Applications icons on top of this background.
struct Layout: Decodable {
    let width: CGFloat
    let height: CGFloat
    let iconY: CGFloat
    let appX: CGFloat
    let applicationsX: CGFloat
}

guard CommandLine.arguments.count == 3 else {
    fatalError("Usage: render-background.swift layout.json output-directory")
}
let layout = try JSONDecoder().decode(Layout.self,
    from: Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1])))
let output = URL(fileURLWithPath: CommandLine.arguments[2], isDirectory: true)

func color(_ hex: UInt32) -> NSColor {
    NSColor(srgbRed: CGFloat((hex >> 16) & 255) / 255,
        green: CGFloat((hex >> 8) & 255) / 255, blue: CGFloat(hex & 255) / 255, alpha: 1)
}

func label(_ text: String, top: CGFloat, size: CGFloat, weight: NSFont.Weight, ink: UInt32) {
    let paragraph = NSMutableParagraphStyle()
    paragraph.alignment = .center
    (text as NSString).draw(in: NSRect(x: 24, y: top, width: layout.width - 48, height: size * 1.8),
        withAttributes: [.font: NSFont.systemFont(ofSize: size, weight: weight),
            .foregroundColor: color(ink), .paragraphStyle: paragraph])
}

for scale in [1, 2] {
    let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil,
        pixelsWide: Int(layout.width) * scale, pixelsHigh: Int(layout.height) * scale,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    bitmap.size = NSSize(width: layout.width, height: layout.height)
    let context = NSGraphicsContext(bitmapImageRep: bitmap)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = context
    let transform = NSAffineTransform()
    // bitmap.size already gives this context a points-to-pixels transform (2x
    // for Retina). Scaling again produces 4x, shifting/cropping the 2x artwork.
    // Only flip the logical point coordinate system to match Finder's icons.
    transform.translateX(by: 0, yBy: layout.height)
    transform.scaleX(by: 1, yBy: -1)
    transform.concat()
    // Explicitly flipped text keeps the raster and Finder icon coordinates aligned.
    NSGraphicsContext.current = NSGraphicsContext(cgContext: context.cgContext, flipped: true)

    let canvas = NSRect(x: 0, y: 0, width: layout.width, height: layout.height)
    color(0xF4F5F7).setFill()
    canvas.fill()
    let glow = NSGradient(starting: color(0xF7F8FA), ending: color(0xE9EDF5))!
    glow.draw(in: canvas, angle: 90)

    // A small notch silhouette links the installer to the app without competing
    // with the two real, full-size Finder icons.
    color(0x181C25).setFill()
    NSBezierPath(roundedRect: NSRect(x: layout.width / 2 - 25, y: -12, width: 50, height: 28),
        xRadius: 10, yRadius: 10).fill()
    label("Make room for Nook.", top: 43, size: 27, weight: .semibold, ink: 0x202532)
    label("Drag Nook to Applications to install.", top: 83, size: 14, weight: .regular, ink: 0x626B7C)

    let arrow = NSBezierPath()
    let center = (layout.appX + layout.applicationsX) / 2
    arrow.move(to: NSPoint(x: center - 23, y: layout.iconY))
    arrow.line(to: NSPoint(x: center + 23, y: layout.iconY))
    arrow.move(to: NSPoint(x: center + 14, y: layout.iconY - 9))
    arrow.line(to: NSPoint(x: center + 23, y: layout.iconY))
    arrow.line(to: NSPoint(x: center + 14, y: layout.iconY + 9))
    arrow.lineWidth = 2.5
    arrow.lineCapStyle = .round
    arrow.lineJoinStyle = .round
    color(0x929BAD).setStroke()
    arrow.stroke()

    label("Then open Nook from Applications.", top: 302, size: 12, weight: .regular, ink: 0x788190)
    NSGraphicsContext.restoreGraphicsState()
    let suffix = scale == 1 ? "" : "@2x"
    let data = bitmap.representation(using: .png, properties: [:])!
    try data.write(to: output.appendingPathComponent("background\(suffix).png"))
}
