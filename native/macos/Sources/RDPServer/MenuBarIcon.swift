import AppKit

/// Menu bar status item artwork.
///
/// Every state is a template image, so macOS tints it black on a light menu bar
/// and white on a dark one — exactly like the built-in status items. The glyph
/// is a vector redraw of the app artwork (`Resources/AppIcon-art.png`): a wide
/// pager body with a belt clip, an inset screen and three front controls.
///
/// State is encoded by shape inside the screen, never by colour:
///   disabled           -> empty screen
///   starting/stopping  -> hollow dot
///   running            -> filled dot
///   error              -> filled dot with a knocked-out exclamation mark
enum MenuBarIcon {
    static let size = NSSize(width: 20, height: 18)

    static func image(for state: UIServiceState) -> NSImage {
        let image = NSImage(size: size)
        // 1x + 2x reps keep the glyph crisp on Retina and on external 1x panels.
        for scale in [CGFloat(1), CGFloat(2)] {
            if let rep = representation(scale: scale, state: state) {
                image.addRepresentation(rep)
            }
        }
        image.isTemplate = true
        image.accessibilityDescription = "RDP 远程桌面"
        return image
    }

    // MARK: - Bitmap rendering

    private static func representation(scale: CGFloat, state: UIServiceState) -> NSBitmapImageRep? {
        // An explicit CGContext keeps the mapping predictable: user space is
        // points, one point is ``scale`` pixels.
        guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(
                  data: nil,
                  width: Int(size.width * scale),
                  height: Int(size.height * scale),
                  bitsPerComponent: 8,
                  bytesPerRow: 0,
                  space: colorSpace,
                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              ) else {
            return nil
        }
        context.scaleBy(x: scale, y: scale)
        context.setShouldAntialias(true)

        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
        drawPager()
        drawStateDot(for: state)
        NSGraphicsContext.restoreGraphicsState()

        guard let cgImage = context.makeImage() else { return nil }
        let rep = NSBitmapImageRep(cgImage: cgImage)
        rep.size = size
        return rep
    }

    // MARK: - Glyph (20 x 18 pt coordinate space, origin bottom-left)

    private static func drawPager() {
        stroke(NSRect(x: 1.2, y: 1.9, width: 17.6, height: 12.2), radius: 2.5, width: 1.55)
        // Belt clip: a loop above the body; the body outline hides its legs.
        stroke(NSRect(x: 6.2, y: 13.3, width: 7.6, height: 3.0), radius: 1.4, width: 1.45)
        // Inset screen.
        stroke(NSRect(x: 3.3, y: 8.0, width: 13.4, height: 3.9), radius: 1.0, width: 1.45)

        NSColor.black.setFill()
        triangle(left: true).fill()
        triangle(left: false).fill()
        NSBezierPath(roundedRect: NSRect(x: 7.8, y: 4.35, width: 4.4, height: 1.6),
                     xRadius: 0.8, yRadius: 0.8).fill()
    }

    private static func drawStateDot(for state: UIServiceState) {
        let center = NSPoint(x: 10.0, y: 9.95)
        switch state {
        case .disabled:
            return
        case .starting, .stopping:
            let ring = circle(center: center, radius: 1.0)
            ring.lineWidth = 0.9
            NSColor.black.setStroke()
            ring.stroke()
        case .running:
            NSColor.black.setFill()
            circle(center: center, radius: 1.1).fill()
        case .error:
            NSColor.black.setFill()
            circle(center: center, radius: 1.25).fill()
            // Knock out an exclamation mark; negative space is the state cue.
            knockOut(NSBezierPath(roundedRect: NSRect(x: center.x - 0.25, y: center.y - 0.45,
                                                      width: 0.5, height: 1.05),
                                  xRadius: 0.25, yRadius: 0.25))
            knockOut(NSBezierPath(ovalIn: NSRect(x: center.x - 0.25, y: center.y - 0.95,
                                                 width: 0.5, height: 0.5)))
        }
    }

    private static func stroke(_ rect: NSRect, radius: CGFloat, width: CGFloat) {
        let path = NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius)
        path.lineWidth = width
        path.lineJoinStyle = .round
        NSColor.black.setStroke()
        path.stroke()
    }

    private static func triangle(left: Bool) -> NSBezierPath {
        let path = NSBezierPath()
        let cy: CGFloat = 5.15
        let halfHeight: CGFloat = 0.85
        if left {
            path.move(to: NSPoint(x: 5.9, y: cy + halfHeight))
            path.line(to: NSPoint(x: 4.5, y: cy))
            path.line(to: NSPoint(x: 5.9, y: cy - halfHeight))
        } else {
            path.move(to: NSPoint(x: 14.1, y: cy + halfHeight))
            path.line(to: NSPoint(x: 15.5, y: cy))
            path.line(to: NSPoint(x: 14.1, y: cy - halfHeight))
        }
        path.close()
        path.lineJoinStyle = .round
        return path
    }

    private static func circle(center: NSPoint, radius: CGFloat) -> NSBezierPath {
        NSBezierPath(ovalIn: NSRect(x: center.x - radius, y: center.y - radius,
                                    width: radius * 2, height: radius * 2))
    }

    /// Erases the path (destination-out) instead of painting it.
    private static func knockOut(_ path: NSBezierPath) {
        guard let context = NSGraphicsContext.current else { return }
        context.saveGraphicsState()
        context.compositingOperation = .clear
        path.fill()
        context.restoreGraphicsState()
    }
}
