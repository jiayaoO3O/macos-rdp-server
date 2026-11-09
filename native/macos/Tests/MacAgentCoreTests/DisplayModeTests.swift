import Foundation

// Unit tests for the auto display-mode matching feature: mode matcher,
// switch policy, capture-geometry recompute after a switch, and IPC type 17
// (display restore). Kept in a separate file but called from
// PermissionSnapshotTests.main() because `make agent-check` links all
// MacAgentCore sources plus the test files into one executable with a single
// @main entry point (same style as ClipboardFileTransferTests).
//
// Product decision 2026-11-08: the Agent only switches the macOS display mode
// to minimise the black bars (pure minimal aspect delta, larger-area tie-break,
// >20 permille improvement threshold). The Worker keeps the fit-with-bars
// composition, so there is no stretch mouse-mapping path and the existing
// letterbox mouse mapping stays unchanged.

enum DisplayModeTests {
    static func run() throws {
        try ipcDisplayRestoreTests()
        modeMatcherTests()
        switchPolicyTests()
        captureGeometryAfterSwitchTests()
        letterboxMouseMappingUnchangedTests()
        print("display_mode_tests_ok")
    }

    // MARK: - IPC type 17

    private static func ipcDisplayRestoreTests() throws {
        precondition(AgentMessageType.displayRestore.rawValue == 17)
        let payload = AgentIPCCodec.encodeDisplayRestore()
        precondition(payload.isEmpty)
        // Strict decode accepts the empty payload and rejects anything else.
        try AgentIPCCodec.decodeDisplayRestore(payload)
        expectThrows("display restore non-empty payload") {
            try AgentIPCCodec.decodeDisplayRestore(Data([0]))
        }
        expectThrows("display restore 4-byte payload") {
            try AgentIPCCodec.decodeDisplayRestore(Data([0, 0, 0, 1]))
        }
        // Full frame round-trip through the tolerant receiver path.
        let message = AgentIPCMessage(type: .displayRestore,
                                      payload: AgentIPCCodec.encodeDisplayRestore())
        let frame = try AgentIPCCodec.encode(message)
        precondition(frame.count == AgentIPCCodec.headerSize)
        if case let .message(decoded) = try AgentIPCCodec.decodeTolerant(frame) {
            precondition(decoded.type == .displayRestore)
            precondition(decoded.payload.isEmpty)
            try AgentIPCCodec.decodeDisplayRestore(decoded.payload)
        } else {
            preconditionFailure("display restore must decode as a known type")
        }
        let strict = try AgentIPCCodec.decode(frame)
        precondition(strict.type == .displayRestore)
        precondition(strict.payload.isEmpty)
        // Type 17 must not be confused with the pre-existing type 4
        // releaseInput teardown message (worker-core contract).
        precondition(AgentMessageType.releaseInput.rawValue == 4)
    }

    // MARK: - mode matcher

    /// The real mode list reported by `CGDisplayCopyAllDisplayModes` with
    /// `kCGDisplayShowDuplicateLowResolutionModes` enabled on this Mac panel
    /// (2940x1912 native): unique pixel dimensions. No 16:9 mode exists.
    static let realMacPanelModes: [DisplayModePixels] = [
        DisplayModePixels(width: 1920, height: 1200),
        DisplayModePixels(width: 2048, height: 1280),
        DisplayModePixels(width: 2048, height: 1332),
        DisplayModePixels(width: 2560, height: 1600),
        DisplayModePixels(width: 2560, height: 1664),
        DisplayModePixels(width: 2940, height: 1836),
        DisplayModePixels(width: 2940, height: 1912),
        DisplayModePixels(width: 3420, height: 2136),
        DisplayModePixels(width: 3420, height: 2224),
    ]

    private static func modeMatcherTests() {
        let modes = realMacPanelModes

        // Exact pixel matches win regardless of list order.
        expectMatch(requested: (2560, 1600), modes: modes, mode: (2560, 1600),
                    reason: .exact, delta: 0)
        expectMatch(requested: (2940, 1912), modes: modes, mode: (2940, 1912),
                    reason: .exact, delta: 0)
        expectMatch(requested: (2940, 1912), modes: Array(modes.reversed()),
                    mode: (2940, 1912), reason: .exact, delta: 0)

        // Pure minimal aspect delta (exact integer comparison, no same-width
        // preference): the 1.6013 (2940x1836) mode wins over the 1.6 modes for
        // every 16:9 request, which minimises the letterbox black bars.
        expectMatch(requested: (2560, 1440), modes: modes, mode: (2940, 1836),
                    reason: .closest, delta: 110)
        expectMatch(requested: (1920, 1080), modes: modes, mode: (2940, 1836),
                    reason: .closest, delta: 110)
        expectMatch(requested: (1280, 720), modes: modes, mode: (2940, 1836),
                    reason: .closest, delta: 110)
        // Request larger than every mode: closest aspect ratio overall.
        expectMatch(requested: (5120, 2880), modes: modes, mode: (2940, 1836),
                    reason: .closest, delta: 110)
        // 4:3-ish request: the 4:3-like mode has the smallest delta.
        expectMatch(requested: (800, 600), modes: modes, mode: (2048, 1332),
                    reason: .closest, delta: 133)
        // 3:2 request: the 2048x1332 mode is the closest aspect (1.5375),
        // slightly better than the native 2940x1912 (1.5377).
        expectMatch(requested: (1440, 960), modes: modes, mode: (2048, 1332),
                    reason: .closest, delta: 24)
        // 16:10 request: 1.6 modes tie at delta 0 -> larger area wins
        // (2560x1600; the 2940x1836/3420x2136 modes are 1.6013, delta 1).
        expectMatch(requested: (1280, 800), modes: modes, mode: (2560, 1600),
                    reason: .closest, delta: 0)
        expectMatch(requested: (1600, 1000), modes: modes, mode: (2560, 1600),
                    reason: .closest, delta: 0)

        // Aspect delta definition: permille of the requested aspect ratio.
        precondition(DisplayModePixels(width: 2940, height: 1836)
            .aspectDeltaPermille(from: DisplayModePixels(width: 2560, height: 1440)) == 110)
        precondition(DisplayModePixels(width: 2560, height: 1600)
            .aspectDeltaPermille(from: DisplayModePixels(width: 2560, height: 1440)) == 111)
        precondition(DisplayModePixels(width: 2940, height: 1912)
            .aspectDeltaPermille(from: DisplayModePixels(width: 2940, height: 1912)) == 0)

        // Exact comparison beats permille rounding: 2940x1836 (110.21 exact) is
        // closer than 3420x2136 (110.33 exact) even though both round to 110.
        precondition(DisplayModePixels(width: 2940, height: 1836)
            .aspectDeltaPermille(from: DisplayModePixels(width: 2560, height: 1440)) == 110)
        precondition(DisplayModePixels(width: 3420, height: 2136)
            .aspectDeltaPermille(from: DisplayModePixels(width: 2560, height: 1440)) == 110)

        // Synthetic identical-aspect candidates: larger area tie-break.
        let tied = [DisplayModePixels(width: 2000, height: 1250),
                    DisplayModePixels(width: 4000, height: 2500)]
        expectMatch(requested: (1600, 1000), modes: tied, mode: (4000, 2500),
                    reason: .closest, delta: 0)
        // Exact match still wins over a larger identical-aspect mode.
        let exactVersusLarger = [DisplayModePixels(width: 1600, height: 1000),
                                 DisplayModePixels(width: 3200, height: 2000)]
        expectMatch(requested: (1600, 1000), modes: exactVersusLarger,
                    mode: (1600, 1000), reason: .exact, delta: 0)

        // Degenerate input.
        precondition(DisplayModeMatcher.match(
            requested: DisplayModePixels(width: 0, height: 1440),
            available: modes) == nil)
        precondition(DisplayModeMatcher.match(
            requested: DisplayModePixels(width: 2560, height: -1),
            available: modes) == nil)
        precondition(DisplayModeMatcher.match(
            requested: DisplayModePixels(width: 2560, height: 1440),
            available: []) == nil)
        precondition(DisplayModeMatcher.match(
            requested: DisplayModePixels(width: 2560, height: 1440),
            available: [DisplayModePixels(width: 0, height: 0)]) == nil)
        // The panel's native mode is representable in the real list.
        precondition(modes.contains(DisplayModePixels(width: 2940, height: 1912)))
    }

    // MARK: - switch policy (no pointless mode churn)

    private static func switchPolicyTests() {
        let modes = realMacPanelModes
        let native = DisplayModePixels(width: 2940, height: 1912)

        func match(_ requested: (Int, Int)) -> DisplayModeMatch {
            DisplayModeMatcher.match(
                requested: DisplayModePixels(width: requested.0, height: requested.1),
                available: modes)!
        }
        func shouldSwitch(current: DisplayModePixels?, requested: (Int, Int)) -> Bool {
            DisplayModeSwitchPolicy.shouldSwitch(
                from: current, to: match(requested),
                requested: DisplayModePixels(width: requested.0, height: requested.1))
        }

        // 173 px bars today (native) -> ~127 px bars after the switch: the
        // 46 permille aspect improvement is worth one mode switch.
        precondition(shouldSwitch(current: native, requested: (2560, 1440)))
        // 1920x1080 on the native panel: same improvement class.
        precondition(shouldSwitch(current: native, requested: (1920, 1080)))
        // Current mode is already the selected one: no churn.
        precondition(!shouldSwitch(current: DisplayModePixels(width: 2940, height: 1836),
                                   requested: (2560, 1440)))
        // Exact request: switch away from the native panel to the bar-free mode.
        precondition(shouldSwitch(current: native, requested: (2560, 1600)))
        precondition(shouldSwitch(current: native, requested: (2940, 1836)))
        // Requested desktop already equals the current mode: already optimal.
        precondition(!shouldSwitch(current: native, requested: (2940, 1912)))
        // 2048x1332 mode is already within a permille of its aspect: the exact
        // mode 2048x1332 would not visibly reduce the bars -> skip.
        precondition(!shouldSwitch(current: native, requested: (2048, 1332)))
        // The 2940x1836 mode is within 1 permille of a 2560x1600 desktop: an
        // exact 2560x1600 switch would be invisible -> skip the churn.
        precondition(!shouldSwitch(current: DisplayModePixels(width: 2940, height: 1836),
                                   requested: (2560, 1600)))
        // Threshold is testable and documented (strictly greater-than).
        let match1440 = match((2560, 1440))
        let requested = DisplayModePixels(width: 2560, height: 1440)
        precondition(DisplayModeSwitchPolicy.shouldSwitch(
            from: native, to: match1440, requested: requested,
            minimumImprovementPermille: 45))
        precondition(!DisplayModeSwitchPolicy.shouldSwitch(
            from: native, to: match1440, requested: requested,
            minimumImprovementPermille: 46))
        // No current-mode information: switch when a mode was selected.
        precondition(DisplayModeSwitchPolicy.shouldSwitch(
            from: nil, to: match1440, requested: requested))
    }

    // MARK: - capture geometry recompute after the mode switch

    private static func captureGeometryAfterSwitchTests() {
        // Real Agent state: native 2940x1912, then IPC type 9 requests 2560x1440
        // (capture 2214x1440, fit = 173 px bars today).
        let state = CaptureGeometryState(
            desktop: CaptureSizeRequest(width: 2940, height: 1912)!,
            nativeWidth: 2940, nativeHeight: 1912)
        let requested = CaptureSizeRequest(width: 2560, height: 1440)!
        let before = state.updateRequested(requested)
        precondition(before.capture == CaptureSizeRequest(width: 2214, height: 1440))
        precondition(before.policy == .fit)

        // Display-mode switch to the matcher's choice: 2940x1836. The existing
        // DisplaySizeMonitor poll calls updateNative(); the capture geometry must
        // recompute against the NEW native size (the log event is
        // display_size_changed with policy=fit).
        let chosen = DisplayModeMatcher.match(
            requested: DisplayModePixels(width: 2560, height: 1440),
            available: realMacPanelModes)!
        precondition(chosen.mode == DisplayModePixels(width: 2940, height: 1836))
        let after = state.updateNative(width: chosen.mode.width,
                                       height: chosen.mode.height)!
        precondition(after.nativeValue == "2940x1836")
        precondition(after.desktopValue == "2560x1440")
        precondition(after.capture == CaptureSizeRequest(width: 2306, height: 1440))
        precondition(after.policy == .fit)
        // Fewer bars: content 2306 wide in a 2560 desktop -> 127 px per side,
        // versus 173 px per side before the switch.
        let beforeBars = (before.desktop.width - before.capture.width) / 2
        let afterBars = (after.desktop.width - after.capture.width) / 2
        precondition(beforeBars == 173)
        precondition(afterBars == 127)
        precondition(afterBars < beforeBars)

        // Exact mode: 2940x1912 desktop on the native mode stays exact.
        let exactState = CaptureGeometryState(
            desktop: CaptureSizeRequest(width: 2940, height: 1912)!,
            nativeWidth: 2940, nativeHeight: 1836)
        let exactAfter = exactState.updateNative(width: 2940, height: 1912)!
        precondition(exactAfter.policy == .exact)
        precondition(exactAfter.capture == CaptureSizeRequest(width: 2940, height: 1912))
        // The matcher selects the exact mode for this request.
        let exactMatch = DisplayModeMatcher.match(
            requested: DisplayModePixels(width: 2940, height: 1912),
            available: realMacPanelModes)!
        precondition(exactMatch.reason == .exact)
        precondition(!DisplayModeSwitchPolicy.shouldSwitch(
            from: DisplayModePixels(width: 2940, height: 1912),
            to: exactMatch,
            requested: DisplayModePixels(width: 2940, height: 1912)))
    }

    // MARK: - the letterbox mouse mapping must stay unchanged

    private static func letterboxMouseMappingUnchangedTests() {
        // 2560x1440 desktop shown from the 2940x1836 mode: capture 2306x1440,
        // letterbox content 2306 wide (127 px bars), mouse mapping clamps bar
        // clicks into the content box and inverts the content box exactly.
        let layout = DisplayLayout.fit(captureWidth: 2306, captureHeight: 1440,
                                       desktopWidth: 2560, desktopHeight: 1440)!
        precondition(layout.contentWidth == 2306 && layout.contentHeight == 1440)
        precondition(layout.offsetX == 127 && layout.offsetY == 0)
        precondition(layout.capturePoint(x: 127, y: 720) == CapturePixelPoint(x: 0, y: 720))
        precondition(layout.capturePoint(x: 2432, y: 720)
            == CapturePixelPoint(x: 2305, y: 720))
        let mapped = DisplayCoordinateMapper.desktopPoint(
            x: 1280, y: 720, desktopWidth: 2560, desktopHeight: 1440,
            captureWidth: 2306, captureHeight: 1440,
            display: DesktopDisplayRect(originX: 0, originY: 0,
                                        width: 1470, height: 918))
        precondition(mapped == DesktopPoint(x: 1470.0 * 1153.0 / 2306.0, y: 459.0))
    }

    // MARK: - helpers

    private static func expectMatch(requested: (Int, Int), modes: [DisplayModePixels],
                                    mode: (Int, Int), reason: DisplayModeMatchReason,
                                    delta: Int) {
        let requestedPixels = DisplayModePixels(width: requested.0, height: requested.1)
        guard let match = DisplayModeMatcher.match(requested: requestedPixels,
                                                   available: modes) else {
            preconditionFailure("expected a match for \(requested)")
        }
        let expected = DisplayModePixels(width: mode.0, height: mode.1)
        precondition(match.mode == expected,
                     "requested \(requested) expected \(expected.value) got \(match.mode.value)")
        precondition(match.reason == reason,
                     "requested \(requested) expected reason \(reason) got \(match.reason)")
        precondition(match.aspectDeltaPermille == delta,
                     "requested \(requested) expected delta \(delta) got \(match.aspectDeltaPermille)")
    }

    private static func expectThrows(_ label: String, _ body: () throws -> Void) {
        do {
            try body()
            preconditionFailure("expected throw: \(label)")
        } catch {
            // expected
        }
    }
}
