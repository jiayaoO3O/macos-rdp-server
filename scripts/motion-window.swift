// Synthetic screen-motion generator for RDP performance measurements.
//
// Creates a visible 1024x768 window whose content changes on every display
// refresh, then exits after MOTION_SECONDS seconds (default 20). It exists so
// ScreenCaptureKit sees real screen changes while scripts/benchmark-live-agent.py
// measures the capture -> Worker -> RDP pipeline; it is not part of the product.
//
// scripts/benchmark-live-agent.py compiles this file on demand with swiftc into
// a private temp directory (no build artifacts are added to the repository).
// Markers on stderr: "motion_ready" once the window is on screen, and
// "motion_done frames=N" on exit.

import AppKit
import Foundation

final class MotionView: NSView {
    var tick: Double = 0

    override var isOpaque: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.black.setFill()
        bounds.fill()

        // A white block travels across the window every ~2 seconds.
        let travel = max(0, bounds.width - 240)
        let x = travel * (0.5 + 0.5 * cos(tick))
        NSColor.white.setFill()
        NSRect(x: x, y: 60, width: 240, height: 240).fill()

        // A blue block follows a faster path near the top edge.
        NSColor.systemBlue.setFill()
        NSRect(x: 40 + 20 * cos(tick * 2), y: bounds.height - 160, width: 120, height: 120).fill()

        // Changing text forces a repaint of the glyph area too.
        let text = String(format: "frame %08.3f", tick)
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedSystemFont(ofSize: 42, weight: .bold),
            .foregroundColor: NSColor.systemGreen,
        ]
        text.draw(at: NSPoint(x: 40, y: bounds.height / 2), withAttributes: attributes)
    }
}

let seconds = Double(ProcessInfo.processInfo.environment["MOTION_SECONDS"] ?? "20") ?? 20
let app = NSApplication.shared
app.setActivationPolicy(.regular)

let rect = NSRect(x: 120, y: 120, width: 1024, height: 768)
let window = NSWindow(contentRect: rect,
                      styleMask: [.titled, .closable, .resizable],
                      backing: .buffered,
                      defer: false)
window.title = "RDP motion probe"
let view = MotionView(frame: rect)
view.autoresizingMask = [.width, .height]
window.contentView = view
window.makeKeyAndOrderFront(nil)
app.activate(ignoringOtherApps: true)

fputs("motion_ready\n", stderr)
fflush(stderr)

var frames = 0
let timer = Timer(timeInterval: 1.0 / 60.0, repeats: true) { _ in
    view.tick += 0.03
    view.needsDisplay = true
    frames += 1
    if Double(frames) >= seconds * 60.0 {
        fputs("motion_done frames=\(frames)\n", stderr)
        fflush(stderr)
        exit(0)
    }
}
RunLoop.main.add(timer, forMode: .common)
app.run()
