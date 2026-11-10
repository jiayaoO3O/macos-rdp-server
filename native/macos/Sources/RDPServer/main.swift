import AppKit
import RDPServerCore

// RDPServer: macOS menu bar app for the RDP server prototype.
//
// Two modes:
//   * headless CLI (--status / --self-test / --help / --version) dispatched before
//     AppKit starts, so packaging/DMG verification and tests can drive the
//     executable without a window, service start or TCC prompt;
//   * menu bar UI (no core flags) with a status item + 360 pt popover.
//
// Quit path: manager.shutdown() then NSApp.terminate.

@main
struct RDPServerMain {
    @MainActor
    static func main() async {
        let arguments = Array(CommandLine.arguments.dropFirst())

        // Core CLI dispatch must happen before any NSApplication/SwiftUI work.
        if let exitCode = RDPServerCLI.run(arguments: arguments) {
            exit(exitCode)
        }

        let invocation = CLIInvocation.parseGUI(arguments: arguments)

        // Dev-only end-to-end smoke of the UI action layer against the real core
        // (isolated data dir, random loopback port). Used for headless verification.
        if DevSmoke.isRequested {
            exit(await DevSmoke.run(invocation: invocation))
        }

        let model = AppBootstrap.makeModel(invocation: invocation)

        // Dev-only offscreen PNG render (RDPSERVER_UI_SNAPSHOT): exits here.
        if DevFlags.previewSnapshotPath != nil {
            _ = NSApplication.shared
            NSApp.setActivationPolicy(.accessory)
            exit(await DevPreview.run(model: model))
        }

        let app = NSApplication.shared
        let openPopover = invocation.openPopoverAtLaunch || DevFlags.openPopoverAtLaunch
        let delegate = AppDelegate(model: model, openPopoverAtLaunch: openPopover)
        app.delegate = delegate
        // .accessory keeps the Dock icon hidden for unbundled dev runs; the
        // packaged app also sets LSUIElement in its Info.plist.
        app.setActivationPolicy(.accessory)
        app.run()
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let model: AppModel
    private let openPopoverAtLaunch: Bool
    private var menuBarController: MenuBarController?
    private var signalSources: [DispatchSourceSignal] = []

    init(model: AppModel, openPopoverAtLaunch: Bool) {
        self.model = model
        self.openPopoverAtLaunch = openPopoverAtLaunch
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        // Best effort: lifecycle lines land in <data>/logs/app.log (same format as
        // the core AppLog) so headless verification can prove the UI exists.
        UILog.configure(dataDirectory: model.snapshot.dataDirectory)
        menuBarController = MenuBarController(model: model)
        model.startPolling()
        installSignalHandlers()

        // Dev/acceptance only (RDPSERVER_AUTOSTART=1): start the service once on
        // launch when credentials are configured. Shipping launches stay disabled.
        if ProcessInfo.processInfo.environment["RDPSERVER_AUTOSTART"] == "1" {
            Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: 700_000_000)
                await self?.model.autostartServiceIfNeeded()
            }
        }

        // Dev/test only: RDPSERVER_OPEN_POPOVER=1 or --show-popover opens the
        // popover once, exactly like clicking the status item.
        if openPopoverAtLaunch {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) { [weak self] in
                self?.menuBarController?.showPopover()
            }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        // Best effort only: the normal quit path already awaited shutdown().
        // A Worker that outlives a crash/SIGKILL notices through
        // RDP_WORKER_MANAGED_BY_APP and exits without becoming an orphan.
    }

    /// Terminal dev runs: a bare SIGTERM/SIGINT would orphan worker/agent
    /// children, so route both through the graceful shutdown path.
    private func installSignalHandlers() {
        for sig in [SIGINT, SIGTERM] {
            signal(sig, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: sig, queue: .main)
            source.setEventHandler { [weak self] in
                guard let self else { return }
                Task { @MainActor in
                    await self.model.shutdownForSignal()
                    exit(0)
                }
            }
            source.resume()
            signalSources.append(source)
        }
    }
}
