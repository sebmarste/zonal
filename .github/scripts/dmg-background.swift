import AppKit

// Finder uses this at 640 × 400 points; the 2× TIFF keeps the instruction crisp.
let size = NSSize(width: 640, height: 400)
let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 1280, pixelsHigh: 800,
    bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
    colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
bitmap.size = size
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
NSColor(calibratedRed: 0.94, green: 0.96, blue: 0.99, alpha: 1).setFill()
NSRect(origin: .zero, size: size).fill()
func label(_ text: String, y: CGFloat, size: CGFloat, weight: NSFont.Weight, color: NSColor) {
    let style = NSMutableParagraphStyle()
    style.alignment = .center
    (text as NSString).draw(in: NSRect(x: 24, y: y, width: 592, height: 44), withAttributes: [
        .font: NSFont.systemFont(ofSize: size, weight: weight),
        .foregroundColor: color, .paragraphStyle: style
    ])
}
label("Install Zonal", y: 318, size: 28, weight: .semibold, color: .init(calibratedWhite: 0.14, alpha: 1))
label("Drag Zonal to Applications", y: 278, size: 17, weight: .regular, color: .init(calibratedWhite: 0.35, alpha: 1))
let arrow = NSBezierPath()
arrow.move(to: NSPoint(x: 284, y: 196))
arrow.line(to: NSPoint(x: 354, y: 196))
arrow.move(to: NSPoint(x: 341, y: 209))
arrow.line(to: NSPoint(x: 354, y: 196))
arrow.line(to: NSPoint(x: 341, y: 183))
arrow.lineWidth = 4
arrow.lineCapStyle = .round
arrow.lineJoinStyle = .round
NSColor(calibratedRed: 0.20, green: 0.45, blue: 0.80, alpha: 1).setStroke()
arrow.stroke()
label("Then open Zonal from Applications.", y: 36, size: 14, weight: .regular,
      color: .init(calibratedWhite: 0.40, alpha: 1))
NSGraphicsContext.restoreGraphicsState()
try bitmap.tiffRepresentation!.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
