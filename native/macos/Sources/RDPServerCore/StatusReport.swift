import Foundation

/// Machine-readable status for headless verification (RDPServer --status).
///
/// One JSON object, snake_case keys, exit 0 when ok. It never prints
/// credentials and never starts the service; permissions are probed through the
/// Agent bundle identity only.
public struct StatusReport: Codable, Sendable {
    public struct PermissionStatus: Codable, Sendable {
        public var screenRecording: Bool
        public var accessibility: Bool

        public init(screenRecording: Bool, accessibility: Bool) {
            self.screenRecording = screenRecording
            self.accessibility = accessibility
        }

        enum CodingKeys: String, CodingKey {
            case screenRecording = "screen_recording"
            case accessibility
        }

        public func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(screenRecording, forKey: .screenRecording)
            try container.encode(accessibility, forKey: .accessibility)
        }
    }

    public struct AgentStatus: Codable, Sendable {
        public var state: String
        public var detail: String?

        public init(state: String, detail: String?) {
            self.state = state
            self.detail = detail
        }

        enum CodingKeys: String, CodingKey {
            case state
            case detail
        }

        public func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(state, forKey: .state)
            try container.encode(detail, forKey: .detail)
        }
    }

    public struct WorkerStatus: Codable, Sendable {
        public var running: Bool
        public var pid: Int32?

        public init(running: Bool, pid: Int32?) {
            self.running = running
            self.pid = pid
        }

        enum CodingKeys: String, CodingKey {
            case running
            case pid
        }

        public func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(running, forKey: .running)
            try container.encode(pid, forKey: .pid)
        }
    }

    public var ok: Bool
    public var appVersion: String
    public var dataDirectory: String
    public var state: String
    public var configured: Bool
    public var enabled: Bool
    public var address: String?
    public var listenHost: String?
    public var port: Int?
    public var allowLAN: Bool
    public var account: String?
    public var principal: String?
    public var permissions: PermissionStatus
    public var agent: AgentStatus
    public var worker: WorkerStatus
    public var lastError: String?
    public var logsDirectory: String
    public var error: String?

    enum CodingKeys: String, CodingKey {
        case ok
        case appVersion = "app_version"
        case dataDirectory = "data_directory"
        case state
        case configured
        case enabled
        case address
        case listenHost = "listen_host"
        case port
        case allowLAN = "allow_lan"
        case account
        case principal
        case permissions
        case agent
        case worker
        case lastError = "last_error"
        case logsDirectory = "logs_directory"
        case error
    }

    /// Encodes nil optionals as explicit nulls so the documented key set is
    /// always present (JSON consumers should not have to distinguish "absent"
    /// from "null").
    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(ok, forKey: .ok)
        try container.encode(appVersion, forKey: .appVersion)
        try container.encode(dataDirectory, forKey: .dataDirectory)
        try container.encode(state, forKey: .state)
        try container.encode(configured, forKey: .configured)
        try container.encode(enabled, forKey: .enabled)
        try container.encode(address, forKey: .address)
        try container.encode(listenHost, forKey: .listenHost)
        try container.encode(port, forKey: .port)
        try container.encode(allowLAN, forKey: .allowLAN)
        try container.encode(account, forKey: .account)
        try container.encode(principal, forKey: .principal)
        try container.encode(permissions, forKey: .permissions)
        try container.encode(agent, forKey: .agent)
        try container.encode(worker, forKey: .worker)
        try container.encode(lastError, forKey: .lastError)
        try container.encode(logsDirectory, forKey: .logsDirectory)
        try container.encode(error, forKey: .error)
    }

    public func jsonData() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(self)
    }

    public func jsonString() throws -> String {
        let data = try jsonData()
        return String(decoding: data, as: UTF8.self)
    }

    /// Builds the report without starting anything and without creating the
    /// data directory (a missing directory is a valid first-run state).
    public static func headless(dataDirectory: URL? = nil,
                                environment: [String: String] = ProcessInfo.processInfo.environment) -> StatusReport {
        let paths = ServerPaths.resolveForDisplay(explicit: dataDirectory, environment: environment)
        let helpers = HelperLocator.resolve(environment: environment)
        var ok = true
        var error: String?

        let store = ConfigurationStore(paths: paths)
        var configuration: ServerConfiguration?
        var configurationError: String?
        if SecureFile.exists(paths.dataDirectory) {
            do {
                try paths.validatePrivateLayout(requireLogs: false)
            } catch let failure {
                ok = false
                error = "\(failure)"
            }
            do {
                configuration = try store.loadIfPresent()
            } catch let failure {
                ok = false
                configurationError = "\(failure)"
            }
        } else {
            // First run: report defaults without touching the disk.
            configuration = ServerConfiguration.defaults(for: paths)
        }
        let credentials = CredentialsManager(paths: paths, helpers: helpers)
        let samAccount = credentials.storedAccount()
        var account = configuration?.account ?? ""
        if account.isEmpty, let samAccount { account = samAccount }
        let permissionSnapshot = PermissionsProbe.query(agentExecutable: helpers.agentExecutable,
                                                        environment: helpers.baseEnvironment)
        let effective = configuration ?? ServerConfiguration.defaults(for: paths)
        let mode = effective.addressMode
        let host: String
        if mode == .lan {
            host = LANAddress.select()?.address ?? "127.0.0.1"
        } else {
            host = "127.0.0.1"
        }
        let lastError = configurationError ?? error
        return StatusReport(
            ok: ok,
            appVersion: RDPServerCoreVersion.value,
            dataDirectory: paths.dataDirectory.path,
            state: ServiceState.disabled.rawValue,
            configured: samAccount != nil && SecureFile.exists(paths.configFile),
            enabled: false,
            address: "\(host):\(effective.port)",
            listenHost: host,
            port: effective.port,
            allowLAN: effective.allowLAN,
            account: account.isEmpty ? nil : account,
            principal: account.isEmpty ? nil : ServerManager.principal(for: account),
            permissions: PermissionStatus(screenRecording: permissionSnapshot.screenRecording,
                                          accessibility: permissionSnapshot.accessibility),
            agent: AgentStatus(state: AgentState.waiting.rawValue, detail: nil),
            worker: WorkerStatus(running: false, pid: nil),
            lastError: lastError,
            logsDirectory: paths.logsDirectory.path,
            error: error)
    }
}
