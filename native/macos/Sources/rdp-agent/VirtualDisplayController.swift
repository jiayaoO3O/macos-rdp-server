import Foundation
import CoreGraphics
import Darwin
import MacAgentCore

/// Parent-side lifecycle for the custom 16:9 virtual display.
///
/// Owns the `rdp-agent virtual-display` child process: spawns it on the first
/// IPC type 9 of a worker session, waits for the single stdout handshake line,
/// logs the ready latency, and tears it down on type 17 / input-socket EOF /
/// agent exit. The child restores the physical display itself (unmirror +
/// explicit `CGDisplaySetDisplayMode` back to its snapshot); this controller
/// additionally:
///
/// - passes the Agent's startup physical pixel size to the child
///   (`--restore-physical WxH`) so every session starts from the same panel mode
///   (fix for the 2026-11-08 reconnect bug where a 1920x1080 session left the
///   panel scaled and later 2560x1440 sessions timed out),
/// - captures and logs the child's stderr (failure stages were invisible before),
/// - force-restores the startup physical mode on failure/teardown,
/// - retries a failed spawn exactly once after ~500 ms; after that it keeps the
///   historical fit-with-bars capture and never leaves the panel non-native.
///
/// No capture rebinding happens here: while the physical display mirrors the
/// virtual display, the Agent's cached ScreenCaptureKit filter keeps returning
/// the virtual display's shared framebuffer, and DisplaySizeMonitor follows the
/// physical display's reported mode (verified on macOS 27.2).
final class VirtualDisplayController: @unchecked Sendable {
    private let enabled: Bool
    private let executablePath: String
    private let physicalDisplayID: CGDirectDisplayID
    private let startupPhysicalPixels: DisplayPixelSize
    private let queue = DispatchQueue(label: "rdp-agent.virtual-display")
    private let handshakeQueue = DispatchQueue(label: "rdp-agent.virtual-display.handshake")
    private let stderrQueue = DispatchQueue(label: "rdp-agent.virtual-display.stderr")
    private let policy: VirtualDisplaySessionPolicy
    /// Mirrors the `.active(_, displayID:)` state for the input receiver. It is
    /// a separately locked cached value instead of `queue.sync`: the serial
    /// queue can block for seconds inside `stopChild()` waiting for the child,
    /// and input injection must never wait on that.
    private let activeDisplayIDLock = NSLock()
    private var cachedActiveDisplayID: CGDirectDisplayID?

    private var process: Process?
    private var inputPipe: Pipe?
    private var outputPipe: Pipe?
    private var errorPipe: Pipe?
    private var spawnStartedAt: UInt64 = 0
    private var spawnGeneration = 0
    private var exitMonitorScheduled = false
    private var stopping = false
    private var sessionActive = false
    private var teardownRequested = false
    private var retryUsed = false
    private var sessionDisplayStateLogged = false
    private var sessionDisplayStateAfterLogged = false
    private var lastDisplayID: UInt32 = 0
    private var lastSessionSize: VirtualDisplaySize?

    init(enabled: Bool, executablePath: String, physicalDisplayID: CGDirectDisplayID,
         startupPhysicalPixels: DisplayPixelSize) {
        self.enabled = enabled
        self.executablePath = executablePath
        self.physicalDisplayID = physicalDisplayID
        self.startupPhysicalPixels = startupPhysicalPixels
        self.policy = VirtualDisplaySessionPolicy(enabled: enabled)
    }

    /// True while the virtual display for the current session is up.
    var isActive: Bool {
        queue.sync { policy.isActive }
    }

    /// The active virtual display's id (the mirror master whose framebuffer the
    /// Agent captures), or nil when no virtual display is up. Safe and cheap to
    /// call on the input path from any thread.
    var activeDisplayID: CGDirectDisplayID? {
        activeDisplayIDLock.lock()
        defer { activeDisplayIDLock.unlock() }
        return cachedActiveDisplayID
    }

    /// IPC type 9: the negotiated desktop box. The first box of a session starts
    /// the virtual display; later boxes do not recreate it in v1.
    func handleCaptureSize(_ desktop: CaptureSizeRequest) {
        guard enabled, let size = VirtualDisplaySize(desktop) else { return }
        queue.async {
            self.beginSessionIfIdle(size: size)
            let actions = self.policy.handle(.captureSize(size))
            self.perform(actions)
        }
    }

    /// IPC type 17, input-socket EOF or any other reason the worker session is
    /// over. Idempotent; safe from any thread.
    func handleTeardown(reason: String) {
        guard enabled else { return }
        queue.async {
            self.teardownRequested = true
            self.performTeardown(reason: reason)
        }
    }

    /// Process-exit path: block until the child is gone (bounded) and the panel
    /// is back to the startup mode, so the Agent never exits with a scaled panel.
    func teardownSynchronously(reason: String) {
        guard enabled else { return }
        queue.sync {
            self.teardownRequested = true
            self.performTeardown(reason: reason)
        }
    }

    // MARK: - serial queue work

    /// One `display_state_before` line per worker session, logged before the
    /// first spawn attempt.
    private func beginSessionIfIdle(size: VirtualDisplaySize) {
        guard case .idle = policy.state else { return }
        sessionActive = true
        teardownRequested = false
        retryUsed = false
        lastSessionSize = size
        sessionDisplayStateLogged = true
        sessionDisplayStateAfterLogged = false
        log("event=display_state_before \(DisplayStateSummary.current())")
    }

    private func perform(_ actions: [VirtualDisplayAction]) {
        for action in actions {
            switch action {
            case .spawnChild(let size):
                spawnChild(size: size)
            case .ignoreResize(let desktop, let current):
                log("event=virtual_display_resize_ignored desktop=\(desktop.value) " +
                    "current=\(current.value) reason=v1_no_recreate")
            case .terminateChild(let reason):
                stopChild(reason: reason, failedStage: nil)
            }
        }
    }

    private func spawnChild(size: VirtualDisplaySize) {
        // Never create a virtual display without a real physical display to
        // mirror: with the MacBook lid closed (or the panel unplugged) a virtual
        // display can become the only "display" and cascade into scaled virtual
        // displays (2026-11-08 incident). Requires an active built-in display or
        // an active non-virtual external display (headless Mac mini production
        // case), never one of our own virtual displays.
        guard DisplayModeHelper.isUsableMirrorTarget(physicalDisplayID),
              !DisplayModeHelper.mirrorTargets().isEmpty else {
            _ = policy.handle(.childFailed(reason: "no_physical_display"))
            log("event=virtual_display_skipped reason=no_physical_display " +
                "physical_display=\(physicalDisplayID) width=\(size.width) " +
                "height=\(size.height) " +
                "targets=\(DisplayModeHelper.mirrorTargets().count)")
            logDisplayStateAfter()
            return
        }
        log("event=virtual_display_target display_id=\(physicalDisplayID) " +
            "builtin=\(CGDisplayIsBuiltin(physicalDisplayID) != 0 ? 1 : 0) " +
            "active=\(CGDisplayIsActive(physicalDisplayID) != 0 ? 1 : 0) " +
            "vendor=0x\(String(CGDisplayVendorNumber(physicalDisplayID), radix: 16)) " +
            "model=0x\(String(CGDisplayModelNumber(physicalDisplayID), radix: 16))")
        lastSessionSize = size
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executablePath)
        process.arguments = ["virtual-display",
                             "--width", String(size.width),
                             "--height", String(size.height),
                             "--physical-display", String(physicalDisplayID),
                             "--restore-physical", startupPhysicalPixels.value]
        var environment = ProcessInfo.processInfo.environment
        // The child must never trigger the interactive TCC prompts.
        environment["RDP_AGENT_NO_PERMISSION_REQUEST"] = "1"
        process.environment = environment
        let input = Pipe()
        let output = Pipe()
        let errors = Pipe()
        process.standardInput = input
        process.standardOutput = output
        process.standardError = errors
        do {
            try process.run()
        } catch {
            _ = policy.handle(.childFailed(reason: "launch"))
            log("event=virtual_display_spawn result=1 stage=launch " +
                "width=\(size.width) height=\(size.height) " +
                "reason=\(sanitize(error.localizedDescription))")
            restoreStartupPhysicalMode(reason: "launch_failed")
            scheduleRetryIfAllowed(failedStage: "launch", size: size)
            return
        }
        self.process = process
        inputPipe = input
        outputPipe = output
        errorPipe = errors
        spawnStartedAt = DispatchTime.now().uptimeNanoseconds
        spawnGeneration += 1
        let generation = spawnGeneration
        log("event=virtual_display_spawn result=0 width=\(size.width) height=\(size.height) " +
            "pid=\(process.processIdentifier) restore_physical=\(startupPhysicalPixels.value) " +
            "executable=\(executablePath)")
        readHandshake(size: size)
        readChildStderr()
        scheduleSpawnTimeout(size: size, generation: generation)
    }

    private func readHandshake(size: VirtualDisplaySize) {
        guard let output = outputPipe else { return }
        let handle = output.fileHandleForReading
        handshakeQueue.async { [weak self] in
            var buffer = Data()
            while buffer.count < 4096 {
                let chunk: Data?
                do {
                    chunk = try handle.read(upToCount: 1)
                } catch {
                    chunk = nil
                }
                guard let chunk, !chunk.isEmpty else { break }
                if chunk.first == 0x0A { break }
                buffer.append(chunk)
            }
            let line = String(decoding: buffer, as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            self?.queue.async { self?.handleHandshake(line: line, expected: size) }
        }
    }

    /// Captures the child's stderr into the Agent log so failure stages are
    /// visible in the field (they were lost before the 2026-11-08 fix round).
    private func readChildStderr() {
        guard let errors = errorPipe else { return }
        let handle = errors.fileHandleForReading
        stderrQueue.async { [weak self] in
            var buffer = Data()
            while true {
                let chunk: Data?
                do {
                    chunk = try handle.read(upToCount: 4096)
                } catch {
                    chunk = nil
                }
                guard let chunk, !chunk.isEmpty else { break }
                buffer.append(chunk)
                while let newline = buffer.firstIndex(of: 0x0A) {
                    let lineData = buffer[buffer.startIndex..<newline]
                    buffer.removeSubrange(buffer.startIndex...newline)
                    let line = String(decoding: lineData, as: UTF8.self)
                    self?.queue.async { self?.logChildStderrLine(line) }
                }
                if buffer.count > 8192 { buffer.removeAll(keepingCapacity: true) }
            }
            if !buffer.isEmpty {
                let line = String(decoding: buffer, as: UTF8.self)
                self?.queue.async { self?.logChildStderrLine(line) }
            }
        }
    }

    private func logChildStderrLine(_ rawLine: String) {
        let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !line.isEmpty else { return }
        log("event=virtual_display_child_stderr line=\(sanitize(line, limit: 400))")
    }

    private func handleHandshake(line: String, expected: VirtualDisplaySize) {
        guard case .starting(let current) = policy.state else {
            // Stale handshake (teardown already raced the spawn): make sure the
            // child does not linger. stopChild() is a no-op without a process.
            stopChild(reason: "stale_ready", failedStage: nil)
            return
        }
        guard let ready = VirtualDisplayChildOutput.parse(line), ready.size == current else {
            _ = policy.handle(.childFailed(reason: "handshake"))
            log("event=virtual_display_spawn result=1 stage=handshake " +
                "width=\(expected.width) height=\(expected.height) " +
                "reason=invalid_handshake line_bytes=\(line.utf8.count)")
            stopChild(reason: "handshake_failed", failedStage: "handshake")
            return
        }
        lastDisplayID = ready.displayID
        _ = policy.handle(.childReady(ready))
        setActiveDisplayID(ready.displayID)
        let elapsedMilliseconds = (DispatchTime.now().uptimeNanoseconds &- spawnStartedAt) / 1_000_000
        log("event=virtual_display_ready result=0 ms=\(elapsedMilliseconds) " +
            "display_id=\(ready.displayID) width=\(ready.size.width) " +
            "height=\(ready.size.height)")
        scheduleExitMonitor()
    }

    private func scheduleSpawnTimeout(size: VirtualDisplaySize, generation: Int) {
        queue.asyncAfter(deadline: .now() + 8) { [weak self] in
            guard let self else { return }
            // A stale timeout from an earlier session/attempt must never kill the
            // current child (this raced in the reconnect harness: cycle 3 was killed
            // by cycle 2's timeout while the new child was still starting).
            guard generation == self.spawnGeneration else { return }
            guard case .starting = self.policy.state else { return }
            _ = self.policy.handle(.childFailed(reason: "ready_timeout"))
            self.log("event=virtual_display_spawn result=1 stage=ready_timeout " +
                     "width=\(size.width) height=\(size.height) timeout_ms=8000")
            self.stopChild(reason: "ready_timeout", failedStage: "ready_timeout")
        }
    }

    /// Detects an unexpected child death while the session still runs (e.g. a
    /// crash): the physical display is restored by WindowServer and then forced
    /// back to the startup mode; the Agent keeps capturing the physical display.
    private func scheduleExitMonitor() {
        guard !exitMonitorScheduled else { return }
        exitMonitorScheduled = true
        queue.asyncAfter(deadline: .now() + 0.25) { [weak self] in
            guard let self else { return }
            self.exitMonitorScheduled = false
            guard let process = self.process, !self.stopping else { return }
            if !process.isRunning {
                self.finishChildExit(expected: false, code: process.terminationStatus,
                                     reason: "unexpected_exit", failedStage: nil,
                                     elapsedMilliseconds: 0, forcedSignal: "none")
                return
            }
            self.scheduleExitMonitor()
        }
    }

    private func performTeardown(reason: String) {
        let actions = policy.handle(.teardown(reason: reason))
        var terminated = false
        for action in actions {
            if case .terminateChild(let terminateReason) = action {
                terminated = true
                stopChild(reason: terminateReason, failedStage: nil)
            }
        }
        if !terminated {
            if process != nil {
                stopChild(reason: reason, failedStage: nil)
            }
            restoreStartupPhysicalMode(reason: "teardown")
            logDisplayStateAfter()
        }
    }

    /// Terminate the child: stdin EOF first (graceful unmirror + mode restore),
    /// then SIGTERM, then SIGKILL, each with a bounded wait. Called on the serial
    /// queue.
    private func stopChild(reason: String, failedStage: String?) {
        guard let process else { return }
        stopping = true
        // Stop targeting the virtual display before the (up to ~2 s) child wait:
        // the mirror may already be coming down and input must fall back to the
        // physical display for the rest of the session.
        setActiveDisplayID(nil)
        let started = DispatchTime.now().uptimeNanoseconds
        // Closing the pipe gives the child EOF; it unmirrors and restores the
        // saved physical mode before exiting.
        try? inputPipe?.fileHandleForWriting.close()
        var forced = "none"
        if !waitForExit(process, timeout: 2.0) {
            forced = "sigterm"
            process.terminate()
            if !waitForExit(process, timeout: 0.5) {
                forced = "sigkill"
                kill(process.processIdentifier, SIGKILL)
                _ = waitForExit(process, timeout: 2.0)
            }
        }
        if !process.isRunning {
            let code = process.terminationStatus
            finishChildExit(expected: true, code: code, reason: reason,
                            failedStage: failedStage,
                            elapsedMilliseconds: (DispatchTime.now().uptimeNanoseconds &- started) / 1_000_000,
                            forcedSignal: forced)
        } else {
            log("event=virtual_display_teardown result=1 reason=\(reason) " +
                "forced=\(forced) stage=wait_child")
            cleanupChildReferences()
            _ = policy.handle(.childExited(code: -1))
            restoreStartupPhysicalMode(reason: "teardown_failed")
            logDisplayStateAfter()
        }
    }

    private func finishChildExit(expected: Bool, code: Int32, reason: String,
                                 failedStage: String?,
                                 elapsedMilliseconds: UInt64, forcedSignal: String) {
        let displayID = lastDisplayID
        cleanupChildReferences()
        _ = policy.handle(.childExited(code: code))
        if expected, let failedStage {
            // Spawn failed before the virtual display was usable: put the panel
            // back to the startup mode, then retry once.
            log("event=virtual_display_spawn result=1 stage=\(failedStage) " +
                "child_exit=\(code) forced=\(forcedSignal) " +
                "display_id=\(displayID) ms=\(elapsedMilliseconds)")
            restoreStartupPhysicalMode(reason: "spawn_failure:\(failedStage)")
            if let size = lastSessionSize {
                scheduleRetryIfAllowed(failedStage: failedStage, size: size)
            } else {
                logDisplayStateAfter()
            }
        } else if expected {
            log("event=virtual_display_teardown result=\(code == 0 ? 0 : 1) " +
                "reason=\(reason) display_id=\(displayID) child_exit=\(code) " +
                "forced=\(forcedSignal) ms=\(elapsedMilliseconds)")
            restoreStartupPhysicalMode(reason: "teardown")
            logDisplayStateAfter()
        } else {
            // Unexpected death (crash/kill): WindowServer already restored the
            // physical display; force the startup mode and keep capturing.
            log("event=virtual_display_child_exit expected=0 code=\(code) " +
                "display_id=\(displayID) reason=unexpected " +
                "capture=physical_unchanged")
            log("event=virtual_display_lost result=1 display_id=\(displayID) code=\(code)")
            restoreStartupPhysicalMode(reason: "child_lost")
            logDisplayStateAfter()
        }
    }

    /// One retry per session after a failed spawn. The physical mode has already
    /// been restored before this runs.
    private func scheduleRetryIfAllowed(failedStage: String, size: VirtualDisplaySize) {
        if failedStage == "physical_offline" {
            log("event=virtual_display_retry result=0 attempt=0 " +
                "reason=physical_offline skipped=1")
            logDisplayStateAfter()
            return
        }
        guard !teardownRequested, !retryUsed, !stopping else {
            log("event=virtual_display_retry result=0 attempt=0 " +
                "reason=\(failedStage) skipped=1")
            logDisplayStateAfter()
            return
        }
        retryUsed = true
        lastSessionSize = size
        log("event=virtual_display_retry result=0 attempt=1 reason=\(failedStage) " +
            "delay_ms=500 width=\(size.width) height=\(size.height)")
        queue.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            guard let self else { return }
            guard !self.teardownRequested, self.process == nil else { return }
            switch self.policy.state {
            case .failed:
                _ = self.policy.handle(.retry)
            default:
                break
            }
            guard case .idle = self.policy.state else {
                self.logDisplayStateAfter()
                return
            }
            let actions = self.policy.handle(.captureSize(size))
            self.perform(actions)
        }
    }

    // MARK: - physical mode safety net

    /// Force the physical display back to the Agent's startup pixel size. Used
    /// after every failure/teardown so a scaled panel can never survive a failed
    /// spawn (field bug: panel left at 1920x1080).
    private func restoreStartupPhysicalMode(reason: String) {
        guard CGDisplayCopyDisplayMode(physicalDisplayID) != nil else {
            log("event=virtual_display_physical_restore result=1 reason=\(reason) " +
                "saved=\(startupPhysicalPixels.value) current=display_offline")
            return
        }
        let before = DisplayModeHelper.currentPixels(displayID: physicalDisplayID)
        if before == startupPhysicalPixels {
            log("event=virtual_display_physical_restore result=0 reason=\(reason) " +
                "saved=\(startupPhysicalPixels.value) current=\(before?.value ?? "unknown")")
            return
        }
        let restored = DisplayModeHelper.setMode(displayID: physicalDisplayID,
                                                 pixels: startupPhysicalPixels,
                                                 timeout: 2.0)
        log("event=virtual_display_physical_restore result=\(restored.result ? 0 : 1) " +
            "reason=\(reason) saved=\(startupPhysicalPixels.value) " +
            "before=\(before?.value ?? "unknown") " +
            "current=\(restored.current?.value ?? "unknown")")
    }

    private func cleanupChildReferences() {
        stopping = false
        process = nil
        inputPipe = nil
        outputPipe = nil
        errorPipe = nil
        lastDisplayID = 0
        // Every exit/teardown path ends here: input falls back to the startup
        // physical display as soon as the virtual display is no longer usable.
        setActiveDisplayID(nil)
    }

    private func setActiveDisplayID(_ displayID: CGDirectDisplayID?) {
        activeDisplayIDLock.lock()
        cachedActiveDisplayID = displayID
        activeDisplayIDLock.unlock()
    }

    private func waitForExit(_ process: Process, timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while process.isRunning, Date() < deadline {
            Thread.sleep(forTimeInterval: 0.05)
        }
        return !process.isRunning
    }

    /// `event=display_state_after` is logged once per session (including failed
    /// sessions where the display never changed, for an auditable before/after).
    private func logDisplayStateAfter() {
        guard sessionDisplayStateLogged, !sessionDisplayStateAfterLogged else { return }
        sessionDisplayStateAfterLogged = true
        sessionActive = false
        log("event=display_state_after \(DisplayStateSummary.current())")
    }

    private func log(_ line: String) {
        FileHandle.standardError.write(Data((line + "\n").utf8))
    }

    private func sanitize(_ message: String, limit: Int = 300) -> String {
        let cleaned = message
            .replacingOccurrences(of: "\n", with: "_")
            .replacingOccurrences(of: "\r", with: "_")
            .replacingOccurrences(of: " ", with: "_")
            .replacingOccurrences(of: "\t", with: "_")
        return String(cleaned.prefix(limit))
    }
}
