import AppKit
import Combine
import Foundation

/// Main-actor view model: wraps the ServerCoreBridge, owns the popover poll loop,
/// the UI-local state (advanced fields, credential draft, banners, toast) and the
/// service actions. Views observe only this object; blocking IO stays inside the
/// bridge/core. Local editor state is ObservableObject based because the SDK's
/// @State macro is unavailable with Command Line Tools only.
@MainActor
final class AppModel: ObservableObject {
    @Published private(set) var snapshot: AppSnapshot
    /// A start/stop/restart/save request is in flight.
    @Published private(set) var isWorking = false
    @Published var showCredentials = false
    @Published private(set) var isSavingCredentials = false
    @Published var credentialError: String?
    @Published var bannerMessage: String?
    @Published var toast: String?

    // 高级 section UI state.
    @Published var advancedExpanded = false
    @Published var portText: String
    @Published var portError: String?

    // Credential editor draft. The password lives here only while the editor is
    // open and is cleared on save/cancel; it is never persisted or logged.
    @Published var credentialUsername = ""
    @Published var credentialPassword = ""
    @Published var credentialConfirm = ""
    @Published var credentialAcknowledgedDisconnect = false
    @Published var credentialSubmitted = false

    /// Called when the service state changes (menu bar icon refresh).
    var onStateChange: ((UIServiceState) -> Void)?

    let bridge: ServerCoreBridge
    private var pollTask: Task<Void, Never>?
    private var toastTask: Task<Void, Never>?
    private var popoverVisible = false

    init(bridge: ServerCoreBridge, initial: AppSnapshot) {
        self.bridge = bridge
        self.snapshot = initial
        self.portText = String(initial.port)
    }

    // MARK: Polling

    func startPolling() {
        restartPolling()
    }

    func stopPolling() {
        pollTask?.cancel()
        pollTask = nil
    }

    /// Faster poll while the popover is open (1 s), slower while idle (2 s).
    func setPopoverVisible(_ visible: Bool) {
        popoverVisible = visible
        restartPolling()
        if visible {
            Task { await refresh() }
        }
    }

    private func restartPolling() {
        pollTask?.cancel()
        let interval: UInt64 = popoverVisible ? 1_000_000_000 : 2_000_000_000
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                await self.refresh()
                try? await Task.sleep(nanoseconds: interval)
            }
        }
    }

    func refresh() async {
        let next = await bridge.fetchSnapshot()
        apply(next)
    }

    private func apply(_ next: AppSnapshot) {
        guard next != snapshot else { return }
        let stateChanged = next.state != snapshot.state
        let portChanged = next.port != snapshot.port
        snapshot = next
        if portChanged {
            portText = String(next.port)
            portError = nil
        }
        if stateChanged {
            onStateChange?(next.state)
        }
    }

    // MARK: Derived presentation

    var toggleTitle: String { snapshot.state.isRunning ? "停止" : "启用" }
    var isToggleDisabled: Bool { isWorking || snapshot.state.isBusy }
    /// Inline error shown in the popover: the latest action error wins over the
    /// core's persisted last_error.
    var bannerText: String? { bannerMessage ?? snapshot.lastError }

    // MARK: Lifecycle actions

    func toggleService() async {
        guard !isWorking, !snapshot.state.isBusy else { return }
        if !snapshot.state.isRunning && !snapshot.configured {
            beginCredentialEdit()
            showToast("请先设置 RDP 用户名和密码")
            return
        }
        isWorking = true
        defer { isWorking = false }
        do {
            try await bridge.setEnabled(!snapshot.state.isRunning)
            bannerMessage = nil
        } catch {
            bannerMessage = error.localizedDescription
        }
        await refresh()
    }

    /// Dev/acceptance helper (RDPSERVER_AUTOSTART=1): start the service on
    /// launch when credentials are configured, so a headless operator can bring
    /// the RDP service up without clicking the popover. No effect by default.
    func autostartServiceIfNeeded() async {
        await refresh()
        guard snapshot.configured, !snapshot.state.isRunning, !snapshot.state.isBusy else { return }
        await toggleService()
    }

    func restartService() async {
        guard !isWorking, snapshot.state.isRunning else { return }
        isWorking = true
        defer { isWorking = false }
        do {
            try await bridge.restart()
            bannerMessage = nil
            showToast("服务已重启")
        } catch {
            bannerMessage = "重启失败：\(error.localizedDescription)"
        }
        await refresh()
    }

    func setAllowLAN(_ enabled: Bool) async {
        guard !isWorking else { return }
        isWorking = true
        defer { isWorking = false }
        do {
            try await bridge.setAllowLAN(enabled)
        } catch {
            bannerMessage = "修改局域网访问失败：\(error.localizedDescription)"
        }
        await refresh()
    }

    func setPort(_ port: Int) async {
        if let message = CredentialRules.portError(String(port)) {
            portError = message
            return
        }
        guard !isWorking else { return }
        isWorking = true
        defer { isWorking = false }
        do {
            try await bridge.setPort(port)
            portError = nil
        } catch {
            bannerMessage = "修改端口失败：\(error.localizedDescription)"
        }
        await refresh()
    }

    // MARK: Small actions

    func copyAddress() {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(snapshot.displayAddress, forType: .string)
        showToast("已复制连接地址")
    }

    func openPrivacySettings(_ pane: UIPrivacyPane) {
        NSWorkspace.shared.open(pane.url)
    }

    func openLogs() {
        NSWorkspace.shared.open(snapshot.logsDirectory)
    }

    func requestPermissions() async {
        await bridge.requestPermissions()
        await refresh()
        showToast("已请求权限，请在系统弹窗中允许")
    }

    // MARK: Credential editor

    func beginCredentialEdit() {
        credentialUsername = snapshot.account
        credentialPassword = ""
        credentialConfirm = ""
        credentialAcknowledgedDisconnect = false
        credentialSubmitted = false
        credentialError = nil
        bannerMessage = nil
        showCredentials = true
    }

    func cancelCredentialEdit() {
        clearCredentialSecrets()
        showCredentials = false
        credentialError = nil
    }

    private func clearCredentialSecrets() {
        credentialPassword = ""
        credentialConfirm = ""
        credentialAcknowledgedDisconnect = false
        credentialSubmitted = false
    }

    /// Persist credentials. When the service is running the editor already asked
    /// for the disconnect confirmation, so the worker is restarted here.
    @discardableResult
    func saveCredentials() async -> Bool {
        credentialSubmitted = true
        if let message = CredentialRules.usernameError(credentialUsername) {
            credentialError = message
            return false
        }
        if let message = CredentialRules.passwordError(credentialPassword) {
            credentialError = message
            return false
        }
        if let message = CredentialRules.confirmError(password: credentialPassword, confirm: credentialConfirm) {
            credentialError = message
            return false
        }
        if snapshot.state.isRunning && !credentialAcknowledgedDisconnect {
            credentialError = "请先确认保存后服务会重启"
            return false
        }
        isSavingCredentials = true
        credentialError = nil
        defer { isSavingCredentials = false }
        let wasRunning = snapshot.state.isRunning
        do {
            try await bridge.saveCredentials(username: credentialUsername, password: credentialPassword)
            if wasRunning {
                try await bridge.restart()
            }
            clearCredentialSecrets()
            showCredentials = false
            showToast(wasRunning ? "账号已保存，服务已重启" : "账号已保存")
            await refresh()
            return true
        } catch {
            credentialError = error.localizedDescription
            return false
        }
    }

    // MARK: Quit

    func quit() {
        Task { @MainActor in
            await bridge.shutdown()
            NSApp.terminate(nil)
        }
    }

    /// Graceful shutdown for SIGINT/SIGTERM in terminal dev runs.
    func shutdownForSignal() async {
        await bridge.shutdown()
    }

    func showToast(_ text: String) {
        toast = text
        toastTask?.cancel()
        toastTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 2_200_000_000)
            guard let self, !Task.isCancelled else { return }
            self.toast = nil
        }
    }
}
