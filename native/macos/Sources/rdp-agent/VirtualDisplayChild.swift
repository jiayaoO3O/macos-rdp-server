import Foundation
import CoreGraphics
import Darwin
import ObjectiveC
import MacAgentCore

/// Child-process implementation of the custom 16:9 virtual display.
///
/// The Agent spawns itself with
///
///     virtual-display --width W --height H --restore-physical PWxPH
///
/// This process owns one private `CGVirtualDisplay` (CoreGraphics' private ObjC
/// classes, as used by open-source DeskPad-style tools), mirrors the physical
/// display onto it with the public CG display-configuration API, prints exactly
/// one handshake line
///
///     display_id=15 width=2560 height=1440
///
/// and then blocks until its stdin reaches EOF (the parent's teardown) or it
/// receives SIGTERM/SIGINT/SIGHUP.
///
/// Field bug (2026-11-08): after a 1920x1080 session the physical panel was left
/// at 1920x1080, so a later 2560x1440 session mirrored from a scaled panel mode,
/// the virtual display bounds never matched the requested size and the child
/// timed out. Fixes:
/// 1. `--restore-physical` forces the Agent's startup physical mode BEFORE
///    creating/mirroring, so every session starts from the same arrangement.
/// 2. The physical display's `CGDisplayMode` is snapshotted before mirroring and
///    explicitly restored after unmirroring (`CGDisplaySetDisplayMode`), with
///    saved/restored sizes logged.
/// 3. Failure paths restore that mode too, so a failed spawn cannot leave the
///    panel in a non-native mode.
///
/// Validation on macOS 27.2: while mirrored, the cached ScreenCaptureKit filter
/// of the Agent's physical display returns the virtual display's shared
/// framebuffer (no letterbox) and CGDisplayCopyDisplayMode(physical) reports the
/// virtual mode, so the parent does not need to rebind its capture.
enum VirtualDisplayChild {
    struct Arguments {
        let size: VirtualDisplaySize
        /// The physical display to mirror (the one the Agent captures). Explicit
        /// so a lid-close/unplug cannot make us mirror a leftover virtual display
        /// that became CGMainDisplayID.
        let physicalDisplayID: CGDirectDisplayID?
        /// The Agent's startup physical pixel size, forced before mirroring.
        let restorePhysical: VirtualDisplaySize?
    }

    static func run(arguments: [String]) throws {
        let parsed = try parse(arguments)
        let physical = parsed.physicalDisplayID ?? CGMainDisplayID()
        // The physical display must still be online: with the MacBook lid closed
        // (no external display) WindowServer can drop the built-in display and
        // CGMainDisplayID() becomes a leftover virtual display; mirroring that
        // cascaded into scaled virtual displays (2026-11-08).
        guard CGDisplayIsActive(physical) != 0,
              let physicalMode = CGDisplayCopyDisplayMode(physical) else {
            throw VirtualDisplayChildError.physicalDisplayOffline(physical)
        }
        _ = physicalMode
        // Never chain virtual displays: if the Agent lost the real display (lid
        // closed with no external monitor) CGMainDisplayID()/the passed id can be
        // a leftover virtual display; mirroring it cascaded into the 2026-11-08
        // scaled-panel bug.
        let builtin = CGDisplayIsBuiltin(physical) != 0
        let active = CGDisplayIsActive(physical) != 0
        guard (builtin && active) || (active && !DisplayModeHelper.isVirtualDisplay(physical)) else {
            throw VirtualDisplayChildError.physicalDisplayIsVirtual(physical)
        }
        FileHandle.standardError.write(Data(
            ("event=virtual_display_child_target display_id=\(physical) builtin=\(builtin ? 1 : 0) " +
             "active=\(active ? 1 : 0) " +
             "vendor=0x\(String(CGDisplayVendorNumber(physical), radix: 16)) " +
             "model=0x\(String(CGDisplayModelNumber(physical), radix: 16))\n").utf8))
        // v1: only support the single-display development setup. An existing
        // mirror chain means the user already has a custom arrangement; never
        // disturb it, keep the historical physical capture instead.
        if CGDisplayMirrorsDisplay(physical) != 0 {
            throw VirtualDisplayChildError.existingMirror
        }
        FileHandle.standardError.write(Data(
            "event=virtual_display_child_display_state_before \(DisplayStateSummary.current())\n".utf8))

        let setup = try VirtualDisplaySetup(size: parsed.size,
                                            physicalDisplayID: physical,
                                            restorePhysical: parsed.restorePhysical)
        do {
            try setup.start()
        } catch {
            // Never leave the panel mirrored or in the forced mode after a
            // failed setup: unmirror + restore the snapshot explicitly.
            let restored = setup.restore(reason: "setup_failed")
            FileHandle.standardError.write(Data(
                ("event=virtual_display_child_restore result=\(restored ? 0 : 1) " +
                 "display_id=\(setup.virtualDisplayID) reason=setup_failed\n").utf8))
            throw error
        }
        let readyLine = "display_id=\(setup.virtualDisplayID) width=\(parsed.size.width) height=\(parsed.size.height)"
        FileHandle.standardError.write(Data(
            ("event=virtual_display_child_ready \(readyLine) " +
             "physical=\(physical) \(DisplayStateSummary.current())\n").utf8))
        FileHandle.standardOutput.write(Data((readyLine + "\n").utf8))

        waitForRestoreRequest()

        let restoreStarted = DispatchTime.now().uptimeNanoseconds
        let result = setup.restore(reason: "teardown")
        let elapsedMilliseconds = (DispatchTime.now().uptimeNanoseconds &- restoreStarted) / 1_000_000
        FileHandle.standardError.write(Data(
            ("event=virtual_display_child_restore result=\(result ? 0 : 1) " +
             "display_id=\(setup.virtualDisplayID) ms=\(elapsedMilliseconds) reason=teardown\n").utf8))
        FileHandle.standardError.write(Data(
            "event=virtual_display_child_display_state_after \(DisplayStateSummary.current())\n".utf8))
    }

    private static func parse(_ arguments: [String]) throws -> Arguments {
        var width: Int?
        var height: Int?
        var physicalDisplayID: CGDirectDisplayID?
        var restorePhysical: VirtualDisplaySize?
        var index = 0
        while index < arguments.count {
            switch arguments[index] {
            case "--width":
                index += 1
                guard index < arguments.count, let value = Int(arguments[index]) else {
                    throw VirtualDisplayChildError.usage
                }
                width = value
            case "--height":
                index += 1
                guard index < arguments.count, let value = Int(arguments[index]) else {
                    throw VirtualDisplayChildError.usage
                }
                height = value
            case "--physical-display":
                index += 1
                guard index < arguments.count, let value = UInt32(arguments[index]),
                      value > 0 else {
                    throw VirtualDisplayChildError.usage
                }
                physicalDisplayID = CGDirectDisplayID(value)
            case "--restore-physical":
                index += 1
                guard index < arguments.count, let value = VirtualDisplaySetup.parseSize(arguments[index]) else {
                    throw VirtualDisplayChildError.usage
                }
                restorePhysical = value
            default:
                throw VirtualDisplayChildError.usage
            }
            index += 1
        }
        guard let width, let height, let size = VirtualDisplaySize(width: width, height: height) else {
            throw VirtualDisplayChildError.usage
        }
        return Arguments(size: size, physicalDisplayID: physicalDisplayID,
                         restorePhysical: restorePhysical)
    }

    /// Blocks until stdin reaches EOF (parent teardown) or a termination signal
    /// arrives. The signal sources and the stdin reader run on their own queues;
    /// this thread only polls a locked flag, so no CoreGraphics work happens in a
    /// signal handler.
    /// The private CGVirtualDisplay machinery dispatches display registration /
    /// mode application blocks onto the main queue (the descriptor's dispatch
    /// queue). A CLI child must pump the main run loop for those to run; polling
    /// with Thread.sleep alone leaves the display at WindowServer's default mode.
    fileprivate static func pumpMainRunLoop(seconds: TimeInterval) {
        let deadline = CFAbsoluteTimeGetCurrent() + seconds
        while CFAbsoluteTimeGetCurrent() < deadline {
            CFRunLoopRunInMode(CFRunLoopMode.defaultMode, 0.02, true)
        }
    }

    private static func waitForRestoreRequest() {
        signal(SIGTERM, SIG_IGN)
        signal(SIGINT, SIG_IGN)
        signal(SIGHUP, SIG_IGN)
        let stop = Flag()
        let signalQueue = DispatchQueue(label: "rdp-agent.virtual-display.signals")
        var sources: [DispatchSourceSignal] = []
        for sig in [SIGTERM, SIGINT, SIGHUP] {
            let source = DispatchSource.makeSignalSource(signal: sig, queue: signalQueue)
            source.setEventHandler { stop.set() }
            source.resume()
            sources.append(source)
        }
        DispatchQueue.global().async {
            var buffer = [UInt8](repeating: 0, count: 256)
            while true {
                let count = read(STDIN_FILENO, &buffer, buffer.count)
                if count <= 0 { break }
            }
            stop.set()
        }
        while !stop.isSet {
            Thread.sleep(forTimeInterval: 0.05)
        }
        withExtendedLifetime(sources) {}
    }
}

enum VirtualDisplayChildError: LocalizedError {
    case usage
    case classesMissing
    case createFailed
    case applyFailed
    case registerFailed
    case mirrorFailed(String)
    case existingMirror
    case physicalDisplayOffline(CGDirectDisplayID)
    case physicalDisplayIsVirtual(CGDirectDisplayID)
    case restorePhysicalFailed(String)

    var errorDescription: String? {
        switch self {
        case .usage:
            return "usage: rdp-agent virtual-display --width W --height H " +
                "[--restore-physical WxH] [--physical-display ID]"
        case .classesMissing: return "CGVirtualDisplay private classes unavailable"
        case .createFailed: return "CGVirtualDisplay creation failed"
        case .applyFailed: return "CGVirtualDisplay applySettings failed"
        case .registerFailed: return "virtual display did not register"
        case .mirrorFailed(let stage): return "display mirror failed at \(stage)"
        case .existingMirror: return "physical display is already mirrored"
        case .physicalDisplayOffline(let displayID):
            return "physical display \(displayID) is not online"
        case .physicalDisplayIsVirtual(let displayID):
            return "display \(displayID) is a virtual display, refusing to chain"
        case .restorePhysicalFailed(let detail): return "physical mode restore failed (\(detail))"
        }
    }
}

/// Owns one CGVirtualDisplay and the physical->virtual mirror for the child's
/// lifetime, including the physical display mode snapshot/restore.
private final class VirtualDisplaySetup {
    let size: VirtualDisplaySize
    let physicalDisplayID: CGDirectDisplayID
    private let display: AnyObject
    private(set) var virtualDisplayID: UInt32 = 0
    private var mirrored = false
    /// Mode snapshot taken right before mirroring; restored on teardown/failure.
    private var savedPhysicalMode: CGDisplayMode?
    private var savedPhysicalPixels: DisplayPixelSize?

    init(size: VirtualDisplaySize, physicalDisplayID: CGDirectDisplayID,
         restorePhysical: VirtualDisplaySize?) throws {
        self.size = size
        self.physicalDisplayID = physicalDisplayID
        // 1. Force the Agent's startup physical mode before mirroring. A previous
        //    session may have left the panel in a scaled mode; mirroring from it
        //    makes WindowServer scale the virtual display and the size check fail
        //    (field reconnect bug, 2026-11-08).
        if let restorePhysical {
            let target = DisplayPixelSize(width: restorePhysical.width,
                                          height: restorePhysical.height)
            let restored = DisplayModeHelper.setMode(displayID: physicalDisplayID,
                                                     pixels: target, timeout: 2.0)
            FileHandle.standardError.write(Data(
                ("event=virtual_display_child_mode_restored result=\(restored.result ? 0 : 1) " +
                 "saved=\(target.value) current=\(restored.current?.value ?? "unknown") " +
                 "reason=pre_session\n").utf8))
            guard restored.result else {
                throw VirtualDisplayChildError.restorePhysicalFailed(
                    "pre_session saved=\(target.value) current=\(restored.current?.value ?? "unknown")")
            }
        }
        // 2. Snapshot the (now correct) mode so teardown can restore it exactly.
        savedPhysicalMode = CGDisplayCopyDisplayMode(physicalDisplayID)
        savedPhysicalPixels = DisplayModeHelper.pixels(of: savedPhysicalMode)
        FileHandle.standardError.write(Data(
            ("event=virtual_display_child_mode_saved " +
             "saved=\(savedPhysicalPixels?.value ?? "unknown") " +
             "current=\(DisplayModeHelper.currentPixels(displayID: physicalDisplayID)?.value ?? "unknown")\n").utf8))

        // 3. Create the virtual display.
        guard let descriptorClass = NSClassFromString("CGVirtualDisplayDescriptor"),
              let displayClass = NSClassFromString("CGVirtualDisplay"),
              let settingsClass = NSClassFromString("CGVirtualDisplaySettings"),
              let modeClass = NSClassFromString("CGVirtualDisplayMode") else {
            throw VirtualDisplayChildError.classesMissing
        }
        guard let allocatedDescriptor = ObjCRuntime.alloc(descriptorClass),
              let descriptor = ObjCRuntime.initObject(allocatedDescriptor) else {
            throw VirtualDisplayChildError.createFailed
        }
        _ = ObjCRuntime.sendVoidId(descriptor, "setName:", "RDP 16:9" as NSString)
        ObjCRuntime.sendVoidSize(descriptor, "setSizeInMillimeters:", CGSize(width: 600, height: 340))
        ObjCRuntime.sendVoidUInt32(descriptor, "setMaxPixelsWide:", UInt32(size.width))
        ObjCRuntime.sendVoidUInt32(descriptor, "setMaxPixelsHigh:", UInt32(size.height))
        ObjCRuntime.sendVoidUInt32(descriptor, "setVendorID:", 0x1234)
        // WindowServer persists per-display settings (notably the last mode)
        // keyed by the virtual display identity. The historical fixed identity was
        // poisoned by a 1920x1080 session, so every later 2560x1440 session came
        // up at 1920x1080 and failed the size check (field reconnect bug). A fresh
        // product+serial per session keeps the requested mode.
        let sessionProduct = UInt32.random(in: 0x1000...0xFFFF)
        let sessionSerial = UInt32.random(in: 1_000...UInt32.max)
        _ = ObjCRuntime.sendVoidUInt32(descriptor, "setProductID:", sessionProduct)
        _ = ObjCRuntime.sendVoidUInt32(descriptor, "setSerialNum:", sessionSerial)
        _ = ObjCRuntime.sendVoidUInt32(descriptor, "setSerialNumber:", sessionSerial)
        FileHandle.standardError.write(Data(
            ("event=virtual_display_child_identity product=0x" +
             String(sessionProduct, radix: 16) + " serial=" + String(sessionSerial) + "\n").utf8))
        ObjCRuntime.sendVoidId(descriptor, "setDispatchQueue:", DispatchQueue.main)
        guard let display = ObjCRuntime.initWithDescriptor(displayClass, descriptor) else {
            throw VirtualDisplayChildError.createFailed
        }
        self.display = display
        guard let mode = ObjCRuntime.initWithWidthHeightRefreshRate(modeClass,
                                                                   width: Int32(size.width),
                                                                   height: Int32(size.height),
                                                                   refreshRate: 60) else {
            throw VirtualDisplayChildError.createFailed
        }
        guard let allocatedSettings = ObjCRuntime.alloc(settingsClass),
              let settings = ObjCRuntime.initObject(allocatedSettings),
              ObjCRuntime.sendBoolUInt32(settings, "setHiDPI:", 0) else {
            throw VirtualDisplayChildError.createFailed
        }
        _ = ObjCRuntime.sendVoidId(settings, "setModes:", [mode] as NSArray)
        guard ObjCRuntime.sendBoolId(display, "applySettings:", settings) else {
            throw VirtualDisplayChildError.applyFailed
        }
    }

    /// Wait for the display to register, mirror the physical display onto it and
    /// wait until the mirror set reports the requested size.
    func start() throws {
        for _ in 0..<200 {
            if let identifier = ObjCRuntime.displayID(display), identifier > 0 {
                virtualDisplayID = identifier
                break
            }
            VirtualDisplayChild.pumpMainRunLoop(seconds: 0.05)
        }
        guard virtualDisplayID > 0 else { throw VirtualDisplayChildError.registerFailed }

        // WindowServer may bring a new virtual display up in a previously used
        // mode (field: 1920x1080 from an earlier session), ignoring the modes
        // passed at creation. Force the requested pixel size explicitly before
        // mirroring; the virtual display exposes a matching mode in its list.
        let requestedPixels = DisplayPixelSize(width: size.width, height: size.height)

        var virtualModeApplied = false
        for _ in 0..<60 {
            if let mode = DisplayModeHelper.find(displayID: virtualDisplayID,
                                                 pixels: requestedPixels) {
                _ = CGDisplaySetDisplayMode(virtualDisplayID, mode, nil)
            }
            let bounds = CGDisplayBounds(virtualDisplayID)
            if Int(bounds.width) == size.width, Int(bounds.height) == size.height {
                virtualModeApplied = true
                break
            }
            VirtualDisplayChild.pumpMainRunLoop(seconds: 0.05)
        }
        FileHandle.standardError.write(Data(
            ("event=virtual_display_child_virtual_mode result=\(virtualModeApplied ? 0 : 1) " +
             "requested=\(size.value) bounds=\(Int(CGDisplayBounds(virtualDisplayID).width))x" +
             "\(Int(CGDisplayBounds(virtualDisplayID).height)) virtual_id=\(virtualDisplayID)\n").utf8))
        guard virtualModeApplied else {
            throw VirtualDisplayChildError.mirrorFailed("virtual_mode")
        }

        var configuration: CGDisplayConfigRef?
        guard CGBeginDisplayConfiguration(&configuration) == .success,
              let configuration else {
            throw VirtualDisplayChildError.mirrorFailed("begin")
        }
        let configureError = CGConfigureDisplayMirrorOfDisplay(configuration,
                                                               physicalDisplayID,
                                                               virtualDisplayID)
        let completeError = CGCompleteDisplayConfiguration(configuration, .forSession)
        FileHandle.standardError.write(Data(
            ("event=virtual_display_child_mirror result=\(configureError == .success && completeError == .success ? 0 : 1) " +
             "physical=\(physicalDisplayID) virtual=\(virtualDisplayID) " +
             "configure=\(configureError.rawValue) complete=\(completeError.rawValue)\n").utf8))
        guard configureError == .success, completeError == .success else {
            throw VirtualDisplayChildError.mirrorFailed(
                "configure=\(configureError.rawValue) complete=\(completeError.rawValue)")
        }
        mirrored = true

        for _ in 0..<200 {
            let bounds = CGDisplayBounds(virtualDisplayID)
            let mirrors = CGDisplayMirrorsDisplay(physicalDisplayID)
            if Int(bounds.width) == size.width, Int(bounds.height) == size.height,
               mirrors == virtualDisplayID {
                return
            }
            VirtualDisplayChild.pumpMainRunLoop(seconds: 0.05)
        }
        // Detailed diagnostics: the parent now captures this stderr.
        let bounds = CGDisplayBounds(virtualDisplayID)
        FileHandle.standardError.write(Data(
            ("event=virtual_display_child_size_check result=1 " +
             "expected=\(size.value) bounds=\(Int(bounds.width))x\(Int(bounds.height)) " +
             "physical_mirrors=\(CGDisplayMirrorsDisplay(physicalDisplayID)) " +
             "virtual_id=\(virtualDisplayID) physical=\(physicalDisplayID)\n").utf8))
        throw VirtualDisplayChildError.mirrorFailed("size_check")
    }

    /// Break the mirror, restore the snapshotted physical mode and verify it.
    /// Called on teardown and on every setup-failure path.
    @discardableResult
    func restore(reason: String) -> Bool {
        var success = true
        if mirrored {
            mirrored = false
            var configuration: CGDisplayConfigRef?
            guard CGBeginDisplayConfiguration(&configuration) == .success,
                  let configuration else {
                return false
            }
            _ = CGConfigureDisplayMirrorOfDisplay(configuration, physicalDisplayID, kCGNullDirectDisplay)
            if virtualDisplayID != 0 {
                _ = CGConfigureDisplayMirrorOfDisplay(configuration, virtualDisplayID, kCGNullDirectDisplay)
            }
            let completeError = CGCompleteDisplayConfiguration(configuration, .forSession)
            success = completeError == .success
            // Wait for the unmirror to take effect before forcing the mode.
            for _ in 0..<40 {
                if CGDisplayMirrorsDisplay(physicalDisplayID) == 0 { break }
                VirtualDisplayChild.pumpMainRunLoop(seconds: 0.05)
            }
            FileHandle.standardError.write(Data(
                ("event=virtual_display_child_unmirror result=\(success ? 0 : 1) " +
                 "physical=\(physicalDisplayID) virtual=\(virtualDisplayID)\n").utf8))
        }
        if let savedPhysicalMode {
            let savedPixels = savedPhysicalPixels
                ?? DisplayModeHelper.pixels(of: savedPhysicalMode)
            let result = CGDisplaySetDisplayMode(physicalDisplayID, savedPhysicalMode, nil)
            var current = DisplayModeHelper.currentPixels(displayID: physicalDisplayID)
            for _ in 0..<40 {
                if current == savedPixels { break }
                VirtualDisplayChild.pumpMainRunLoop(seconds: 0.05)
                current = DisplayModeHelper.currentPixels(displayID: physicalDisplayID)
            }
            let verified = result == .success && current == savedPixels
            if !verified { success = false }
            FileHandle.standardError.write(Data(
                ("event=virtual_display_child_mode_restored result=\(verified ? 0 : 1) " +
                 "saved=\(savedPixels?.value ?? "unknown") " +
                 "current=\(current?.value ?? "unknown") reason=\(reason)\n").utf8))
        }
        return success
    }

    static func parseSize(_ text: String) -> VirtualDisplaySize? {
        let parts = text.split(separator: "x")
        guard parts.count == 2, let width = Int(parts[0]), let height = Int(parts[1]) else {
            return nil
        }
        return VirtualDisplaySize(width: width, height: height)
    }
}

/// Public CoreGraphics display-mode helpers shared by the child setup/restore
/// paths (pixel-size lookup, mode set with bounded verification).
enum DisplayModeHelper {
    static func pixels(of mode: CGDisplayMode?) -> DisplayPixelSize? {
        guard let mode, mode.pixelWidth > 0, mode.pixelHeight > 0 else { return nil }
        return DisplayPixelSize(width: mode.pixelWidth, height: mode.pixelHeight)
    }

    static func currentPixels(displayID: CGDirectDisplayID) -> DisplayPixelSize? {
        if let pixels = pixels(of: CGDisplayCopyDisplayMode(displayID)) {
            return pixels
        }
        let bounds = CGDisplayBounds(displayID)
        guard bounds.width > 0, bounds.height > 0 else { return nil }
        return DisplayPixelSize(width: Int(bounds.width), height: Int(bounds.height))
    }

    /// All modes of a display, including the HiDPI duplicate variants behind the
    /// duplicate-low-resolution option (needed to find scaled/native pixel sizes).
    static func modes(displayID: CGDirectDisplayID) -> [CGDisplayMode] {
        let options = [kCGDisplayShowDuplicateLowResolutionModes: true] as CFDictionary
        if let modes = CGDisplayCopyAllDisplayModes(displayID, options) as? [CGDisplayMode],
           !modes.isEmpty {
            return modes
        }
        return (CGDisplayCopyAllDisplayModes(displayID, nil) as? [CGDisplayMode]) ?? []
    }

    /// Display ids that may be used as the mirror target: an active built-in
    /// display (MacBook dev case) or an active non-virtual external display
    /// (headless Mac mini + 4K display production case).
    static func mirrorTargets() -> [CGDirectDisplayID] {
        var count: UInt32 = 0
        CGGetOnlineDisplayList(0, nil, &count)
        guard count > 0 else { return [] }
        var identifiers = [CGDirectDisplayID](repeating: 0, count: Int(count))
        var actual: UInt32 = 0
        CGGetOnlineDisplayList(count, &identifiers, &actual)
        return identifiers.prefix(Int(actual)).filter { isUsableMirrorTarget($0) }
    }

    static func isUsableMirrorTarget(_ displayID: CGDirectDisplayID) -> Bool {
        let active = CGDisplayIsActive(displayID) != 0
        let builtin = CGDisplayIsBuiltin(displayID) != 0
        guard active, CGDisplayCopyDisplayMode(displayID) != nil,
              !isVirtualDisplay(displayID) else { return false }
        return builtin || active
    }

    /// WindowServer reports leftover/file-backed virtual displays with the
    /// generic "unkn"/"virt" vendor/model identity.
    static func isVirtualDisplay(_ displayID: CGDirectDisplayID) -> Bool {
        CGDisplayVendorNumber(displayID) == 0x756e_6b6e  // "unkn"
            && CGDisplayModelNumber(displayID) == 0x7669_7274  // "virt"
    }

    static func find(displayID: CGDirectDisplayID,
                     pixels: DisplayPixelSize) -> CGDisplayMode? {
        modes(displayID: displayID).first {
            $0.pixelWidth == pixels.width && $0.pixelHeight == pixels.height
        }
    }

    /// Set the display to the mode with the given pixel size and verify with a
    /// bounded poll. Returns whether the requested pixels are now active.
    static func setMode(displayID: CGDirectDisplayID, pixels: DisplayPixelSize,
                        timeout: TimeInterval) -> (result: Bool, current: DisplayPixelSize?) {
        if currentPixels(displayID: displayID) == pixels {
            return (true, pixels)
        }
        guard let mode = find(displayID: displayID, pixels: pixels) else {
            return (false, currentPixels(displayID: displayID))
        }
        // Set the mode through a display-configuration transaction: a bare
        // CGDisplaySetDisplayMode from a short-lived process is reverted when the
        // process exits (observed with the harness set-display-mode helper and
        // the virtual-display child, which exits right after restoring).
        var configuration: CGDisplayConfigRef?
        var setResult = CGDisplaySetDisplayMode(displayID, mode, nil)
        if CGBeginDisplayConfiguration(&configuration) == .success, let configuration {
            let configure = CGConfigureDisplayWithDisplayMode(configuration, displayID, mode, nil)
            let complete = CGCompleteDisplayConfiguration(configuration, .forSession)
            if configure == .success, complete == .success { setResult = .success }
        }
        var current = currentPixels(displayID: displayID)
        let deadline = Date().addingTimeInterval(timeout)
        while current != pixels, Date() < deadline {
            Thread.sleep(forTimeInterval: 0.05)
            current = currentPixels(displayID: displayID)
        }
        return (setResult == .success && current == pixels, current)
    }
}

/// One-line snapshot of the current display arrangement for the
/// `event=display_state_before/after` log lines (no SCK/TCC required).
enum DisplayStateSummary {
    static func current() -> String {
        var count: UInt32 = 0
        CGGetOnlineDisplayList(0, nil, &count)
        guard count > 0 else { return "online=0" }
        var identifiers = [CGDirectDisplayID](repeating: 0, count: Int(count))
        var actual: UInt32 = 0
        CGGetOnlineDisplayList(count, &identifiers, &actual)
        var parts: [String] = ["online=\(actual)"]
        for index in 0..<Int(actual) {
            let identifier = identifiers[index]
            let mode = CGDisplayCopyDisplayMode(identifier)
            let bounds = CGDisplayBounds(identifier)
            parts.append("id=\(identifier) main=\(CGDisplayIsMain(identifier) != 0 ? 1 : 0) " +
                         "pixels=\(mode?.pixelWidth ?? 0)x\(mode?.pixelHeight ?? 0) " +
                         "points=\(Int(bounds.width))x\(Int(bounds.height))")
        }
        return parts.joined(separator: " ")
    }
}

/// DispatchSource/ObjC callbacks only need a locked boolean.
private final class Flag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false

    var isSet: Bool {
        lock.lock()
        defer { lock.unlock() }
        return value
    }

    func set() {
        lock.lock()
        value = true
        lock.unlock()
    }
}

/// Minimal `objc_msgSend` bridge for the private CoreGraphics classes. Swift
/// cannot call `objc_msgSend` directly under ARC, so each call looks up the
/// method implementation and bit-casts it to the exact C signature.
private enum ObjCRuntime {
    static func alloc(_ cls: AnyClass) -> AnyObject? {
        typealias Function = @convention(c) (AnyObject, Selector) -> AnyObject
        guard let imp = classImplementation(cls, "alloc") else { return nil }
        return unsafeBitCast(imp, to: Function.self)(cls as AnyObject, selector("alloc"))
    }

    static func displayID(_ object: AnyObject) -> UInt32? {
        typealias Function = @convention(c) (AnyObject, Selector) -> UInt32
        guard let imp = instanceImplementation(object, "displayID") else { return nil }
        return unsafeBitCast(imp, to: Function.self)(object, selector("displayID"))
    }

    static func initObject(_ object: AnyObject) -> AnyObject? {
        typealias Function = @convention(c) (AnyObject, Selector) -> AnyObject
        guard let imp = instanceImplementation(object, "init") else { return nil }
        return unsafeBitCast(imp, to: Function.self)(object, selector("init"))
    }

    static func initWithDescriptor(_ cls: AnyClass, _ descriptor: AnyObject) -> AnyObject? {
        guard let allocated = alloc(cls) else { return nil }
        typealias Function = @convention(c) (AnyObject, Selector, AnyObject) -> AnyObject
        guard let imp = instanceImplementation(allocated, "initWithDescriptor:") else { return nil }
        return unsafeBitCast(imp, to: Function.self)(allocated, selector("initWithDescriptor:"),
                                                    descriptor)
    }

    static func initWithWidthHeightRefreshRate(_ cls: AnyClass, width: Int32, height: Int32,
                                               refreshRate: Double) -> AnyObject? {
        guard let allocated = alloc(cls) else { return nil }
        typealias Function = @convention(c) (AnyObject, Selector, Int32, Int32, Double) -> AnyObject
        let name = "initWithWidth:height:refreshRate:"
        guard let imp = instanceImplementation(allocated, name) else { return nil }
        return unsafeBitCast(imp, to: Function.self)(allocated, selector(name), width, height,
                                                    refreshRate)
    }

    @discardableResult




    static func sendVoidId(_ object: AnyObject, _ name: String, _ argument: AnyObject?) -> Bool {
        typealias Function = @convention(c) (AnyObject, Selector, AnyObject) -> Void
        guard let argument, let imp = instanceImplementation(object, name) else { return false }
        unsafeBitCast(imp, to: Function.self)(object, selector(name), argument)
        return true
    }

    static func sendVoidSize(_ object: AnyObject, _ name: String, _ argument: CGSize) {
        typealias Function = @convention(c) (AnyObject, Selector, CGSize) -> Void
        guard let imp = instanceImplementation(object, name) else { return }
        unsafeBitCast(imp, to: Function.self)(object, selector(name), argument)
    }

    static func sendVoidUInt32(_ object: AnyObject, _ name: String, _ argument: UInt32) {
        typealias Function = @convention(c) (AnyObject, Selector, UInt32) -> Void
        guard let imp = instanceImplementation(object, name) else { return }
        unsafeBitCast(imp, to: Function.self)(object, selector(name), argument)
    }

    @discardableResult
    static func sendBoolUInt32(_ object: AnyObject, _ name: String, _ argument: UInt32) -> Bool {
        typealias Function = @convention(c) (AnyObject, Selector, UInt32) -> Void
        guard let imp = instanceImplementation(object, name) else { return false }
        unsafeBitCast(imp, to: Function.self)(object, selector(name), argument)
        return true
    }

    static func sendBoolId(_ object: AnyObject, _ name: String, _ argument: AnyObject) -> Bool {
        typealias Function = @convention(c) (AnyObject, Selector, AnyObject) -> Bool
        guard let imp = instanceImplementation(object, name) else { return false }
        return unsafeBitCast(imp, to: Function.self)(object, selector(name), argument)
    }

    private static func selector(_ name: String) -> Selector {
        sel_registerName(name)
    }

    private static func instanceImplementation(_ object: AnyObject, _ name: String) -> IMP? {
        guard let method = class_getInstanceMethod(type(of: object), selector(name)) else {
            return nil
        }
        return method_getImplementation(method)
    }

    private static func classImplementation(_ cls: AnyClass, _ name: String) -> IMP? {
        guard let method = class_getClassMethod(cls, selector(name)) else { return nil }
        return method_getImplementation(method)
    }
}
