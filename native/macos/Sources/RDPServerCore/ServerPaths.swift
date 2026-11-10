import Foundation
import Darwin

/// Private on-disk layout owned by the menu bar app.
///
/// Everything the app persists lives below one 0700 directory:
///
///     <data>/config.json            worker configuration (0600)
///     <data>/sam                    RDP account + NT hash (0600)
///     <data>/key.pem, cert.pem      self-signed TLS material (0600)
///     <data>/certificate-addresses  SAN bookkeeping for certificate regeneration
///     <data>/agent.sock             Worker <-> Agent Unix socket (0600)
///     <data>/worker.lease           identity of the worker this app spawned (0600)
///     <data>/agent-generation       monotonically increasing Agent generation
///     <data>/logs/worker.log        Worker stdout/stderr
///     <data>/logs/agent.log         Agent stdout/stderr
///     <data>/logs/app.log           menu app lifecycle events (no secrets)
public struct ServerPaths: Sendable, Equatable {
    /// AF_UNIX sun_path is 104 bytes on macOS, including the terminating NUL.
    public static let maximumSocketPathBytes = 104

    public let dataDirectory: URL

    public init(dataDirectory: URL) {
        self.dataDirectory = dataDirectory.standardizedFileURL
    }

    public var configFile: URL { dataDirectory.appendingPathComponent("config.json") }
    public var samFile: URL { dataDirectory.appendingPathComponent("sam") }
    public var keyFile: URL { dataDirectory.appendingPathComponent("key.pem") }
    public var certificateFile: URL { dataDirectory.appendingPathComponent("cert.pem") }
    public var certificateAddressesFile: URL { dataDirectory.appendingPathComponent("certificate-addresses") }
    public var agentSocket: URL { dataDirectory.appendingPathComponent("agent.sock") }
    public var workerLeaseFile: URL { dataDirectory.appendingPathComponent("worker.lease") }
    public var generationFile: URL { dataDirectory.appendingPathComponent("agent-generation") }
    public var logsDirectory: URL { dataDirectory.appendingPathComponent("logs", isDirectory: true) }
    public var workerLog: URL { logsDirectory.appendingPathComponent("worker.log") }
    public var agentLog: URL { logsDirectory.appendingPathComponent("agent.log") }
    public var appLog: URL { logsDirectory.appendingPathComponent("app.log") }

    public enum ResolutionError: Error, Equatable, CustomStringConvertible, Sendable {
        case notAbsolute(String)
        case notADirectory(String)
        case symbolicLink(String)
        case notOwnedByCurrentUser(String)
        case insecurePermissions(String)
        case socketPathTooLong(Int)
        case filesystem(String)

        public var description: String {
            switch self {
            case .notAbsolute(let path):
                return "data directory must be an absolute path: \(path)"
            case .notADirectory(let path):
                return "data directory is not a directory: \(path)"
            case .symbolicLink(let path):
                return "refusing to use a symbolic link as data directory: \(path)"
            case .notOwnedByCurrentUser(let path):
                return "data directory must be owned by the current user: \(path)"
            case .insecurePermissions(let path):
                return "data directory must have private permissions (0700): \(path)"
            case .socketPathTooLong(let bytes):
                return "agent socket path is \(bytes) bytes; the AF_UNIX limit is \(ServerPaths.maximumSocketPathBytes - 1) bytes"
            case .filesystem(let message):
                return message
            }
        }
    }

    /// Resolves the data directory: explicit URL, then RDPSERVER_DATA_DIR, then
    /// ~/Library/Application Support/RDPServer.
    ///
    /// - Parameter create: create the private directory layout when missing.
    ///   Headless status checks pass false so they never mutate the disk.
    public static func resolve(explicit: URL? = nil,
                               environment: [String: String] = ProcessInfo.processInfo.environment,
                               create: Bool = true) throws -> ServerPaths {
        let paths = ServerPaths(dataDirectory: chooseDirectory(explicit: explicit, environment: environment))
        if create {
            try paths.createPrivateLayout()
        } else {
            try paths.validatePrivateLayout(requireLogs: false)
        }
        try paths.validateSocketPath()
        return paths
    }

    /// Resolves the path only (no filesystem access, no validation). Used by
    /// headless status reporting so a missing or unusable directory still yields
    /// a well-formed JSON object.
    public static func resolveForDisplay(explicit: URL? = nil,
                                         environment: [String: String] = ProcessInfo.processInfo.environment) -> ServerPaths {
        ServerPaths(dataDirectory: chooseDirectory(explicit: explicit, environment: environment))
    }

    private static func chooseDirectory(explicit: URL?,
                                        environment: [String: String]) -> URL {
        if let explicit { return explicit }
        if let value = environment["RDPSERVER_DATA_DIR"], !value.isEmpty,
           value.hasPrefix("/") {
            return URL(fileURLWithPath: value)
        }
        let home: String
        if let value = environment["HOME"], value.hasPrefix("/") {
            home = value
        } else {
            home = NSHomeDirectory()
        }
        return URL(fileURLWithPath: home)
            .appendingPathComponent("Library/Application Support/RDPServer", isDirectory: true)
    }

    public func createPrivateLayout() throws {
        try createPrivateDirectory(dataDirectory, label: "data directory")
        try createPrivateDirectory(logsDirectory, label: "logs directory")
        try validatePrivateLayout(requireLogs: true)
    }

    public func validatePrivateLayout(requireLogs: Bool) throws {
        try validatePrivateDirectory(dataDirectory, label: "data directory")
        if requireLogs || SecureFile.exists(logsDirectory) {
            try validatePrivateDirectory(logsDirectory, label: "logs directory")
        }
    }

    public func validateSocketPath() throws {
        let bytes = agentSocket.path.utf8.count + 1
        guard bytes < Self.maximumSocketPathBytes else {
            throw ResolutionError.socketPathTooLong(bytes)
        }
    }

    /// Removes a stale Agent socket. The Worker's C listener silently refuses to
    /// listen when the path already exists, so this must run before every start
    /// and after every stop.
    public func removeAgentSocket() {
        unlink(agentSocket.path)
    }

    public func removeWorkerLease() {
        unlink(workerLeaseFile.path)
    }

    public var socketExists: Bool { SecureFile.exists(agentSocket) }

    public var hasConfiguration: Bool { SecureFile.exists(configFile) }

    public var hasCredentials: Bool {
        SecureFile.isOwnedRegularFile(samFile, mode: 0o600) && SecureFile.fileSize(at: samFile) > 0
    }

    public var hasCertificates: Bool {
        SecureFile.isOwnedRegularFile(keyFile, mode: 0o600)
            && SecureFile.isOwnedRegularFile(certificateFile, mode: 0o600)
            && SecureFile.fileSize(at: keyFile) > 0
            && SecureFile.fileSize(at: certificateFile) > 0
    }

    private func createPrivateDirectory(_ url: URL, label: String) throws {
        if SecureFile.exists(url) { return }
        do {
            try FileManager.default.createDirectory(
                at: url,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700])
        } catch {
            throw ResolutionError.filesystem("cannot create \(label): \(error.localizedDescription)")
        }
        if Darwin.chmod(url.path, 0o700) != 0 {
            throw ResolutionError.filesystem("cannot set \(label) permissions: errno \(errno)")
        }
    }

    private func validatePrivateDirectory(_ url: URL, label: String) throws {
        var info = stat()
        guard url.path.withCString({ lstat($0, &info) }) == 0 else {
            throw ResolutionError.notADirectory("\(label) is missing: \(url.path)")
        }
        let type = info.st_mode & 0o170000
        if type == 0o120000 {
            throw ResolutionError.symbolicLink("\(label): \(url.path)")
        }
        guard type == 0o040000 else {
            throw ResolutionError.notADirectory("\(label): \(url.path)")
        }
        guard info.st_uid == geteuid() else {
            throw ResolutionError.notOwnedByCurrentUser("\(label): \(url.path)")
        }
        let permissions = info.st_mode & 0o777
        guard permissions & 0o077 == 0, permissions & 0o700 == 0o700 else {
            throw ResolutionError.insecurePermissions("\(label): \(url.path)")
        }
    }
}
