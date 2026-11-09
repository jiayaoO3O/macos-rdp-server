import Foundation

/// High-level lifecycle state of the managed service.
public enum ServiceState: String, Codable, Equatable, Sendable {
    case disabled
    case starting
    case running
    case stopping
    case error
}

/// State of the desktop Agent child process.
public enum AgentState: String, Codable, Equatable, Sendable {
    case waiting
    case capturing
    case failed
}

/// Listening policy for the Worker.
public enum AddressMode: String, Codable, Equatable, Sendable {
    /// 127.0.0.1 only (allow_lan = false).
    case loopback
    /// address = "auto", allow_lan = true: one private LAN IPv4, followed by the
    /// Worker supervisor when the address changes.
    case lan
}

/// macOS privacy panes the app can deep-link to (it never grants permissions).
public enum PrivacyPane: String, Codable, Equatable, Sendable {
    case screenRecording
    case accessibility
    case fullDiskAccess

    public var settingsURL: URL {
        let base = "x-apple.systempreferences:com.apple.preference.security?"
        switch self {
        case .screenRecording: return URL(string: base + "Privacy_ScreenCapture")!
        case .accessibility: return URL(string: base + "Privacy_Accessibility")!
        case .fullDiskAccess: return URL(string: base + "Privacy_AllFiles")!
        }
    }
}

/// Validation failures surfaced to the credential editor.
public enum CredentialValidationError: Error, Equatable, Sendable, CustomStringConvertible {
    case usernameInvalid
    case passwordInvalid
    case passwordTooLong
    case writeFailed(String)

    public var description: String {
        switch self {
        case .usernameInvalid:
            return "username must be 1-64 lowercase letters, digits, '.', '_' or '-'"
        case .passwordInvalid:
            return "password must not be empty or contain a newline"
        case .passwordTooLong:
            return "password must be at most 4095 UTF-8 bytes"
        case .writeFailed(let message):
            return message
        }
    }
}

/// The TCC permissions the Agent bundle needs.
///
/// The menu bar app itself is not the TCC identity: Screen Recording and
/// Accessibility belong to the nested RDPAgent.app bundle. This snapshot is
/// produced by running that binary with RDP_AGENT_NO_PERMISSION_REQUEST=1 and
/// parsing its status report.
public struct PermissionSnapshot: Codable, Equatable, Sendable {
    public var screenRecording: Bool
    public var accessibility: Bool
    /// False when the Agent helper is missing or its report could not be parsed.
    public var isAvailable: Bool
    public var lastError: String?
    public var checkedAt: Date?

    public init(screenRecording: Bool = false,
                accessibility: Bool = false,
                isAvailable: Bool = false,
                lastError: String? = nil,
                checkedAt: Date? = nil) {
        self.screenRecording = screenRecording
        self.accessibility = accessibility
        self.isAvailable = isAvailable
        self.lastError = lastError
        self.checkedAt = checkedAt
    }

    public var desktopReady: Bool { screenRecording && accessibility }

    public var summary: String {
        guard isAvailable else { return "permissions=unknown" }
        return "screen_recording=\(screenRecording ? "granted" : "missing") accessibility=\(accessibility ? "granted" : "missing")"
    }
}

/// Immutable fact sheet the UI renders. Produced by ServerManager.snapshot().
public struct ServerSnapshot: Equatable, Sendable {
    public var state: ServiceState
    public var configured: Bool
    /// host:port the Worker is listening on, nil while not listening.
    public var address: String?
    public var listenHost: String
    public var port: Int
    public var allowLAN: Bool
    /// Bare RDP username (no MACRDP domain prefix).
    public var account: String?
    /// MACRDP\user, for display.
    public var principal: String?
    public var permissions: PermissionSnapshot
    public var agentState: AgentState
    public var agentDetail: String?
    public var workerRunning: Bool
    public var workerPID: Int32?
    public var agentPID: Int32?
    public var generation: UInt64?
    /// True when configuration was saved while running: show a disconnect
    /// warning and offer restart().
    public var needsRestart: Bool
    public var lastError: String?
    /// Read-only detection of the old LaunchAgent plist. Never modified.
    public var legacyLaunchAgentInstalled: Bool
    public var logsDirectory: URL
    public var dataDirectory: URL

    public init(state: ServiceState = .disabled,
                configured: Bool = false,
                address: String? = nil,
                listenHost: String = "127.0.0.1",
                port: Int = 3389,
                allowLAN: Bool = false,
                account: String? = nil,
                principal: String? = nil,
                permissions: PermissionSnapshot = PermissionSnapshot(),
                agentState: AgentState = .waiting,
                agentDetail: String? = nil,
                workerRunning: Bool = false,
                workerPID: Int32? = nil,
                agentPID: Int32? = nil,
                generation: UInt64? = nil,
                needsRestart: Bool = false,
                lastError: String? = nil,
                legacyLaunchAgentInstalled: Bool = false,
                logsDirectory: URL = URL(fileURLWithPath: "/"),
                dataDirectory: URL = URL(fileURLWithPath: "/")) {
        self.state = state
        self.configured = configured
        self.address = address
        self.listenHost = listenHost
        self.port = port
        self.allowLAN = allowLAN
        self.account = account
        self.principal = principal
        self.permissions = permissions
        self.agentState = agentState
        self.agentDetail = agentDetail
        self.workerRunning = workerRunning
        self.workerPID = workerPID
        self.agentPID = agentPID
        self.generation = generation
        self.needsRestart = needsRestart
        self.lastError = lastError
        self.legacyLaunchAgentInstalled = legacyLaunchAgentInstalled
        self.logsDirectory = logsDirectory
        self.dataDirectory = dataDirectory
    }
}

/// Errors thrown by ServerManager control operations.
public enum ServerError: Error, Equatable, Sendable, CustomStringConvertible {
    case notConfigured
    case alreadyRunning
    case notRunning
    case invalidConfiguration(String)
    case dataDirectory(String)
    case helperMissing(String)
    case credentials(String)
    case certificate(String)
    case workerFailed(String)
    case agentFailed(String)
    case notReady(String)

    public var description: String {
        switch self {
        case .notConfigured:
            return "RDP account credentials are not configured yet"
        case .alreadyRunning:
            return "service is already running"
        case .notRunning:
            return "service is not running"
        case .invalidConfiguration(let message):
            return message
        case .dataDirectory(let message):
            return message
        case .helperMissing(let name):
            return "required helper is missing: \(name)"
        case .credentials(let message):
            return message
        case .certificate(let message):
            return message
        case .workerFailed(let message):
            return message
        case .agentFailed(let message):
            return message
        case .notReady(let message):
            return message
        }
    }
}

/// Read-only check for the legacy launchd-managed Agent deployment. The app
/// never uninstalls or modifies it; the design doc tells the user to remove it.
public enum LegacyDeployment {
    public static func launchAgentPlistURL(environment: [String: String] = ProcessInfo.processInfo.environment) -> URL {
        let home: String
        if let value = environment["HOME"], value.hasPrefix("/") {
            home = value
        } else {
            home = NSHomeDirectory()
        }
        return URL(fileURLWithPath: home)
            .appendingPathComponent("Library/LaunchAgents/com.rdp-server.agent.plist")
    }

    public static func launchAgentInstalled(environment: [String: String] = ProcessInfo.processInfo.environment) -> Bool {
        SecureFile.exists(launchAgentPlistURL(environment: environment))
    }
}
