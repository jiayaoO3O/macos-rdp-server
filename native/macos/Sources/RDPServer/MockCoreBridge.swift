import Foundation

/// Dev-only bridge (RDPSERVER_UI_MOCK=1) that simulates the service lifecycle so
/// the UI can be built and screenshot-verified without starting the real worker
/// or agent and without reading .runtime. It is never used in a packaged run.
@MainActor
final class MockCoreBridge: ServerCoreBridge {
    private var snapshot: AppSnapshot

    var currentSnapshot: AppSnapshot { snapshot }

    init(dataDirectory: URL,
         running: Bool = false,
         permissionsGranted: Bool = false,
         agentFailed: Bool = false) {
        var initial = AppSnapshot()
        initial.dataDirectory = dataDirectory
        initial.logsDirectory = dataDirectory.appendingPathComponent("logs", isDirectory: true)
        initial.account = "rdpuser"
        initial.principal = "MACRDP\\rdpuser"
        initial.permissions = UIPermissions(screenRecording: permissionsGranted,
                                            accessibility: permissionsGranted,
                                            available: true)
        initial.legacyLaunchAgentInstalled = false
        if running || agentFailed {
            initial.state = .running
            initial.allowLAN = true
            initial.listenHost = "192.0.2.10"
            initial.address = "192.0.2.10:3389"
            initial.workerRunning = true
            initial.workerPID = 4242
            initial.agentState = agentFailed ? .failed : .capturing
            initial.agentDetail = agentFailed ? "虚拟显示器创建失败，已回退" : "pid 4343 generation 7"
            initial.workerPID = 4242
            initial.agentPID = agentFailed ? nil : 4343
            initial.lastError = agentFailed ? "Agent 帧超时，等待重连" : nil
        }
        snapshot = initial
    }

    func fetchSnapshot() async -> AppSnapshot { snapshot }

    func setEnabled(_ enabled: Bool) async throws {
        if enabled {
            snapshot.state = .starting
            try? await Task.sleep(nanoseconds: 600_000_000)
            snapshot.state = .running
            snapshot.workerRunning = true
            snapshot.workerPID = 4242
            snapshot.agentPID = 4343
            snapshot.listenHost = snapshot.allowLAN ? "192.0.2.10" : "127.0.0.1"
            snapshot.address = "\(snapshot.listenHost):\(snapshot.port)"
            snapshot.agentState = .capturing
            snapshot.agentDetail = "pid 4343 generation 8"
            snapshot.lastError = nil
        } else {
            snapshot.state = .stopping
            try? await Task.sleep(nanoseconds: 400_000_000)
            snapshot.state = .disabled
            snapshot.workerRunning = false
            snapshot.workerPID = nil
            snapshot.agentPID = nil
            snapshot.agentState = .waiting
            snapshot.agentDetail = nil
            snapshot.address = nil
        }
    }

    func setAllowLAN(_ enabled: Bool) async throws {
        snapshot.allowLAN = enabled
        snapshot.listenHost = enabled ? "192.0.2.10" : "127.0.0.1"
        if snapshot.state == .running {
            snapshot.address = "\(snapshot.listenHost):\(snapshot.port)"
            snapshot.needsRestart = true
            try? await Task.sleep(nanoseconds: 500_000_000)
        }
    }

    func setPort(_ port: Int) async throws {
        guard port >= 1024, port <= 65535 else {
            throw BridgeError.validation("端口需在 1024–65535 之间")
        }
        snapshot.port = port
        if snapshot.state == .running {
            snapshot.address = "\(snapshot.listenHost):\(snapshot.port)"
            snapshot.needsRestart = true
            try? await Task.sleep(nanoseconds: 500_000_000)
        }
    }

    func saveCredentials(username: String, password: String) async throws {
        if let message = CredentialRules.usernameError(username) {
            throw BridgeError.validation(message)
        }
        if let message = CredentialRules.passwordError(password) {
            throw BridgeError.validation(message)
        }
        try? await Task.sleep(nanoseconds: 300_000_000)
        snapshot.account = username.lowercased()
        snapshot.principal = "MACRDP\\" + username.lowercased()
        snapshot.configured = true
        if snapshot.state == .running {
            snapshot.needsRestart = true
        }
    }

    func restart() async throws {
        let wasRunning = snapshot.state == .running
        guard wasRunning else { return }
        snapshot.state = .starting
        try? await Task.sleep(nanoseconds: 700_000_000)
        snapshot.state = .running
        snapshot.needsRestart = false
        snapshot.address = "\(snapshot.listenHost):\(snapshot.port)"
        snapshot.agentState = .capturing
    }

    func requestPermissions() async {
        try? await Task.sleep(nanoseconds: 500_000_000)
        snapshot.permissions = UIPermissions(screenRecording: true, accessibility: true, available: true)
    }

    func shutdown() async {
        snapshot.state = .disabled
        snapshot.workerRunning = false
        snapshot.workerPID = nil
        snapshot.agentPID = nil
    }
}
