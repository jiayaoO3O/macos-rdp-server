import AppKit

/// Menu bar status item artwork. Template images only (macOS tints them), so the
/// service state is encoded by shape, not colour:
///   disabled           -> plain display glyph
///   starting/stopping  -> display glyph + hollow dot
///   running            -> display glyph + filled dot
///   error              -> display glyph with exclamation badge
enum MenuBarIcon {
    /// The status item uses the 📟 pager emoji (the product's icon); a small
    /// coloured dot encodes the service state without hiding the emoji.
    static func image(for state: UIServiceState) -> NSImage {
        let base = pagerImage()
        guard state == .running || state == .starting || state == .stopping || state == .error else {
            return base
        }
        let size = base.size
        let composite = NSImage(size: size, flipped: false) { rect in
            base.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1.0)
            let diameter: CGFloat = 5.0
            let dot = NSRect(x: rect.maxX - diameter - 0.5,
                             y: rect.minY + 0.5,
                             width: diameter,
                             height: diameter)
            let path = NSBezierPath(ovalIn: dot)
            switch state {
            case .running: NSColor.systemGreen.setFill()
            case .error: NSColor.systemOrange.setFill()
            default: NSColor.secondaryLabelColor.setFill()
            }
            path.fill()
            return true
        }
        composite.isTemplate = false
        composite.accessibilityDescription = "RDP 远程桌面"
        return composite
    }

    private static func pagerImage() -> NSImage {
        let size = NSSize(width: 20, height: 18)
        let image = NSImage(size: size)
        image.lockFocus()
        let text = "📟" as NSString
        let font = NSFont(name: "AppleColorEmoji", size: 15)
            ?? NSFont.systemFont(ofSize: 15)
        text.draw(at: NSPoint(x: 1, y: 0),
                  withAttributes: [.font: font])
        image.unlockFocus()
        image.isTemplate = false
        image.accessibilityDescription = "RDP 远程桌面"
        return image
    }

    private static func fallbackImage() -> NSImage {
        let image = NSImage(size: NSSize(width: 18, height: 16))
        image.lockFocus()
        NSColor.black.setFill()
        NSBezierPath(roundedRect: NSRect(x: 1, y: 3, width: 16, height: 11), xRadius: 2, yRadius: 2).fill()
        image.unlockFocus()
        image.isTemplate = true
        return image
    }
}
