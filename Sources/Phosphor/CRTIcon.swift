import AppKit
import PhosphorCore

/// Mini CRT for the menu bar. The screen fills from the bottom with the usage percent.
/// Drawn in colour (not a template image) so it stays readable on light and dark menu bars.
enum CRTIcon {
    static let pointSize: CGFloat = 18

    static func image(fill: Double, band: IconColor.Band) -> NSImage {
        let points = NSSize(width: pointSize, height: pointSize)
        let image = NSImage(size: points)
        image.isTemplate = false
        for scale in [1, 2] {
            let pixels = Int(pointSize) * scale
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
            ) else { continue }
            // Point size stays 18×18. The 36-pixel rep is the @2x backing store, not a bigger icon.
            // The bitmap context's user space is that point size, so drawing must use points.
            // Drawing `pixels` (36) here used to paint a double-size glyph and Retina showed only the left half.
            rep.size = points
            NSGraphicsContext.saveGraphicsState()
            if let ctx = NSGraphicsContext(bitmapImageRep: rep) {
                NSGraphicsContext.current = ctx
                draw(side: pointSize, fill: CGFloat(min(1, max(0, fill))), band: band)
            }
            NSGraphicsContext.restoreGraphicsState()
            image.addRepresentation(rep)
        }
        return image
    }

    /// User space is points. AppKit's bitmap context is flipped: y grows downward.
    /// The phosphor fill grows upward from the screen bottom.
    private static func draw(side: CGFloat, fill: CGFloat, band: IconColor.Band) {
        let u = side / 18
        func p(_ value: CGFloat) -> CGFloat { (value * u).rounded() }

        let body = NSRect(x: p(1), y: p(0.5), width: p(16), height: p(14.2))
        let stand = NSRect(x: p(6.2), y: p(15), width: p(5.6), height: p(2.2))
        let outline = body.insetBy(dx: -max(1, p(0.6)) / 2, dy: -max(1, p(0.6)) / 2)
        let screen = NSRect(x: body.minX + p(2.3), y: body.minY + p(2.1),
                            width: body.width - p(4.6), height: body.height - p(4.6))

        NSColor(calibratedWhite: 0.94, alpha: 1).setStroke()
        let ring = NSBezierPath(roundedRect: outline, xRadius: p(3.4), yRadius: p(3.4))
        ring.lineWidth = max(1, p(1))
        ring.stroke()

        NSColor(calibratedWhite: 0.10, alpha: 1).setFill()
        NSBezierPath(roundedRect: body, xRadius: p(2.8), yRadius: p(2.8)).fill()
        NSBezierPath(roundedRect: stand, xRadius: p(0.8), yRadius: p(0.8)).fill()

        NSColor(calibratedRed: 0.07, green: 0.08, blue: 0.10, alpha: 1).setFill()
        NSBezierPath(roundedRect: screen, xRadius: p(1.2), yRadius: p(1.2)).fill()

        let level = (screen.height * fill).rounded()
        if level >= 1 {
            let phosphor = NSRect(x: screen.minX, y: screen.maxY - level, width: screen.width, height: level)
            swatch(band).setFill()
            NSBezierPath(roundedRect: phosphor, xRadius: p(1), yRadius: p(1)).fill()
        }

        let glass = NSRect(x: screen.minX + p(0.6), y: screen.minY + p(0.5),
                           width: screen.width - p(1.2), height: p(1.3))
        NSColor(calibratedWhite: 1, alpha: 0.18).setFill()
        NSBezierPath(roundedRect: glass, xRadius: p(0.6), yRadius: p(0.6)).fill()
    }

    static func swatch(_ band: IconColor.Band) -> NSColor {
        switch band {
        case .green: return NSColor(calibratedRed: 0.22, green: 0.80, blue: 0.45, alpha: 1)
        case .yellow: return NSColor(calibratedRed: 0.95, green: 0.74, blue: 0.22, alpha: 1)
        case .red: return NSColor(calibratedRed: 0.93, green: 0.30, blue: 0.27, alpha: 1)
        case .neutral: return NSColor(calibratedWhite: 0.42, alpha: 1)
        }
    }
}
