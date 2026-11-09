import Foundation

/// Fallback bridge used when the live core cannot be constructed (for example an
/// unwritable data directory). Keeps the popover useful: it renders the failure
/// and every action reports the same reason instead of crashing the app.
@MainActor
final class BrokenCoreBridge: ServerCoreBridge {
    let brokenSnapshot: AppSnapshot
    private let reason: String

    init(reason: String) {
        self.reason = reason
        var snapshot = AppSnapshot()
        snapshot.state = .error
        snapshot.lastError = reason
        snapshot.permissions = UIPermissions(screenRecording: false, accessibility: false, available: false)
        snapshot.logsDirectory = URL(fileURLWithPath: NSHomeDirectory())
        snapshot.dataDirectory = URL(fileURLWithPath: NSHomeDirectory())
        brokenSnapshot = snapshot
    }

    func fetchSnapshot() async -> AppSnapshot { brokenSnapshot }

    func setEnabled(_ enabled: Bool) async throws { throw BridgeError.operation(reason) }
    func setAllowLAN(_ enabled: Bool) async throws { throw BridgeError.operation(reason) }
    func setPort(_ port: Int) async throws { throw BridgeError.operation(reason) }
    func saveCredentials(username: String, password: String) async throws { throw BridgeError.operation(reason) }
    func restart() async throws { throw BridgeError.operation(reason) }
    func requestPermissions() async {}
    func shutdown() async {}
}
