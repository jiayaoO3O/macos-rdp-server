import AppKit
import SwiftUI

/// Owns the NSStatusItem + NSPopover. AppKit (instead of SwiftUI MenuBarExtra)
/// because we need an exactly sized 360 pt popover, dynamic height as sections
/// expand, a right-click menu, and reliable icon/state updates.
@MainActor
final class MenuBarController: NSObject, NSPopoverDelegate {
    private let model: AppModel
    private let statusItem: NSStatusItem
    private let popover = NSPopover()
    private let hostingController: NSHostingController<PopoverView>
    private var sizeObservation: NSKeyValueObservation?
    private var lastCloseAt = Date.distantPast
    private var lastPopoverLogEvent = ""
    private var lastPopoverLogAt = Date.distantPast

    init(model: AppModel) {
        self.model = model
        self.statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        self.hostingController = NSHostingController(rootView: PopoverView(model: model))
        super.init()
        configure()
    }

    deinit {
        sizeObservation?.invalidate()
    }

    private func configure() {
        hostingController.sizingOptions = [.preferredContentSize]

        popover.behavior = .transient
        popover.animates = true
        popover.delegate = self
        popover.contentViewController = hostingController
        popover.contentSize = NSSize(width: 360, height: 460)

        if let button = statusItem.button {
            button.imagePosition = .imageOnly
            button.target = self
            button.action = #selector(statusItemClicked(_:))
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
            button.toolTip = tooltip(for: model.snapshot.state)
            button.setAccessibilityLabel("RDP 远程桌面：\(model.snapshot.state.title)")
            button.image = MenuBarIcon.image(for: model.snapshot.state)
        }

        model.onStateChange = { [weak self] state in
            self?.applyIcon(for: state)
        }

        // SwiftUI reports the intrinsic content height; keep the popover in sync
        // so expanding 高级 / error banners / the credential editor resize it.
        UILog.event("menu_bar_ready", ["state": model.snapshot.state.logToken])

        sizeObservation = hostingController.observe(\.preferredContentSize, options: [.new]) { [weak self] _, change in
            guard let size = change.newValue, size.height > 0 else { return }
            Task { @MainActor [weak self] in
                self?.applyContentSize(size)
            }
        }
    }

    /// Dev-only entry point used by RDPSERVER_UI_DEV_OPEN=1.
    func showPopover() {
        guard let button = statusItem.button else { return }
        NSApp.activate(ignoringOtherApps: true)
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
    }

    @objc private func statusItemClicked(_ sender: Any?) {
        if let event = NSApp.currentEvent, event.type == .rightMouseUp {
            showContextMenu()
            return
        }
        if popover.isShown {
            popover.performClose(nil)
            return
        }
        // A transient popover closes right before the click action fires; do not
        // immediately reopen in that case (otherwise the popover never closes).
        if Date().timeIntervalSince(lastCloseAt) < 0.25 { return }
        showPopover()
    }

    private func applyContentSize(_ preferred: NSSize) {
        let width: CGFloat = 360
        let height = min(max(preferred.height.rounded(.up), 220), 720)
        guard abs(popover.contentSize.width - width) > 0.5
            || abs(popover.contentSize.height - height) > 0.5 else { return }
        popover.contentSize = NSSize(width: width, height: height)
    }

    private func applyIcon(for state: UIServiceState) {
        guard let button = statusItem.button else { return }
        button.image = MenuBarIcon.image(for: state)
        button.toolTip = tooltip(for: state)
        button.setAccessibilityLabel("RDP 远程桌面：\(state.title)")
    }

    private func tooltip(for state: UIServiceState) -> String {
        "RDP 远程桌面 · \(state.title)"
    }

    private func showContextMenu() {
        let menu = NSMenu()
        let logs = NSMenuItem(title: "打开日志", action: #selector(openLogsFromMenu), keyEquivalent: "")
        logs.target = self
        menu.addItem(logs)
        menu.addItem(.separator())
        let quit = NSMenuItem(title: "退出", action: #selector(quitFromMenu), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)
        // Attaching the menu and clicking is the standard way to show a context
        // menu from a status item that already has an action.
        statusItem.menu = menu
        statusItem.button?.performClick(nil)
        statusItem.menu = nil
    }

    @objc private func openLogsFromMenu() {
        model.openLogs()
    }

    @objc private func quitFromMenu() {
        model.quit()
    }

    // MARK: NSPopoverDelegate

    func popoverDidShow(_ notification: Notification) {
        model.setPopoverVisible(true)
        logPopover("popover_opened")
    }

    func popoverDidClose(_ notification: Notification) {
        model.setPopoverVisible(false)
        lastCloseAt = Date()
        logPopover("popover_closed")
    }

    /// Deduplicated so transient reopens cannot spam app.log.
    private func logPopover(_ event: String) {
        let now = Date()
        if lastPopoverLogEvent == event, now.timeIntervalSince(lastPopoverLogAt) < 0.5 { return }
        lastPopoverLogEvent = event
        lastPopoverLogAt = now
        UILog.event(event, ["state": model.snapshot.state.logToken])
    }
}
