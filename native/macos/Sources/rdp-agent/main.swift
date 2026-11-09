import Foundation
import AppKit
import ApplicationServices
import CoreGraphics
import CoreMedia
import CoreVideo
import Darwin
import Dispatch
import ImageIO
import MacAgentCore
import ScreenCaptureKit
import UniformTypeIdentifiers

@main
struct Agent {
    /// Auto display-mode matching: on IPC type 9 the Agent switches
    /// the macOS display to the mode that minimises the letterbox black bars for
    /// the client desktop box (product decision: no stretch). Default ON; set
    /// RDP_AGENT_MATCH_DISPLAY_MODE=0 to disable mode switching (rollback).
    private static let matchDisplayModeEnabled =
        ProcessInfo.processInfo.environment["RDP_AGENT_MATCH_DISPLAY_MODE"] != "0"

    /// Custom 16:9 virtual display: disabled by default for the first
    /// deploy. RDP_AGENT_VIRTUAL_DISPLAY=1 makes the Agent spawn a child process
    /// that creates a virtual display at the negotiated desktop box and mirrors
    /// the physical display onto it, so ScreenCaptureKit captures the box 1:1
    /// (no letterbox bars) without changing the existing capture filtering.
    private static let virtualDisplayEnabled = VirtualDisplayFeatureGate.isEnabled(
        environmentValue: ProcessInfo.processInfo.environment["RDP_AGENT_VIRTUAL_DISPLAY"])

    static func main() async {
        let arguments = Array(CommandLine.arguments.dropFirst())
        // The virtual-display child is a non-interactive helper: it
        // must never request TCC permissions, so handle it before main() does.
        if arguments.first == "virtual-display" {
            do {
                try VirtualDisplayChild.run(arguments: Array(arguments.dropFirst()))
            } catch {
                fputs("rdp-agent: \(error.localizedDescription)\n", stderr)
                exit(1)
            }
            return
        }
        // Explicit permission request used by the menu bar app (RDPServerCore):
        // request the missing TCC permissions for this bundle identity, print
        // the resulting report and exit. No capture loop and no service state.
        if arguments.first == "request-permissions" {
            requestMissingPermissions()
            let snapshot = PermissionSnapshot(
                screenRecording: CGPreflightScreenCaptureAccess(),
                accessibility: AXIsProcessTrusted())
            print(snapshot.report)
            return
        }
        do {
            if ProcessInfo.processInfo.environment["RDP_AGENT_NO_PERMISSION_REQUEST"] != "1" {
                requestMissingPermissions()
            }
            try await run(arguments)
        } catch {
            if ProcessInfo.processInfo.environment["RDP_AGENT_NO_PERMISSION_REQUEST"] == "1",
               let agentError = error as? AgentError,
               case .screenRecordingPermission = agentError {
                fputs("rdp-agent: Screen Recording permission is missing; grant it, then restart the LaunchAgent.\n", stderr)
                exit(0)
            }
            fputs("rdp-agent: \(error.localizedDescription)\n", stderr)
            exit(1)
        }
    }

    private static func run(_ arguments: [String]) async throws {
        let command = arguments.first ?? "status"
        let permissions = PermissionSnapshot(
            screenRecording: CGPreflightScreenCaptureAccess(),
            accessibility: AXIsProcessTrusted()
        )

        switch command {
        case "status":
            print(permissions.report)
        case "displays":
            let content = try await shareableContent()
            for (index, display) in content.displays.enumerated() {
                let pixels = captureDimensions(for: display)
                print("index=\(index) id=\(display.displayID) points=\(display.width)x\(display.height) pixels=\(pixels.width)x\(pixels.height)")
            }
        case "capture":
            guard permissions.screenRecording else { throw AgentError.screenRecordingPermission }
            guard arguments.count == 3, let index = Int(arguments[1]), index >= 0 else {
                throw AgentError.usage
            }
            let content = try await shareableContent()
            guard content.displays.indices.contains(index) else { throw AgentError.displayIndex }
            let display = content.displays[index]
            let pixels = captureDimensions(for: display)
            let excludedApps = content.applications.filter {
                CaptureExclusion.excludes(bundleIdentifier: $0.bundleIdentifier)
            }
            let filter = SCContentFilter(display: display, excludingApplications: excludedApps, exceptingWindows: [])
            let configuration = screenshotConfiguration(
                size: CaptureSizeRequest(width: display.width, height: display.height)!,
                targetFramesPerSecond: 30, sRGB: true)
            configuration.width = pixels.width
            configuration.height = pixels.height
            let image = try await capture(filter: filter, configuration: configuration)
            try writePNG(image, to: URL(fileURLWithPath: arguments[2]))
            print("captured display=\(display.displayID) width=\(image.width) height=\(image.height) path=\(arguments[2])")
        case "capture-stream":
            guard permissions.screenRecording else { throw AgentError.screenRecordingPermission }
            guard arguments.count == 3, let index = Int(arguments[1]), index >= 0,
                  let seconds = Int(arguments[2]), (1...30).contains(seconds) else {
                throw AgentError.usage
            }
            let content = try await shareableContent()
            guard content.displays.indices.contains(index) else { throw AgentError.displayIndex }
            let display = content.displays[index]
            let pixels = captureDimensions(for: display)
            let excludedApps = content.applications.filter {
                CaptureExclusion.excludes(bundleIdentifier: $0.bundleIdentifier)
            }
            let filter = SCContentFilter(display: display, excludingApplications: excludedApps, exceptingWindows: [])
            let configuration = screenshotConfiguration(
                size: CaptureSizeRequest(width: pixels.width, height: pixels.height)!,
                targetFramesPerSecond: 30, sRGB: true)
            configuration.minimumFrameInterval = CMTime(value: 1, timescale: 30)
            // queueDepth 1 stalls SCStream on macOS 27 (one sample buffer only).
            // The default pixel format is 420v, so 32BGRA must be explicit or the
            // observer rejects every frame (this caused "no display frames").
            configuration.queueDepth = 3
            let observer = CaptureFrameObserver()
            let stream = SCStream(filter: filter, configuration: configuration, delegate: observer)
            try stream.addStreamOutput(observer, type: .screen,
                                       sampleHandlerQueue: DispatchQueue(label: "rdp-agent.capture"))
            do {
                try await stream.startCapture()
            } catch {
                fputs("event=capture_stream_error stage=start message=\(error.localizedDescription)\n", stderr)
                throw error
            }
            do {
                try await Task.sleep(nanoseconds: UInt64(seconds) * 1_000_000_000)
            } catch {
                try? await stream.stopCapture()
                throw error
            }
            try await stream.stopCapture()
            let progress = observer.snapshot()
            let diagnostics = observer.diagnostics
            if progress.frameCount == 0 {
                fputs("event=capture_stream_diag frames=0 sampled=\(diagnostics.sampled) no_image_buffer=\(diagnostics.noImageBuffer) rejected_format=\(diagnostics.rejectedPixelFormat) rejected_size=\(diagnostics.rejectedSize) formats=\(diagnostics.formats) delegate_error=\(observer.failure ?? "none")\n", stderr)
                throw AgentError.noFrames
            }
            print("frames=\(progress.frameCount) display=\(display.displayID) width=\(progress.width) height=\(progress.height)")
        case "capture-bench":
            guard permissions.screenRecording else { throw AgentError.screenRecordingPermission }
            try await captureBench(arguments)
        case "stream":
            guard permissions.screenRecording else { throw AgentError.screenRecordingPermission }
            guard arguments.count == 5, let index = Int(arguments[2]), index >= 0,
                  let secondsArgument = Int(arguments[3]),
                  let duration = AgentStreamDuration(argument: secondsArgument),
                  let generation = UInt64(arguments[4]), generation > 0 else {
                throw AgentError.usage
            }
            let socket = try AgentUnixSocket(path: arguments[1])
            let content = try await shareableContent()
            guard content.displays.indices.contains(index) else { throw AgentError.displayIndex }
            let display = content.displays[index]
            let pixels = captureDimensions(for: display)
            let excludedApps = content.applications.filter {
                CaptureExclusion.excludes(bundleIdentifier: $0.bundleIdentifier)
            }
            let filter = SCContentFilter(display: display, excludingApplications: excludedApps, exceptingWindows: [])
            let configuration = SCStreamConfiguration()
            configuration.width = pixels.width
            configuration.height = pixels.height
            configuration.pixelFormat = kCVPixelFormatType_32BGRA
            configuration.minimumFrameInterval = CMTime(value: 1, timescale: 5)
            configuration.queueDepth = 3
            let frameID = FrameIDCounter()
            let clipboard = ClipboardMonitor()
            let clipboardFiles = ClipboardFileReceiver(clipboard: clipboard)
            let displayID = display.displayID
            let displayMode = DisplayModeController(displayID: displayID,
                                                    enabled: Agent.matchDisplayModeEnabled)
            let clipboardStager = ClipboardLocalFileOfferStager(
                fileSystem: PosixClipboardLocalFileStagingFileSystem())
            defer { clipboardStager.removeAllDirectories() }
            // Diagnostics path: no IPC type 9 here, so use the native size as
            // both desktop and capture (the old full-frame mapping).
            guard let streamSize = CaptureSizeRequest(width: pixels.width,
                                                      height: pixels.height) else {
                throw AgentError.noContent
            }
            let geometry = CaptureGeometryState(desktop: streamSize, nativeWidth: pixels.width,
                                                nativeHeight: pixels.height)
            let inputController = AgentInputController()
            DispatchQueue(label: "rdp-agent.remote-input").async { [weak socket] in
                guard let socket else { return }
                do {
                    try socket.receiveMessages { message in
                        displayMode.noteInbound()
                        do {
                            if message.type == .displayRestore {
                                displayMode.handleRestoreMessage(message.payload)
                                return
                            }
                            if message.type == .clipboardData {
                                try clipboard.setRemoteUnicodePayload(message.payload)
                                return
                            }
                            if ClipboardFileReceiver.handles(message.type) {
                                // File assembly runs on its own serial queue so the
                                // input receiver never blocks on file IO.
                                clipboardFiles.submit(message)
                                return
                            }
                            guard message.type == .inputEvent else { return }
                            let event = try AgentIPCCodec.decodeInputEvent(message.payload)
                            // Per-event mapping/decode problems are dropped and
                            // rate-limited; releasing the user's keys here used to
                            // turn one stray mouse event into swallowed typing.
                            inputController.apply(event, displayID: displayID,
                                                  geometry: geometry.snapshot())
                        } catch {
                            inputController.logRejected(error)
                        }
                    }
                } catch AgentUnixSocketError.closed {
                    displayMode.handlePeerClosed()
                    inputController.releaseAll(reason: "socket_closed")
                    fputs("event=input_receiver_stopped reason=socket_closed\n", stderr)
                } catch {
                    displayMode.restoreSynchronously(reason: "input_receiver_error")
                    inputController.releaseAll(reason: "input_receiver_error")
                    fputs("event=input_receiver_stopped reason=\(sanitize(error.localizedDescription))\n", stderr)
                    exit(1)
                }
            }
            let observer = CaptureFrameObserver { [weak socket] imageWidth, imageHeight, pixels in
                guard let socket else { throw AgentError.socketClosed }
                try sendLocalClipboardUpdate(clipboard, stager: clipboardStager) {
                    try socket.send($0)
                }
                try socket.sendFrame(
                    metadata: AgentFrameMetadata(generation: generation,
                                                 frameID: frameID.next(),
                                                 width: UInt32(imageWidth),
                                                 height: UInt32(imageHeight),
                                                 bytesPerPixel: 4),
                    pixels: pixels
                )
            }
            let stream = SCStream(filter: filter, configuration: configuration, delegate: observer)
            try stream.addStreamOutput(observer, type: .screen,
                                       sampleHandlerQueue: DispatchQueue(label: "rdp-agent.stream"))
            try await stream.startCapture()
            do {
                if let seconds = duration.seconds {
                    try await Task.sleep(nanoseconds: UInt64(seconds) * 1_000_000_000)
                } else {
                    waitForTerminationSignal()
                }
            } catch {
                try? await stream.stopCapture()
                throw error
            }
            try await stream.stopCapture()
            socket.close()
            let progress = observer.snapshot()
            if let failure = observer.failure {
                throw AgentError.streamFailed(failure)
            }
            guard progress.frameCount > 0 else { throw AgentError.noFrames }
            print("frames_sent=\(progress.frameCount) display=\(display.displayID) width=\(progress.width) height=\(progress.height)")
        case "stream-snapshot":
            try await streamSnapshot(arguments, permissions: permissions)
        case "set-display-mode":
            // Test/deployment helper (used by scripts/test-virtual-display-integration.py):
            // force the main display to a mode with the given pixel size.
            guard arguments.count == 3, let width = Int(arguments[1]), let height = Int(arguments[2]),
                  width > 0, height > 0 else {
                throw AgentError.usage
            }
            let pixels = DisplayPixelSize(width: width, height: height)
            let displayID = CGMainDisplayID()
            let set = DisplayModeHelper.setMode(displayID: displayID, pixels: pixels, timeout: 3.0)
            print("display_mode_set result=\(set.result ? 0 : 1) display=\(displayID) " +
                  "requested=\(pixels.width)x\(pixels.height) " +
                  "current=\(set.current?.value ?? "unknown")")
            if !set.result { throw AgentError.inputEvent }
        case "move":
            guard permissions.accessibility else { throw AgentError.accessibilityPermission }
            guard arguments.count == 3, let x = Double(arguments[1]), let y = Double(arguments[2]),
                  x.isFinite, y.isFinite else { throw AgentError.usage }
            let point = CGPoint(x: x, y: y)
            guard let event = CGEvent(mouseEventSource: nil, mouseType: .mouseMoved,
                                      mouseCursorPosition: point, mouseButton: .left) else {
                throw AgentError.inputEvent
            }
            event.post(tap: .cghidEventTap)
            print("mouse_moved x=\(x) y=\(y)")
        default:
            throw AgentError.usage
        }
    }

    // MARK: - stream-snapshot

    private static func streamSnapshot(_ arguments: [String],
                                       permissions: PermissionSnapshot) async throws {
        guard permissions.screenRecording else { throw AgentError.screenRecordingPermission }
        guard arguments.count == 5, let index = Int(arguments[2]), index >= 0,
              let secondsArgument = Int(arguments[3]),
              let duration = AgentStreamDuration(argument: secondsArgument),
              let generation = UInt64(arguments[4]), generation > 0 else {
            throw AgentError.usage
        }
        let environment = ProcessInfo.processInfo.environment
        let targetFramesPerSecond = SnapshotPacing.resolvedTargetFramesPerSecond(
            environmentValue: environment["RDP_AGENT_TARGET_FPS"])
        let streamCaptureEnabled = environment["RDP_AGENT_CAPTURE_STREAM"] == "1"
        let virtualDisplayEnabled = Agent.virtualDisplayEnabled
        let socket = try AgentUnixSocket(path: arguments[1])
        let content = try await shareableContent()
        Agent.logDisplayInventory()
        guard content.displays.indices.contains(index) else { throw AgentError.displayIndex }
        let display = content.displays[index]
        let dimensions = captureDimensions(for: display)
        // Physical panel pixel size at Agent startup. The virtual-display child
        // forces this mode before mirroring and restores it on teardown, so a
        // failed/scaled session can never leave the panel non-native (reconnect
        // bug fix, 2026-11-08).
        let startupPhysicalPixels = Agent.physicalModePixels(displayID: display.displayID)
        let excludedApps = content.applications.filter {
            CaptureExclusion.excludes(bundleIdentifier: $0.bundleIdentifier)
        }
        let filter = SCContentFilter(display: display, excludingApplications: excludedApps, exceptingWindows: [])
        // Before the first type 9 arrives the negotiated desktop box is the
        // native display size (the historical full-display behaviour).
        guard let initialDesktop = CaptureSizeRequest(width: dimensions.width,
                                                      height: dimensions.height) else {
            throw AgentError.noContent
        }
        let geometry = CaptureGeometryState(desktop: initialDesktop,
                                            nativeWidth: dimensions.width,
                                            nativeHeight: dimensions.height)
        let displayMonitor = DisplaySizeMonitor(displayID: display.displayID, geometry: geometry)
        let displayMode = DisplayModeController(displayID: display.displayID,
                                                enabled: Agent.matchDisplayModeEnabled)
        // Custom 16:9 virtual display: spawned on the first IPC type 9
        // of a worker session, torn down on type 17 / socket EOF / process exit.
        let virtualDisplay = virtualDisplayEnabled
            ? VirtualDisplayController(enabled: true,
                                       executablePath: Agent.agentExecutablePath(),
                                       physicalDisplayID: display.displayID,
                                       startupPhysicalPixels: startupPhysicalPixels)
            : nil
        let clipboardStager = ClipboardLocalFileOfferStager(
            fileSystem: PosixClipboardLocalFileStagingFileSystem())
        // Whatever ends this Agent process (peer teardown, capture error, SIGTERM
        // handling), never leave the user's display in a switched mode and never
        // leak the local->remote staging directories.
        defer {
            virtualDisplay?.teardownSynchronously(reason: "agent_exit")
            displayMode.restoreSynchronously(reason: "agent_exit")
            clipboardStager.removeAllDirectories()
        }
        let frameID = FrameIDCounter()
        let clipboard = ClipboardMonitor()
        let clipboardFiles = ClipboardFileReceiver(clipboard: clipboard)
        let inputController = AgentInputController()
        // Every termination path (peer teardown, capture error, thrown error,
        // SIGTERM) must release injected keys and post the unconditional
        // modifier sweep: a modifier still down when the Agent exits stays stuck
        // in the focused app/IME until the user presses a real key on the Mac.
        defer { inputController.releaseAll(reason: "termination") }
        startInputReceiver(socket: socket, displayID: display.displayID,
                           geometry: geometry,
                           clipboard: clipboard, clipboardFiles: clipboardFiles,
                           displayMode: displayMode, virtualDisplay: virtualDisplay,
                           controller: inputController)
        let deadline = duration.seconds.map { ContinuousClock.now + .seconds($0) }
        let stop = SnapshotStopSignal()
        let writer = AgentSocketWriter(socket: socket)
        let context = CaptureLoopContext(writer: writer, generation: generation, frameID: frameID,
                                         clipboard: clipboard,
                                         clipboardStager: clipboardStager,
                                         geometry: geometry,
                                         displayMonitor: displayMonitor,
                                         displayMode: displayMode,
                                         stop: stop, deadline: deadline,
                                         targetFramesPerSecond: targetFramesPerSecond)
        fputs("event=capture_config source=\(streamCaptureEnabled ? "stream" : "snapshot") target_fps=\(targetFramesPerSecond) width=\(dimensions.width) height=\(dimensions.height) stream_queue_depth=\(streamQueueDepth(environment)) virtual_display=\(virtualDisplayEnabled ? 1 : 0)\n", stderr)

        var frames = 0
        if streamCaptureEnabled {
            do {
                frames = try await runStreamCapture(context: context, filter: filter)
            } catch let fallback as StreamFallback {
                switch fallback {
                case let .unavailable(reason):
                    fputs("event=capture_stream_fallback reason=\(sanitize(reason))\n", stderr)
                    frames = try await runSnapshotCapture(context: context, filter: filter)
                }
            }
        } else {
            frames = try await runSnapshotCapture(context: context, filter: filter)
        }
        // Stop the capture loop first, then restore the user's display arrangement
        // before the socket/process teardown completes.
        virtualDisplay?.teardownSynchronously(reason: "session_end")
        writer.close()
        // inputController.releaseAll(reason: "termination") runs from the defer
        // above, covering thrown errors too.
        print("snapshot_frames_sent=\(frames) display=\(display.displayID) width=\(dimensions.width) height=\(dimensions.height)")
    }

    /// SCScreenshotManager loop: one screenshot + BGRA conversion per iteration.
    private static func runSnapshotCapture(context: CaptureLoopContext,
                                           filter: SCContentFilter) async throws -> Int {
        let interval = SnapshotPacing.intervalNanoseconds(
            targetFramesPerSecond: context.targetFramesPerSecond)
        let deltaFramesEnabled = ProcessInfo.processInfo.environment["RDP_AGENT_DELTA_FRAMES"] == "1"
        var frames = 0
        var timing = CaptureTiming(windowSize: 30)
        var deltaEncoder = AgentFrameDeltaEncoder()
        var pixels = Data()
        var pending: Task<CapturedFrame, Error>?
        var conversionStrategy = CapturePixelStrategy.automatic

        func startNextCapture() -> Task<CapturedFrame, Error> {
            let requested = context.geometry.snapshot().capture
            let request = ScreenshotRequest(filter: filter, width: requested.width,
                                            height: requested.height,
                                            targetFramesPerSecond: context.targetFramesPerSecond)
            return Task { try await Agent.capture(request: request) }
        }

        while !context.stop.requested && (context.deadline == nil || ContinuousClock.now < context.deadline!) {
            // Pick up a native display resolution change (design section 4); the
            // next screenshot request then uses the recomputed capture size.
            context.displayMonitor.poll()
            context.displayMode.poll()
            let frameStart = DispatchTime.now().uptimeNanoseconds
            let frame: CapturedFrame
            if let pending {
                frame = try await pending.value
            } else {
                frame = try await startNextCapture().value
            }
            // The pending frame may have completed during the previous iteration's
            // pacing sleep, so the conversion clock starts only now. conversion_ms
            // must contain the CGImage -> BGRA work and nothing else; the wait for
            // the pending frame is reported separately as await_ms.
            let conversionStart = DispatchTime.now().uptimeNanoseconds
            // Start the next screenshot before the current frame is converted, so
            // capture and conversion stop adding up.
            pending = startNextCapture()
            let image = frame.image
            conversionStrategy = CapturePixelConverter.resolvedStrategy(for: image,
                                                                        requested: .automatic)
            try CapturePixelConverter.copyBGRA(image, into: &pixels, strategy: conversionStrategy)
            let converted = DispatchTime.now().uptimeNanoseconds
            try sendLocalClipboardUpdate(context.clipboard,
                                         stager: context.clipboardStager,
                                         send: context.writer.send)
            let metadata = AgentFrameMetadata(generation: context.generation,
                                              frameID: context.frameID.next(),
                                              width: UInt32(image.width),
                                              height: UInt32(image.height),
                                              bytesPerPixel: 4)
            if deltaFramesEnabled {
                let tiles = try deltaEncoder.encode(pixels: &pixels, width: image.width,
                                                    height: image.height,
                                                    generation: context.generation)
                if !tiles.isEmpty {
                    try context.writer.sendFrameDelta(metadata: metadata, tiles: tiles)
                    frames += 1
                }
            } else {
                try context.writer.sendFrame(metadata: metadata, pixels: pixels)
                frames += 1
            }
            let sent = DispatchTime.now().uptimeNanoseconds
            let requested = frame.requested
            if let means = timing.record(capture: frame.capturedAt &- frame.startedAt,
                                         conversion: converted &- conversionStart,
                                         send: sent &- converted,
                                         wait: conversionStart &- frameStart) {
                let line = String(
                    format: "event=snapshot_timing samples=30 width=%d height=%d capture_ms=%.1f conversion_ms=%.1f ipc_ms=%.1f await_ms=%.1f source=snapshot requested_width=%d requested_height=%d image_width=%d image_height=%d target_fps=%d loop_ms=%.1f overlap=1 convert=%@\n",
                    image.width, image.height,
                    means.captureMilliseconds, means.conversionMilliseconds, means.sendMilliseconds,
                    means.waitMilliseconds,
                    requested.width, requested.height, image.width, image.height,
                    context.targetFramesPerSecond,
                    // Mean busy time of the loop iteration (start of await through
                    // send), i.e. await + conversion + IPC. Excludes the trailing
                    // pacing sleep and is consistent with the other means.
                    means.waitMilliseconds + means.conversionMilliseconds + means.sendMilliseconds,
                    conversionStrategy.label)
                FileHandle.standardError.write(Data(line.utf8))
            }
            let elapsed = DispatchTime.now().uptimeNanoseconds &- frameStart
            let delay = SnapshotPacing.delayNanoseconds(elapsed: elapsed,
                                                         intervalNanoseconds: interval)
            if delay > 0 { try await Task.sleep(nanoseconds: delay) }
        }
        return frames
    }

    /// Optional continuous SCStream loop: no per-frame screenshot and no
    /// per-frame CGImage conversion; CVPixelBuffer rows are copied straight into
    /// the same BGRA tile/IPC pipeline.
    private static func runStreamCapture(context: CaptureLoopContext,
                                         filter: SCContentFilter) async throws -> Int {
        let environment = ProcessInfo.processInfo.environment
        let queueDepth = streamQueueDepth(environment)
        let initial = context.geometry.snapshot().capture
        let configuration = streamConfiguration(width: initial.width, height: initial.height,
                                                targetFramesPerSecond: context.targetFramesPerSecond,
                                                queueDepth: queueDepth)
        let pump = StreamFramePump(writer: context.writer,
                                   geometry: context.geometry,
                                   frameID: context.frameID,
                                   generation: context.generation,
                                   targetFramesPerSecond: context.targetFramesPerSecond,
                                   configuredWidth: initial.width,
                                   configuredHeight: initial.height)
        let stream = SCStream(filter: filter, configuration: configuration, delegate: pump)
        do {
            try stream.addStreamOutput(pump, type: .screen,
                                       sampleHandlerQueue: DispatchQueue(label: "rdp-agent.capture-stream"))
        } catch {
            throw StreamFallback.unavailable("addStreamOutput: \(error.localizedDescription)")
        }
        pump.attach(stream: stream)
        do {
            try await stream.startCapture()
        } catch {
            throw StreamFallback.unavailable("startCapture: \(error.localizedDescription)")
        }
        let startupDeadline = DispatchTime.now().uptimeNanoseconds &+ 2_000_000_000
        var stoppedByRequest = false
        while !context.stop.requested && (context.deadline == nil || ContinuousClock.now < context.deadline!) {
            do {
                try await Task.sleep(nanoseconds: 100_000_000)
            } catch {
                break
            }
            // A native display resolution change recomputes the requested capture
            // size; the pump's existing reconfigure path applies it (design 4).
            context.displayMonitor.poll()
            context.displayMode.poll()
            try sendLocalClipboardUpdate(context.clipboard,
                                         stager: context.clipboardStager,
                                         send: context.writer.send)
            let status = pump.snapshot()
            let now = DispatchTime.now().uptimeNanoseconds
            if let failure = status.failure {
                try? await stream.stopCapture()
                // A broken IPC socket means the worker is gone; exit like the
                // snapshot loop does instead of silently falling back.
                if failure.hasPrefix("send:") { throw AgentError.socketClosed }
                throw StreamFallback.unavailable(failure)
            }
            if status.frameCount == 0 && now >= startupDeadline {
                try? await stream.stopCapture()
                throw StreamFallback.unavailable("no display frames within 2s")
            }
            if let reconfigureStart = status.reconfigureStartedAt, now &- reconfigureStart > 5_000_000_000 {
                try? await stream.stopCapture()
                throw StreamFallback.unavailable("capture-size reconfigure timed out")
            }
        }
        stoppedByRequest = true
        try? await stream.stopCapture()
        let status = pump.snapshot()
        if let failure = status.failure, status.framesSent == 0 {
            if failure.hasPrefix("send:") { throw AgentError.socketClosed }
            throw StreamFallback.unavailable(failure)
        }
        fputs("event=capture_stream_summary frames_sent=\(status.framesSent) frames_received=\(status.frameCount) dropped=\(status.dropped) width=\(status.width) height=\(status.height) stopped_by_request=\(stoppedByRequest) target_fps=\(context.targetFramesPerSecond) queue_depth=\(queueDepth)\n", stderr)
        return status.framesSent
    }

    private static func streamQueueDepth(_ environment: [String: String]) -> Int {
        let requested = Int(environment["RDP_AGENT_STREAM_QUEUE_DEPTH"] ?? "") ?? 3
        return min(max(requested, 2), 8)
    }

    private static func screenshotConfiguration(size: CaptureSizeRequest,
                                                targetFramesPerSecond: Int,
                                                sRGB: Bool) -> SCStreamConfiguration {
        let configuration = SCStreamConfiguration()
        configuration.width = size.width
        configuration.height = size.height
        configuration.pixelFormat = kCVPixelFormatType_32BGRA
        if sRGB { configuration.colorSpaceName = CGColorSpace.sRGB }
        // Historical behaviour left the cursor out of the capture; the RDP client
        // draws its own cursor. Opt in only for diagnostics.
        configuration.showsCursor = ProcessInfo.processInfo.environment["RDP_AGENT_SHOW_CURSOR"] == "1"
        configuration.minimumFrameInterval = CMTime(
            value: 1, timescale: CMTimeScale(targetFramesPerSecond))
        return configuration
    }

    fileprivate static func streamConfiguration(width: Int, height: Int,
                                            targetFramesPerSecond: Int,
                                            queueDepth: Int) -> SCStreamConfiguration {
        let configuration = SCStreamConfiguration()
        configuration.width = width
        configuration.height = height
        configuration.pixelFormat = kCVPixelFormatType_32BGRA
        configuration.colorSpaceName = CGColorSpace.sRGB
        configuration.showsCursor = ProcessInfo.processInfo.environment["RDP_AGENT_SHOW_CURSOR"] == "1"
        // queueDepth 1 stalls SCStream delivery on macOS 27 (only one sample
        // buffer arrives), so 2...8 is enforced by streamQueueDepth.
        configuration.queueDepth = queueDepth
        configuration.minimumFrameInterval = CMTime(
            value: 1, timescale: CMTimeScale(targetFramesPerSecond))
        return configuration
    }

    // MARK: - capture benchmark

    private static func captureBench(_ arguments: [String]) async throws {
        let displayIndex = arguments.count > 1 ? Int(arguments[1]) ?? 0 : 0
        let iterations = max(3, min(arguments.count > 2 ? Int(arguments[2]) ?? 30 : 30, 200))
        let streamSeconds = max(1, min(arguments.count > 3 ? Int(arguments[3]) ?? 3 : 3, 30))
        let content = try await shareableContent()
        guard content.displays.indices.contains(displayIndex) else { throw AgentError.displayIndex }
        let display = content.displays[displayIndex]
        let dimensions = captureDimensions(for: display)
        let excludedApps = content.applications.filter {
            CaptureExclusion.excludes(bundleIdentifier: $0.bundleIdentifier)
        }
        let filter = SCContentFilter(display: display, excludingApplications: excludedApps, exceptingWindows: [])
        let size = CaptureSizeRequest(width: dimensions.width, height: dimensions.height)!
        let environment = ProcessInfo.processInfo.environment
        let targetFPS = SnapshotPacing.resolvedTargetFramesPerSecond(
            environmentValue: environment["RDP_AGENT_TARGET_FPS"])
        print("event=capture_bench_start display=\(display.displayID) width=\(dimensions.width) height=\(dimensions.height) iterations=\(iterations) target_fps=\(targetFPS)")

        func describe(_ variant: String, _ image: CGImage) {
            let layout = CapturePixelConverter.layout(of: image)
            let colorSpaceName = image.colorSpace?.name as String? ?? "unnamed"
            let providerBytes = image.dataProvider?.data.map { CFDataGetLength($0) } ?? -1
            print("event=capture_bench_layout variant=\(variant) \(layout.describe) colorspace=\(colorSpaceName) provider_bytes=\(providerBytes)")
        }

        let p3Image = try await capture(filter: filter, configuration: screenshotConfiguration(
            size: size, targetFramesPerSecond: targetFPS, sRGB: false))
        describe("default", p3Image)
        let srgbImage = try await capture(filter: filter, configuration: screenshotConfiguration(
            size: size, targetFramesPerSecond: targetFPS, sRGB: true))
        describe("srgb", srgbImage)

        let variants: [(String, Bool, CapturePixelStrategy)] = [
            ("legacy_p3_deviceRGB", false, .contextDeviceRGB),
            ("p3_auto", false, .automatic),
            ("srgb_auto", true, .automatic),
            ("srgb_contextImageSpace", true, .contextImageColorSpace),
        ]
        for (label, sRGB, strategy) in variants {
            // A conversion failure on one variant must not abort the whole run.
            var captureStats = CaptureBenchmark()
            var conversionStats = CaptureBenchmark()
            var loopStats = CaptureBenchmark()
            var reusable = Data()
            var conversionError: String?
            for iteration in 0..<iterations {
                let frameStart = DispatchTime.now().uptimeNanoseconds
                let configuration = screenshotConfiguration(size: size,
                                                             targetFramesPerSecond: targetFPS,
                                                             sRGB: sRGB)
                let image = try await capture(filter: filter, configuration: configuration)
                let captured = DispatchTime.now().uptimeNanoseconds
                do {
                    try CapturePixelConverter.copyBGRA(image, into: &reusable, strategy: strategy)
                } catch {
                    conversionError = "\(error)"
                    break
                }
                let converted = DispatchTime.now().uptimeNanoseconds
                if iteration > 0 {
                    captureStats.record(nanoseconds: captured &- frameStart)
                    conversionStats.record(nanoseconds: converted &- captured)
                    loopStats.record(nanoseconds: converted &- frameStart)
                }
            }
            if let conversionError {
                print("event=capture_bench variant=\(label) error=\(sanitize(conversionError))")
                continue
            }
            let captureText = captureStats.stats?.describe ?? "none"
            let conversionText = conversionStats.stats?.describe ?? "none"
            let loopText = loopStats.stats?.describe ?? "none"
            print("event=capture_bench variant=\(label) capture:\(captureText) conversion:\(conversionText) loop:\(loopText)")
        }

        // Colour fidelity. Both capture paths are sampled twice so the pair
        // comparison can be read against a same-path control (a moving screen
        // otherwise shows up as a huge colour diff).
        struct ColorDiff {
            var samples = 0
            var meanRGB = [Double](repeating: 0, count: 3)
            var maxRGB = [Int](repeating: 0, count: 3)
            var alphaNotOpaque = 0
            var over8 = 0
            var over32 = 0
            var over127 = 0
        }
        func diff(_ first: Data, _ second: Data, legacyOrder: Bool) -> ColorDiff {
            var result = ColorDiff()
            let count = min(first.count, second.count)
            guard count > 0 else { return result }
            var totals = [Double](repeating: 0, count: 3)
            var samples = [Int](repeating: 0, count: 3)
            let step = 97
            first.withUnsafeBytes { firstBuffer in
                second.withUnsafeBytes { secondBuffer in
                    guard let firstBase = firstBuffer.baseAddress,
                          let secondBase = secondBuffer.baseAddress else { return }
                    var index = 0
                    while index < count {
                        let channel = index % 4
                        let firstValue = Int(firstBase.load(fromByteOffset: index, as: UInt8.self))
                        let secondValue = Int(secondBase.load(fromByteOffset: index, as: UInt8.self))
                        let difference = abs(firstValue - secondValue)
                        if channel < 3 {
                            totals[channel] += Double(difference)
                            samples[channel] += 1
                            result.maxRGB[channel] = max(result.maxRGB[channel], difference)
                            if difference > 8 { result.over8 += 1 }
                            if difference > 32 { result.over32 += 1 }
                            if difference > 127 { result.over127 += 1 }
                        } else if secondValue != 255 {
                            result.alphaNotOpaque += 1
                        }
                        index += step
                    }
                }
            }
            for channel in 0..<3 {
                result.meanRGB[channel] = samples[channel] > 0
                    ? totals[channel] / Double(samples[channel]) : 0
                result.samples = max(result.samples, samples[channel])
            }
            if !legacyOrder {
                // second path is the new one; re-label alpha stat already counted.
            }
            return result
        }
        func describeDiff(_ label: String, _ value: ColorDiff) -> String {
            let mean = value.meanRGB.reduce(0, +) / 3
            let max = value.maxRGB.max() ?? 0
            let over8Percent = value.samples > 0 ? Double(value.over8) / Double(value.samples * 3) * 100 : 0
            return "\(label)_mean_rgb=\(String(format: "%.2f", mean)) \(label)_max_rgb=\(max) \(label)_gt8=\(value.over8)(\(String(format: "%.3f", over8Percent))%) \(label)_gt32=\(value.over32) \(label)_gt127=\(value.over127)"
        }
        do {
            let legacyA = try await capture(filter: filter, configuration: screenshotConfiguration(
                size: size, targetFramesPerSecond: targetFPS, sRGB: false))
            var legacyPixelsA = Data()
            try CapturePixelConverter.copyBGRA(legacyA, into: &legacyPixelsA,
                                               strategy: .contextDeviceRGB)
            let newA = try await capture(filter: filter, configuration: screenshotConfiguration(
                size: size, targetFramesPerSecond: targetFPS, sRGB: true))
            var newPixelsA = Data()
            try CapturePixelConverter.copyBGRA(newA, into: &newPixelsA, strategy: .automatic)
            let newB = try await capture(filter: filter, configuration: screenshotConfiguration(
                size: size, targetFramesPerSecond: targetFPS, sRGB: true))
            var newPixelsB = Data()
            try CapturePixelConverter.copyBGRA(newB, into: &newPixelsB, strategy: .automatic)
            let test = diff(legacyPixelsA, newPixelsA, legacyOrder: true)
            let control = diff(newPixelsA, newPixelsB, legacyOrder: false)
            // Restrict the test comparison to pixels that did not change between
            // the two consecutive same-path captures: that removes moving screen
            // content and leaves only the actual colour-path difference.
            var staticSamples = 0
            var staticTotal = 0.0
            var staticMax = 0
            var staticOver8 = 0
            let count = min(legacyPixelsA.count, min(newPixelsA.count, newPixelsB.count))
            if count > 0 {
                legacyPixelsA.withUnsafeBytes { legacyBuffer in
                    newPixelsA.withUnsafeBytes { newBuffer in
                        newPixelsB.withUnsafeBytes { stableBuffer in
                            guard let legacyBase = legacyBuffer.baseAddress,
                                  let newBase = newBuffer.baseAddress,
                                  let stableBase = stableBuffer.baseAddress else { return }
                            var index = 0
                            while index < count {
                                let channel = index % 4
                                if channel < 3, newBase.load(fromByteOffset: index, as: UInt8.self) ==
                                    stableBase.load(fromByteOffset: index, as: UInt8.self) {
                                    let difference = abs(Int(legacyBase.load(fromByteOffset: index, as: UInt8.self)) -
                                                         Int(newBase.load(fromByteOffset: index, as: UInt8.self)))
                                    staticTotal += Double(difference)
                                    staticMax = max(staticMax, difference)
                                    if difference > 8 { staticOver8 += 1 }
                                    staticSamples += 1
                                }
                                index += 97
                            }
                        }
                    }
                }
            }
            let staticMean = staticSamples > 0 ? staticTotal / Double(staticSamples) : 0
            print("event=capture_bench_color_diff samples=\(test.samples) " +
                  describeDiff("legacy_vs_srgb_direct", test) + " " +
                  describeDiff("srgb_vs_srgb_control", control) +
                  " static_rgb_samples=\(staticSamples) static_rgb_mean=\(String(format: "%.2f", staticMean)) static_rgb_max=\(staticMax) static_rgb_gt8=\(staticOver8)" +
                  " (byte order is BGRA; RDP planar uses PIXEL_FORMAT_BGRX32 so alpha is ignored; legacy path = P3 image converted to DeviceRGB)")
        } catch {
            print("event=capture_bench_color_diff error=\(sanitize("\(error)"))")
        }

        // Continuous SCStream measurement.
        let queueDepth = streamQueueDepth(environment)
        let streamConfiguration = streamConfiguration(width: size.width, height: size.height,
                                                      targetFramesPerSecond: targetFPS,
                                                      queueDepth: queueDepth)
        let collector = BenchStreamCollector()
        let stream = SCStream(filter: filter, configuration: streamConfiguration, delegate: collector)
        do {
            try stream.addStreamOutput(collector, type: .screen,
                                       sampleHandlerQueue: DispatchQueue(label: "rdp-agent.bench-stream"))
            try await stream.startCapture()
            let started = DispatchTime.now().uptimeNanoseconds
            try await Task.sleep(nanoseconds: UInt64(streamSeconds) * 1_000_000_000)
            try await stream.stopCapture()
            let elapsed = DispatchTime.now().uptimeNanoseconds &- started
            let summary = collector.summary()
            let copyText = summary.copyStats.stats?.describe ?? "none"
            let deliveredFPS = Double(summary.frames) / (Double(elapsed) / 1e9)
            print("event=capture_bench_stream frames=\(summary.frames) elapsed_ms=\(String(format: "%.1f", Double(elapsed) / 1_000_000)) delivered_fps=\(String(format: "%.1f", deliveredFPS)) pixel_format=0x\(String(summary.pixelFormat, radix: 16)) queue_depth=\(queueDepth) copy:\(copyText) failure=\(summary.failure.map(sanitize) ?? "none")")
        } catch {
            print("event=capture_bench_stream error=\(sanitize("\(error)"))")
        }
    }

    // MARK: - shared helpers

    private static func requestMissingPermissions() {
        let snapshot = PermissionSnapshot(
            screenRecording: CGPreflightScreenCaptureAccess(),
            accessibility: AXIsProcessTrusted()
        )

        if snapshot.needsScreenRecordingRequest {
            fputs("rdp-agent: requesting Screen Recording permission…\n", stderr)
            _ = CGRequestScreenCaptureAccess()
        }
        if snapshot.needsAccessibilityRequest {
            fputs("rdp-agent: requesting Accessibility permission…\n", stderr)
            let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
            _ = AXIsProcessTrustedWithOptions(options)
        }
    }

    private static func waitForTerminationSignal() {
        signal(SIGINT, SIG_IGN)
        signal(SIGTERM, SIG_IGN)
        let semaphore = DispatchSemaphore(value: 0)
        let signalQueue = DispatchQueue(label: "rdp-agent.stop-signal")
        let lock = NSLock()
        var receivedSignal = false
        let sources = [SIGINT, SIGTERM].map { signalNumber in
            let source = DispatchSource.makeSignalSource(signal: signalNumber, queue: signalQueue)
            source.setEventHandler {
                lock.lock()
                defer { lock.unlock() }
                guard !receivedSignal else { return }
                receivedSignal = true
                semaphore.signal()
            }
            source.resume()
            return source
        }
        semaphore.wait()
        sources.forEach { $0.cancel() }
        signal(SIGINT, SIG_DFL)
        signal(SIGTERM, SIG_DFL)
    }

    /// Absolute path of this executable, used to spawn the virtual-display child
    /// (the child is the same binary with the `virtual-display` subcommand).
    private static func agentExecutablePath() -> String {
        if let path = Bundle.main.executablePath, path.hasPrefix("/") {
            return path
        }
        let argument = CommandLine.arguments.first ?? ""
        if argument.hasPrefix("/") {
            return argument
        }
        let currentDirectory = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        return URL(fileURLWithPath: argument, relativeTo: currentDirectory)
            .standardizedFileURL.path
    }

    private static func shareableContent() async throws -> SCShareableContent {
        try await withCheckedThrowingContinuation { continuation in
            SCShareableContent.getExcludingDesktopWindows(false, onScreenWindowsOnly: true) { content, error in
                if let error { continuation.resume(throwing: error) }
                else if let content { continuation.resume(returning: content) }
                else { continuation.resume(throwing: AgentError.noContent) }
            }
        }
    }

    private static func captureDimensions(for display: SCDisplay) -> DisplayPixelSize {
        let mode = CGDisplayCopyDisplayMode(display.displayID)
        let pixelWidth = mode.map { $0.pixelWidth } ?? 0
        let pixelHeight = mode.map { $0.pixelHeight } ?? 0
        return DisplayPixelSize.resolve(pointsWidth: display.width, pointsHeight: display.height,
                                        pixelsWidth: pixelWidth,
                                        pixelsHeight: pixelHeight)
    }

    /// Startup diagnostics: one line with every online display (builtin/active/
    /// main/pixels/points/vendor/model) so orphan/ghost display states are obvious
    /// in the log; also warn when the main display looks like one of our virtual
    /// displays (2026-11-08 incident).
    private static func logDisplayInventory() {
        var count: UInt32 = 0
        CGGetOnlineDisplayList(0, nil, &count)
        var identifiers = [CGDirectDisplayID](repeating: 0, count: Int(max(count, 1)))
        var actual: UInt32 = 0
        CGGetOnlineDisplayList(count, &identifiers, &actual)
        var parts: [String] = ["online=\(actual)"]
        for index in 0..<Int(actual) {
            let identifier = identifiers[index]
            let mode = CGDisplayCopyDisplayMode(identifier)
            let bounds = CGDisplayBounds(identifier)
            parts.append("id=\(identifier) " +
                         "builtin=\(CGDisplayIsBuiltin(identifier) != 0 ? 1 : 0) " +
                         "active=\(CGDisplayIsActive(identifier) != 0 ? 1 : 0) " +
                         "main=\(CGDisplayIsMain(identifier) != 0 ? 1 : 0) " +
                         "pixels=\(mode?.pixelWidth ?? 0)x\(mode?.pixelHeight ?? 0) " +
                         "points=\(Int(bounds.width))x\(Int(bounds.height)) " +
                         "vendor=0x\(String(CGDisplayVendorNumber(identifier), radix: 16)) " +
                         "model=0x\(String(CGDisplayModelNumber(identifier), radix: 16))")
        }
        FileHandle.standardError.write(Data(
            ("event=display_inventory " + parts.joined(separator: " ") + "\n").utf8))
        let main = CGMainDisplayID()
        if DisplayModeHelper.isVirtualDisplay(main) {
            FileHandle.standardError.write(Data(
                ("event=main_display_virtual result=1 display_id=\(main) " +
                 "note=no_real_physical_display\n").utf8))
        }
    }

    /// Physical panel pixel size at Agent startup (used by the virtual display
    /// child to force/restore the panel mode). Falls back to the display bounds
    /// when CoreGraphics has no mode yet (e.g. display waking up).
    fileprivate static func physicalModePixels(displayID: CGDirectDisplayID) -> DisplayPixelSize {
        if let mode = CGDisplayCopyDisplayMode(displayID), mode.pixelWidth > 0 {
            return DisplayPixelSize(width: mode.pixelWidth, height: mode.pixelHeight)
        }
        let bounds = CGDisplayBounds(displayID)
        return DisplayPixelSize(width: Int(bounds.width), height: Int(bounds.height))
    }

    /// Native display pixel size by display id, for the capture-loop poller
    /// (no SCDisplay is available there, so the point size comes from
    /// CGDisplayBounds).
    fileprivate static func currentDisplaySize(displayID: CGDirectDisplayID) -> DisplayPixelSize {
        let mode = CGDisplayCopyDisplayMode(displayID)
        let bounds = CGDisplayBounds(displayID)
        return DisplayPixelSize.resolve(pointsWidth: Int(bounds.width),
                                        pointsHeight: Int(bounds.height),
                                        pixelsWidth: mode?.pixelWidth ?? 0,
                                        pixelsHeight: mode?.pixelHeight ?? 0)
    }

    private static func capture(filter: SCContentFilter,
                                configuration: SCStreamConfiguration) async throws -> CGImage {
        try await withCheckedThrowingContinuation { continuation in
            SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration) { image, error in
                if let error { continuation.resume(throwing: error) }
                else if let image { continuation.resume(returning: image) }
                else { continuation.resume(throwing: AgentError.noImage) }
            }
        }
    }

    fileprivate static func capture(request: ScreenshotRequest) async throws -> CapturedFrame {
        let startedAt = DispatchTime.now().uptimeNanoseconds
        let configuration = screenshotConfiguration(
            size: CaptureSizeRequest(width: request.width, height: request.height)!,
            targetFramesPerSecond: request.targetFramesPerSecond, sRGB: true)
        let image = try await capture(filter: request.filter, configuration: configuration)
        let capturedAt = DispatchTime.now().uptimeNanoseconds
        return CapturedFrame(image: image,
                             requested: CaptureSizeRequest(width: request.width,
                                                           height: request.height)!,
                             startedAt: startedAt, capturedAt: capturedAt)
    }

    private static func writePNG(_ image: CGImage, to url: URL) throws {
        guard let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else {
            throw AgentError.pngDestination
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else {
            throw AgentError.pngWrite
        }
    }

    private static func startInputReceiver(socket: AgentUnixSocket, displayID: CGDirectDisplayID,
                                           geometry: CaptureGeometryState,
                                           clipboard: ClipboardMonitor,
                                           clipboardFiles: ClipboardFileReceiver,
                                           displayMode: DisplayModeController,
                                           virtualDisplay: VirtualDisplayController?,
                                           controller: AgentInputController) {
        DispatchQueue(label: "rdp-agent.remote-input").async { [weak socket] in
            guard let socket else { return }
            do {
                try socket.receiveMessages { message in
                    // Any inbound IPC proves the peer is alive (used by the
                    // display-mode dead-peer restore fallback).
                    displayMode.noteInbound()
                    // One malformed or unsupported message must never stop the
                    // receiver: a receiver that exits silently leaves the Worker's
                    // writes to this socket unread, which used to wedge the Worker
                    // peer threads (frozen picture, then a black session on
                    // reconnect). 2026-11-07 field failure.
                    do {
                        if message.type == .displayRestore {
                            // Worker -> Agent type 17 (empty payload): restore the
                            // display arrangement for the finished worker session.
                            // The virtual display child unmirrors and exits; the
                            // saved auto-matched mode is restored as before.
                            virtualDisplay?.handleTeardown(reason: "peer_restore")
                            displayMode.handleRestoreMessage(message.payload)
                            return
                        }
                        if message.type == .clipboardData {
                            try clipboard.setRemoteUnicodePayload(message.payload)
                            return
                        }
                        if message.type == .captureSize {
                            // IPC type 9 carries the negotiated DESKTOP box (the
                            // wire format is unchanged); the Agent derives the
                            // capture size from it and the native display size.
                            guard let desktop = AgentIPCCodec.decodeCaptureSize(message.payload) else {
                                throw AgentError.invalidInputCoordinates
                            }
                            let updated = geometry.updateRequested(desktop)
                            FileHandle.standardError.write(Data(("event=capture_size_updated " +
                                "width=\(updated.desktop.width) height=\(updated.desktop.height) " +
                                "\(updated.logFields)\n").utf8))
                            // Custom virtual display: the first type 9
                            // of a session spawns the child at the negotiated box;
                            // later boxes do not recreate it in v1. Otherwise the
                            // legacy auto display-mode matching runs.
                            if let virtualDisplay {
                                virtualDisplay.handleCaptureSize(desktop)
                            } else {
                                displayMode.requestDesktop(desktop)
                            }
                            return
                        }
                        if ClipboardFileReceiver.handles(message.type) {
                            // File clipboard assembly runs on its own serial
                            // queue: writing up to 4 GiB must never stall the
                            // input receiver (design §1/§2.1).
                            clipboardFiles.submit(message)
                            return
                        }
                        guard message.type == .inputEvent else { return }
                        let event = try AgentIPCCodec.decodeInputEvent(message.payload)
                        let snapshot = geometry.snapshot()
                        let target = Agent.inputDisplayTarget(
                            physicalDisplayID: displayID, geometry: snapshot,
                            virtualDisplay: virtualDisplay, controller: controller)
                        controller.apply(event, displayID: target.displayID,
                                         geometry: snapshot)
                    } catch {
                        // A malformed message is dropped, rate-limited and the
                        // receiver keeps going; per-event errors must never
                        // release the user's pressed keys (2026-11-08: one
                        // rejected mouse event used to release all modifiers).
                        controller.logRejected(error)
                    }
                }
            } catch AgentUnixSocketError.closed {
                // Peer gone: put the user's display arrangement back before the
                // display-mode restore retries are needed.
                virtualDisplay?.handleTeardown(reason: "peer_closed")
                displayMode.handlePeerClosed()
                controller.releaseAll(reason: "socket_closed")
                FileHandle.standardError.write(Data("event=input_receiver_stopped reason=socket_closed\n".utf8))
            } catch {
                // Unrecoverable receive failure: exit so launchd restarts a healthy
                // agent instead of leaving a process that never reads input again.
                virtualDisplay?.teardownSynchronously(reason: "input_receiver_error")
                displayMode.restoreSynchronously(reason: "input_receiver_error")
                controller.releaseAll(reason: "input_receiver_error")
                FileHandle.standardError.write(Data("event=input_receiver_stopped reason=\(sanitize(error.localizedDescription))\n".utf8))
                exit(1)
            }
        }
    }

    /// Resolve the display a remote input event must be injected on and feed the
    /// rate-limited input-target diagnostics. The pure decision lives in
    /// `InputDisplayTargetResolver` (MacAgentCore, unit tested); this helper only
    /// samples CoreGraphics and never blocks on the virtual-display queue.
    ///
    /// While the virtual display is active the Agent captures its framebuffer,
    /// but the mirrored physical display can keep native HiDPI point bounds on
    /// macOS 26.x (field bug 2026-11-09: injected points scaled by
    /// points/pixels, offset growing towards the bottom-right). Input therefore
    /// targets the virtual display in that state and the startup physical
    /// display otherwise (fit-with-bars path, unchanged).
    private static func inputDisplayTarget(
        physicalDisplayID: CGDirectDisplayID, geometry: CaptureGeometry,
        virtualDisplay: VirtualDisplayController?,
        controller: AgentInputController) -> InputDisplayTarget {
        let physicalBounds = desktopRect(CGDisplayBounds(physicalDisplayID))
        let reportedVirtualDisplayID = virtualDisplay?.activeDisplayID
        var virtualDisplayID: UInt32?
        var virtualBounds: DesktopDisplayRect?
        // A reported-but-dead virtual id (child teardown race, display unplugged)
        // must never be used for CGEvent injection: fall back to physical.
        if let candidate = reportedVirtualDisplayID {
            let bounds = CGDisplayBounds(candidate)
            if CGDisplayIsActive(candidate) != 0,
               bounds.width > 0, bounds.height > 0 {
                virtualDisplayID = candidate
                virtualBounds = desktopRect(bounds)
            }
        }
        let target = InputDisplayTargetResolver.resolve(
            activeVirtualDisplayID: virtualDisplayID,
            virtualBounds: virtualBounds,
            captureWidth: geometry.capture.width,
            captureHeight: geometry.capture.height,
            physicalDisplayID: physicalDisplayID,
            physicalBounds: physicalBounds)
        var fallbackReason: String?
        if target.source == .physical, reportedVirtualDisplayID != nil {
            fallbackReason = virtualDisplayID == nil ? "display_unavailable" : "bounds_mismatch"
        }
        controller.noteInputTarget(target, fallbackReason: fallbackReason,
                                   geometry: geometry)
        return target
    }

    private static func desktopRect(_ bounds: CGRect) -> DesktopDisplayRect {
        DesktopDisplayRect(originX: Double(bounds.origin.x),
                           originY: Double(bounds.origin.y),
                           width: Double(bounds.width),
                           height: Double(bounds.height))
    }

    /// Pumps one local clipboard change to the Worker. Text keeps the existing
    /// type-8 wire format (`[1] + utf8`); a pasteboard holding file URLs becomes
    /// a direction-2 begin/entries/end metadata offer instead (design §2.2/§3).
    /// Exactly one of the two is sent per change.
    /// Local file staging is opt-in: the Worker reads the original paths
    /// directly (it already has the launcher's file permissions), so staging
    /// every offer would make the Agent hit TCC prompts for folders the Worker
    /// can read (field test 2026-11-08: the Agent blocked in open() on a
    /// ~/Downloads file while the Worker could read it). Set
    /// RDP_AGENT_CLIPBOARD_STAGING=1 to stage instead (needed when the Worker
    /// itself cannot read the source folder and the Agent has Full Disk Access).
    private static let clipboardStagingEnabled =
        ProcessInfo.processInfo.environment["RDP_AGENT_CLIPBOARD_STAGING"] == "1"

    private static func sendLocalClipboardUpdate(
        _ clipboard: ClipboardMonitor,
        stager: ClipboardLocalFileOfferStager,
        send: (AgentIPCMessage) throws -> Void
    ) throws {
        switch clipboard.poll() {
        case .none:
            return
        case .text(let payload):
            // Field diagnostics: a real-client "copy does nothing" report can be
            // diagnosed from the agent log (kind + size only, never content).
            FileHandle.standardError.write(Data(
                "event=clipboard_local_update kind=text bytes=\(payload.count)\n".utf8))
            try send(AgentIPCMessage(type: .clipboardData, payload: payload))
            // The text clipboard supersedes any previous file offer: the Worker
            // revokes the advertisement with this type-8 message, then the
            // staged copies are no longer needed.
            stager.removeAllDirectories()
        case .empty:
            // Empty / non-text clipboard: revoke any remote file advertisement.
            FileHandle.standardError.write(Data(
                "event=clipboard_local_update kind=empty\n".utf8))
            try send(AgentIPCMessage(type: .clipboardData, payload: Data([1])))
            stager.removeAllDirectories()
        case .files(let urls):
            FileHandle.standardError.write(Data(
                "event=clipboard_local_update kind=files count=\(urls.count)\n".utf8))
            do {
                // Default: advertise the original paths (the Worker reads them).
                // Optional staging (design addendum §9) for the case where the
                // Worker cannot read a protected folder but the Agent can.
                if Self.clipboardStagingEnabled {
                    let staged = try stager.stage(urls: urls)
                    for message in try staged.offer.messages() {
                        try send(message)
                    }
                    FileHandle.standardError.write(Data(("event=clipboard_file_offer " +
                        "direction=local_to_remote count=\(staged.offer.entries.count) " +
                        "bytes=\(staged.offer.begin.totalBytes) staged=1\n").utf8))
                } else {
                    let offer = try ClipboardLocalFileOfferBuilder.build(urls: urls)
                    for message in try offer.messages() {
                        try send(message)
                    }
                    FileHandle.standardError.write(Data(("event=clipboard_file_offer " +
                        "direction=local_to_remote count=\(offer.entries.count) " +
                        "bytes=\(offer.begin.totalBytes) staged=0\n").utf8))
                }
            } catch {
                // Reject the file list but still tell the Worker to drop any
                // previous file advertisement, using the empty-text reset.
                FileHandle.standardError.write(Data(("event=clipboard_file_rejected " +
                    "direction=local_to_remote " +
                    "reason=\(clipboardOfferRejectionReason(error)) " +
                    "\(clipboardOfferRejectionLogFields(error))\n").utf8))
                try send(AgentIPCMessage(type: .clipboardData, payload: Data([1])))
            }
        }
    }

    private static func clipboardOfferRejectionReason(_ error: Error) -> String {
        if let staging = error as? ClipboardLocalFileStagingError {
            switch staging {
            case .unreadable: return "unreadable"
            case .readFailed: return "unreadable"
            case .sizeMismatch: return "size_mismatch"
            case .invalidStagedName: return "bad_name"
            case .fileSystem: return "io_failed"
            }
        }
        guard let offerError = error as? ClipboardLocalFileOfferError else {
            return "offer_failed"
        }
        switch offerError {
        case .empty: return "empty"
        case .tooManyFiles: return "too_many_files"
        case .invalidFile: return "not_regular"
        case .invalidName: return "bad_name"
        case .invalidPath: return "bad_name"
        case .fileTooLarge: return "too_large"
        case .totalTooLarge: return "too_large"
        }
    }

    /// Sanitized, grep-able diagnostic fields for a rejected local file list.
    /// `name` is always a validated single path component (never a full path)
    /// and `errno` is the raw POSIX errno, per the design logging rules.
    private static func clipboardOfferRejectionLogFields(_ error: Error) -> String {
        if let staging = error as? ClipboardLocalFileStagingError {
            switch staging {
            case let .unreadable(name, errorNumber):
                return "name=\(name) errno=\(errorNumber)"
            case let .readFailed(errorNumber):
                return "errno=\(errorNumber)"
            case let .sizeMismatch(name, expected, actual):
                return "name=\(name) expected=\(expected) actual=\(actual)"
            case let .invalidStagedName(name):
                return "name=\(name)"
            case .fileSystem:
                return "stage=filesystem"
            }
        }
        return "stage=offer"
    }
}

private func sanitize(_ message: String) -> String {
    message.replacingOccurrences(of: " ", with: "_")
        .replacingOccurrences(of: "\n", with: "_")
}

// MARK: - capture loop plumbing

private struct CaptureLoopContext {
    let writer: AgentSocketWriter
    let generation: UInt64
    let frameID: FrameIDCounter
    let clipboard: ClipboardMonitor
    let clipboardStager: ClipboardLocalFileOfferStager
    let geometry: CaptureGeometryState
    let displayMonitor: DisplaySizeMonitor
    let displayMode: DisplayModeController
    let stop: SnapshotStopSignal
    let deadline: ContinuousClock.Instant?
    let targetFramesPerSecond: Int
}

/// Polls the captured display's native pixel size so a resolution change is
/// picked up by a running capture loop (design section 4). Detection runs at
/// most every 500 ms; an unavailable display mode keeps the last known size.
private final class DisplaySizeMonitor {
    static let pollIntervalNanoseconds: UInt64 = 500_000_000

    private let displayID: CGDirectDisplayID
    private let geometry: CaptureGeometryState
    private let lock = NSLock()
    private var lastPolledAt: UInt64 = 0
    private var lastKnown: DisplayPixelSize

    init(displayID: CGDirectDisplayID, geometry: CaptureGeometryState) {
        self.displayID = displayID
        self.geometry = geometry
        let current = geometry.snapshot()
        self.lastKnown = DisplayPixelSize(width: current.nativeWidth,
                                          height: current.nativeHeight)
    }

    /// Detect a display resolution change; on change recompute the geometry and
    /// log event=display_size_changed. Cheap to call once per capture loop
    /// iteration (throttled internally).
    func poll(now: UInt64 = DispatchTime.now().uptimeNanoseconds) {
        lock.lock()
        let due = now &- lastPolledAt >= Self.pollIntervalNanoseconds
        if due { lastPolledAt = now }
        let previous = lastKnown
        lock.unlock()
        guard due else { return }
        let current = Agent.currentDisplaySize(displayID: displayID)
        // 0x0 / absent mode: keep the last known native size.
        guard current.width > 0, current.height > 0 else { return }
        guard current != previous else { return }
        lock.lock()
        lastKnown = current
        lock.unlock()
        guard let updated = geometry.updateNative(width: current.width, height: current.height) else {
            return
        }
        fputs("event=display_size_changed native=\(updated.nativeValue) desktop=\(updated.desktopValue) capture=\(updated.captureValue) policy=\(updated.policy.rawValue)\n", stderr)
    }
}

/// Applies and restores the macOS display mode for the auto display-mode
/// matching feature: on every IPC type-9 desktop box the Agent picks
/// the closest available display mode (DisplayModeMatcher), saves the original
/// mode once and switches with CGDisplaySetDisplayMode; IPC type 17 (worker peer
/// teardown, empty payload) restores the saved mode. A 120 s dead-peer fallback
/// retries the restore if the peer socket was seen closing and CoreGraphics did
/// not report success.
///
/// All CoreGraphics display calls run on one serial queue so the input receiver
/// never blocks on a mode switch. The capture loops poll `poll()` so a worker
/// crash cannot leave the user's display in a switched mode. When the feature is
/// disabled (RDP_AGENT_MATCH_DISPLAY_MODE=0) every method is a cheap no-op and
/// the input controller keeps the old fit-with-bars mouse mapping.
private final class DisplayModeController: @unchecked Sendable {
    /// How long a known-dead peer may keep a switched display mode before the
    /// safety net retries the restore (120 s).
    static let deadPeerRestoreTimeoutNanoseconds: UInt64 = 120 * 1_000_000_000

    private let displayID: CGDirectDisplayID
    private let enabled: Bool
    private let queue = DispatchQueue(label: "rdp-agent.display-mode")
    private let lock = NSLock()
    /// The mode to put back on restore; nil when nothing was switched.
    private var originalMode: CGDisplayMode?
    /// Pixel size of the mode currently applied by this Agent (nil when the
    /// display is in its saved/original mode).
    private var appliedPixels: DisplayModePixels?
    /// Set when the worker IPC socket was observed closed; drives the fallback.
    private var disconnectedAt: UInt64?
    private var lastRestoreAttemptAt: UInt64 = 0

    init(displayID: CGDirectDisplayID, enabled: Bool) {
        self.displayID = displayID
        self.enabled = enabled
    }

    /// Any inbound IPC message proves the peer is alive again.
    func noteInbound() {
        guard enabled else { return }
        lock.lock()
        disconnectedAt = nil
        lock.unlock()
    }

    /// IPC type 9 arrived: select and apply the best display mode asynchronously.
    func requestDesktop(_ desktop: CaptureSizeRequest) {
        guard enabled else { return }
        noteInbound()
        queue.async { [weak self] in
            self?.apply(desktop: desktop)
        }
    }

    /// IPC type 17 arrived (worker peer teardown): restore the saved mode once,
    /// idempotently. The wire format is an empty payload.
    func handleRestoreMessage(_ payload: Data) {
        if (try? AgentIPCCodec.decodeDisplayRestore(payload)) == nil {
            FileHandle.standardError.write(Data(
                "event=display_mode_restore_invalid bytes=\(payload.count)\n".utf8))
        }
        queue.async { [weak self] in
            self?.restoreOnce(reason: "peer_restore", logNoOp: true)
        }
    }

    /// The agent socket reported EOF/closed: the peer is gone, restore now. The
    /// dead-peer poll retries if CoreGraphics refuses this first attempt.
    func handlePeerClosed() {
        guard enabled else { return }
        lock.lock()
        if disconnectedAt == nil {
            disconnectedAt = DispatchTime.now().uptimeNanoseconds
        }
        lock.unlock()
        queue.async { [weak self] in
            self?.restoreOnce(reason: "peer_closed", logNoOp: false)
        }
    }

    /// Dead-peer safety net, called once per capture-loop iteration (cheap: only
    /// locks when the feature is on). Never fires during a healthy idle session:
    /// it requires the IPC socket to have been observed closed.
    func poll(now: UInt64 = DispatchTime.now().uptimeNanoseconds) {
        guard enabled else { return }
        lock.lock()
        var due = false
        if let disconnectedAt, originalMode != nil {
            let reference = max(disconnectedAt, lastRestoreAttemptAt)
            due = now &- reference > Self.deadPeerRestoreTimeoutNanoseconds
            if due { lastRestoreAttemptAt = now }
        }
        lock.unlock()
        guard due else { return }
        FileHandle.standardError.write(Data(
            "event=display_mode_restore_retry reason=dead_peer\n".utf8))
        queue.async { [weak self] in
            self?.restoreOnce(reason: "dead_peer", logNoOp: false)
        }
    }

    /// Synchronous restore for process-exit paths (defer blocks, error exits).
    func restoreSynchronously(reason: String) {
        guard enabled else { return }
        queue.sync { [weak self] in
            self?.restoreOnce(reason: reason, logNoOp: false)
        }
    }

    // MARK: - serial queue work

    private func apply(desktop: CaptureSizeRequest) {
        let requested = DisplayModePixels(width: desktop.width, height: desktop.height)
        let modes = availableModes()
        let unique = uniquePixels(modes)
        guard let match = DisplayModeMatcher.match(requested: requested,
                                                   available: unique) else {
            logSelected(desktop: desktop, match: nil, result: 1, extra: "reason=no_modes")
            return
        }
        let currentMode = CGDisplayCopyDisplayMode(displayID)
        let currentPixels = currentMode.map {
            DisplayModePixels(width: $0.pixelWidth, height: $0.pixelHeight)
        }
        // Skip pointless mode churn: already showing the selected mode, or the
        // black-bar improvement is below the product threshold (>20 permille of
        // aspect delta, DisplayModeSwitchPolicy).
        if let currentPixels, currentPixels == match.mode {
            logSelected(desktop: desktop, match: match, result: 0,
                        extra: "switched=0 reason=already_mode")
            return
        }
        if let currentPixels,
           !DisplayModeSwitchPolicy.shouldSwitch(from: currentPixels, to: match,
                                                 requested: requested) {
            logSelected(desktop: desktop, match: match, result: 0,
                        extra: "switched=0 current=\(currentPixels.value) " +
                            "current_aspect_delta_permille=" +
                            "\(currentPixels.aspectDeltaPermille(from: requested)) " +
                            "reason=below_threshold")
            return
        }
        let candidates = rankedModes(for: match.mode, modes: modes,
                                     scale: backingScale(of: currentMode))
        guard !candidates.isEmpty else {
            logSelected(desktop: desktop, match: match, result: 1,
                        extra: "reason=no_candidate")
            return
        }
        let savedOriginal = saveOriginalIfNeeded(currentMode)
        for candidate in candidates {
            let result = CGDisplaySetDisplayMode(displayID, candidate, nil)
            if result == .success {
                lock.lock()
                appliedPixels = match.mode
                lock.unlock()
                logSelected(desktop: desktop, match: match, result: 0,
                            extra: "switched=1 " +
                                "points=\(candidate.width)x\(candidate.height) " +
                                "original_saved=\(savedOriginal ? 1 : 0)")
                return
            }
        }
        logSelected(desktop: desktop, match: match, result: 1, extra: "reason=cg_failed")
        // No switch happened: drop the original saved for this attempt unless an
        // earlier type 9 already switched the display (then it must be kept for
        // the later restore).
        lock.lock()
        if appliedPixels == nil && savedOriginal {
            originalMode = nil
        }
        lock.unlock()
    }

    /// Saves the current display mode the first time a switch is attempted.
    /// Returns true when this call saved it (for the log line).
    private func saveOriginalIfNeeded(_ current: CGDisplayMode?) -> Bool {
        guard let current else { return false }
        lock.lock()
        defer { lock.unlock() }
        guard originalMode == nil else { return false }
        originalMode = current
        return true
    }

    private func restoreOnce(reason: String, logNoOp: Bool) {
        lock.lock()
        let original = originalMode
        lock.unlock()
        guard let original else {
            // Idempotent: type 17 after an already-restored (or never switched)
            // display is a successful no-op. Internal exit/EOF paths stay quiet.
            if logNoOp {
                logRestored(result: 0, reason: reason + "_noop")
            }
            return
        }
        let result = CGDisplaySetDisplayMode(displayID, original, nil)
        if result == .success {
            lock.lock()
            originalMode = nil
            appliedPixels = nil
            disconnectedAt = nil
            lock.unlock()
            logRestored(result: 0, reason: reason)
        } else {
            // Keep the saved mode so the dead-peer poll can retry.
            lock.lock()
            lastRestoreAttemptAt = DispatchTime.now().uptimeNanoseconds
            lock.unlock()
            logRestored(result: 1, reason: reason + "_cg_error")
        }
    }

    private func availableModes() -> [CGDisplayMode] {
        // The low-resolution duplicate modes are required to see the HiDPI
        // variants of every pixel size (2940x1836/1912, 3420x2136/2224 on this
        // panel); fall back to the plain list when the option is unsupported.
        let options = [kCGDisplayShowDuplicateLowResolutionModes: true] as CFDictionary
        if let modes = CGDisplayCopyAllDisplayModes(displayID, options) as? [CGDisplayMode],
           !modes.isEmpty {
            return modes
        }
        return (CGDisplayCopyAllDisplayModes(displayID, nil) as? [CGDisplayMode]) ?? []
    }

    private func uniquePixels(_ modes: [CGDisplayMode]) -> [DisplayModePixels] {
        var seen = Set<DisplayModePixels>()
        var ordered: [DisplayModePixels] = []
        for mode in modes {
            let pixels = DisplayModePixels(width: mode.pixelWidth, height: mode.pixelHeight)
            guard pixels.width > 0, pixels.height > 0 else { continue }
            if seen.insert(pixels).inserted {
                ordered.append(pixels)
            }
        }
        return ordered
    }

    /// All CGDisplayMode variants of one pixel size, ordered by how close their
    /// point size is to the current backing scale (keeps Retina UI scaling when
    /// switching; falls through to the other variants if CoreGraphics refuses).
    private func rankedModes(for pixels: DisplayModePixels, modes: [CGDisplayMode],
                             scale: Double) -> [CGDisplayMode] {
        let candidates = modes.filter {
            $0.pixelWidth == pixels.width && $0.pixelHeight == pixels.height
        }
        return candidates.sorted { first, second in
            let firstScore = abs(modeScale(first) - scale)
            let secondScore = abs(modeScale(second) - scale)
            if abs(firstScore - secondScore) > 1e-9 { return firstScore < secondScore }
            if first.width != second.width { return first.width < second.width }
            return first.height < second.height
        }
    }

    private func backingScale(of mode: CGDisplayMode?) -> Double {
        guard let mode else { return 1 }
        return modeScale(mode)
    }

    private func modeScale(_ mode: CGDisplayMode) -> Double {
        guard mode.width > 0 else { return 1 }
        return Double(mode.pixelWidth) / Double(mode.width)
    }

    private func logSelected(desktop: CaptureSizeRequest, match: DisplayModeMatch?,
                             result: Int, extra: String) {
        let chosen = match?.mode.value ?? "none"
        let delta = match?.aspectDeltaPermille ?? 0
        let reason = match?.reason.rawValue ?? "no_match"
        FileHandle.standardError.write(Data(
            ("event=display_mode_selected requested=\(desktop.width)x\(desktop.height) " +
             "chosen=\(chosen) aspect_delta_permille=\(delta) result=\(result) " +
             "reason=\(reason) \(extra)\n").utf8))
    }

    private func logRestored(result: Int, reason: String) {
        FileHandle.standardError.write(Data(
            "event=display_mode_restored result=\(result) reason=\(reason)\n".utf8))
    }
}

private enum StreamFallback: Error {
    case unavailable(String)
}

private final class ScreenshotRequest: @unchecked Sendable {
    let filter: SCContentFilter
    let width: Int
    let height: Int
    let targetFramesPerSecond: Int

    init(filter: SCContentFilter, width: Int, height: Int, targetFramesPerSecond: Int) {
        self.filter = filter
        self.width = width
        self.height = height
        self.targetFramesPerSecond = targetFramesPerSecond
    }
}

private final class CapturedFrame: @unchecked Sendable {
    let image: CGImage
    let requested: CaptureSizeRequest
    let startedAt: UInt64
    let capturedAt: UInt64

    init(image: CGImage, requested: CaptureSizeRequest, startedAt: UInt64, capturedAt: UInt64) {
        self.image = image
        self.requested = requested
        self.startedAt = startedAt
        self.capturedAt = capturedAt
    }
}

/// Serialises writes from the capture callback and the clipboard poll so the
/// IPC message stream can never interleave.
private final class AgentSocketWriter: @unchecked Sendable {
    private let socket: AgentUnixSocket
    private let lock = NSLock()

    init(socket: AgentUnixSocket) {
        self.socket = socket
    }

    func send(_ message: AgentIPCMessage) throws {
        lock.lock()
        defer { lock.unlock() }
        try socket.send(message)
    }

    func sendFrame(metadata: AgentFrameMetadata, pixels: Data) throws {
        lock.lock()
        defer { lock.unlock() }
        try socket.sendFrame(metadata: metadata, pixels: pixels)
    }

    func sendFrameDelta(metadata: AgentFrameMetadata, tiles: [AgentFrameTile]) throws {
        lock.lock()
        defer { lock.unlock() }
        try socket.sendFrameDelta(metadata: metadata, tiles: tiles)
    }

    func close() {
        lock.lock()
        defer { lock.unlock() }
        socket.close()
    }
}

/// Continuous-SCStream frame pump. All capture-side work happens on the single
/// ScreenCaptureKit sample-handler queue, so the delta encoder only ever sees
/// one frame at a time.
private final class StreamFramePump: NSObject, SCStreamOutput, SCStreamDelegate {
    struct Status {
        let frameCount: Int
        let framesSent: Int
        let dropped: Int
        let failure: String?
        let reconfigureStartedAt: UInt64?
        let width: Int
        let height: Int
    }

    private let writer: AgentSocketWriter
    private let geometry: CaptureGeometryState
    private let frameID: FrameIDCounter
    private let generation: UInt64
    private let targetFramesPerSecond: Int

    private let stateLock = NSLock()
    private var frameCount = 0
    private var framesSent = 0
    private var dropped = 0
    private var storedFailure: String?
    private var reconfigureStartedAt: UInt64?
    private var observedWidth = 0
    private var observedHeight = 0

    // Only touched on the SCStream sample-handler queue.
    private var deltaEncoder = AgentFrameDeltaEncoder()
    private var pixels = Data()
    private var timing = CaptureTiming(windowSize: 30)
    private var configuredWidth: Int
    private var configuredHeight: Int
    private var lastCallbackEnd: UInt64 = 0
    private weak var stream: SCStream?

    init(writer: AgentSocketWriter, geometry: CaptureGeometryState, frameID: FrameIDCounter,
         generation: UInt64, targetFramesPerSecond: Int,
         configuredWidth: Int, configuredHeight: Int) {
        self.writer = writer
        self.geometry = geometry
        self.frameID = frameID
        self.generation = generation
        self.targetFramesPerSecond = targetFramesPerSecond
        self.configuredWidth = configuredWidth
        self.configuredHeight = configuredHeight
    }

    func attach(stream: SCStream) {
        self.stream = stream
    }

    func snapshot() -> Status {
        stateLock.lock()
        defer { stateLock.unlock() }
        return Status(frameCount: frameCount, framesSent: framesSent, dropped: dropped,
                      failure: storedFailure, reconfigureStartedAt: reconfigureStartedAt,
                      width: observedWidth, height: observedHeight)
    }

    private func storeFailure(_ message: String) {
        stateLock.lock()
        if storedFailure == nil { storedFailure = message }
        stateLock.unlock()
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        storeFailure("delegate: \(error.localizedDescription)")
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
                of outputType: SCStreamOutputType) {
        guard outputType == .screen else { return }
        let callbackStart = DispatchTime.now().uptimeNanoseconds
        let wait = lastCallbackEnd == 0 ? 0 : callbackStart &- lastCallbackEnd
        defer { lastCallbackEnd = DispatchTime.now().uptimeNanoseconds }
        guard CMSampleBufferIsValid(sampleBuffer),
              let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else {
            recordDrop()
            return
        }
        let format = CVPixelBufferGetPixelFormatType(pixelBuffer)
        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        guard StreamCaptureHealth.isUsableFrame(pixelFormat: format, width: width, height: height,
                                                maxDimension: AgentFrameAssembler.maxFrameDimension) else {
            recordDrop()
            return
        }
        let requested = geometry.snapshot().capture
        stateLock.lock()
        let configured = (width: configuredWidth, height: configuredHeight)
        stateLock.unlock()
        let plan = StreamSizePlan(requestedWidth: requested.width, requestedHeight: requested.height,
                                  configuredWidth: configured.width,
                                  configuredHeight: configured.height)
        if plan.needsReconfigure {
            requestReconfigure(size: requested)
            recordDrop()
            return
        }
        guard plan.accepts(frameWidth: width, frameHeight: height) else {
            recordDrop()
            return
        }
        guard CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly) == kCVReturnSuccess,
              let base = CVPixelBufferGetBaseAddress(pixelBuffer) else {
            recordDrop()
            return
        }
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }
        let sourceBytesPerRow = CVPixelBufferGetBytesPerRow(pixelBuffer)
        let rowBytes = width * 4
        guard sourceBytesPerRow >= rowBytes else {
            recordDrop()
            return
        }
        let conversionStart = DispatchTime.now().uptimeNanoseconds
        let needed = rowBytes * height
        // Reuse the buffer across frames; the delta encoder hands the previous
        // frame buffer back through the inout overload.
        if pixels.count != needed { pixels = Data(count: needed) }
        pixels.withUnsafeMutableBytes { buffer in
            guard let destination = buffer.baseAddress else { return }
            if sourceBytesPerRow == rowBytes {
                memcpy(destination, base, needed)
            } else {
                for row in 0..<height {
                    memcpy(destination.advanced(by: row * rowBytes),
                           base.advanced(by: row * sourceBytesPerRow), rowBytes)
                }
            }
        }
        let converted = DispatchTime.now().uptimeNanoseconds
        let metadata = AgentFrameMetadata(generation: generation, frameID: frameID.next(),
                                          width: UInt32(width), height: UInt32(height),
                                          bytesPerPixel: 4)
        var sentAny = false
        do {
            let tiles = try deltaEncoder.encode(pixels: &pixels, width: width, height: height,
                                                generation: generation)
            if !tiles.isEmpty {
                try writer.sendFrameDelta(metadata: metadata, tiles: tiles)
                sentAny = true
            }
        } catch {
            storeFailure("send: \(error.localizedDescription)")
        }
        let sentAt = DispatchTime.now().uptimeNanoseconds
        stateLock.lock()
        frameCount += 1
        observedWidth = width
        observedHeight = height
        if sentAny { framesSent += 1 }
        stateLock.unlock()
        // Push capture: there is no per-frame capture call, so capture_ms is 0 and
        // the time between callbacks is reported as await_ms (wait for the next
        // pushed frame). conversion_ms is only the CVPixelBuffer row copy.
        if let means = timing.record(capture: 0,
                                     conversion: converted &- conversionStart,
                                     send: sentAt &- converted,
                                     wait: wait) {
            let line = String(
                format: "event=snapshot_timing samples=30 width=%d height=%d capture_ms=%.1f conversion_ms=%.1f ipc_ms=%.1f await_ms=%.1f source=stream requested_width=%d requested_height=%d image_width=%d image_height=%d target_fps=%d loop_ms=%.1f overlap=1 convert=row-copy\n",
                width, height,
                means.captureMilliseconds, means.conversionMilliseconds, means.sendMilliseconds,
                means.waitMilliseconds,
                requested.width, requested.height, width, height,
                targetFramesPerSecond,
                // Mean callback busy time (conversion + IPC); await_ms is the
                // separate wait between pushed frames.
                means.conversionMilliseconds + means.sendMilliseconds)
            FileHandle.standardError.write(Data(line.utf8))
        }
    }

    private func recordDrop() {
        stateLock.lock()
        dropped += 1
        stateLock.unlock()
    }

    private func completeReconfigure(size: CaptureSizeRequest) {
        stateLock.lock()
        configuredWidth = size.width
        configuredHeight = size.height
        reconfigureStartedAt = nil
        stateLock.unlock()
        fputs("event=capture_size_applied width=\(size.width) height=\(size.height)\n", stderr)
    }

    private func requestReconfigure(size: CaptureSizeRequest) {
        stateLock.lock()
        let alreadyInFlight = reconfigureStartedAt != nil
        if !alreadyInFlight { reconfigureStartedAt = DispatchTime.now().uptimeNanoseconds }
        stateLock.unlock()
        guard !alreadyInFlight, let stream else { return }
        let configuration = Agent.streamConfiguration(width: size.width, height: size.height,
                                                     targetFramesPerSecond: targetFramesPerSecond,
                                                     queueDepth: 3)
        Task { [weak self] in
            do {
                try await stream.updateConfiguration(configuration)
                self?.completeReconfigure(size: size)
            } catch {
                self?.storeFailure("updateConfiguration: \(error.localizedDescription)")
            }
        }
    }
}

/// Measures CVPixelBuffer-to-BGRA copy cost for capture-bench.
private final class BenchStreamCollector: NSObject, SCStreamOutput, SCStreamDelegate {
    private let stateLock = NSLock()
    private var frames = 0
    private var pixelFormat: UInt32 = 0
    private var copyStats = CaptureBenchmark()
    private var storedFailure: String?
    private var pixels = Data()

    struct Summary {
        let frames: Int
        let pixelFormat: UInt32
        let copyStats: CaptureBenchmark
        let failure: String?
    }

    func summary() -> Summary {
        stateLock.lock()
        defer { stateLock.unlock() }
        return Summary(frames: frames, pixelFormat: pixelFormat,
                       copyStats: copyStats, failure: storedFailure)
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        stateLock.lock()
        if storedFailure == nil { storedFailure = error.localizedDescription }
        stateLock.unlock()
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
                of outputType: SCStreamOutputType) {
        guard outputType == .screen, CMSampleBufferIsValid(sampleBuffer),
              let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        let format = CVPixelBufferGetPixelFormatType(pixelBuffer)
        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        guard StreamCaptureHealth.isUsableFrame(pixelFormat: format, width: width, height: height,
                                                maxDimension: AgentFrameAssembler.maxFrameDimension),
              CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly) == kCVReturnSuccess,
              let base = CVPixelBufferGetBaseAddress(pixelBuffer) else { return }
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }
        let sourceBytesPerRow = CVPixelBufferGetBytesPerRow(pixelBuffer)
        let rowBytes = width * 4
        guard sourceBytesPerRow >= rowBytes else { return }
        let needed = rowBytes * height
        if pixels.count != needed { pixels = Data(count: needed) }
        let start = DispatchTime.now().uptimeNanoseconds
        pixels.withUnsafeMutableBytes { buffer in
            guard let destination = buffer.baseAddress else { return }
            for row in 0..<height {
                memcpy(destination.advanced(by: row * rowBytes),
                       base.advanced(by: row * sourceBytesPerRow), rowBytes)
            }
        }
        let end = DispatchTime.now().uptimeNanoseconds
        stateLock.lock()
        frames += 1
        pixelFormat = format
        copyStats.record(nanoseconds: end &- start)
        stateLock.unlock()
    }
}

private final class SnapshotStopSignal {
    private let lock = NSLock()
    private var stopped = false
    private var sources: [DispatchSourceSignal] = []

    var requested: Bool {
        lock.lock()
        defer { lock.unlock() }
        return stopped
    }

    init() {
        let queue = DispatchQueue(label: "rdp-agent.snapshot-stop")
        for number in [SIGINT, SIGTERM] {
            signal(number, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: number, queue: queue)
            source.setEventHandler { [weak self] in
                guard let self else { return }
                self.lock.lock()
                self.stopped = true
                self.lock.unlock()
            }
            source.resume()
            sources.append(source)
        }
    }

    deinit {
        sources.forEach { $0.cancel() }
        signal(SIGINT, SIG_DFL)
        signal(SIGTERM, SIG_DFL)
    }
}

/// Diagnostic-only session event tap. With RDP_AGENT_EVENT_TAP=1 it logs every
/// keyboard event the WindowServer delivers to the session (key code +
/// modifier flags), which is the only way to see the modifier flags an app
/// actually receives from injected events (CGEventSource.flagsState does not
/// reflect nil-source modifier state). Field 2026-11-08: a plain `e` opened the
/// macOS "Emoji & Symbols" panel in Edge/VS Code, whose Edit menu binds that
/// panel to a Command/Control+E equivalent.
private func agentProbeLog(_ line: String) {
    FileHandle.standardError.write(Data((line + "\n").utf8))
}

private final class InputEventTapProbe: @unchecked Sendable {
    static let shared = InputEventTapProbe()
    private var tap: CFMachPort?
    private var runLoop: CFRunLoop?
    private var started = false

    func start() {
        guard ProcessInfo.processInfo.environment["RDP_AGENT_EVENT_TAP"] == "1" else { return }
        guard !started else { return }
        started = true
        let mask: CGEventMask = (1 << CGEventType.keyDown.rawValue)
            | (1 << CGEventType.keyUp.rawValue)
            | (1 << CGEventType.flagsChanged.rawValue)
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap, place: .headInsertEventTap, options: .listenOnly,
            eventsOfInterest: mask,
            callback: { _, type, event, _ in
                let ts = Int64(Date().timeIntervalSince1970 * 1000)
                let key = event.getIntegerValueField(.keyboardEventKeycode)
                agentProbeLog(String(format: "ts=%lld event=input_event_tap kind=%d code=0x%02x flags=0x%08x",
                                      ts, type.rawValue, Int(key), event.flags.rawValue))
                return Unmanaged.passUnretained(event)
            }, userInfo: nil) else {
            agentProbeLog("event=input_event_tap_failed reason=tap_create")
            return
        }
        self.tap = tap
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        let thread = Thread {
            let loop = CFRunLoopGetCurrent()
            self.runLoop = loop
            CFRunLoopAddSource(loop, source, .commonModes)
            CGEvent.tapEnable(tap: tap, enable: true)
            agentProbeLog("event=input_event_tap_started")
            CFRunLoopRun()
        }
        thread.name = "input-event-tap"
        thread.start()
    }
}

/// Effective input-injection display for logging: `Equatable` so the controller
/// emits `event=input_target` only when the target actually changes.
private struct InputTargetSignature: Equatable {
    let displayID: UInt32
    let source: InputDisplaySource
}

/// Thin platform adapter around the pure `KeyboardInputState` machine.
///
/// Mapping, press tracking, the stuck-modifier guard and trace formatting live
/// in MacAgentCore (unit tested); this class only posts CGEvents and writes log
/// lines. Mutable state is protected by `lock` because the socket receiver and
/// process teardown call in from different queues.
private final class AgentInputController: @unchecked Sendable {
    static func epochMilliseconds() -> Int64 {
        Int64(Date().timeIntervalSince1970 * 1000)
    }

    /// Key-ups for every Cmd/Option/Control key. Posted before a plain key-down
    /// when the client holds none of them, to clear a stale AppKit modifier state
    /// (nil-source modifiers are delivered as flagsChanged but are invisible in
    /// CGEventSource.flagsState, so the adapter cannot detect the staleness).
    static func guardedModifierResyncEffects() -> [KeyboardEffect] {
        [UInt16(0x37), 0x36, 0x3a, 0x3d, 0x3b, 0x3e].map { .key(virtualKey: $0, down: false) }
    }

    private let lock = NSLock()
    private var state: KeyboardInputState
    private var inputAudit = AgentInputAudit()
    private var pressedButtons = Set<Int>()
    /// Multi-click tracking so injected mouse events carry the right CGEvent
    /// clickState (1 single / 2 double / 3 triple). Without it every synthetic
    /// click is a single click, so remote double-click (title-bar zoom, opening
    /// files, word selection) never triggered (field report 2026-11-08).
    private var mouseClickState = MouseClickState()
    private var rejectedGate = RateLimitedLogGate()
    private var mouseDropGate = RateLimitedLogGate()
    /// Input-target diagnostics gates, protected by `lock` together with the
    /// last logged signature: a mirror transition must never flood the log.
    private var inputTargetGate = RateLimitedLogGate()
    private var inputTargetFallbackGate = RateLimitedLogGate()
    private var lastInputTargetSignature: InputTargetSignature?
    private let traceEnabled: Bool
    private let modifierFlagsProvider: () -> KeyboardModifierFlags

    init(environment: [String: String] = ProcessInfo.processInfo.environment,
         modifierFlagsProvider: @escaping () -> KeyboardModifierFlags =
            AgentInputController.platformModifierFlags) {
        state = KeyboardInputState(guardConfig: StuckModifierGuardConfig.resolve(
            environmentValue: environment["RDP_AGENT_STUCK_MODIFIER_GUARD"]))
        traceEnabled = InputTraceFeatureGate.isEnabled(
            environmentValue: environment["RDP_AGENT_INPUT_TRACE"])
        self.modifierFlagsProvider = modifierFlagsProvider
        let doubleClickMilliseconds = UInt64(max(0, NSEvent.doubleClickInterval * 1_000))
        mouseClickState = MouseClickState(
            config: .init(intervalMilliseconds: doubleClickMilliseconds))
        InputEventTapProbe.shared.start()
    }

    /// Current macOS modifier state for the opt-in trace. Diagnostics only:
    /// posting a nil-source modifier key event is delivered as a flagsChanged
    /// event but does not update this combined session state.
    static func platformModifierFlags() -> KeyboardModifierFlags {
        let flags = CGEventSource.flagsState(.combinedSessionState)
        return KeyboardModifierFlags(command: flags.contains(.maskCommand),
                                     option: flags.contains(.maskAlternate),
                                     control: flags.contains(.maskControl),
                                     shift: flags.contains(.maskShift),
                                     capsLock: flags.contains(.maskAlphaShift))
    }

    func apply(_ input: AgentInputEvent, displayID: CGDirectDisplayID,
               geometry: CaptureGeometry) {
        switch input.kind {
        case .mouse:
            applyMouse(input, displayID: displayID, geometry: geometry)
            recordInput(.mouse)
        case .scancode:
            applyScancode(input)
            recordInput(.scancode)
        case .unicode:
            applyUnicode(input)
            recordInput(.unicode)
        case .releaseAll:
            releaseAll(reason: "peer_release_all")
        }
    }

    /// Default audit behaviour (unchanged): one line per input kind per process,
    /// no key codes and no typed text. The per-event detail only appears with
    /// RDP_AGENT_INPUT_TRACE=1.
    private func recordInput(_ kind: AgentInputKind) {
        lock.lock()
        let shouldLog = inputAudit.shouldLog(kind)
        lock.unlock()
        guard shouldLog else { return }
        logLine("event=remote_input_received kind=\(AgentInputAudit.label(for: kind))")
    }

    private func applyScancode(_ input: AgentInputEvent) {
        let now = DispatchTime.now().uptimeNanoseconds / 1_000_000
        let systemFlags = modifierFlagsProvider()
        let extended = input.flags & MacKeyMap.flagExtended != 0
        let down = input.flags & MacKeyMap.flagRelease == 0
        let mappedKey = MacKeyMap.virtualKey(scancode: input.code, extended: extended)
        lock.lock()
        let guardedHeldBefore = state.isGuardedModifierHeld
        let result = state.handleScancode(scancode: input.code, flags: input.flags,
                                          nowMilliseconds: now)
        let guardedHeldAfter = state.isGuardedModifierHeld
        let pressedKeys = state.pressedKeyCount
        lock.unlock()
        // Field 2026-11-08 (21:47 / 21:57): while plain text was typed in VS Code,
        // the macOS Character Palette (the "Emoji & Symbols" panel) opened, which
        // only the Control+Command+Space menu shortcut does. The RDP trace showed
        // Space arriving with no modifiers held, so the stale modifiers live in
        // the injected-event state (nil-source modifier events are delivered to
        // apps as flagsChanged but are not visible in combinedSessionState).
        // Before every plain key-down, resynchronise by posting key-ups for the
        // Cmd/Option/Control keys the client is not actually holding; a key-up
        // for a key that is not down is harmless for normal typing but clears a
        // stale AppKit modifier state. Skip it when a guarded modifier is tracked
        // (real combos and the one-shot Win combo need their modifier intact).
        if down, let mappedKey, KeyboardModifierKey(rawValue: mappedKey) == nil,
           !guardedHeldBefore, !guardedHeldAfter {
            post(Self.guardedModifierResyncEffects())
        }
        post(result.effects)
        if traceEnabled {
            logLine("ts=\(Self.epochMilliseconds()) " + InputTraceFormatter.scancodeLine(
                flags: input.flags,
                identity: KeyboardScancodeIdentity(
                    scancode: input.code, extended: extended,
                    extended1: input.flags & MacKeyMap.flagExtended1 != 0),
                mappedVirtualKey: mappedKey,
                down: down,
                systemFlags: systemFlags, pressedKeys: pressedKeys)
                + String(format: " hw=cmd:%d,opt:%d,ctrl:%d,shift:%d",
                         CGEventSource.keyState(.combinedSessionState, key: 0x37) ? 1 : 0,
                         CGEventSource.keyState(.combinedSessionState, key: 0x3a) ? 1 : 0,
                         CGEventSource.keyState(.combinedSessionState, key: 0x3b) ? 1 : 0,
                         CGEventSource.keyState(.combinedSessionState, key: 0x38) ? 1 : 0))
        }
        if let firstUnsupported = result.firstUnsupported {
            // An unmappable key is ignored: never throw and never release the
            // other pressed keys for it. The old throw+releaseAll answer to a
            // single unknown key silently dropped held modifiers mid-typing.
            logLine(InputTraceFormatter.rejectedLine(reason: "unsupported_scancode",
                                                    identity: firstUnsupported,
                                                    systemFlags: systemFlags))
        }
        for stuck in result.stuckModifierReleases {
            // Functional safety event: logged even without the trace.
            logLine("ts=\(Self.epochMilliseconds()) " +
                    InputTraceFormatter.stuckModifierLine(stuck, systemFlags: systemFlags))
        }
        for released in result.winCommandReleases {
            // Field 2026-11-08: the Windows client kept the Win key down across
            // typing; every key became Cmd+<key>. Release it after the combo.
            logLine("ts=\(Self.epochMilliseconds()) " +
                    InputTraceFormatter.winCommandReleaseLine(released, systemFlags: systemFlags))
        }
    }

    private func applyUnicode(_ input: AgentInputEvent) {
        let systemFlags = modifierFlagsProvider()
        lock.lock()
        let result = state.handleUnicode(code: input.code, flags: input.flags)
        let pressedUnicode = state.pressedUnicodeCount
        lock.unlock()
        post(result.effects)
        if traceEnabled {
            // Never log input.code: unicode codes are typed text.
            logLine("ts=\(Self.epochMilliseconds()) " + InputTraceFormatter.unicodeLine(
                flags: input.flags, down: input.flags & MacKeyMap.flagRelease == 0,
                systemFlags: systemFlags, pressedUnicode: pressedUnicode))
        }
    }

    /// Release every tracked key/unicode press and mouse button, then post an
    /// unconditional key-up for each modifier (Cmd/Option/Control/Shift/Caps).
    ///
    /// The sweep also runs when the press table is empty: a nil-source modifier
    /// event is delivered to the focused app/IME as a flagsChanged event without
    /// updating WindowServer state, so the only way to clear a stale injected
    /// modifier is to post its key-up (a key-up for a key that is not down is a
    /// no-op for normal typing). Only real teardown paths (peer release-all,
    /// socket close, receiver failure, process termination) call this.
    func releaseAll(reason: String) {
        injectedModifiers.removeAll()
        let systemFlags = modifierFlagsProvider()
        lock.lock()
        let result = state.releaseAll()
        mouseClickState.reset()
        let buttons = pressedButtons
        pressedButtons.removeAll()
        lock.unlock()
        post(result.effects)
        for button in buttons {
            postMouseButton(button, down: false, point: .zero)
        }
        logLine(InputTraceFormatter.releaseAllLine(
            reason: reason, result: result,
            systemFlags: traceEnabled ? systemFlags : nil))
    }

    /// A malformed/undecodable input message: drop it, rate-limited, and keep the
    /// receiver (and the user's held keys) alive.
    func logRejected(_ error: Error) {
        let now = DispatchTime.now().uptimeNanoseconds / 1_000_000
        lock.lock()
        let allowed = rejectedGate.allow(nowMilliseconds: now)
        let suppressed = allowed ? rejectedGate.takeSuppressedCount() : 0
        lock.unlock()
        guard allowed else { return }
        logLine(InputTraceFormatter.droppedLine(reason: "invalid_payload", suppressed: suppressed) +
                " error=\(sanitize(error.localizedDescription))")
    }

    /// Rate-limited diagnostics for the display chosen for input injection.
    /// Called once per input event by the production receiver: a change of the
    /// effective target is logged (the first event always logs; a change during
    /// the gate interval is retried on later events until it is emitted) and a
    /// fallback while the virtual display still reports active is logged at most
    /// once per interval. Coordinates are never logged, so this cannot become
    /// per-event spam.
    func noteInputTarget(_ target: InputDisplayTarget, fallbackReason: String?,
                         geometry: CaptureGeometry) {
        let signature = InputTargetSignature(displayID: target.displayID,
                                             source: target.source)
        let now = DispatchTime.now().uptimeNanoseconds / 1_000_000
        var targetLog: (allowed: Bool, suppressed: Int)?
        var fallbackLog: (allowed: Bool, suppressed: Int)?
        lock.lock()
        if lastInputTargetSignature != signature {
            let allowed = inputTargetGate.allow(nowMilliseconds: now)
            if allowed {
                lastInputTargetSignature = signature
                targetLog = (true, inputTargetGate.takeSuppressedCount())
            } else {
                // Do not update the cached signature on suppression: the change
                // is retried by the next event so the field log always shows the
                // final effective target (a mirror transition happens within the
                // gate interval at session start).
                targetLog = (false, 0)
            }
        }
        if fallbackReason != nil {
            let allowed = inputTargetFallbackGate.allow(nowMilliseconds: now)
            fallbackLog = (allowed, allowed ? inputTargetFallbackGate.takeSuppressedCount() : 0)
        }
        lock.unlock()
        let fields = "display_id=\(target.displayID)" +
            " bounds=\(Int(target.bounds.width.rounded()))x\(Int(target.bounds.height.rounded()))" +
            " capture=\(geometry.captureValue) desktop=\(geometry.desktopValue)"
        if let targetLog, targetLog.allowed {
            logLine("event=input_target source=\(target.source.rawValue) \(fields)" +
                    Self.suppressedField(targetLog.suppressed))
        }
        if let fallbackLog, fallbackLog.allowed, let fallbackReason {
            logLine("event=input_target_fallback reason=\(fallbackReason) " +
                    "source=\(target.source.rawValue) \(fields)" +
                    Self.suppressedField(fallbackLog.suppressed))
        }
    }

    private static func suppressedField(_ count: Int) -> String {
        count > 0 ? " suppressed=\(count)" : ""
    }

    private func applyMouse(_ input: AgentInputEvent, displayID: CGDirectDisplayID,
                            geometry: CaptureGeometry) {
        let bounds = CGDisplayBounds(displayID)
        let display = DesktopDisplayRect(originX: Double(bounds.origin.x),
                                         originY: Double(bounds.origin.y),
                                         width: Double(bounds.width),
                                         height: Double(bounds.height))
        // Desktop coordinates arrive from the Worker; invert the same
        // fit-with-bars layout it uses, then map capture pixels to display
        // points (design section 5). Bar clicks clamp to the content edge.
        // The auto display-mode feature only changes the native pixel size; the
        // Worker keeps the letterbox composition, so this mapping is unchanged.
        guard let mapped = DisplayCoordinateMapper.desktopPoint(
            x: Int(input.x), y: Int(input.y),
            desktopWidth: geometry.desktop.width, desktopHeight: geometry.desktop.height,
            captureWidth: geometry.capture.width, captureHeight: geometry.capture.height,
            display: display
        ) else {
            // The captured display went inactive / zero-bounds under us (display
            // arrangement or virtual-display transition). Drop this event and
            // keep going: this must not release the user's pressed keys, and the
            // 2026-11-08 field log had thousands of these per session.
            logMouseDrop(reason: "invalid_coordinates",
                         boundsWidth: Int(bounds.width), boundsHeight: Int(bounds.height),
                         geometry: geometry, displayID: displayID)
            return
        }
        let point = CGPoint(x: CGFloat(mapped.x), y: CGFloat(mapped.y))
        if input.flags & 0x0800 != 0 {
            let moveType: CGEventType
            if pressedButtons.contains(0) { moveType = .leftMouseDragged }
            else if pressedButtons.contains(1) { moveType = .rightMouseDragged }
            else if pressedButtons.contains(2) { moveType = .otherMouseDragged }
            else { moveType = .mouseMoved }
            lock.lock()
            let dragButton = pressedButtons.first ?? 0
            let dragClickState = moveType == .mouseMoved
                ? 0 : mouseClickState.clickState(for: dragButton)
            lock.unlock()
            // Drag events keep the clickState of the current press so a
            // double-click-then-drag (word selection) works as well.
            postMouse(moveType, button: dragButton, point: point,
                      clickState: dragClickState)
        }
        let now = DispatchTime.now().uptimeNanoseconds / 1_000_000
        for (flag, button) in [(UInt16(0x1000), 0), (UInt16(0x2000), 1), (UInt16(0x4000), 2)] {
            guard input.flags & flag != 0 else { continue }
            let down = input.flags & 0x8000 != 0
            lock.lock()
            let clickState: Int
            if down {
                clickState = mouseClickState.buttonDown(button: button,
                                                        x: Double(mapped.x),
                                                        y: Double(mapped.y),
                                                        nowMilliseconds: now)
            } else {
                clickState = mouseClickState.clickState(for: button)
            }
            lock.unlock()
            postMouseButton(button, down: down, point: point, clickState: clickState)
            if down { pressedButtons.insert(button) } else { pressedButtons.remove(button) }
            if down && clickState > 1 && traceEnabled {
                logLine("ts=\(Self.epochMilliseconds()) event=input_multi_click button=\(button) count=\(clickState)")
            }
        }
        if let wheel1 = RDPWheel.macOSWheel1(flags: input.flags) {
            guard let event = CGEvent(scrollWheelEvent2Source: nil, units: .line,
                                      wheelCount: 1, wheel1: wheel1, wheel2: 0, wheel3: 0) else {
                logMouseDrop(reason: "event_creation_failed", boundsWidth: Int(bounds.width),
                             boundsHeight: Int(bounds.height), geometry: geometry,
                             displayID: displayID)
                return
            }
            event.post(tap: .cghidEventTap)
        }
    }

    /// Rate-limited drop log; only numeric sizes (display bounds, negotiated
    /// desktop, capture) so the next real session shows WHY the mapping failed.
    private func logMouseDrop(reason: String, boundsWidth: Int, boundsHeight: Int,
                              geometry: CaptureGeometry, displayID: CGDirectDisplayID) {
        let now = DispatchTime.now().uptimeNanoseconds / 1_000_000
        lock.lock()
        let allowed = mouseDropGate.allow(nowMilliseconds: now)
        let suppressed = allowed ? mouseDropGate.takeSuppressedCount() : 0
        // The effective input target that failed to map (diagnosis for the
        // virtual-vs-physical selection); "unknown" only on the diagnostic
        // stream path, which never resolves a target.
        let inputSource = lastInputTargetSignature?.source.rawValue ?? "unknown"
        lock.unlock()
        guard allowed else { return }
        logLine(InputTraceFormatter.droppedLine(reason: reason, suppressed: suppressed) +
                " display_bounds=\(boundsWidth)x\(boundsHeight)" +
                " desktop=\(geometry.desktop.width)x\(geometry.desktop.height)" +
                " capture=\(geometry.capture.width)x\(geometry.capture.height)" +
                " display_id=\(displayID)" +
                " input_source=\(inputSource)")
    }

    private func post(_ effects: [KeyboardEffect]) {
        for effect in effects {
            switch effect {
            case let .key(virtualKey, down):
                postKey(virtualKey, down: down)
            case let .unicode(code, down):
                postUnicode(code, down: down)
            }
        }
    }

    /// Modifier virtual keys currently held down by our own injection. Used to
    /// stamp explicit CGEventFlags on every posted key: with a nil event source
    /// the events inherit the source's flags, which can carry a stale
    /// maskSecondaryFn (Fn) bit after F-keys/arrow keys/Win combos; an `e` then
    /// arrived as Fn+E and macOS opened the "Emoji & Symbols" panel
    /// (CharacterPalette). Field 2026-11-08, event-tap evidence.
    private var injectedModifiers: Set<UInt16> = []

    private func postKey(_ key: UInt16, down: Bool) {
        let isModifier = KeyboardModifierKey(rawValue: key) != nil
        if isModifier {
            if down { injectedModifiers.insert(key) } else { injectedModifiers.remove(key) }
        }
        guard let event = CGEvent(keyboardEventSource: nil, virtualKey: CGKeyCode(key),
                                  keyDown: down) else { return }
        event.flags = Self.eventFlags(for: injectedModifiers)
        event.post(tap: .cghidEventTap)
    }

    static func eventFlags(for modifiers: Set<UInt16>) -> CGEventFlags {
        CGEventFlags(rawValue: KeyboardModifierFlags.from(pressedVirtualKeys: modifiers)
            .cgEventFlagsRawValue)
    }

    private func postUnicode(_ code: UInt16, down: Bool) {
        guard let event = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: down) else { return }
        var character = UniChar(code)
        withUnsafePointer(to: &character) { event.keyboardSetUnicodeString(stringLength: 1, unicodeString: $0) }
        event.flags = Self.eventFlags(for: injectedModifiers)
        event.post(tap: .cghidEventTap)
    }

    private func postMouseButton(_ button: Int, down: Bool, point: CGPoint, clickState: Int = 0) {
        let type: CGEventType
        switch (button, down) {
        case (0, true): type = .leftMouseDown
        case (0, false): type = .leftMouseUp
        case (1, true): type = .rightMouseDown
        case (1, false): type = .rightMouseUp
        case (_, true): type = .otherMouseDown
        default: type = .otherMouseUp
        }
        postMouse(type, button: button, point: point, clickState: clickState)
    }

    private func postMouse(_ type: CGEventType, button: Int, point: CGPoint, clickState: Int = 0) {
        let mouseButton: CGMouseButton = button == 0 ? .left : (button == 1 ? .right : .center)
        guard let event = CGEvent(mouseEventSource: nil, mouseType: type,
                                  mouseCursorPosition: point, mouseButton: mouseButton) else { return }
        // macOS derives NSEvent.clickCount from this field; default synthetic
        // events are single clicks, which is why remote double-click did nothing.
        if clickState > 0 {
            event.setIntegerValueField(.mouseEventClickState, value: Int64(clickState))
        }
        event.post(tap: .cghidEventTap)
    }

    private func logLine(_ line: String) {
        FileHandle.standardError.write(Data((line + "\n").utf8))
    }
}


/// Thin NSPasteboard adapter for the pure clipboard logic in MacAgentCore.
/// Reads file URL lists (modern `public.file-url` objects plus the legacy
/// `public.file-url` plist and `NSFilenamesPboardType` path array fallbacks);
/// writes either text or file URLs with clearContents + writeObjects.
private final class NSPasteboardClipboardBridge: ClipboardPasteboardBridge {
    private let pasteboard = NSPasteboard.general

    var changeCount: Int { pasteboard.changeCount }

    func readFileURLs() -> [URL]? {
        let objects = pasteboard.readObjects(forClasses: [NSURL.self],
                                             options: [.urlReadingFileURLsOnly: true])
        if let urls = ClipboardPasteboardFileURLs.fileURLs(from: objects) {
            return urls
        }
        // A single file copied by a legacy app: public.file-url holds one path
        // string in the property list (some apps store an array instead).
        if let plist = pasteboard.propertyList(forType: .fileURL) {
            let objects = (plist as? [Any]) ?? [plist]
            if let urls = ClipboardPasteboardFileURLs.fileURLs(from: objects) {
                return urls
            }
        }
        // Multiple files from a legacy app: NSFilenamesPboardType is an array
        // of absolute path strings (deprecated but still produced by some
        // clients; Finder uses the file-url objects above).
        let filenamesType = NSPasteboard.PasteboardType("NSFilenamesPboardType")
        if let paths = pasteboard.propertyList(forType: filenamesType) as? [String],
           let urls = ClipboardPasteboardFileURLs.fileURLs(from: paths) {
            return urls
        }
        return nil
    }

    func readText() -> String? { pasteboard.string(forType: .string) }

    func writeFileURLs(_ urls: [URL]) -> Bool {
        pasteboard.clearContents()
        return pasteboard.writeObjects(urls.map { $0 as NSURL })
    }

    func writeText(_ text: String) -> Bool {
        pasteboard.clearContents()
        return pasteboard.setString(text, forType: .string)
    }
}

/// Polls the local pasteboard for changes. File lists are preferred over text
/// (design §3); only a real change is reported, and pasteboard writes performed
/// by the Agent itself (remote clipboard applied) are folded into
/// `lastChangeCount` so they never echo back to the Worker.
private final class ClipboardMonitor: @unchecked Sendable {
    enum Update {
        case none
        /// Type 8 payload: direction 1 (local -> remote) followed by UTF-8.
        case text(Data)
        /// Direction 2 file offer sources.
        case files([URL])
        /// Type 8 empty payload: clear the remote text and file advertisement.
        case empty
    }

    private let lock = NSLock()
    private var lastChangeCount = -1
    private let pasteboard = NSPasteboardClipboardBridge()

    /// Returns the pending local clipboard change, if any, and marks it handled.
    func poll() -> Update {
        lock.lock()
        defer { lock.unlock() }
        let changeCount = pasteboard.changeCount
        guard changeCount != lastChangeCount else { return .none }
        lastChangeCount = changeCount
        let content = ClipboardLocalClipboardDetector.content(
            fileURLs: pasteboard.readFileURLs(), text: pasteboard.readText())
        switch content {
        case .files(let urls):
            return .files(urls)
        case .text(let text):
            let bytes = Data(text.utf8)
            guard bytes.count < AgentIPCCodec.maxPayloadSize else { return .none }
            return .text(Data([1]) + bytes)
        case .empty:
            return .empty
        }
    }

    /// Applies a remote (Windows -> macOS) text payload; wire format unchanged
    /// (`[2] + UTF-16LE`, design §3 text compatibility).
    func setRemoteUnicodePayload(_ payload: Data) throws {
        guard payload.first == 2, payload.count > 1,
              let text = String(data: payload.dropFirst(), encoding: .utf16LittleEndian) else {
            throw AgentError.invalidClipboardData
        }
        let normalized = text.trimmingCharacters(in: CharacterSet(charactersIn: "\0"))
        lock.lock()
        defer { lock.unlock() }
        _ = pasteboard.writeText(normalized)
        lastChangeCount = pasteboard.changeCount
    }

    /// Applies an assembled remote file offer so Finder paste works
    /// (clearContents + writeObjects, design §2.1 step 6).
    func setRemoteFileURLs(_ urls: [URL]) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        let applied = ClipboardRemotePasteboardWriter.applyFileURLs(urls, to: pasteboard)
        lastChangeCount = pasteboard.changeCount
        return applied
    }
}

/// Assembles a direction-1 (Windows -> macOS) file offer on its own serial
/// queue. The input receiver only enqueues the bounded IPC payloads, so writing
/// up to 4 GiB of files never blocks mouse/keyboard processing. Backpressure is
/// bounded (`maxPendingBytes`): if the Worker ever streams faster than the disk
/// for long enough, the offer is aborted and cleaned up instead of growing
/// memory without bound (the Worker fails the transfer when the session/offer
/// protocol notices the missing completion).
private final class ClipboardFileReceiver: @unchecked Sendable {
    private static let maxPendingBytes = 64 * 1024 * 1024

    static func handles(_ type: AgentMessageType) -> Bool {
        switch type {
        case .clipboardFileOfferBegin, .clipboardFileEntry, .clipboardFileChunk,
             .clipboardFileOfferEnd:
            return true
        default:
            return false
        }
    }

    private let queue = DispatchQueue(label: "rdp-agent.clipboard-files")
    private let lock = NSLock()
    private let clipboard: ClipboardMonitor
    private let assembler: ClipboardFileAssembler
    private var generation: UInt64 = 0
    private var pendingBytes = 0
    /// After a failed/aborted offer the rest of that offer's messages are
    /// dropped without logging until the next begin arrives.
    private var discarding = false

    init(clipboard: ClipboardMonitor,
         fileSystem: ClipboardFileAssemblyFileSystem = PosixClipboardFileAssemblyFileSystem()) {
        self.clipboard = clipboard
        self.assembler = ClipboardFileAssembler(fileSystem: fileSystem)
    }

    /// Non-blocking: called from the input receiver for every file message.
    func submit(_ message: AgentIPCMessage) {
        switch message.type {
        case .clipboardFileOfferBegin:
            // A new begin implicitly cancels anything this Agent still has
            // queued for the previous offer, so old chunks cannot corrupt it.
            lock.lock()
            generation &+= 1
            let generation = generation
            pendingBytes = 0
            discarding = false
            lock.unlock()
            queue.async { [weak self] in
                self?.process(message, generation: generation)
            }
        case .clipboardFileEntry, .clipboardFileChunk, .clipboardFileOfferEnd:
            lock.lock()
            if discarding {
                lock.unlock()
                return
            }
            pendingBytes += message.payload.count
            let overflow = pendingBytes > Self.maxPendingBytes
            if overflow {
                generation &+= 1
                pendingBytes = 0
                discarding = true
            }
            let generation = generation
            lock.unlock()
            if overflow {
                log("event=clipboard_file_rejected direction=remote_to_local " +
                    "reason=ipc_backpressure")
                queue.async { [weak self] in
                    guard let self else { return }
                    self.handleEvents(self.assembler.abort(reason: .backpressure))
                }
            } else {
                queue.async { [weak self] in
                    self?.process(message, generation: generation)
                }
            }
        default:
            return
        }
    }

    private func process(_ message: AgentIPCMessage, generation: UInt64) {
        lock.lock()
        let skip = discarding || generation != self.generation
        lock.unlock()
        guard !skip else { return }
        let events = assembler.handle(message)
        lock.lock()
        pendingBytes = max(0, pendingBytes - message.payload.count)
        lock.unlock()
        handleEvents(events)
    }

    /// After a terminal event the rest of this offer's already-queued messages
    /// are dropped silently until the next begin (avoids one rejected log line
    /// per remaining chunk after a local failure).
    private func markDiscarding() {
        lock.lock()
        discarding = true
        pendingBytes = 0
        lock.unlock()
    }

    private func handleEvents(_ events: [ClipboardFileAssemblyEvent]) {
        for event in events {
            switch event {
            case let .offerStarted(fileCount, totalBytes):
                log("event=clipboard_file_offer direction=remote_to_local " +
                    "count=\(fileCount) bytes=\(totalBytes)")
            case let .fileFinished(index, size, _):
                log("event=clipboard_file_entry direction=remote_to_local " +
                    "index=\(index) size=\(size)")
            case let .offerCompleted(urls, totalBytes):
                log("event=clipboard_file_complete direction=remote_to_local " +
                    "files=\(urls.count) bytes=\(totalBytes) result=0")
                if !clipboard.setRemoteFileURLs(urls) {
                    log("event=clipboard_file_rejected direction=remote_to_local " +
                        "reason=pasteboard_failed")
                }
                markDiscarding()
            case .offerCancelled:
                log("event=clipboard_file_complete direction=remote_to_local " +
                    "files=0 bytes=0 result=1")
                markDiscarding()
            case let .offerFailed(reason):
                log("event=clipboard_file_rejected direction=remote_to_local " +
                    "reason=\(reason.logReason)")
                markDiscarding()
            }
        }
    }

    private func log(_ line: String) {
        FileHandle.standardError.write(Data((line + "\n").utf8))
    }
}

private final class FrameIDCounter {
    private let lock = NSLock()
    private var value: UInt64 = 0

    func next() -> UInt64 {
        lock.lock()
        defer { lock.unlock() }
        value &+= 1
        return value
    }
}

private final class CaptureFrameObserver: NSObject, SCStreamOutput, SCStreamDelegate {
    struct Diagnostics {
        var sampled = 0
        var noImageBuffer = 0
        var rejectedPixelFormat = 0
        var rejectedSize = 0
        var formats = "none"
    }

    private let lock = NSLock()
    private var progress = CaptureProgress()
    private let onFrame: ((Int, Int, Data) throws -> Void)?
    private var storedFailure: String?
    private var diagnosticsStorage = Diagnostics()

    init(onFrame: ((Int, Int, Data) throws -> Void)? = nil) {
        self.onFrame = onFrame
    }

    var failure: String? {
        lock.lock()
        defer { lock.unlock() }
        return storedFailure
    }

    var diagnostics: Diagnostics {
        lock.lock()
        defer { lock.unlock() }
        return diagnosticsStorage
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        lock.lock()
        if storedFailure == nil { storedFailure = error.localizedDescription }
        lock.unlock()
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
                of outputType: SCStreamOutputType) {
        guard outputType == .screen else { return }
        lock.lock()
        diagnosticsStorage.sampled += 1
        lock.unlock()
        guard CMSampleBufferIsValid(sampleBuffer),
              let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else {
            lock.lock()
            diagnosticsStorage.noImageBuffer += 1
            lock.unlock()
            return
        }
        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        let format = CVPixelBufferGetPixelFormatType(pixelBuffer)
        guard StreamCaptureHealth.isUsableFrame(pixelFormat: format, width: width, height: height,
                                                maxDimension: AgentFrameAssembler.maxFrameDimension) else {
            lock.lock()
            if StreamPixelFormat.isBGRA(format) {
                diagnosticsStorage.rejectedSize += 1
            } else {
                diagnosticsStorage.rejectedPixelFormat += 1
                diagnosticsStorage.formats = String(format: "0x%08x", format)
            }
            lock.unlock()
            return
        }
        guard CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly) == kCVReturnSuccess,
              let base = CVPixelBufferGetBaseAddress(pixelBuffer) else { return }
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }
        let bytesPerRow = CVPixelBufferGetBytesPerRow(pixelBuffer)
        let packedRowBytes = width * 4
        guard bytesPerRow >= packedRowBytes else { return }
        var pixels = Data(count: packedRowBytes * height)
        pixels.withUnsafeMutableBytes { destination in
            guard let target = destination.baseAddress else { return }
            for row in 0..<height {
                memcpy(target.advanced(by: row * packedRowBytes),
                       base.advanced(by: row * bytesPerRow), packedRowBytes)
            }
        }
        do {
            try onFrame?(width, height, pixels)
        } catch {
            lock.lock()
            if storedFailure == nil { storedFailure = error.localizedDescription }
            lock.unlock()
        }
        lock.lock()
        _ = progress.record(width: width, height: height)
        lock.unlock()
    }

    func snapshot() -> CaptureProgress {
        lock.lock()
        defer { lock.unlock() }
        return progress
    }
}

private enum AgentError: LocalizedError {
    case usage, screenRecordingPermission, accessibilityPermission, displayIndex
    case inputEvent, noContent, noImage, noFrames, socketClosed, pngDestination, pngWrite
    case streamFailed(String)
    case unsupportedScancode(UInt16), invalidInputCoordinates
    case invalidClipboardData

    var errorDescription: String? {
        switch self {
        case .usage: return "usage: rdp-agent status | displays | capture <display-index> <output.png> | capture-stream <display-index> <seconds 1..30> | capture-bench [display-index] [iterations] [stream-seconds] | stream <socket-path> <display-index> <seconds 0..30; 0=until SIGINT/SIGTERM> <generation> | stream-snapshot <socket-path> <display-index> <seconds 1..30> <generation> | move <x> <y>"
        case .screenRecordingPermission: return "Screen Recording permission is missing; grant it to rdp-agent in System Settings > Privacy & Security > Screen & System Audio Recording."
        case .accessibilityPermission: return "Accessibility permission is missing; grant it to rdp-agent in System Settings > Privacy & Security > Accessibility."
        case .displayIndex: return "display index is not available"
        case .inputEvent: return "could not create mouse event"
        case .noContent: return "ScreenCaptureKit returned no shareable content"
        case .noImage: return "ScreenCaptureKit returned no image"
        case .noFrames: return "ScreenCaptureKit stream produced no display frames"
        case .socketClosed: return "Agent IPC socket is no longer available"
        case let .streamFailed(message): return "Agent IPC frame stream failed: \(message)"
        case let .unsupportedScancode(code): return "unsupported RDP scancode 0x\(String(code, radix: 16))"
        case .invalidInputCoordinates: return "invalid remote mouse coordinates"
        case .invalidClipboardData: return "invalid clipboard payload"
        case .pngDestination: return "could not create PNG output"
        case .pngWrite: return "could not write PNG output"
        }
    }
}
