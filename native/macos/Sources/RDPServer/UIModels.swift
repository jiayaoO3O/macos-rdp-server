import Foundation

// UI-facing mirror of the core status. The view layer only knows these types so
// a change in RDPServerCore naming stays confined to LiveCoreBridge.
// All strings here are user-facing Chinese; log/diagnostic output stays English.

enum UIServiceState: Equatable, Sendable {
    case disabled
    case starting
    case running
    case stopping
    case error

    var isBusy: Bool { self == .starting || self == .stopping }

    /// Header state text: 未启用 / 启动中 / 运行中 / 停止中 / 错误.
    var title: String {
        switch self {
        case .disabled: return "未启用"
        case .starting: return "启动中"
        case .running: return "运行中"
        case .stopping: return "停止中"
        case .error: return "错误"
        }
    }

    var isRunning: Bool { self == .running }

    /// Stable ASCII token for log lines (never localise log values).
    var logToken: String {
        switch self {
        case .disabled: return "disabled"
        case .starting: return "starting"
        case .running: return "running"
        case .stopping: return "stopping"
        case .error: return "error"
        }
    }
}

enum UIAgentState: Equatable, Sendable {
    case waiting
    case capturing
    case failed

    var title: String {
        switch self {
        case .waiting: return "等待 Agent"
        case .capturing: return "正在采集"
        case .failed: return "采集异常"
        }
    }
}

struct UIPermissions: Equatable, Sendable {
    var screenRecording: Bool
    var accessibility: Bool
    /// False when the Agent helper is missing / its status report could not be
    /// read, so "missing" is not asserted as a fact.
    var available: Bool = true

    var allGranted: Bool { screenRecording && accessibility }
}

/// One immutable snapshot of everything the popover renders. Produced by a
/// ServerCoreBridge; never contains secrets (no password, no NT hash).
struct AppSnapshot: Equatable {
    var state: UIServiceState = .disabled
    /// Config + SAM exist; false on first run, where enabling the service has to
    /// open the credential editor first.
    var configured: Bool = true
    /// Fully formatted "host:port" when a listener address is known.
    var address: String?
    var listenHost: String = "127.0.0.1"
    var port: Int = 3389
    var allowLAN: Bool = false
    var account: String = ""
    var principal: String = ""
    var permissions = UIPermissions(screenRecording: false, accessibility: false)
    var agentState: UIAgentState = .waiting
    var agentDetail: String?
    var workerRunning: Bool = false
    var workerPID: Int32?
    var agentPID: Int32?
    var needsRestart: Bool = false
    var lastError: String?
    var logsDirectory: URL = URL(fileURLWithPath: "/tmp", isDirectory: true)
    var dataDirectory: URL = URL(fileURLWithPath: "/tmp", isDirectory: true)
    /// Legacy LaunchAgent (com.rdp-server.agent) still installed: show a gentle
    /// hint only, the app never runs launchctl itself.
    var legacyLaunchAgentInstalled: Bool = false

    /// "host:port" for display/copy; falls back to the configured listener
    /// address while the service is stopped.
    var displayAddress: String {
        if let address, !address.isEmpty { return address }
        return "\(listenHost):\(port)"
    }

    /// "MACRDP\\\\user" for user-facing copy (the backslash is literal).
    var principalDisplay: String {
        if principal.isEmpty { return "MACRDP\\（未设置）" }
        return principal
    }

    var isBusy: Bool { state.isBusy }

    var permissionSummary: String {
        if !permissions.available { return "权限状态未知" }
        if permissions.allGranted { return "权限正常" }
        var missing: [String] = []
        if !permissions.screenRecording { missing.append("屏幕录制") }
        if !permissions.accessibility { missing.append("辅助功能") }
        return "缺少" + missing.joined(separator: "、") + "权限"
    }
}
