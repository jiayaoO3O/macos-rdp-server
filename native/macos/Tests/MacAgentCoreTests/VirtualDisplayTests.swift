import Foundation

/// Pure-logic tests for the custom 16:9 virtual display: feature
/// gate, child handshake parsing, session state machine and the identity
/// mouse/geometry mapping that makes the 1x virtual display transparent to the
/// existing fit-with-bars pipeline.
enum VirtualDisplayTests {
    static func run() throws {
        testFeatureGate()
        testSizeValidation()
        testChildOutputParsing()
        testSessionLifecycle()
        testTeardownIdempotence()
        testChildFailureDoesNotRetryWithinSession()
        testIdentityMappingOnVirtualDisplay()
        testInputDisplayTargetResolution()
        testVirtualDisplayInputMappingSemantics()
    }

    private static func rect(_ width: Double, _ height: Double) -> DesktopDisplayRect {
        DesktopDisplayRect(originX: 0, originY: 0, width: width, height: height)
    }

    /// Virtual-vs-physical input target selection. Field bug 2026-11-09: on
    /// macOS 26.5.1 the mirrored physical display kept its HiDPI point bounds
    /// while the capture was the virtual framebuffer, so every injected point
    /// was additionally scaled by points/pixels (error growing towards the
    /// bottom-right). The old code always used the physical bounds.
    private static func testInputDisplayTargetResolution() {
        let physical = rect(1280, 720)
        let virtual = rect(2560, 1440)

        // (a) Active virtual display whose bounds match the capture exactly wins;
        // input then maps 1:1 instead of being scaled by points/pixels.
        let virtualTarget = InputDisplayTargetResolver.resolve(
            activeVirtualDisplayID: 15, virtualBounds: virtual,
            captureWidth: 2560, captureHeight: 1440,
            physicalDisplayID: 1, physicalBounds: physical)
        precondition(virtualTarget == InputDisplayTarget(displayID: 15, bounds: virtual,
                                                         source: .virtual))
        precondition(virtualTarget.source.rawValue == "virtual")
        precondition(DisplayCoordinateMapper.desktopPoint(
            x: 2000, y: 1000, desktopWidth: 2560, desktopHeight: 1440,
            captureWidth: 2560, captureHeight: 1440, display: virtualTarget.bounds) ==
                     DesktopPoint(x: 2000, y: 1000))
        // The pre-fix physical mapping (1280x720 bounds) scales it by 0.5.
        precondition(DisplayCoordinateMapper.desktopPoint(
            x: 2000, y: 1000, desktopWidth: 2560, desktopHeight: 1440,
            captureWidth: 2560, captureHeight: 1440, display: physical) ==
                     DesktopPoint(x: 1000, y: 500))

        // Field resolution 2508x1220 on a 2x physical panel (1254x610 points).
        let virtual2508 = rect(2508, 1220)
        let physical1254 = rect(1254, 610)
        let target2508 = InputDisplayTargetResolver.resolve(
            activeVirtualDisplayID: 17, virtualBounds: virtual2508,
            captureWidth: 2508, captureHeight: 1220,
            physicalDisplayID: 1, physicalBounds: physical1254)
        precondition(target2508.source == .virtual)
        precondition(target2508.displayID == 17)
        precondition(DisplayCoordinateMapper.desktopPoint(
            x: 2000, y: 1000, desktopWidth: 2508, desktopHeight: 1220,
            captureWidth: 2508, captureHeight: 1220, display: target2508.bounds) ==
                     DesktopPoint(x: 2000, y: 1000))
        precondition(DisplayCoordinateMapper.desktopPoint(
            x: 2000, y: 1000, desktopWidth: 2508, desktopHeight: 1220,
            captureWidth: 2508, captureHeight: 1220, display: physical1254) ==
                     DesktopPoint(x: 1000, y: 500))
        precondition(DisplayCoordinateMapper.desktopPoint(
            x: 872, y: 488, desktopWidth: 2508, desktopHeight: 1220,
            captureWidth: 2508, captureHeight: 1220, display: physical1254) ==
                     DesktopPoint(x: 436, y: 244))

        // (b) No active virtual display: the unchanged historical physical path.
        let physicalTarget = InputDisplayTargetResolver.resolve(
            activeVirtualDisplayID: nil, virtualBounds: virtual,
            captureWidth: 2560, captureHeight: 1440,
            physicalDisplayID: 1, physicalBounds: physical)
        precondition(physicalTarget == InputDisplayTarget(displayID: 1, bounds: physical,
                                                          source: .physical))
        precondition(physicalTarget.source.rawValue == "physical")

        // (c) Active id but unusable bounds (nil / zero / degenerate): physical.
        for bounds in [nil, rect(0, 0), rect(2560, 0), rect(0, 1440),
                       rect(-2560, 1440), rect(2560, -1440)] {
            let fallback = InputDisplayTargetResolver.resolve(
                activeVirtualDisplayID: 15, virtualBounds: bounds,
                captureWidth: 2560, captureHeight: 1440,
                physicalDisplayID: 1, physicalBounds: physical)
            precondition(fallback == physicalTarget,
                         "unusable virtual bounds must fall back: \(String(describing: bounds))")
        }

        // (d) Virtual active but capture still the physical fit (~1 s mirror
        // transition) or a stale size: keep the physical mapping untouched.
        for (captureWidth, captureHeight) in [(2214, 1440), (1280, 720),
                                              (2560, 1441), (2561, 1440)] {
            let transition = InputDisplayTargetResolver.resolve(
                activeVirtualDisplayID: 15, virtualBounds: virtual,
                captureWidth: captureWidth, captureHeight: captureHeight,
                physicalDisplayID: 1, physicalBounds: physical)
            precondition(transition == physicalTarget,
                         "capture \(captureWidth)x\(captureHeight) must keep physical")
        }

        // Rounded equality is the documented tolerance for fractional bounds.
        let rounded = InputDisplayTargetResolver.resolve(
            activeVirtualDisplayID: 15, virtualBounds: rect(2559.6, 1440.4),
            captureWidth: 2560, captureHeight: 1440,
            physicalDisplayID: 1, physicalBounds: physical)
        precondition(rounded.source == .virtual)
        precondition(rounded.displayID == 15)
    }

    /// (e) The selected virtual bounds feed the same linear capture -> points
    /// formula as before: a 2x-style virtual display (1254x610 points for a
    /// 2508x1220 capture) maps proportionally by x/2 instead of the identity.
    private static func testVirtualDisplayInputMappingSemantics() {
        let virtualBounds = rect(1254, 610)
        precondition(DisplayCoordinateMapper.desktopPoint(
            x: 1000, y: 500, desktopWidth: 2508, desktopHeight: 1220,
            captureWidth: 2508, captureHeight: 1220, display: virtualBounds) ==
                     DesktopPoint(x: 500, y: 250))
        precondition(DisplayCoordinateMapper.desktopPoint(
            x: 2000, y: 1000, desktopWidth: 2508, desktopHeight: 1220,
            captureWidth: 2508, captureHeight: 1220, display: virtualBounds) ==
                     DesktopPoint(x: 1000, y: 500))
        precondition(DisplayCoordinateMapper.desktopPoint(
            x: 2507, y: 1219, desktopWidth: 2508, desktopHeight: 1220,
            captureWidth: 2508, captureHeight: 1220, display: virtualBounds) ==
                     DesktopPoint(x: 1254.0 * 2507.0 / 2508.0,
                                  y: 610.0 * 1219.0 / 1220.0))
        // The resolver only selects such a display when its rounded point size
        // equals the capture; a mismatching one stays on the physical path.
        let mismatch = InputDisplayTargetResolver.resolve(
            activeVirtualDisplayID: 15, virtualBounds: virtualBounds,
            captureWidth: 2508, captureHeight: 1220,
            physicalDisplayID: 1, physicalBounds: rect(1254, 610))
        precondition(mismatch.source == .physical)
    }

    private static func testFeatureGate() {
        precondition(VirtualDisplayFeatureGate.isEnabled(environmentValue: nil) == false)
        precondition(VirtualDisplayFeatureGate.isEnabled(environmentValue: "0") == false)
        precondition(VirtualDisplayFeatureGate.isEnabled(environmentValue: "true") == false)
        precondition(VirtualDisplayFeatureGate.isEnabled(environmentValue: "01") == false)
        precondition(VirtualDisplayFeatureGate.isEnabled(environmentValue: "") == false)
        precondition(VirtualDisplayFeatureGate.isEnabled(environmentValue: "1") == true)
    }

    private static func testSizeValidation() {
        precondition(VirtualDisplaySize(width: 2560, height: 1440) != nil)
        precondition(VirtualDisplaySize(width: 1, height: 1) != nil)
        precondition(VirtualDisplaySize(width: 16_384, height: 1024) != nil)
        precondition(VirtualDisplaySize(width: 0, height: 1440) == nil)
        precondition(VirtualDisplaySize(width: 2560, height: 0) == nil)
        precondition(VirtualDisplaySize(width: -2560, height: 1440) == nil)
        precondition(VirtualDisplaySize(width: 16_385, height: 1440) == nil)
        // BGRA 64 MiB budget: 16384x16384 would be 1 GiB.
        precondition(VirtualDisplaySize(width: 16_384, height: 16_384) == nil)
        precondition(VirtualDisplaySize(CaptureSizeRequest(width: 2560, height: 1440)!) ==
                     VirtualDisplaySize(width: 2560, height: 1440))
        precondition(VirtualDisplaySize(width: 2560, height: 1440)?.value == "2560x1440")
    }

    private static func testChildOutputParsing() {
        precondition(VirtualDisplayChildOutput.parse("display_id=15 width=2560 height=1440") ==
                     VirtualDisplayChildReady(displayID: 15,
                                              size: VirtualDisplaySize(width: 2560, height: 1440)!))
        // Token order is not significant and extra fields are ignored.
        precondition(VirtualDisplayChildOutput.parse("width=2560 height=1440 display_id=15 extra=1") ==
                     VirtualDisplayChildReady(displayID: 15,
                                              size: VirtualDisplaySize(width: 2560, height: 1440)!))
        precondition(VirtualDisplayChildOutput.parse("display_id=0 width=2560 height=1440") == nil)
        precondition(VirtualDisplayChildOutput.parse("display_id=15 width=2560") == nil)
        precondition(VirtualDisplayChildOutput.parse("display_id=x width=2560 height=1440") == nil)
        precondition(VirtualDisplayChildOutput.parse("display_id=15 width=0 height=1440") == nil)
        precondition(VirtualDisplayChildOutput.parse("") == nil)
        precondition(VirtualDisplayChildOutput.parse("event=ready") == nil)
    }

    private static func geometry(_ width: Int, _ height: Int) -> VirtualDisplaySize {
        VirtualDisplaySize(width: width, height: height)!
    }

    private static func ready(_ displayID: UInt32, _ width: Int, _ height: Int) -> VirtualDisplayChildReady {
        VirtualDisplayChildReady(displayID: displayID, size: geometry(width, height))
    }

    private static func testSessionLifecycle() {
        // Disabled: the whole feature is a no-op.
        let disabled = VirtualDisplaySessionPolicy(enabled: false)
        precondition(disabled.state == .disabled)
        precondition(disabled.handle(.captureSize(geometry(2560, 1440))).isEmpty)
        precondition(disabled.handle(.teardown(reason: "peer_restore")).isEmpty)
        precondition(disabled.state == .disabled)

        let policy = VirtualDisplaySessionPolicy(enabled: true)
        precondition(policy.state == .idle)

        // First type 9 of a session spawns the child exactly once.
        precondition(policy.handle(.captureSize(geometry(2560, 1440))) ==
                     [.spawnChild(geometry(2560, 1440))])
        precondition(policy.state == .starting(geometry(2560, 1440)))

        // A second type 9 while starting is ignored (no recreate), still logged.
        precondition(policy.handle(.captureSize(geometry(2940, 1836))) ==
                     [.ignoreResize(desktop: geometry(2940, 1836), current: geometry(2560, 1440))])
        precondition(policy.state == .starting(geometry(2560, 1440)))

        // Handshake activates the session; no rebind action is needed because the
        // cached physical-display capture keeps returning the mirror framebuffer.
        precondition(policy.handle(.childReady(ready(15, 2560, 1440))).isEmpty)
        precondition(policy.state == .active(geometry(2560, 1440), displayID: 15))
        precondition(policy.isActive)

        // Later type 9 changes do not recreate the virtual display in v1.
        precondition(policy.handle(.captureSize(geometry(1920, 1080))) ==
                     [.ignoreResize(desktop: geometry(1920, 1080), current: geometry(2560, 1440))])
        precondition(policy.handle(.captureSize(geometry(2560, 1440))).isEmpty)
        precondition(policy.state == .active(geometry(2560, 1440), displayID: 15))

        // IPC type 17 / EOF / exit: terminate the child, then back to idle.
        precondition(policy.handle(.teardown(reason: "peer_restore")) ==
                     [.terminateChild(reason: "peer_restore")])
        precondition(policy.state == .stopping(geometry(2560, 1440), wasActive: true))
        precondition(policy.handle(.childExited(code: 0)).isEmpty)
        precondition(policy.state == .idle)
        // A second teardown (e.g. EOF after type 17) is a successful no-op.
        precondition(policy.handle(.teardown(reason: "peer_closed")).isEmpty)
        precondition(policy.state == .idle)

        // The next worker session spawns a fresh virtual display.
        precondition(policy.handle(.captureSize(geometry(2560, 1440))) ==
                     [.spawnChild(geometry(2560, 1440))])
    }

    private static func testTeardownIdempotence() {
        // Teardown while the child is still starting: terminate, no failure state.
        let early = VirtualDisplaySessionPolicy(enabled: true)
        _ = early.handle(.captureSize(geometry(2560, 1440)))
        precondition(early.handle(.teardown(reason: "peer_closed")) ==
                     [.terminateChild(reason: "peer_closed")])
        precondition(early.state == .stopping(geometry(2560, 1440), wasActive: false))
        _ = early.handle(.childExited(code: 0))
        precondition(early.state == .idle)

        // Teardown twice while active only terminates once.
        let active = VirtualDisplaySessionPolicy(enabled: true)
        _ = active.handle(.captureSize(geometry(2560, 1440)))
        _ = active.handle(.childReady(ready(15, 2560, 1440)))
        precondition(active.handle(.teardown(reason: "peer_restore")) ==
                     [.terminateChild(reason: "peer_restore")])
        precondition(active.handle(.teardown(reason: "peer_closed")).isEmpty)
        _ = active.handle(.childExited(code: 0))
        precondition(active.state == .idle)
    }

    private static func testChildFailureDoesNotRetryWithinSession() {
        // Child setup fails while starting: keep physical capture, do not respawn
        // for later type 9s of the same session.
        let policy = VirtualDisplaySessionPolicy(enabled: true)
        _ = policy.handle(.captureSize(geometry(2560, 1440)))
        precondition(policy.handle(.childFailed(reason: "mirror_failed")).isEmpty)
        precondition(policy.state == .failed("child_failed:mirror_failed"))
        precondition(policy.handle(.captureSize(geometry(2560, 1440))).isEmpty)
        precondition(policy.state == .failed("child_failed:mirror_failed"))
        // Teardown resets the machine for the next session.
        precondition(policy.handle(.teardown(reason: "peer_restore")).isEmpty)
        precondition(policy.state == .idle)

        // A child exiting unexpectedly while active keeps physical capture; the
        // next session starts fresh.
        let lost = VirtualDisplaySessionPolicy(enabled: true)
        _ = lost.handle(.captureSize(geometry(2560, 1440)))
        _ = lost.handle(.childReady(ready(15, 2560, 1440)))
        precondition(lost.handle(.childExited(code: 139)).isEmpty)
        precondition(lost.state == .failed("child_lost"))
        precondition(lost.handle(.captureSize(geometry(2560, 1440))).isEmpty)
        _ = lost.handle(.teardown(reason: "peer_restore"))
        precondition(lost.handle(.captureSize(geometry(2560, 1440))) ==
                     [.spawnChild(geometry(2560, 1440))])

        // The platform layer retries once after a spawn failure: retry resets the
        // failed state, the following captureSize spawns again (the retry budget
        // is enforced by the platform layer, not by the policy).
        let retried = VirtualDisplaySessionPolicy(enabled: true)
        _ = retried.handle(.captureSize(geometry(2560, 1440)))
        _ = retried.handle(.childFailed(reason: "ready_timeout"))
        precondition(retried.state == .failed("child_failed:ready_timeout"))
        precondition(retried.handle(.retry).isEmpty)
        precondition(retried.state == .idle)
        precondition(retried.handle(.captureSize(geometry(2560, 1440))) ==
                     [.spawnChild(geometry(2560, 1440))])

        // A stale handshake after teardown is terminated, not reactivated.
        let stale = VirtualDisplaySessionPolicy(enabled: true)
        _ = stale.handle(.captureSize(geometry(2560, 1440)))
        _ = stale.handle(.teardown(reason: "peer_restore"))
        precondition(stale.handle(.childReady(ready(15, 2560, 1440))) ==
                     [.terminateChild(reason: "late_ready")])
        _ = stale.handle(.childExited(code: 0))
        precondition(stale.state == .idle)
    }

    /// A 1x 2560x1440 virtual display makes desktop (Worker frame) coordinates,
    /// capture pixels and macOS display points identical: the existing
    /// fit-with-bars math yields offsets 0 and the same point.
    private static func testIdentityMappingOnVirtualDisplay() {
        let desktop = CaptureSizeRequest(width: 2560, height: 1440)!
        // Capture policy: the negotiated box equals the native virtual display.
        let captured = CaptureGeometry.resolve(desktop: desktop,
                                               nativeWidth: 2560, nativeHeight: 1440)!
        precondition(captured.policy == .exact)
        precondition(captured.capture == desktop)
        precondition(captured.desktopValue == "2560x1440")
        precondition(captured.nativeValue == "2560x1440")
        precondition(captured.logFields.contains("policy=exact"))

        // Real Agent flow: geometry starts at the physical native size, then the
        // DisplaySizeMonitor picks up the mirrored virtual mode (2560x1440).
        let state = CaptureGeometryState(desktop: desktop,
                                         nativeWidth: 2940, nativeHeight: 1912)
        precondition(state.snapshot().policy == .fit)
        let updated = state.updateNative(width: 2560, height: 1440)!
        precondition(updated.policy == .exact)
        precondition(updated.capture == desktop)

        // Display points == pixels == desktop: every coordinate maps to itself.
        let display = DesktopDisplayRect(originX: 0, originY: 0, width: 2560, height: 1440)
        for (x, y) in [(0, 0), (1, 1), (100, 200), (1280, 720),
                       (2559, 1439), (2558, 1438)] {
            let mapped = DisplayCoordinateMapper.desktopPoint(
                x: x, y: y,
                desktopWidth: 2560, desktopHeight: 1440,
                captureWidth: 2560, captureHeight: 1440,
                display: display)
            precondition(mapped == DesktopPoint(x: Double(x), y: Double(y)),
                         "desktopPoint(\(x),\(y)) == \(String(describing: mapped))")
        }
        // The layout the Worker uses is 1:1 (no bars/scaling) for this case.
        let layout = DisplayLayout.fit(captureWidth: 2560, captureHeight: 1440,
                                       desktopWidth: 2560, desktopHeight: 1440)!
        precondition(layout.isOneToOne)
        precondition(layout.offsetX == 0 && layout.offsetY == 0)
        precondition(layout.contentWidth == 2560 && layout.contentHeight == 1440)

        // A later non-16:9 type 9 change (DISP resize, not recreated in v1)
        // keeps the existing fit-with-bars mapping consistent: 1440x1080 (4:3)
        // into the 2560x1440 virtual capture becomes a 1440x810 fit.
        let resized = state.updateRequested(CaptureSizeRequest(width: 1440, height: 1080)!)
        precondition(resized.policy == .fit)
        precondition(resized.capture == CaptureSizeRequest(width: 1440, height: 810)!)
        let resizedMap = DisplayCoordinateMapper.desktopPoint(
            x: 719, y: 539,
            desktopWidth: 1440, desktopHeight: 1080,
            captureWidth: resized.capture.width, captureHeight: resized.capture.height,
            display: display)
        precondition(resizedMap != nil)
    }
}
