import AppKit
import SwiftUI

/// Dev-only offscreen renderer for UI verification: RDPSERVER_UI_SNAPSHOT=/path.png
/// (with RDPSERVER_UI_MOCK=1) renders the popover content (or the status icons)
/// to PNG and exits. No service is started, no screen-recording permission is
/// needed, and no desktop pixels are captured.
enum DevPreview {
    @MainActor
    static func run(model: AppModel) async -> Int32 {
        guard let path = DevFlags.previewSnapshotPath else { return 1 }
        // Populate the model the same way the running app would (snapshot +
        // Agent capability), so the PNG matches runtime state.
        await model.refresh()
        let url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
        let viewName = DevFlags.previewSnapshotView
        // Dev-only: expand 高级 so the advanced controls are visible in snapshots.
        if ProcessInfo.processInfo.environment["RDPSERVER_UI_SNAPSHOT_ADVANCED"] == "1" {
            model.advancedExpanded = true
        }
        let ok: Bool
        switch viewName {
        case "credentials":
            model.showCredentials = true
            ok = render(PopoverView(model: model), to: url)
        case "icon":
            ok = renderIconSheet(to: url)
        default:
            ok = render(PopoverView(model: model), to: url)
        }
        if ok {
            print("event=ui_snapshot_written view=\(viewName) path=\(path)")
            return 0
        }
        fputs("event=ui_snapshot_failed view=\(viewName)\n", stderr)
        return 1
    }

    @MainActor
    private static func render<V: View>(_ view: V, to url: URL) -> Bool {
        let hosting = NSHostingView(rootView: view.frame(width: 360))
        hosting.frame = NSRect(x: 0, y: 0, width: 360, height: 460)
        hosting.layoutSubtreeIfNeeded()
        let height = max(hosting.fittingSize.height, 120)
        let frame = NSRect(x: 0, y: 0, width: 360, height: height)
        hosting.frame = frame

        // A borderless offscreen window gives SwiftUI a real backing store; the
        // window is never shown to the user.
        let window = NSWindow(contentRect: frame,
                              styleMask: [.borderless],
                              backing: .buffered,
                              defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = hosting
        window.setFrameOrigin(NSPoint(x: -20000, y: -20000))
        hosting.layoutSubtreeIfNeeded()
        hosting.displayIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))
        hosting.layoutSubtreeIfNeeded()
        hosting.displayIfNeeded()

        guard let rep = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) else {
            return false
        }
        hosting.cacheDisplay(in: hosting.bounds, to: rep)
        window.close()
        guard let data = rep.representation(using: .png, properties: [:]) else { return false }
        do {
            try data.write(to: url)
            return true
        } catch {
            return false
        }
    }

    @MainActor
    private static func renderIconSheet(to url: URL) -> Bool {
        let states: [UIServiceState] = [.disabled, .starting, .running, .error]
        let canvas = NSImage(size: NSSize(width: 132, height: 30))
        canvas.lockFocus()
        NSColor.windowBackgroundColor.setFill()
        NSRect(x: 0, y: 0, width: 132, height: 30).fill()
        for (index, state) in states.enumerated() {
            let image = MenuBarIcon.image(for: state)
            let rect = NSRect(x: 10 + CGFloat(index) * 30, y: 6, width: 20, height: 18)
            image.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1.0)
        }
        canvas.unlockFocus()
        guard let tiff = canvas.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let data = rep.representation(using: .png, properties: [:]) else {
            return false
        }
        do {
            try data.write(to: url)
            return true
        } catch {
            return false
        }
    }
}
