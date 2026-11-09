import Foundation

/// How the Agent chose the capture size relative to the negotiated desktop box
/// and the native display pixel size (design section 4).
public enum CapturePolicy: String, Equatable {
    /// The desktop box fits inside the display and keeps the display aspect
    /// ratio within 0.5%, so the capture is the desktop box 1:1.
    case exact
    /// The desktop box keeps its aspect ratio but is scaled into the capture.
    case fit
    /// The desktop box is at least as large as the display on both axes, so the
    /// capture is the native display size and the Worker upscales it.
    case native
}

/// Pure capture-size policy from (requested desktop box, native display pixels).
///
/// The contract (docs/DESIGN-2026-11-07-resolution-adaptation.md section 4) is
/// shared bit-for-bit with the C Worker and the protocol tests:
///
///     match = |W*nh - H*nw| * 200 <= H*nw        (<= 0.5% aspect difference)
///     if match && W <= nw && H <= nh:            capture = W x H,  policy exact
///     else if W >= nw && H >= nh:                capture = nw x nh, policy native
///     else if W*nh <= H*nw:                      capture = W x (nh*W + nw/2)/nw
///     else:                                      capture = (nw*H + nh/2)/nh x H
///     (fit branches use policy fit)
///
/// The capture is never upscaled past the native display size. The final safety
/// clamp keeps the result inside CaptureSizeRequest's 1...16384 per axis and
/// 64 MiB BGRA limits (a 6K/8K native display can exceed the pixel budget).
public struct CaptureGeometry: Equatable {
    public let desktop: CaptureSizeRequest
    public let nativeWidth: Int
    public let nativeHeight: Int
    public let capture: CaptureSizeRequest
    public let policy: CapturePolicy

    /// Event/audit text helpers: "WxH" and k=v fields shared by the Agent logs.
    public var desktopValue: String { "\(desktop.width)x\(desktop.height)" }
    public var nativeValue: String { "\(nativeWidth)x\(nativeHeight)" }
    public var captureValue: String { "\(capture.width)x\(capture.height)" }
    public var logFields: String {
        "desktop=\(desktopValue) native=\(nativeValue) capture=\(captureValue) policy=\(policy.rawValue)"
    }

    init(desktop: CaptureSizeRequest, nativeWidth: Int, nativeHeight: Int,
         capture: CaptureSizeRequest, policy: CapturePolicy) {
        self.desktop = desktop
        self.nativeWidth = nativeWidth
        self.nativeHeight = nativeHeight
        self.capture = capture
        self.policy = policy
    }

    /// Compute the capture geometry. Returns nil only for a degenerate native
    /// display size (<= 0); callers keep their last known geometry then.
    public static func resolve(desktop: CaptureSizeRequest,
                               nativeWidth: Int,
                               nativeHeight: Int) -> CaptureGeometry? {
        guard nativeWidth > 0, nativeHeight > 0 else { return nil }
        let W = desktop.width
        let H = desktop.height
        let nw = nativeWidth
        let nh = nativeHeight

        // |W*nh - H*nw| * 200 <= H*nw  <=>  relative aspect difference <= 0.5%.
        let match = abs(W * nh - H * nw) * 200 <= H * nw
        var cw: Int
        var ch: Int
        let policy: CapturePolicy
        if match && W <= nw && H <= nh {
            cw = W
            ch = H
            policy = .exact
        } else if W >= nw && H >= nh {
            cw = nw
            ch = nh
            policy = .native
        } else if UInt64(W) * UInt64(nh) <= UInt64(H) * UInt64(nw) {
            // The desktop box is relatively wider: the width is the limiting axis.
            cw = W
            ch = max(1, (nh * W + nw / 2) / nw)
            policy = .fit
        } else {
            // The desktop box is relatively taller: the height is the limiting axis.
            ch = H
            cw = max(1, (nw * H + nh / 2) / nh)
            policy = .fit
        }
        // The Agent never upscales the capture past the native display.
        if cw > nw { cw = nw }
        if ch > nh { ch = nh }
        let limited = limitedCaptureSize(width: cw, height: ch)
        guard let capture = CaptureSizeRequest(width: limited.width, height: limited.height) else {
            return nil
        }
        return CaptureGeometry(desktop: desktop, nativeWidth: nw, nativeHeight: nh,
                               capture: capture, policy: policy)
    }

    /// Final safety clamp to the CaptureSizeRequest limits (1...16384 per axis,
    /// area * 4 <= 64 MiB). Only reachable for a native display larger than the
    /// pixel budget; the desktop box itself is already budget-checked.
    private static func limitedCaptureSize(width: Int, height: Int) -> (width: Int, height: Int) {
        let maximumDimension = 16_384
        let maximumPixels = UInt64(16_777_216) // 64 MiB / 4 bytes per BGRA pixel
        var w = min(max(width, 1), maximumDimension)
        var h = min(max(height, 1), maximumDimension)
        guard UInt64(w) * UInt64(h) > maximumPixels else { return (w, h) }
        // Shrink both axes by the same factor, then remove the remaining
        // rounding excess from the larger axis so the aspect ratio is kept.
        let scale = (Double(maximumPixels) / Double(UInt64(w) * UInt64(h))).squareRoot()
        w = max(1, Int(Double(w) * scale))
        h = max(1, Int(Double(h) * scale))
        while UInt64(w) * UInt64(h) > maximumPixels {
            if w >= h { w = max(1, w - 1) } else { h = max(1, h - 1) }
        }
        return (w, h)
    }
}

/// Thread-safe Agent geometry state: the negotiated desktop box (IPC type 9),
/// the native display pixel size and the computed capture size. The input
/// receiver, the display-size poller and both capture loops share one instance.
public final class CaptureGeometryState: @unchecked Sendable {
    private let lock = NSLock()
    private var geometry: CaptureGeometry

    public init(desktop: CaptureSizeRequest, nativeWidth: Int, nativeHeight: Int) {
        // A missing native size must not lose the request: an unknown display
        // degrades to 1x1 instead of failing, and updateNative() replaces it as
        // soon as the real size is available.
        let nw = max(1, nativeWidth)
        let nh = max(1, nativeHeight)
        geometry = CaptureGeometry.resolve(desktop: desktop, nativeWidth: nw, nativeHeight: nh)
            ?? CaptureGeometry(desktop: desktop, nativeWidth: nw, nativeHeight: nh,
                               capture: desktop, policy: .exact)
    }

    public func snapshot() -> CaptureGeometry {
        lock.lock()
        defer { lock.unlock() }
        return geometry
    }

    /// A newly negotiated desktop box arrived (Agent IPC type 9). Recomputes the
    /// capture size against the current native display size.
    @discardableResult
    public func updateRequested(_ desktop: CaptureSizeRequest) -> CaptureGeometry {
        lock.lock()
        defer { lock.unlock() }
        let current = geometry
        if let next = CaptureGeometry.resolve(desktop: desktop,
                                              nativeWidth: current.nativeWidth,
                                              nativeHeight: current.nativeHeight) {
            geometry = next
        }
        return geometry
    }

    /// The display reported a new native pixel size. Returns the new geometry
    /// only when the native size actually changed; 0x0/absent modes keep the
    /// last known size and return nil.
    @discardableResult
    public func updateNative(width: Int, height: Int) -> CaptureGeometry? {
        guard width > 0, height > 0 else { return nil }
        lock.lock()
        defer { lock.unlock() }
        let current = geometry
        guard current.nativeWidth != width || current.nativeHeight != height else { return nil }
        guard let next = CaptureGeometry.resolve(desktop: current.desktop,
                                                 nativeWidth: width,
                                                 nativeHeight: height) else { return nil }
        geometry = next
        return next
    }
}
