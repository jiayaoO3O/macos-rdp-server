import Foundation

/// Regression tests for injected mouse multi-click detection (field report
/// 2026-11-08: remote double-click did nothing because every synthetic click
/// carried clickState=1).
enum MouseClickStateTests {
    static func run() {
        testSingleClick()
        testDoubleClick()
        testTripleClickCapsAtThree()
        testSlowSecondClickStartsNewSequence()
        testSecondClickTooFarAwayStartsNewSequence()
        testButtonsHaveIndependentSequences()
        testReset()
    }

    private static func state() -> MouseClickState {
        MouseClickState(config: .init(intervalMilliseconds: 500, movementTolerancePoints: 4))
    }

    private static func testSingleClick() {
        var clicks = state()
        let count = clicks.buttonDown(button: 0, x: 100, y: 100, nowMilliseconds: 1_000)
        precondition(count == 1)
        precondition(clicks.clickState(for: 0) == 1)
        precondition(clicks.clickState(for: 1) == 1, "unused button starts at single click")
    }

    private static func testDoubleClick() {
        var clicks = state()
        _ = clicks.buttonDown(button: 0, x: 100, y: 100, nowMilliseconds: 1_000)
        let second = clicks.buttonDown(button: 0, x: 101, y: 100, nowMilliseconds: 1_200)
        precondition(second == 2, "second click within interval must be a double click")
        precondition(clicks.clickState(for: 0) == 2)
    }

    private static func testTripleClickCapsAtThree() {
        var clicks = state()
        _ = clicks.buttonDown(button: 0, x: 50, y: 50, nowMilliseconds: 0)
        precondition(clicks.buttonDown(button: 0, x: 50, y: 50, nowMilliseconds: 150) == 2)
        precondition(clicks.buttonDown(button: 0, x: 50, y: 50, nowMilliseconds: 300) == 3)
        precondition(clicks.buttonDown(button: 0, x: 50, y: 50, nowMilliseconds: 450) == 3,
                     "a fourth click in the window must stay at triple")
    }

    private static func testSlowSecondClickStartsNewSequence() {
        var clicks = state()
        _ = clicks.buttonDown(button: 0, x: 20, y: 20, nowMilliseconds: 1_000)
        let second = clicks.buttonDown(button: 0, x: 20, y: 20, nowMilliseconds: 1_600)
        precondition(second == 1, "click after the double-click interval is a single click")
    }

    private static func testSecondClickTooFarAwayStartsNewSequence() {
        var clicks = state()
        _ = clicks.buttonDown(button: 0, x: 20, y: 20, nowMilliseconds: 1_000)
        let second = clicks.buttonDown(button: 0, x: 40, y: 20, nowMilliseconds: 1_100)
        precondition(second == 1, "moving beyond the tolerance must not count as a double click")
    }

    private static func testButtonsHaveIndependentSequences() {
        var clicks = state()
        _ = clicks.buttonDown(button: 0, x: 10, y: 10, nowMilliseconds: 0)
        _ = clicks.buttonDown(button: 1, x: 10, y: 10, nowMilliseconds: 100)
        precondition(clicks.clickState(for: 1) == 1, "right button must not inherit left double click")
        let leftAgain = clicks.buttonDown(button: 0, x: 10, y: 10, nowMilliseconds: 200)
        precondition(leftAgain == 2)
    }

    private static func testReset() {
        var clicks = state()
        _ = clicks.buttonDown(button: 0, x: 10, y: 10, nowMilliseconds: 0)
        _ = clicks.buttonDown(button: 0, x: 10, y: 10, nowMilliseconds: 100)
        precondition(clicks.clickState(for: 0) == 2)
        clicks.reset()
        precondition(clicks.clickState(for: 0) == 1)
        precondition(clicks.buttonDown(button: 0, x: 10, y: 10, nowMilliseconds: 200) == 1)
    }
}
