import Foundation

/// Custom 16:9 virtual display.
///
/// The Agent asks a short-lived child process to create a virtual display whose
/// pixel size is exactly the negotiated desktop box and to mirror the physical
/// display onto it. While the mirror is active the physical display reports the
/// virtual mode (e.g. 2560x1440) and ScreenCaptureKit keeps returning frames
/// through the capture filter the Agent resolved at startup, so the Worker runs
/// 1:1 without letterbox bars. The physical panel itself shows a letterboxed
/// copy, which is acceptable (the user only sees the RDP view).
///
/// This file contains only pure logic (feature gate, child handshake parsing and
/// the session state machine); the platform process/CoreGraphics work lives in
/// the `rdp-agent` executable target.

/// Pixel size requested for the virtual display. It must fit the display-server
/// and capture limits (1...16384 per axis and the 64 MiB BGRA budget, matching
/// CaptureSizeRequest).
public struct VirtualDisplaySize: Equatable, Sendable {
    public let width: Int
    public let height: Int

    public init?(width: Int, height: Int) {
        guard width > 0, height > 0, width <= 16_384, height <= 16_384,
              UInt64(width) * UInt64(height) <= 16_777_216 else {
            return nil
        }
        self.width = width
        self.height = height
    }

    public init?(_ request: CaptureSizeRequest) {
        self.init(width: request.width, height: request.height)
    }

    public var value: String { "\(width)x\(height)" }
}

/// Feature gate for the virtual-display capture path.
///
/// Default OFF for the first deploy (the user accepts the feature after a field
/// test); RDP_AGENT_VIRTUAL_DISPLAY=1 enables it. Only the literal "1" enables
/// the feature so a typo/empty value keeps the historical physical capture.
public enum VirtualDisplayFeatureGate {
    public static func isEnabled(environmentValue: String?) -> Bool {
        environmentValue == "1"
    }
}

/// One successful child handshake: the virtual display id plus the size the
/// child actually created.
public struct VirtualDisplayChildReady: Equatable, Sendable {
    public let displayID: UInt32
    public let size: VirtualDisplaySize

    public init(displayID: UInt32, size: VirtualDisplaySize) {
        self.displayID = displayID
        self.size = size
    }
}

/// Parsing for the child's single stdout handshake line:
///
///     display_id=15 width=2560 height=1440
///
/// Token order is not significant; all three fields must be present and valid.
public enum VirtualDisplayChildOutput {
    public static func parse(_ line: String) -> VirtualDisplayChildReady? {
        var fields: [String: String] = [:]
        for token in line.split(whereSeparator: { $0 == " " || $0 == "\t" || $0 == "\r" }) {
            let parts = token.split(separator: "=", maxSplits: 1)
            guard parts.count == 2 else { continue }
            fields[String(parts[0])] = String(parts[1])
        }
        guard let idText = fields["display_id"], let displayID = UInt32(idText),
              displayID > 0,
              let widthText = fields["width"], let width = Int(widthText),
              let heightText = fields["height"], let height = Int(heightText),
              let size = VirtualDisplaySize(width: width, height: height) else {
            return nil
        }
        return VirtualDisplayChildReady(displayID: displayID, size: size)
    }
}

/// Lifecycle of one worker session's virtual display.
public enum VirtualDisplayState: Equatable, Sendable {
    /// Feature disabled (RDP_AGENT_VIRTUAL_DISPLAY != 1): every event is ignored.
    case disabled
    /// Feature enabled, no virtual display for the current worker session.
    case idle
    /// Child spawned; waiting for its handshake line.
    case starting(VirtualDisplaySize)
    /// Child ready and the physical display is mirrored onto the virtual display.
    case active(VirtualDisplaySize, displayID: UInt32)
    /// Teardown requested; waiting for the child process to exit.
    case stopping(VirtualDisplaySize, wasActive: Bool)
    /// This session cannot use a virtual display (child failure/size mismatch);
    /// the Agent keeps capturing the physical display until the next session.
    case failed(String)
}

/// A worker-session lifecycle event for the virtual display.
public enum VirtualDisplayEvent: Equatable, Sendable {
    /// IPC type 9: negotiated desktop box (the first one of a session starts the
    /// virtual display; later ones do not recreate it in v1).
    case captureSize(VirtualDisplaySize)
    /// The child printed its handshake line.
    case childReady(VirtualDisplayChildReady)
    /// The child exited (expected during teardown, unexpected while active).
    case childExited(code: Int32)
    /// Spawning/reading the handshake/child setup failed.
    case childFailed(reason: String)
    /// IPC type 17, input-socket EOF, agent exit or the dead-peer path.
    case teardown(reason: String)
    /// The parent asks for one retry after a failed spawn (the platform layer
    /// has already restored the physical display mode).
    case retry
}

/// Side effect the platform layer must perform for one event.
public enum VirtualDisplayAction: Equatable, Sendable {
    case spawnChild(VirtualDisplaySize)
    case ignoreResize(desktop: VirtualDisplaySize, current: VirtualDisplaySize)
    case terminateChild(reason: String)
}

/// Pure virtual-display session state machine.
///
/// The platform layer locks around this object and performs the returned
/// actions. No capture rebinding is needed on macOS 27.2: while the physical
/// display mirrors the virtual display, the Agent's cached ScreenCaptureKit
/// filter for the physical display returns the virtual display's shared
/// framebuffer (verified: 2560x1440 BGRA, identical pixels, no letterbox), and
/// the DisplaySizeMonitor follows the physical display's reported mode.
public final class VirtualDisplaySessionPolicy {
    public private(set) var state: VirtualDisplayState
    private let enabled: Bool

    public init(enabled: Bool) {
        self.enabled = enabled
        self.state = enabled ? .idle : .disabled
    }

    /// Feed one lifecycle event; returns the actions the platform layer must run.
    public func handle(_ event: VirtualDisplayEvent) -> [VirtualDisplayAction] {
        guard enabled else { return [] }
        switch state {
        case .disabled:
            return []
        case .idle:
            switch event {
            case .captureSize(let size):
                state = .starting(size)
                return [.spawnChild(size)]
            case .teardown:
                // Reset (idempotent) so a later worker session can start again.
                state = .idle
                return []
            case .childReady, .childExited, .childFailed, .retry:
                return []
            }
        case .starting(let current):
            switch event {
            case .captureSize(let size):
                guard size != current else { return [] }
                return [.ignoreResize(desktop: size, current: current)]
            case .childReady(let ready):
                guard ready.size == current else {
                    state = .failed("size_mismatch")
                    return [.terminateChild(reason: "size_mismatch")]
                }
                state = .active(ready.size, displayID: ready.displayID)
                return []
            case .childFailed(let reason):
                state = .failed("child_failed:\(reason)")
                return []
            case .childExited(let code):
                state = .failed("child_exited:\(code)")
                return []
            case .teardown(let reason):
                state = .stopping(current, wasActive: false)
                return [.terminateChild(reason: reason)]
            case .retry:
                return []
            }
        case .active(let current, _):
            switch event {
            case .captureSize(let size):
                guard size != current else { return [] }
                return [.ignoreResize(desktop: size, current: current)]
            case .childReady:
                // A duplicate handshake can only be stale; make sure it goes away.
                return [.terminateChild(reason: "unexpected_ready")]
            case .childExited, .childFailed:
                // The virtual display is gone; WindowServer already restored the
                // physical display, the Agent keeps capturing it unchanged.
                state = .failed("child_lost")
                return []
            case .teardown(let reason):
                state = .stopping(current, wasActive: true)
                return [.terminateChild(reason: reason)]
            case .retry:
                return []
            }
        case .stopping(_, _):
            switch event {
            case .childExited, .childFailed:
                state = .idle
                return []
            case .childReady:
                return [.terminateChild(reason: "late_ready")]
            case .teardown, .captureSize, .retry:
                return []
            }
        case .failed:
            switch event {
            case .teardown, .retry:
                // A new worker session (or the single platform retry) may start
                // a fresh virtual display.
                state = .idle
                return []
            case .childReady:
                return [.terminateChild(reason: "unexpected_ready")]
            case .captureSize, .childExited, .childFailed:
                return []
            }
        }
    }

    /// True while the virtual display for the current session is up.
    public var isActive: Bool {
        if case .active = state { return true }
        return false
    }
}
