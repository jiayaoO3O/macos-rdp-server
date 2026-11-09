import Foundation
import Darwin

/// Result of the headless self test (RDPServer --self-test).
public struct SelfTestReport: Codable, Sendable {
    public struct Check: Codable, Sendable {
        public var name: String
        public var ok: Bool
        public var detail: String?

        public init(name: String, ok: Bool, detail: String?) {
            self.name = name
            self.ok = ok
            self.detail = detail
        }
    }

    public var ok: Bool
    public var checks: [Check]
    public var dataDirectory: String?
    public var startedService: Bool
    public var error: String?

    enum CodingKeys: String, CodingKey {
        case ok
        case checks
        case dataDirectory = "data_directory"
        case startedService = "started_service"
        case error
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(ok, forKey: .ok)
        try container.encode(checks, forKey: .checks)
        try container.encode(dataDirectory, forKey: .dataDirectory)
        try container.encode(startedService, forKey: .startedService)
        try container.encode(error, forKey: .error)
    }

    public func jsonData() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(self)
    }

    public func jsonString() throws -> String {
        String(decoding: try jsonData(), as: UTF8.self)
    }
}

/// Headless self test for the menu bar app core.
///
/// Uses an isolated data directory (a private temp directory when the caller
/// does not pass one), generated certificate, random account/password, and a
/// free loopback port. It never touches the repo .runtime, never overwrites
/// bin/, and never starts the service unless startService is requested.
///
/// Check names are grouped so a packaging verifier can assert different
/// subsets on different machines:
///
///     helpers.*      helper binary resolution (worker, rdpctl, agent, openssl)
///     paths.*        private data directory, socket path, log directory
///     certificate.*  self-signed TLS material and SAN
///     credentials.*  SAM written through rdpctl stdin, mode, format
///     config.*       config.json round-trip, absolute paths, no secrets
///     agent.*        permission query through the Agent bundle identity
///     secrets.*      no plaintext password, hash only in the SAM file
///     worker.*       optional: Worker starts and listens (startService)
///     agent.frames   optional: Agent frames flow; skipped (ok) when the
///                    Screen Recording / Accessibility permissions are missing
///     cleanup.*      optional: no leftover children / socket after stop
public enum SelfTest {
    public static func run(dataDirectory: URL? = nil,
                           helpersDirectory: URL? = nil,
                           startService: Bool = false,
                           environment: [String: String] = ProcessInfo.processInfo.environment) -> SelfTestReport {
        var checks: [SelfTestReport.Check] = []
        var createdTemporaryDirectory = false

        func add(_ name: String, _ ok: Bool, _ detail: String? = nil) {
            checks.append(SelfTestReport.Check(name: name, ok: ok, detail: detail))
        }

        let directory: URL
        if let dataDirectory {
            directory = dataDirectory
        } else {
            directory = SelfTest.makeTemporaryDirectory()
            createdTemporaryDirectory = true
        }
        defer {
            if createdTemporaryDirectory {
                try? FileManager.default.removeItem(at: directory)
            }
        }

        let helpers: HelperLocator
        if let helpersDirectory {
            helpers = HelperLocator(helpersDirectory: helpersDirectory, source: .environment)
        } else {
            helpers = HelperLocator.resolve(environment: environment)
        }
        add("helpers.directory", SecureFile.exists(helpers.helpersDirectory), helpers.summary)
        add("helpers.rdp-worker", helpers.workerAvailable, helpers.workerExecutable.path)
        add("helpers.rdpctl", helpers.rdpctlAvailable, helpers.rdpctlExecutable.path)
        add("helpers.agent", helpers.agentAvailable, helpers.agentExecutable?.path ?? "not found")
        add("helpers.openssl", helpers.opensslAvailable, HelperLocator.opensslExecutable.path)

        let paths: ServerPaths
        do {
            paths = try ServerPaths.resolve(explicit: directory, create: true)
        } catch {
            add("paths.data_directory", false, "\(error)")
            return report(checks: checks, directory: directory, startedService: false,
                          error: "\(error)")
        }
        add("paths.data_directory_mode", SecureFile.fileMode(at: paths.dataDirectory) == 0o700,
            String(format: "%03o", SecureFile.fileMode(at: paths.dataDirectory) ?? 0))
        add("paths.data_directory_owner", SecureFile.ownerID(at: paths.dataDirectory) == geteuid(), "current user")
        add("paths.logs_mode", SecureFile.fileMode(at: paths.logsDirectory) == 0o700,
            String(format: "%03o", SecureFile.fileMode(at: paths.logsDirectory) ?? 0))
        add("paths.socket_length",
            paths.agentSocket.path.utf8.count + 1 < ServerPaths.maximumSocketPathBytes,
            "\(paths.agentSocket.path.utf8.count + 1) bytes < \(ServerPaths.maximumSocketPathBytes)")

        // TLS material.
        let certificates = CertificateManager(paths: paths)
        do {
            let addresses = try certificates.ensure(addresses: ["127.0.0.1"])
            add("certificate.generated", paths.hasCertificates, addresses.joined(separator: ","))
            add("certificate.key_mode", SecureFile.fileMode(at: paths.keyFile) == 0o600, "0600")
            add("certificate.cert_mode", SecureFile.fileMode(at: paths.certificateFile) == 0o600, "0600")
            let sans = certificates.sanAddresses() ?? []
            add("certificate.san_loopback", sans.contains("127.0.0.1"), sans.joined(separator: ","))
        } catch {
            add("certificate.generation", false, "\(error)")
        }

        // Credentials through rdpctl stdin; never persisted as plaintext.
        let account = "selftest\(String(format: "%04x", UInt32.random(in: 0...0xFFFF)))"
        let password = "Selftest-\(UUID().uuidString.replacingOccurrences(of: "-", with: ""))"
        let credentials = CredentialsManager(paths: paths, helpers: helpers)
        var samText: String?
        var ntHash: String?
        do {
            try credentials.save(account: account, password: password)
            samText = (try? SecureFile.readString(at: paths.samFile, maxBytes: 8192)) ?? ""
            add("credentials.sam_saved", samText != nil, nil)
            add("credentials.sam_mode", SecureFile.fileMode(at: paths.samFile) == 0o600, "0600")
            let fields = (samText ?? "").split(separator: ":", omittingEmptySubsequences: false)
            ntHash = fields.count > 3 ? String(fields[3]) : nil
            if let ntHash {
                add("credentials.hash_format", CredentialsManager.isValidNTHash(ntHash), "32 hex")
            } else {
                add("credentials.hash_format", false, "no hash field")
            }
            add("credentials.sam_account", (samText ?? "").hasPrefix("\(account):MACRDP::"), account)
            add("credentials.account_roundtrip", credentials.storedAccount() == account, account)
        } catch {
            add("credentials.save", false, "\(error)")
        }

        // Worker configuration on a free loopback port.
        let store = ConfigurationStore(paths: paths)
        var configuration = ServerConfiguration.defaults(for: paths)
        configuration.account = account
        let port = freeTCPPort() ?? 34123
        configuration.port = port
        do {
            try store.save(configuration)
            let loaded = try store.loadIfPresent()
            add("config.written", loaded != nil, nil)
            add("config.mode", SecureFile.fileMode(at: paths.configFile) == 0o600, "0600")
            add("config.loadable", loaded == configuration, "round-trip")
            add("config.loopback",
                loaded?.address == "127.0.0.1" && loaded?.allowLAN == false,
                loaded.map { "address=\($0.address) allow_lan=\($0.allowLAN)" } ?? "missing")
            add("config.absolute_paths",
                loaded?.sam.hasPrefix("/") == true
                    && loaded?.key.hasPrefix("/") == true
                    && loaded?.certificate.hasPrefix("/") == true,
                nil)
            add("config.no_secrets",
                !((try? SecureFile.readString(at: paths.configFile, maxBytes: 8192)) ?? "").contains(password),
                "no plaintext password")
        } catch {
            add("config.write", false, "\(error)")
        }

        // Permission query through the Agent bundle identity (no prompts).
        let permissionQuery = PermissionsProbe.query(agentExecutable: helpers.agentExecutable,
                                                     environment: helpers.baseEnvironment)
        add("agent.permission_query", permissionQuery.isAvailable,
            permissionQuery.lastError ?? permissionQuery.summary)
        if startService {
            do {
                let manager = try ServerManager(dataDirectory: paths.dataDirectory,
                                                helpersDirectory: helpers.helpersDirectory)
                do {
                    let started = try manager.startNow(timeout: 25)
                    add("worker.started", started.state == .running, started.state.rawValue)
                    add("worker.listening", started.address != nil, started.address ?? "not listening")
                    if let address = started.address {
                        add("worker.tcp_connect", tcpConnectable(address: address), address)
                    } else {
                        add("worker.tcp_connect", false, "no address")
                    }
                    let refreshed = manager.refreshNow()
                    if refreshed.permissions.desktopReady {
                        var captured = false
                        let deadline = Date().addingTimeInterval(20)
                        while Date() < deadline {
                            let polled = manager.refreshNow()
                            if polled.agentState == .capturing {
                                captured = true
                                break
                            }
                            if polled.state != .running { break }
                            usleep(250_000)
                        }
                        let running = manager.snapshot()
                        add("agent.frames", captured, running.agentDetail ?? "no frames observed")
                    } else {
                        // Explicitly skipped rather than failed: permissions are a
                        // per-machine state, and the app requests them from the UI.
                        add("agent.frames", true,
                            "skipped: \(refreshed.permissions.summary) (grant permissions in the app)")
                    }
                    let stopped = manager.stopNow()
                    add("cleanup.state", stopped.state == .disabled && !stopped.workerRunning,
                        stopped.state.rawValue)
                    add("cleanup.no_running_pids", stopped.workerPID == nil && stopped.agentPID == nil, nil)
                    add("cleanup.socket_removed", !paths.socketExists, nil)
                } catch {
                    add("worker.start", false, "\(error)")
                    _ = manager.stopNow()
                }
                manager.shutdownNow()
            } catch {
                add("worker.manager", false, "\(error)")
            }
        }

        // Leak scan must run last: it also covers the logs written by the
        // optional lifecycle part.
        var files: [URL] = []
        if let enumerator = FileManager.default.enumerator(at: paths.dataDirectory,
                                                           includingPropertiesForKeys: nil) {
            for case let url as URL in enumerator where SecureFile.isRegularFile(url) {
                files.append(url)
            }
        }
        var plaintextLeakFile: String?
        var hashLeakFile: String?
        let passwordBytes = Data(password.utf8)
        let hashBytes = ntHash.flatMap { Data($0.utf8) }
        for file in files {
            guard SecureFile.fileSize(at: file) <= 8 << 20 else { continue }
            guard let data = try? Data(contentsOf: file) else { continue }
            if data.range(of: passwordBytes) != nil {
                plaintextLeakFile = file.lastPathComponent
            }
            if let hashBytes, file.lastPathComponent != "sam",
               data.range(of: hashBytes) != nil {
                hashLeakFile = file.lastPathComponent
            }
        }
        add("secrets.no_plaintext_password", plaintextLeakFile == nil, plaintextLeakFile ?? "clean")
        add("secrets.hash_only_in_sam", hashLeakFile == nil, hashLeakFile ?? "clean")

        var fileModeFailures: [String] = []
        for file in files where SecureFile.fileMode(at: file) != 0o600 {
            fileModeFailures.append(file.lastPathComponent)
        }
        add("paths.files_private", fileModeFailures.isEmpty,
            fileModeFailures.isEmpty ? "\(files.count) files" : fileModeFailures.joined(separator: ","))

        return report(checks: checks, directory: directory, startedService: startService, error: nil)
    }

    /// Short-lived private directory for the self test. Prefers /tmp because the
    /// data directory path also holds the AF_UNIX socket, which must stay below
    /// the 104-byte sun_path limit even when TMPDIR is deeply nested.
    private static func makeTemporaryDirectory() -> URL {
        let name = "rdp-selftest-\(UUID().uuidString.prefix(8))"
        for base in [URL(fileURLWithPath: "/tmp"), FileManager.default.temporaryDirectory] {
            let candidate = base.appendingPathComponent(name, isDirectory: true)
            if candidate.appendingPathComponent("agent.sock").path.utf8.count + 1
                < ServerPaths.maximumSocketPathBytes {
                return candidate
            }
        }
        return FileManager.default.temporaryDirectory.appendingPathComponent(name, isDirectory: true)
    }

    private static func report(checks: [SelfTestReport.Check],
                               directory: URL,
                               startedService: Bool,
                               error: String?) -> SelfTestReport {
        let ok = checks.allSatisfy { $0.ok } && error == nil
        return SelfTestReport(ok: ok,
                              checks: checks,
                              dataDirectory: directory.path,
                              startedService: startedService,
                              error: error)
    }

    private static func freeTCPPort() -> Int? {
        let descriptor = socket(AF_INET, SOCK_STREAM, 0)
        guard descriptor >= 0 else { return nil }
        defer { close(descriptor) }
        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = 0
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        let bound = withUnsafePointer(to: &address) { pointer -> Int32 in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { socketAddress in
                bind(descriptor, socketAddress, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bound == 0 else { return nil }
        var local = sockaddr_in()
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let named = withUnsafeMutablePointer(to: &local) { pointer -> Int32 in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { socketAddress in
                getsockname(descriptor, socketAddress, &length)
            }
        }
        guard named == 0 else { return nil }
        let port = Int(UInt16(bigEndian: local.sin_port))
        return port >= 1024 ? port : nil
    }

    private static func tcpConnectable(address: String) -> Bool {
        let parts = address.split(separator: ":")
        guard parts.count == 2, let port = Int(parts[1]) else { return false }
        let host = String(parts[0])
        var target = sockaddr_in()
        target.sin_family = sa_family_t(AF_INET)
        target.sin_port = in_port_t(UInt16(port)).bigEndian
        guard host.withCString({ inet_pton(AF_INET, $0, &target.sin_addr) }) == 1 else { return false }
        let descriptor = socket(AF_INET, SOCK_STREAM, 0)
        guard descriptor >= 0 else { return false }
        defer { close(descriptor) }
        return withUnsafePointer(to: &target) { pointer -> Bool in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { socketAddress in
                connect(descriptor, socketAddress, socklen_t(MemoryLayout<sockaddr_in>.size)) == 0
            }
        }
    }
}
