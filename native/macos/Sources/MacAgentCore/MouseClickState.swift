import Foundation

/// Tracks multi-click sequences for injected mouse events.
///
/// macOS decides double/triple clicks from the CGEvent `clickState` field
/// (`NSEvent.clickCount`): 1 = single, 2 = double, 3 = triple. Synthetic
/// events created with `CGEvent(mouseEventSource: nil, ...)` default to a single
/// click, so a remote double-click (two separate down/up pairs sent by the RDP
/// client) was delivered as two unrelated single clicks: title-bar zoom, Finder
/// file open, list double-click and word selection never triggered (field report
/// 2026-11-08). The pure state machine lives here so it is unit-testable; the
/// platform layer only reads `NSEvent.doubleClickInterval` and stamps the value
/// onto the posted events.
public struct MouseClickState: Equatable {
    public struct Config: Equatable {
        /// `NSEvent.doubleClickInterval` converted to milliseconds (user setting).
        public let intervalMilliseconds: UInt64
        /// Maximum cursor travel between consecutive clicks of one sequence.
        public let movementTolerancePoints: Double

        public init(intervalMilliseconds: UInt64 = 500, movementTolerancePoints: Double = 4) {
            self.intervalMilliseconds = intervalMilliseconds
            self.movementTolerancePoints = movementTolerancePoints
        }
    }

    private struct Sequence: Equatable {
        var count: Int
        var lastMilliseconds: UInt64
        var x: Double
        var y: Double
    }

    public var config: Config
    private var sequences: [Int: Sequence] = [:]

    public init(config: Config = Config()) {
        self.config = config
    }

    /// Registers a button-down and returns the clickState that should be
    /// attached to this click's down/drag/up events: 1 = single, 2 = double,
    /// 3 = triple. A click within the interval and the movement tolerance of
    /// the previous click advances the sequence; a fourth click in the window
    /// stays at 3 (AppKit's meaningful maximum).
    public mutating func buttonDown(button: Int, x: Double, y: Double,
                                    nowMilliseconds: UInt64) -> Int {
        var count = 1
        if let previous = sequences[button] {
            let elapsed = nowMilliseconds >= previous.lastMilliseconds
                ? nowMilliseconds - previous.lastMilliseconds : UInt64.max
            let dx = x - previous.x
            let dy = y - previous.y
            let moved = (dx * dx + dy * dy).squareRoot()
            if elapsed <= config.intervalMilliseconds && moved <= config.movementTolerancePoints {
                count = min(previous.count + 1, 3)
            }
        }
        sequences[button] = Sequence(count: count, lastMilliseconds: nowMilliseconds, x: x, y: y)
        return count
    }

    /// clickState currently associated with a button press (used for drag and
    /// up events); 1 before any click has been recorded.
    public func clickState(for button: Int) -> Int {
        sequences[button]?.count ?? 1
    }

    /// Clears every sequence (session teardown / release-all).
    public mutating func reset() {
        sequences.removeAll()
    }
}
