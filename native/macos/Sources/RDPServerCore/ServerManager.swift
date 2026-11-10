import Foundation
import Darwin

/// Thread-safe supervisor for the Go Worker and the Swift desktop Agent.
///
/// Lifecycle:
///
///     disabled -> starting -> running -> stopping -> disabled
///                     \-> error (worker failed / crashed)
///
/// Start removes any stale Agent socket, spawns the Worker, waits up to 10 s for
/// it to listen (TCP connect + "event=listening"), then spawns the Agent with
/// RDP_AGENT_* environment matching scripts/run-agent-stream.sh. Stop kills the
/// Agent first (so it can restore the display arrangement), then the Worker, and
/// unlinks the socket afterwards.
///
/// All state mutation is serialized: control operations take controlLock, the
/// 1 s monitor tick and readers use stateLock. Blocking waits never hold
/// stateLock, and the async API hops to a background queue so callers on the
/// main thread never block on process or subprocess I/O.
public final class ServerManager: @unchecked Sendable {
    public static let readinessTimeout: Double = 10
    public static let agentStopGrace: Double = 5
    /// Must match `stopChild` in cmd/rdp-worker/main.go: the address:auto
    /// supervisor waits this long for its FreeRDP child before SIGKILL.
    public static let lanSupervisorStopGrace: Double = 5
    // Keep the App's grace longer than the supervisor's child-shutdown window
    // so escalation to SIGKILL does not orphan that child.
    public static let workerStopGrace: Double = 10
    public static let agentRestartLimit = 3
    public static let agentRestartWindow: Double = 30
    public static let logRotationBytes: UInt64 = 32 << 20

    public let paths: ServerPaths
    public let helpers: HelperLocator
    public let configurationStore: ConfigurationStore
    public let credentials: CredentialsManager
    public let certificates: CertificateManager

    private let appLog: AppLog
    private let stateLock = NSLock()
    private let controlLock = NSLock()
    private let tailLock = NSLock()
    private let monitorQueue = DispatchQueue(label: "com.rdp-server.core.monitor")
    private var monitorTimer: DispatchSourceTimer?

    // Guarded by stateLock.
    private var serviceState: ServiceState = .disabled
    private var workerProcess: ChildProcess?
    private var agentProcess: ChildProcess?
    private var workerListening = false
    private var listenHost = "127.0.0.1"
    private var configuration: ServerConfiguration
    private var lastError: String?
    private var permissions = PermissionSnapshot()
    private var permissionProbeBusy = false
    private var lastAgentFrameAt: Date?
    private var agentFailed = false
    private var agentDetailText: String?
    private var agentRestartTimes: [Date] = []
    private var generation: UInt64 = 0
    private var maxObservedGeneration: UInt64 = 0
    private var appliedConfiguration: Data?
    private var shuttingDown = false

    // Log offsets owned by the monitor queue.
    private var workerTail: LogTail?
    private var agentTail: LogTail?

    // MARK: - Construction

    public init(dataDirectory: URL? = nil, helpersDirectory: URL? = nil) throws {
        let environment = ProcessInfo.processInfo.environment
        let resolvedPaths: ServerPaths
        do {
            resolvedPaths = try ServerPaths.resolve(explicit: dataDirectory,
                                                    environment: environment,
                                                    create: true)
        } catch {
            throw ServerError.dataDirectory("\(error)")
        }
        self.paths = resolvedPaths
        if let helpersDirectory {
            self.helpers = HelperLocator(helpersDirectory: helpersDirectory, source: .environment)
        } else {
            self.helpers = HelperLocator.resolve(environment: environment)
        }
        self.configurationStore = ConfigurationStore(paths: resolvedPaths)
        self.credentials = CredentialsManager(paths: resolvedPaths, helpers: self.helpers)
        self.certificates = CertificateManager(paths: resolvedPaths)
        self.appLog = AppLog(url: resolvedPaths.appLog)

        var loaded: ServerConfiguration
        var loadError: String?
        do {
            loaded = try configurationStore.loadOrDefault()
        } catch {
            loaded = ServerConfiguration.defaults(for: resolvedPaths)
            loadError = "\(error)"
        }
        if loaded.account.isEmpty, let stored = credentials.storedAccount() {
            loaded.account = stored
        }
        self.configuration = loaded
        self.lastError = loadError
        if loaded.addressMode == .lan, let selected = LANAddress.select() {
            self.listenHost = selected.address
        }
        startMonitor()
    }

    deinit {
        monitorTimer?.cancel()
        stateLock.lock()
        let worker = workerProcess
        let agent = agentProcess
        stateLock.unlock()
        if let agent { agent.terminate(graceSeconds: Self.agentStopGrace) }
        if let worker {
            worker.terminate(graceSeconds: Self.workerStopGrace)
            paths.removeWorkerLease()
        }
        paths.removeAgentSocket()
    }

    // MARK: - Snapshots

    public func snapshot() -> ServerSnapshot {
        stateLock.lock()
        defer { stateLock.unlock() }
        return snapshotLocked()
    }

    private func snapshotLocked() -> ServerSnapshot {
        let samAccount = credentials.storedAccount()
        let account = configuration.account.isEmpty ? samAccount : configuration.account
        let configured = samAccount != nil
            && configurationStore.exists()
            && (configuration.validationError() == nil)
        let currentData = configurationStore.loadData()
        let workerRunning = workerProcess?.isRunning ?? false
        let agentRunning = agentProcess?.isRunning ?? false
        let now = Date()
        var agentState: AgentState = .waiting
        if agentRunning {
            if agentFailed {
                agentState = .failed
            } else if let frameAt = lastAgentFrameAt,
                      now.timeIntervalSince(frameAt) < 5 {
                agentState = .capturing
            }
        } else if agentFailed {
            agentState = .failed
        }
        let detail: String?
        if let agent = agentProcess, agent.isRunning {
            let suffix = agentState == .capturing ? "" : " (waiting for first frame)"
            detail = agentFailed ? agentDetailText : "pid \(agent.pid) generation \(generation)\(suffix)"
        } else {
            detail = agentDetailText
        }
        let address: String?
        if workerListening, workerRunning {
            address = "\(listenHost):\(configuration.port)"
        } else {
            address = nil
        }
        let needsRestart = serviceState == .running && appliedConfiguration != nil
            && appliedConfiguration != currentData
        return ServerSnapshot(
            state: serviceState,
            configured: configured,
            address: address,
            listenHost: listenHost,
            port: configuration.port,
            allowLAN: configuration.allowLAN,
            account: account,
            principal: account.map { ServerManager.principal(for: $0) },
            permissions: permissions,
            agentState: agentState,
            agentDetail: detail,
            workerRunning: workerRunning,
            workerPID: workerRunning ? workerProcess?.pid : nil,
            agentPID: agentRunning ? agentProcess?.pid : nil,
            generation: generation == 0 ? nil : generation,
            needsRestart: needsRestart,
            lastError: lastError,
            legacyLaunchAgentInstalled: LegacyDeployment.launchAgentInstalled(),
            logsDirectory: paths.logsDirectory,
            dataDirectory: paths.dataDirectory)
    }

    // MARK: - Blocking control API (CLI / self-test)

    /// Starts Worker + Agent and returns once the Worker listens (or throws).
    @discardableResult
    public func startNow(timeout: Double = ServerManager.readinessTimeout) throws -> ServerSnapshot {
        controlLock.lock()
        defer { controlLock.unlock() }

        stateLock.lock()
        if shuttingDown {
            stateLock.unlock()
            throw ServerError.notRunning
        }
        let stateNow = serviceState
        stateLock.unlock()
        if stateNow == .running || stateNow == .starting {
            return snapshot()
        }
        if stateNow == .stopping {
            throw ServerError.notReady("service is stopping")
        }

        // A previous App crash can leave a Worker (and its address:auto child)
        // on the same port/socket. Stop it before spawning a replacement. The
        // lease covers this version; the command-line scan also covers Workers
        // started before leases existed.
        let cleanup = StaleWorkerCleanup.run(
            leaseURL: paths.workerLeaseFile,
            configPath: paths.configFile.path,
            graceSeconds: Self.workerStopGrace,
            logger: { [appLog] line in appLog.append(line) })
        if !cleanup.succeeded {
            throw failStaleWorker("a previous Worker is still running (\(cleanup.remaining.count) process(es))")
        }

        // Reload the configuration from disk so external edits are honoured.
        var config: ServerConfiguration
        do {
            config = try configurationStore.loadOrDefault()
        } catch {
            throw failStart("\(error)")
        }
        guard let storedAccount = credentials.storedAccount() else {
            // First run: stay in the disabled state (the UI knows configured=false),
            // do not surface an error for a normal "not set up yet" situation.
            stateLock.lock()
            serviceState = .disabled
            lastError = nil
            stateLock.unlock()
            throw ServerError.notConfigured
        }
        config.account = storedAccount
        if let error = config.validationError() {
            throw failStart(error)
        }
        guard helpers.workerAvailable else {
            throw failStart("required helper is missing: rdp-worker")
        }
        let desiredAddresses = CertificateManager.desiredAddresses(includeLAN: config.addressMode == .lan)
        do {
            try certificates.ensure(addresses: desiredAddresses)
        } catch {
            throw failStart("\(error)")
        }
        do {
            if try configurationStore.loadIfPresent() != config {
                try configurationStore.save(config)
            }
        } catch {
            throw failStart("\(error)")
        }

        // Logs may only be rotated while their writers are stopped.
        LogTail.rotateIfNeeded(paths.workerLog, maximumBytes: Self.logRotationBytes)
        LogTail.rotateIfNeeded(paths.agentLog, maximumBytes: Self.logRotationBytes)
        // The Worker's C listener silently gives up when the socket path exists.
        paths.removeAgentSocket()

        let workerTail = LogTail(url: paths.workerLog)
        workerTail.seekToEnd()
        let worker: ChildProcess
        do {
            var environment = helpers.baseEnvironment
            // The Worker exits (and stops its address:auto FreeRDP child) when
            // this App disappears, including an App crash or SIGKILL.
            environment["RDP_WORKER_MANAGED_BY_APP"] = "1"
            worker = try ChildProcess(
                executable: helpers.workerExecutable,
                arguments: ["-config", paths.configFile.path,
                            "-agent-socket", paths.agentSocket.path],
                environment: environment,
                logURL: paths.workerLog,
                onExit: { [weak self] in self?.scheduleProcessPoll() })
        } catch {
            throw failStart("\(error)")
        }
        writeWorkerLease(worker)
        setWorkerTail(workerTail)

        stateLock.lock()
        serviceState = .starting
        workerProcess = worker
        workerListening = false
        agentFailed = false
        agentDetailText = nil
        agentRestartTimes = []
        lastError = nil
        configuration = config
        appliedConfiguration = configurationStore.loadData()
        listenHost = config.addressMode == .loopback
            ? "127.0.0.1"
            : (LANAddress.select()?.address ?? "127.0.0.1")
        stateLock.unlock()
        appLog.append("event=service_starting address_mode=\(config.addressMode.rawValue) port=\(config.port) allow_lan=\(config.allowLAN ? 1 : 0)")

        switch waitForWorkerReady(worker: worker, config: config, tail: workerTail, timeout: timeout) {
        case .ready(let host):
            stateLock.lock()
            listenHost = host
            workerListening = true
            stateLock.unlock()
        case .failed(let message):
            // The supervised child may still be shutting down; give the
            // supervisor its full window before escalating to SIGKILL.
            worker.terminate(graceSeconds: Self.workerStopGrace)
            paths.removeAgentSocket()
            paths.removeWorkerLease()
            stateLock.lock()
            workerProcess = nil
            workerListening = false
            serviceState = .error
            appliedConfiguration = nil
            lastError = message
            stateLock.unlock()
            appLog.append("event=service_start_failed")
            throw ServerError.workerFailed(message)
        }

        do {
            try spawnAgent(config: config)
        } catch {
            stateLock.lock()
            serviceState = .running
            workerListening = true
            agentFailed = true
            agentDetailText = "\(error)"
            lastError = "\(error)"
            stateLock.unlock()
            appLog.append("event=agent_start_failed")
            return snapshot()
        }
        stateLock.lock()
        serviceState = .running
        workerListening = true
        agentFailed = false
        lastError = nil
        stateLock.unlock()
        appLog.append("event=service_started generation=\(snapshot().generation ?? 0)")
        return snapshot()
    }

    /// Stops Worker + Agent (Agent first), unlinks the socket and returns.
    @discardableResult
    public func stopNow() -> ServerSnapshot {
        controlLock.lock()
        defer { controlLock.unlock() }

        stateLock.lock()
        let agent = agentProcess
        let worker = workerProcess
        let hadChildren = agent != nil || worker != nil
        serviceState = .stopping
        stateLock.unlock()

        if !hadChildren {
            paths.removeAgentSocket()
            stateLock.lock()
            serviceState = .disabled
            workerListening = false
            appliedConfiguration = nil
            agentFailed = false
            agentDetailText = nil
            lastAgentFrameAt = nil
            stateLock.unlock()
            return snapshot()
        }

        // Agent first: it closes the socket and restores the display arrangement.
        if let agent {
            agent.terminate(graceSeconds: Self.agentStopGrace)
            appLog.append("event=agent_stopped status=\(agent.terminationStatus ?? -1)")
        }
        stateLock.lock()
        agentProcess = nil
        agentFailed = false
        agentDetailText = nil
        lastAgentFrameAt = nil
        stateLock.unlock()

        if let worker {
            worker.terminate(graceSeconds: Self.workerStopGrace)
            appLog.append("event=worker_stopped status=\(worker.terminationStatus ?? -1)")
        }
        paths.removeAgentSocket()
        paths.removeWorkerLease()

        stateLock.lock()
        workerProcess = nil
        workerListening = false
        serviceState = .disabled
        appliedConfiguration = nil
        agentRestartTimes = []
        stateLock.unlock()
        appLog.append("event=service_stopped")
        return snapshot()
    }

    /// Recomputes permissions (cached for a few seconds) and log-derived state.
    @discardableResult
    public func refreshNow(forcePermissions: Bool = false) -> ServerSnapshot {
        scanLogsNow()
        let shouldProbe: Bool
        stateLock.lock()
        let checkedAt = permissions.checkedAt
        let busy = permissionProbeBusy
        if busy {
            shouldProbe = false
        } else if forcePermissions {
            shouldProbe = true
        } else if let checkedAt {
            shouldProbe = Date().timeIntervalSince(checkedAt) > 5
        } else {
            shouldProbe = true
        }
        if shouldProbe { permissionProbeBusy = true }
        stateLock.unlock()
        if shouldProbe {
            let probe = PermissionsProbe.query(agentExecutable: helpers.agentExecutable,
                                               environment: helpers.baseEnvironment)
            stateLock.lock()
            permissions = probe
            permissionProbeBusy = false
            stateLock.unlock()
        }
        return snapshot()
    }

    /// Validates, hashes (rdpctl stdin) and persists the account + SAM file.
    /// While running this only marks snapshot.needsRestart; the caller decides
    /// when to show the disconnect warning and restart.
    @discardableResult
    public func saveCredentialsNow(account: String, password: String) throws -> ServerSnapshot {
        try credentials.save(account: account, password: password)
        var config = try configurationStore.loadOrDefault()
        config.account = account
        do {
            try configurationStore.save(config)
        } catch {
            throw ServerError.credentials("\(error)")
        }
        if !paths.hasCertificates {
            do {
                try certificates.ensure(addresses: CertificateManager.desiredAddresses(includeLAN: config.addressMode == .lan))
            } catch {
                throw ServerError.certificate("\(error)")
            }
        }
        stateLock.lock()
        configuration = config
        lastError = nil
        stateLock.unlock()
        appLog.append("event=credentials_saved")
        return snapshot()
    }

    @discardableResult
    public func setAddressModeNow(_ mode: AddressMode) throws -> ServerSnapshot {
        var config = try configurationStore.loadOrDefault()
        guard !config.account.isEmpty else {
            throw ServerError.notConfigured
        }
        config.applyAddressMode(mode)
        do {
            try configurationStore.save(config)
        } catch {
            throw ServerError.invalidConfiguration("\(error)")
        }
        stateLock.lock()
        configuration = config
        stateLock.unlock()
        return snapshot()
    }

    @discardableResult
    public func setPortNow(_ port: Int) throws -> ServerSnapshot {
        guard port >= 1024, port <= 65535 else {
            throw ServerError.invalidConfiguration("port must be 1024...65535")
        }
        var config = try configurationStore.loadOrDefault()
        guard !config.account.isEmpty else {
            throw ServerError.notConfigured
        }
        config.port = port
        do {
            try configurationStore.save(config)
        } catch {
            throw ServerError.invalidConfiguration("\(error)")
        }
        stateLock.lock()
        configuration = config
        stateLock.unlock()
        return snapshot()
    }

    /// Requests the macOS privacy permissions through the Agent bundle identity.
    @discardableResult
    public func requestPermissionsNow() -> PermissionSnapshot {
        let result = PermissionsProbe.request(agentExecutable: helpers.agentExecutable,
                                              environment: helpers.baseEnvironment)
        stateLock.lock()
        permissions = result
        stateLock.unlock()
        appLog.append("event=permissions_requested screen_recording=\(result.screenRecording ? 1 : 0) accessibility=\(result.accessibility ? 1 : 0)")
        if result.desktopReady {
            respawnAgentIfPermissionBlocked()
        }
        return result
    }

    public func shutdownNow() {
        stateLock.lock()
        if shuttingDown {
            stateLock.unlock()
            return
        }
        shuttingDown = true
        stateLock.unlock()
        stopNow()
        monitorTimer?.cancel()
        monitorTimer = nil
    }

    // MARK: - Async API (used by the menu bar UI)

    public func refresh() async -> ServerSnapshot {
        (try? await runOffMain { self.refreshNow() }) ?? snapshot()
    }

    public func start() async -> ServerSnapshot {
        do {
            return try await runOffMain { try self.startNow() }
        } catch {
            return snapshot()
        }
    }

    public func stop() async -> ServerSnapshot {
        (try? await runOffMain { self.stopNow() }) ?? snapshot()
    }

    public func setEnabled(_ enabled: Bool) async -> ServerSnapshot {
        enabled ? await start() : await stop()
    }

    public func restart() async -> ServerSnapshot {
        _ = await stop()
        return await start()
    }

    @discardableResult
    public func saveCredentials(account: String, password: String) async throws -> ServerSnapshot {
        try await runOffMain { try self.saveCredentialsNow(account: account, password: password) }
    }

    @discardableResult
    public func setAddressMode(_ mode: AddressMode) async throws -> ServerSnapshot {
        try await runOffMain { try self.setAddressModeNow(mode) }
    }

    @discardableResult
    public func setPort(_ port: Int) async throws -> ServerSnapshot {
        try await runOffMain { try self.setPortNow(port) }
    }

    public func requestPermissions() async -> PermissionSnapshot {
        (try? await runOffMain { self.requestPermissionsNow() }) ?? PermissionSnapshot()
    }

    public func shutdown() async {
        _ = try? await runOffMain { self.shutdownNow() }
    }

    // MARK: - Utilities exposed for the UI and CLI

    public func recentLogLines(limit: Int = 100) -> [String] {
        LogTail.tailLines(of: paths.workerLog, limit: limit)
    }

    public func recentAgentLogLines(limit: Int = 100) -> [String] {
        LogTail.tailLines(of: paths.agentLog, limit: limit)
    }

    public func openLogsDirectory() -> Bool {
        PermissionsProbe.open(paths.logsDirectory)
    }

    public func openDataDirectory() -> Bool {
        PermissionsProbe.open(paths.dataDirectory)
    }

    public func openSystemSettings(_ pane: PrivacyPane) -> Bool {
        PermissionsProbe.open(pane.settingsURL)
    }

    public static func validateUsername(_ value: String) -> CredentialValidationError? {
        CredentialsManager.validateAccount(value)
    }

    public static func validatePassword(_ value: String) -> CredentialValidationError? {
        CredentialsManager.validatePassword(value)
    }

    public static func principal(for account: String) -> String {
        "MACRDP\\" + account
    }

    // MARK: - Worker identity / cleanup

    /// Records the Worker identity for the next start after a crash/SIGKILL.
    private func writeWorkerLease(_ worker: ChildProcess) {
        guard let lease = WorkerLease.capture(pid: worker.pid) else {
            appLog.append("event=worker_lease_failed pid=\(worker.pid) reason=identity")
            return
        }
        do {
            try lease.write(to: paths.workerLeaseFile)
            appLog.append("event=worker_lease_written pid=\(worker.pid)")
        } catch {
            appLog.append("event=worker_lease_failed pid=\(worker.pid) reason=write")
        }
    }

    // MARK: - Agent supervision

    private func spawnAgent(config: ServerConfiguration) throws {
        guard let agentExecutable = helpers.agentExecutable else {
            throw ServerError.helperMissing("RDPAgent.app/Contents/MacOS/rdp-agent")
        }
        LogTail.rotateIfNeeded(paths.agentLog, maximumBytes: Self.logRotationBytes)
        let nextGeneration = nextAgentGeneration()
        var environment = helpers.baseEnvironment
        environment["RDP_AGENT_NO_PERMISSION_REQUEST"] = "1"
        environment["RDP_AGENT_DELTA_FRAMES"] = "1"
        environment["RDP_AGENT_CAPTURE_STREAM"] = "1"
        environment["RDP_AGENT_TARGET_FPS"] = "60"
        environment["RDP_AGENT_VIRTUAL_DISPLAY"] = "1"
        let tail = LogTail(url: paths.agentLog)
        tail.seekToEnd()
        let agent: ChildProcess
        do {
            agent = try ChildProcess(
                executable: agentExecutable,
                arguments: ["stream-snapshot", paths.agentSocket.path, "0", "0", String(nextGeneration)],
                environment: environment,
                logURL: paths.agentLog,
                onExit: { [weak self] in self?.scheduleProcessPoll() })
        } catch {
            throw ServerError.agentFailed("\(error)")
        }
        do {
            try SecureFile.writeString("\(nextGeneration)\n", to: paths.generationFile, mode: 0o600)
        } catch {
            // Advisory only; the Agent also accepts a larger generation from the log.
        }
        setAgentTail(tail)
        stateLock.lock()
        agentProcess = agent
        generation = nextGeneration
        maxObservedGeneration = max(maxObservedGeneration, nextGeneration)
        lastAgentFrameAt = nil
        agentFailed = false
        agentDetailText = nil
        stateLock.unlock()
        appLog.append("event=agent_started generation=\(nextGeneration)")
    }

    private func respawnAgentIfPermissionBlocked() {
        stateLock.lock()
        let shouldRespawn = serviceState == .running && agentFailed
        let config = configuration
        stateLock.unlock()
        guard shouldRespawn else { return }
        controlLock.lock()
        defer { controlLock.unlock() }
        stateLock.lock()
        let stillNeeded = serviceState == .running && agentFailed
        stateLock.unlock()
        guard stillNeeded else { return }
        do {
            try spawnAgent(config: config)
            stateLock.lock()
            agentFailed = false
            lastError = nil
            stateLock.unlock()
        } catch {
            stateLock.lock()
            agentDetailText = "\(error)"
            lastError = "\(error)"
            stateLock.unlock()
        }
    }

    private func nextAgentGeneration() -> UInt64 {
        var maximum: UInt64 = 0
        if let text = try? SecureFile.readString(at: paths.generationFile, maxBytes: 64),
           let value = UInt64(text.trimmingCharacters(in: .whitespacesAndNewlines)) {
            maximum = value
        }
        stateLock.lock()
        maximum = max(maximum, maxObservedGeneration)
        stateLock.unlock()
        // Survive a deleted generation file: the Worker log records accepted
        // generations, and the Agent rejects stale generations.
        for line in LogTail.tailLines(of: paths.workerLog, limit: 4000, maximumBytes: 512 << 10) {
            for token in line.split(separator: " ") where token.hasPrefix("generation=") {
                if let value = UInt64(token.dropFirst("generation=".count)) {
                    maximum = max(maximum, value)
                }
            }
        }
        return maximum + 1
    }

    // MARK: - Monitoring

    private func startMonitor() {
        let timer = DispatchSource.makeTimerSource(queue: monitorQueue)
        timer.schedule(deadline: .now() + 1, repeating: 1, leeway: .milliseconds(200))
        timer.setEventHandler { [weak self] in self?.tick() }
        timer.resume()
        monitorTimer = timer
    }

    private func scheduleProcessPoll() {
        monitorQueue.async { [weak self] in
            self?.tickProcesses()
        }
    }

    private func tick() {
        stateLock.lock()
        let shutting = shuttingDown
        stateLock.unlock()
        if shutting { return }
        tickProcesses()
        tickScanLogs()
    }

    private func tickProcesses() {
        stateLock.lock()
        let worker = workerProcess
        let agent = agentProcess
        let service = serviceState
        stateLock.unlock()
        if service != .running { return }
        if let worker, !worker.isRunning {
            handleWorkerExit(worker)
            return
        }
        if let agent, !agent.isRunning {
            handleAgentExit(agent)
        }
    }

    private func handleWorkerExit(_ worker: ChildProcess) {
        controlLock.lock()
        defer { controlLock.unlock() }
        stateLock.lock()
        guard workerProcess === worker else {
            stateLock.unlock()
            return
        }
        workerProcess = nil
        workerListening = false
        serviceState = .error
        appliedConfiguration = nil
        let agent = agentProcess
        agentProcess = nil
        stateLock.unlock()

        if let agent {
            // Give the Agent its full window to restore the display layout
            // before escalating to SIGKILL.
            agent.terminate(graceSeconds: Self.agentStopGrace)
        }
        paths.removeAgentSocket()
        paths.removeWorkerLease()
        let status = worker.terminationStatus.map(String.init) ?? "unknown"
        let tail = LogTail.tailLines(of: paths.workerLog, limit: 12)
            .filter { $0.contains("event=") }
            .suffix(4)
            .joined(separator: " | ")
        let message = "worker exited unexpectedly (status \(status))\(tail.isEmpty ? "" : ": " + tail)"
        stateLock.lock()
        lastError = message
        agentFailed = false
        agentRestartTimes = []
        stateLock.unlock()
        appLog.append("event=worker_exited_unexpectedly status=\(status)")
    }

    private func handleAgentExit(_ agent: ChildProcess) {
        controlLock.lock()
        defer { controlLock.unlock() }
        stateLock.lock()
        guard agentProcess === agent, serviceState == .running else {
            stateLock.unlock()
            return
        }
        agentProcess = nil
        lastAgentFrameAt = nil
        let now = Date()
        agentRestartTimes = agentRestartTimes.filter { now.timeIntervalSince($0) < Self.agentRestartWindow }
        let attempts = agentRestartTimes.count
        let config = configuration
        stateLock.unlock()

        if attempts >= Self.agentRestartLimit {
            let tail = LogTail.tailLines(of: paths.agentLog, limit: 12)
                .filter { $0.contains("event=") || $0.lowercased().contains("error") }
                .suffix(4)
                .joined(separator: " | ")
            let message = "desktop agent exited \(attempts + 1) times within \(Int(Self.agentRestartWindow))s; giving up\(tail.isEmpty ? "" : ": " + tail)"
            stateLock.lock()
            agentFailed = true
            agentDetailText = message
            lastError = message
            stateLock.unlock()
            appLog.append("event=agent_restart_exhausted attempts=\(attempts + 1)")
            return
        }
        stateLock.lock()
        agentRestartTimes.append(now)
        stateLock.unlock()
        usleep(300_000)
        do {
            try spawnAgent(config: config)
            appLog.append("event=agent_restarted attempt=\(attempts + 1)")
        } catch {
            stateLock.lock()
            agentFailed = true
            agentDetailText = "\(error)"
            lastError = "\(error)"
            stateLock.unlock()
            appLog.append("event=agent_restart_failed")
        }
    }

    private func setWorkerTail(_ tail: LogTail) {
        tailLock.lock()
        workerTail = tail
        tailLock.unlock()
    }

    private func setAgentTail(_ tail: LogTail) {
        tailLock.lock()
        agentTail = tail
        tailLock.unlock()
    }

    private func pollTails() -> (worker: [String], agent: [String]) {
        tailLock.lock()
        let worker = workerTail
        let agent = agentTail
        tailLock.unlock()
        return (worker?.poll() ?? [], agent?.poll() ?? [])
    }

    /// Runs on the monitor queue only (single reader per log file).
    private func tickScanLogs() {
        let (workerLines, agentLines) = pollTails()
        guard !workerLines.isEmpty || !agentLines.isEmpty else { return }
        var frames = 0
        var lanHost: String?
        var observedGeneration: UInt64 = 0
        for line in workerLines {
            if line.contains("event=agent_frame_received") { frames += 1 }
            if line.contains("event=lan_address_selected") || line.contains("event=lan_worker_started") {
                if let address = ServerManager.fieldValue(in: line, key: "address=") {
                    lanHost = address
                }
            } else if line.contains("event=lan_address_changed") {
                if let address = ServerManager.fieldValue(in: line, key: "new=") {
                    lanHost = address
                }
            }
            for token in line.split(separator: " ") where token.hasPrefix("generation=") {
                if let value = UInt64(token.dropFirst("generation=".count)) {
                    observedGeneration = max(observedGeneration, value)
                }
            }
        }
        var agentError: String?
        for line in agentLines where line.contains("event=") {
            if line.contains("error=") || line.contains("event=capture_stream_error") {
                agentError = line
            }
        }
        stateLock.lock()
        if frames > 0 { lastAgentFrameAt = Date() }
        if let lanHost { listenHost = lanHost }
        if observedGeneration > maxObservedGeneration {
            maxObservedGeneration = observedGeneration
        }
        if let agentError, agentFailed {
            agentDetailText = agentError
        }
        stateLock.unlock()
    }

    private func scanLogsNow() {
        monitorQueue.sync { self.tickScanLogs() }
    }

    // MARK: - Readiness

    private enum Readiness {
        case ready(String)
        case failed(String)
    }

    private func waitForWorkerReady(worker: ChildProcess,
                                    config: ServerConfiguration,
                                    tail: LogTail,
                                    timeout: Double) -> Readiness {
        let deadline = Date().addingTimeInterval(timeout)
        var host = config.addressMode == .loopback
            ? "127.0.0.1"
            : (LANAddress.select()?.address ?? "")
        while Date() < deadline {
            if !worker.isRunning {
                let status = worker.terminationStatus.map(String.init) ?? "unknown"
                let tailText = LogTail.tailLines(of: paths.workerLog, limit: 12)
                    .filter { $0.contains("event=") || $0.lowercased().contains("error") }
                    .suffix(4)
                    .joined(separator: " | ")
                return .failed("worker exited during startup (status \(status))\(tailText.isEmpty ? "" : ": " + tailText)")
            }
            for line in tail.poll() {
                if line.contains("event=lan_address_selected") || line.contains("event=lan_worker_started"),
                   let address = ServerManager.fieldValue(in: line, key: "address=") {
                    host = address
                }
                if line.contains("event=lan_address_changed"),
                   let address = ServerManager.fieldValue(in: line, key: "new=") {
                    host = address
                }
            }
            if host.isEmpty {
                host = config.addressMode == .loopback
                    ? "127.0.0.1"
                    : (LANAddress.select()?.address ?? "")
            }
            // Dual confirmation: the Worker logs event=listening and the port
            // accepts a TCP connection. The connect check alone is enough, but
            // the log event is kept for diagnostics in the failure message.
            if !host.isEmpty, ServerManager.tcpConnectable(host: host, port: config.port) {
                return .ready(host)
            }
            usleep(100_000)
        }
        let tailText = LogTail.tailLines(of: paths.workerLog, limit: 15)
            .filter { $0.contains("event=") }
            .suffix(5)
            .joined(separator: " | ")
        let target = host.isEmpty ? "the configured address" : host
        return .failed("worker did not start listening on \(target):\(config.port) within \(Int(timeout))s\(tailText.isEmpty ? "" : ": " + tailText)")
    }

    private func failStart(_ message: String) -> ServerError {
        stateLock.lock()
        serviceState = .error
        lastError = message
        appliedConfiguration = nil
        stateLock.unlock()
        appLog.append("event=service_start_rejected")
        return .invalidConfiguration(message)
    }

    private func failStaleWorker(_ message: String) -> ServerError {
        stateLock.lock()
        serviceState = .error
        lastError = message
        appliedConfiguration = nil
        stateLock.unlock()
        appLog.append("event=stale_worker_cleanup_failed")
        return .workerFailed(message)
    }

    // MARK: - Helpers

    private func runOffMain<T>(_ body: @escaping () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<T, Error>) in
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    continuation.resume(returning: try body())
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    static func fieldValue(in line: String, key: String) -> String? {
        for token in line.split(separator: " ") where token.hasPrefix(key) {
            let value = token.dropFirst(key.count)
            if !value.isEmpty { return String(value) }
        }
        return nil
    }

    private static func tcpConnectable(host: String, port: Int, timeout: Double = 0.2) -> Bool {
        guard port >= 1, port <= 65535 else { return false }
        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = in_port_t(UInt16(port)).bigEndian
        guard host.withCString({ inet_pton(AF_INET, $0, &address.sin_addr) }) == 1 else {
            return false
        }
        let descriptor = socket(AF_INET, SOCK_STREAM, 0)
        guard descriptor >= 0 else { return false }
        defer { close(descriptor) }
        let flags = fcntl(descriptor, F_GETFL, 0)
        _ = fcntl(descriptor, F_SETFL, flags | O_NONBLOCK)
        let connected = withUnsafePointer(to: &address) { pointer -> Int32 in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { socketAddress in
                connect(descriptor, socketAddress, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        if connected == 0 { return true }
        guard errno == EINPROGRESS else { return false }
        var pollDescriptor = pollfd(fd: descriptor, events: Int16(POLLOUT), revents: 0)
        let milliseconds = Int32(timeout * 1000)
        let ready = poll(&pollDescriptor, 1, milliseconds)
        guard ready > 0 else { return false }
        var socketError: Int32 = 0
        var length = socklen_t(MemoryLayout<Int32>.size)
        guard getsockopt(descriptor, SOL_SOCKET, SO_ERROR, &socketError, &length) == 0 else {
            return false
        }
        return socketError == 0
    }
}
