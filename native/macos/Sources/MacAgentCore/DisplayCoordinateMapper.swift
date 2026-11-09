public struct DesktopPoint: Equatable {
    public let x: Double
    public let y: Double

    public init(x: Double, y: Double) {
        self.x = x
        self.y = y
    }
}

public struct DesktopDisplayRect: Equatable {
    public let originX: Double
    public let originY: Double
    public let width: Double
    public let height: Double

    public init(originX: Double, originY: Double, width: Double, height: Double) {
        self.originX = originX
        self.originY = originY
        self.width = width
        self.height = height
    }
}

/// Which display receives injected remote input. Logged as `source=` in the
/// input-target diagnostics, so keep the raw values stable.
public enum InputDisplaySource: String, Equatable {
    case virtual
    case physical
}

/// The display a remote input event is expressed in: the `displayID` passed to
/// the CGEvent constructor plus the bounds used for the capture-pixel -> point
/// mapping.
public struct InputDisplayTarget: Equatable {
    public let displayID: UInt32
    public let bounds: DesktopDisplayRect
    public let source: InputDisplaySource

    public init(displayID: UInt32, bounds: DesktopDisplayRect,
                source: InputDisplaySource) {
        self.displayID = displayID
        self.bounds = bounds
        self.source = source
    }
}

/// Pure choice of the input-injection display.
///
/// While the custom 16:9 virtual display mirrors the physical panel, the
/// captured framebuffer is the virtual display's, but the physical display can
/// keep its native HiDPI point bounds (field bug 2026-11-09: every injected
/// point was additionally scaled by points/pixels, so the offset grew towards
/// the bottom-right). Input must therefore be expressed in the virtual
/// display's bounds while that display is the capture source, and in the
/// startup physical display's bounds otherwise (fit-with-bars path, unchanged
/// behaviour).
public enum InputDisplayTargetResolver {
    /// Use the virtual display iff it is active, its bounds are non-degenerate,
    /// and its (rounded) point size equals the captured pixel size. The size
    /// equality check keeps the ~1 s mirror transition (virtual display already
    /// active, capture still the physical fit) on the old physical mapping.
    public static func resolve(activeVirtualDisplayID: UInt32?,
                               virtualBounds: DesktopDisplayRect?,
                               captureWidth: Int, captureHeight: Int,
                               physicalDisplayID: UInt32,
                               physicalBounds: DesktopDisplayRect) -> InputDisplayTarget {
        let physical = InputDisplayTarget(displayID: physicalDisplayID,
                                          bounds: physicalBounds,
                                          source: .physical)
        guard let virtualDisplayID = activeVirtualDisplayID,
              let virtualBounds else { return physical }
        let roundedWidth = Int(virtualBounds.width.rounded())
        let roundedHeight = Int(virtualBounds.height.rounded())
        guard roundedWidth > 0, roundedHeight > 0,
              roundedWidth == captureWidth, roundedHeight == captureHeight else {
            return physical
        }
        return InputDisplayTarget(displayID: virtualDisplayID,
                                  bounds: virtualBounds,
                                  source: .virtual)
    }
}

public enum DisplayCoordinateMapper {
    /// Existing capture-pixel -> macOS display (points) linear mapping. Kept for
    /// compatibility; the RDP mouse path now goes through desktopPoint().
    public static func point(x: Int, y: Int, captureWidth: Int, captureHeight: Int,
                             display: DesktopDisplayRect) -> DesktopPoint? {
        guard captureWidth > 0, captureHeight > 0,
              x >= 0, x < captureWidth, y >= 0, y < captureHeight,
              display.width > 0, display.height > 0 else { return nil }
        return DesktopPoint(
            x: display.originX + display.width * Double(x) / Double(captureWidth),
            y: display.originY + display.height * Double(y) / Double(captureHeight)
        )
    }

    /// Desktop (Worker frame) coordinate -> capture pixel: inverts the
    /// fit-with-bars layout and clamps bar clicks to the nearest content edge.
    public static func capturePoint(x: Int, y: Int,
                                    desktopWidth: Int, desktopHeight: Int,
                                    captureWidth: Int, captureHeight: Int) -> CapturePixelPoint? {
        guard let layout = DisplayLayout.fit(captureWidth: captureWidth,
                                             captureHeight: captureHeight,
                                             desktopWidth: desktopWidth,
                                             desktopHeight: desktopHeight) else { return nil }
        return layout.capturePoint(x: x, y: y)
    }

    /// Desktop (Worker frame) coordinate -> macOS display point (design
    /// section 5): desktop -> content box (bar clicks clamp into the content)
    /// -> capture pixel -> display points.
    public static func desktopPoint(x: Int, y: Int,
                                    desktopWidth: Int, desktopHeight: Int,
                                    captureWidth: Int, captureHeight: Int,
                                    display: DesktopDisplayRect) -> DesktopPoint? {
        guard let pixel = capturePoint(x: x, y: y,
                                       desktopWidth: desktopWidth,
                                       desktopHeight: desktopHeight,
                                       captureWidth: captureWidth,
                                       captureHeight: captureHeight) else { return nil }
        return point(x: pixel.x, y: pixel.y,
                     captureWidth: captureWidth, captureHeight: captureHeight,
                     display: display)
    }
}
