import Foundation

/// System Settings privacy panes the permission rows can open. The live bridge
/// maps these onto RDPServerCore.PrivacyPane; the UI never imports the core.
enum UIPrivacyPane {
    case screenRecording
    case accessibility
    case fullDiskAccess

    var url: URL {
        switch self {
        case .screenRecording:
            return URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!
        case .accessibility:
            return URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!
        case .fullDiskAccess:
            return URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles")!
        }
    }
}

/// User-facing error from the bridge. The core throws its own errors; mapping
/// them to Chinese text happens in the bridge implementation so views never
/// show raw diagnostics.
enum BridgeError: LocalizedError, Equatable {
    case validation(String)
    case operation(String)

    var errorDescription: String? {
        switch self {
        case .validation(let message): return message
        case .operation(let message): return message
        }
    }
}

/// Contract between the RDPServer executable and RDPServerCore. Every method is
/// main-actor isolated; the live implementation moves blocking work (process
/// spawn, file IO, subprocess queries) off the main thread inside the core.
@MainActor
protocol ServerCoreBridge: AnyObject {
    /// Cheap refresh used by the popover poll loop. Must not throw on a healthy
    /// read and must not start or stop anything as a side effect.
    func fetchSnapshot() async -> AppSnapshot
    /// Start the service (true) or stop it gracefully (false).
    func setEnabled(_ enabled: Bool) async throws
    func setAllowLAN(_ enabled: Bool) async throws
    func setPort(_ port: Int) async throws
    /// Validate, hash and persist new RDP credentials. The plaintext password is
    /// never stored beyond this call.
    func saveCredentials(username: String, password: String) async throws
    /// Restart the worker after a config/credential change (disconnects the
    /// current RDP session).
    func restart() async throws
    /// Launch the agent-identity TCC prompts (Screen Recording / Accessibility).
    func requestPermissions() async
    /// Idempotent graceful shutdown used by the Quit item and by SIGTERM.
    func shutdown() async
}

/// Dev-only switches. A Finder/launchd launched app has no environment, so the
/// shipping path never sees these; they exist to build and visually verify the
/// UI without touching the real service.
enum DevFlags {
    static var uiMock: Bool {
        ProcessInfo.processInfo.environment["RDPSERVER_UI_MOCK"] == "1"
    }
    /// Open the popover shortly after launch so automated screenshots work
    /// without UI scripting / Accessibility permission (dev/test only).
    /// RDPSERVER_OPEN_POPOVER=1 is the documented switch; RDPSERVER_UI_DEV_OPEN=1
    /// is kept as an alias.
    static var openPopoverAtLaunch: Bool {
        let environment = ProcessInfo.processInfo.environment
        return environment["RDPSERVER_OPEN_POPOVER"] == "1" || environment["RDPSERVER_UI_DEV_OPEN"] == "1"
    }
    static var mockRunning: Bool {
        let state = ProcessInfo.processInfo.environment["RDPSERVER_UI_MOCK_STATE"]
        return state == "running" || state == "error"
    }
    static var mockPermissionsGranted: Bool {
        ProcessInfo.processInfo.environment["RDPSERVER_UI_MOCK_PERMISSIONS"] == "granted"
    }
    static var mockAgentFailed: Bool {
        ProcessInfo.processInfo.environment["RDPSERVER_UI_MOCK_STATE"] == "error"
    }
    /// Offscreen PNG of the popover content (dev only, no screen-recording
    /// permission and no desktop pixels involved).
    static var previewSnapshotPath: String? {
        ProcessInfo.processInfo.environment["RDPSERVER_UI_SNAPSHOT"]
    }
    static var previewSnapshotView: String {
        ProcessInfo.processInfo.environment["RDPSERVER_UI_SNAPSHOT_VIEW"] ?? "main"
    }
}

enum AppBootstrap {
    /// Build the popover model for GUI mode. Production always uses the live
    /// core bridge; RDPSERVER_UI_MOCK=1 selects the dev-only simulated bridge.
    @MainActor
    static func makeModel(invocation: CLIInvocation) -> AppModel {
        if DevFlags.uiMock {
            let bridge = MockCoreBridge(
                dataDirectory: invocation.displayDataDirectory,
                running: DevFlags.mockRunning,
                permissionsGranted: DevFlags.mockPermissionsGranted,
                agentFailed: DevFlags.mockAgentFailed
            )
            return AppModel(bridge: bridge, initial: bridge.currentSnapshot)
        }
        do {
            let bridge = try LiveCoreBridge(dataDirectory: invocation.dataDirectory)
            return AppModel(bridge: bridge, initial: bridge.snapshotNow())
        } catch {
            let bridge = BrokenCoreBridge(reason: "无法初始化服务：\(error.localizedDescription)")
            return AppModel(bridge: bridge, initial: bridge.brokenSnapshot)
        }
    }
}
