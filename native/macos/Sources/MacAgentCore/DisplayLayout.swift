import Foundation

/// A point in the capture pixel grid.
public struct CapturePixelPoint: Equatable {
    public let x: Int
    public let y: Int

    public init(x: Int, y: Int) {
        self.x = x
        self.y = y
    }
}

/// Fit-with-bars layout of a capture frame inside the negotiated desktop box.
///
/// The integer math is identical to the C Worker's composition (and the
/// protocol tests), see docs/DESIGN-2026-11-07-resolution-adaptation.md
/// section 3:
///
///     if (UInt64)cw*H <= (UInt64)W*ch:   // capture relatively wider: fit height
///         contentH = H
///         contentW = max(1, (cw*H + ch/2) / ch)
///     else:                              // fit width
///         contentW = W
///         contentH = max(1, (ch*W + cw/2) / cw)
///     offX = (W - contentW) / 2
///     offY = (H - contentH) / 2
///     scaled = (cw != contentW || ch != contentHeight)
///
/// The content box is centred; the remaining desktop pixels are black bars.
public struct DisplayLayout: Equatable {
    public let captureWidth: Int
    public let captureHeight: Int
    public let desktopWidth: Int
    public let desktopHeight: Int
    public let contentWidth: Int
    public let contentHeight: Int
    public let offsetX: Int
    public let offsetY: Int

    /// True when the capture is resampled into the desktop content box.
    public var scaled: Bool {
        captureWidth != contentWidth || captureHeight != contentHeight
    }

    /// True when the capture covers the whole desktop 1:1 (no bars, no scaling).
    public var isOneToOne: Bool {
        !scaled && offsetX == 0 && offsetY == 0
    }

    /// Build the letterbox layout for a capture frame shown in a desktop box.
    /// Returns nil for degenerate (non-positive) sizes.
    public static func fit(captureWidth: Int, captureHeight: Int,
                           desktopWidth: Int, desktopHeight: Int) -> DisplayLayout? {
        let cw = captureWidth
        let ch = captureHeight
        let W = desktopWidth
        let H = desktopHeight
        guard cw > 0, ch > 0, W > 0, H > 0 else { return nil }
        var contentWidth: Int
        var contentHeight: Int
        if UInt64(cw) * UInt64(H) <= UInt64(W) * UInt64(ch) {
            // Capture relatively wider or equal: fit the height, bars left/right.
            contentHeight = H
            contentWidth = max(1, (cw * H + ch / 2) / ch)
        } else {
            // Capture relatively taller: fit the width, bars top/bottom.
            contentWidth = W
            contentHeight = max(1, (ch * W + cw / 2) / cw)
        }
        // Enforce the documented invariants (content must fit the desktop).
        contentWidth = min(contentWidth, W)
        contentHeight = min(contentHeight, H)
        return DisplayLayout(captureWidth: cw, captureHeight: ch,
                             desktopWidth: W, desktopHeight: H,
                             contentWidth: contentWidth, contentHeight: contentHeight,
                             offsetX: (W - contentWidth) / 2,
                             offsetY: (H - contentHeight) / 2)
    }

    /// Desktop (Worker frame) coordinate -> capture pixel. A click in a black
    /// bar clamps to the nearest content edge (design section 5), so the result
    /// is always a valid capture pixel.
    public func capturePoint(x: Int, y: Int) -> CapturePixelPoint {
        let sx: Int
        if x < offsetX {
            sx = 0
        } else if x >= offsetX + contentWidth {
            sx = captureWidth - 1
        } else {
            sx = (x - offsetX) * captureWidth / contentWidth
        }
        let sy: Int
        if y < offsetY {
            sy = 0
        } else if y >= offsetY + contentHeight {
            sy = captureHeight - 1
        } else {
            sy = (y - offsetY) * captureHeight / contentHeight
        }
        return CapturePixelPoint(x: sx, y: sy)
    }
}
