import Foundation
import RDPServerCore

/// Live implementation of the UI contract on top of RDPServerCore.ServerManager.
/// This file is the ONLY place that imports the core: the view layer sees the
/// UI mirror types (AppSnapshot / UIServiceState / UIPermissions) instead.
@MainActor
final class LiveCoreBridge: ServerCoreBridge {
    private let manager: ServerManager

    /// - Parameter dataDirectory: explicit data directory (--data-dir), or nil to
    ///   let the core resolve RDPSERVER_DATA_DIR / the default location.
    init(dataDirectory: URL?) throws {
        manager = try ServerManager(dataDirectory: dataDirectory)
    }

    /// Cheap synchronous snapshot for the initial UI frame; does no process IO.
    func snapshotNow() -> AppSnapshot {
        Self.map(manager.snapshot())
    }

    func fetchSnapshot() async -> AppSnapshot {
        Self.map(await manager.refresh())
    }

    func setEnabled(_ enabled: Bool) async throws {
        let result = await manager.setEnabled(enabled)
        if result.state == .error, let message = result.lastError {
            throw BridgeError.operation(message)
        }
    }

    func setAllowLAN(_ enabled: Bool) async throws {
        do {
            _ = try await manager.setAddressMode(enabled ? .lan : .loopback)
        } catch {
            throw Self.translate(error)
        }
    }

    func setPort(_ port: Int) async throws {
        do {
            _ = try await manager.setPort(port)
        } catch {
            throw Self.translate(error)
        }
    }

    func saveCredentials(username: String, password: String) async throws {
        do {
            _ = try await manager.saveCredentials(account: username, password: password)
        } catch {
            throw Self.translate(error)
        }
    }

    func restart() async throws {
        let result = await manager.restart()
        if result.state == .error, let message = result.lastError {
            throw BridgeError.operation(message)
        }
    }

    func requestPermissions() async {
        _ = await manager.requestPermissions()
    }

    func shutdown() async {
        await manager.shutdown()
    }

    // MARK: - Mapping core -> UI

    static func map(_ core: ServerSnapshot) -> AppSnapshot {
        var snapshot = AppSnapshot()
        snapshot.state = mapState(core.state)
        snapshot.configured = core.configured
        snapshot.address = core.address
        snapshot.listenHost = core.listenHost
        snapshot.port = core.port
        snapshot.allowLAN = core.allowLAN
        snapshot.account = core.account ?? ""
        snapshot.principal = core.principal ?? ""
        snapshot.permissions = UIPermissions(
            screenRecording: core.permissions.screenRecording,
            accessibility: core.permissions.accessibility,
            available: core.permissions.isAvailable
        )
        snapshot.agentState = mapAgent(core.agentState)
        snapshot.agentDetail = core.agentDetail
        snapshot.workerRunning = core.workerRunning
        snapshot.workerPID = core.workerPID
        snapshot.agentPID = core.agentPID
        snapshot.needsRestart = core.needsRestart
        snapshot.lastError = core.lastError ?? core.permissions.lastError
        snapshot.logsDirectory = core.logsDirectory
        snapshot.dataDirectory = core.dataDirectory
        snapshot.legacyLaunchAgentInstalled = core.legacyLaunchAgentInstalled
        return snapshot
    }

    private static func mapState(_ state: ServiceState) -> UIServiceState {
        switch state {
        case .disabled: return .disabled
        case .starting: return .starting
        case .running: return .running
        case .stopping: return .stopping
        case .error: return .error
        }
    }

    private static func mapAgent(_ state: AgentState) -> UIAgentState {
        switch state {
        case .waiting: return .waiting
        case .capturing: return .capturing
        case .failed: return .failed
        }
    }

    /// Core errors are English diagnostics; the popover shows Chinese text, so
    /// translate the known cases and keep the raw detail for the unknown ones.
    private static func translate(_ error: Error) -> BridgeError {
        if let credential = error as? CredentialValidationError {
            switch credential {
            case .usernameInvalid:
                return .validation("用户名只能使用 1–64 位小写字母、数字或 . _ -")
            case .passwordInvalid:
                return .validation("密码不能为空或包含换行")
            case .passwordTooLong:
                return .validation("密码过长（最多 4095 字节）")
            case .writeFailed(let message):
                return .validation("保存失败：\(message)")
            }
        }
        if let server = error as? ServerError {
            switch server {
            case .notConfigured:
                return .operation("请先设置 RDP 用户名和密码")
            case .alreadyRunning:
                return .operation("服务已在运行")
            case .notRunning:
                return .operation("服务未在运行")
            case .invalidConfiguration(let message):
                return .operation("配置无效：\(message)")
            case .dataDirectory(let message):
                return .operation("数据目录不可用：\(message)")
            case .helperMissing(let name):
                return .operation("缺少必要组件：\(name)")
            case .credentials(let message):
                return .operation("账号凭据错误：\(message)")
            case .certificate(let message):
                return .operation("证书错误：\(message)")
            case .workerFailed(let message):
                return .operation("Worker 启动失败：\(message)")
            case .agentFailed(let message):
                return .operation("Agent 启动失败：\(message)")
            case .notReady(let message):
                return .operation("服务未就绪：\(message)")
            }
        }
        return .operation(error.localizedDescription)
    }
}
