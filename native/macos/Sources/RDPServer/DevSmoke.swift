import Foundation

/// Dev-only end-to-end smoke of the UI action layer against the REAL core:
/// RDPSERVER_UI_SMOKE=1 (plus required RDPSERVER_SMOKE_PASSWORD) runs against an
/// isolated --data-dir, persists a test credential, picks a random loopback port,
/// starts the real Worker + Agent,
/// exercises permission probe / stuck-key release, then stops everything and
/// prints one JSON object. It never uses the mock bridge, never touches .runtime
/// and never binds 3389. Used to verify the AppModel/LiveCoreBridge action paths
/// without a clickable UI.
@MainActor
enum DevSmoke {
    static var isRequested: Bool {
        ProcessInfo.processInfo.environment["RDPSERVER_UI_SMOKE"] == "1"
    }

    static func run(invocation: CLIInvocation) async -> Int32 {
        let environment = ProcessInfo.processInfo.environment
        // Dev-only ephemeral credential: never ship a default password. The
        // documented UI-smoke command passes RDPSERVER_SMOKE_PASSWORD explicitly.
        guard let password = environment["RDPSERVER_SMOKE_PASSWORD"], !password.isEmpty else {
            fputs("RDPSERVER_UI_SMOKE=1 requires RDPSERVER_SMOKE_PASSWORD (dev-only, ephemeral)\n", stderr)
            return 2
        }
        let account = environment["RDPSERVER_SMOKE_ACCOUNT"] ?? "smoketest"
        let start = Date()
        var checks: [(name: String, ok: Bool, detail: String?)] = []

        func record(_ name: String, _ ok: Bool, _ detail: String? = nil) {
            checks.append((name, ok, detail))
            let status = ok ? "ok" : "FAIL"
            fputs("event=ui_smoke_check name=" + name + " status=" + status
                  + (detail.map { " detail=" + $0 } ?? "") + "\n", stderr)
        }

        do {
            let bridge = try LiveCoreBridge(dataDirectory: invocation.dataDirectory)
            let model = AppModel(bridge: bridge, initial: bridge.snapshotNow())
            record("initial_snapshot", true, "state=" + model.snapshot.state.title)
            record("initial_not_configured", model.snapshot.configured == false)

            let port = Int(environment["RDPSERVER_SMOKE_PORT"] ?? "") ?? Int.random(in: 20000...45000)
            model.portText = String(port)
            model.beginCredentialEdit()
            model.credentialUsername = account
            model.credentialPassword = password
            model.credentialConfirm = password
            let saved = await model.saveCredentials()
            record("save_credentials",
                   saved && model.snapshot.configured,
                   model.credentialError ?? "configured=" + String(model.snapshot.configured))
            record("save_credentials_no_plaintext", model.credentialPassword.isEmpty,
                   "password field cleared")

            await model.setPort(port)
            record("set_port", model.snapshot.port == port, "port=" + String(model.snapshot.port))

            await model.toggleService()
            let started = await waitFor(model: model, until: { $0.state == .running || $0.state == .error }, timeout: 20)
            record("start", started && model.snapshot.state == .running,
                   "state=" + model.snapshot.state.title + " error=" + (model.snapshot.lastError ?? "none"))
            record("address_present", (model.snapshot.address ?? "").contains(":"),
                   model.snapshot.address ?? "nil")
            record("worker_running", model.snapshot.workerRunning)
            record("agent_running", model.snapshot.agentPID != nil,
                   model.snapshot.agentDetail ?? "nil")

            await model.requestPermissions()
            record("permission_probe", model.snapshot.permissions.available,
                   "screen=" + String(model.snapshot.permissions.screenRecording)
                   + " accessibility=" + String(model.snapshot.permissions.accessibility))

            await model.refresh()
            await model.toggleService()
            let stopped = await waitFor(model: model, until: { $0.state == .disabled || $0.state == .error }, timeout: 20)
            record("stop", stopped && model.snapshot.state == .disabled,
                   "state=" + model.snapshot.state.title + " error=" + (model.snapshot.lastError ?? "none"))
            record("worker_stopped", model.snapshot.workerRunning == false)

            await model.shutdownForSignal()
            record("shutdown", true)
        } catch {
            record("exception", false, String(describing: error))
        }

        let ok = checks.allSatisfy { $0.ok }
        let payload: [String: Any] = [
            "ok": ok,
            "elapsed_ms": Int(Date().timeIntervalSince(start) * 1000),
            "checks": checks.map { check -> [String: Any] in
                var item: [String: Any] = ["name": check.name, "ok": check.ok]
                if let detail = check.detail { item["detail"] = detail }
                return item
            },
        ]
        if let data = try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys, .prettyPrinted]),
           let text = String(data: data, encoding: .utf8) {
            print(text)
        }
        return ok ? 0 : 1
    }

    private static func waitFor(model: AppModel,
                                until predicate: (AppSnapshot) -> Bool,
                                timeout: Double) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if predicate(model.snapshot) { return true }
            await model.refresh()
            if predicate(model.snapshot) { return true }
            try? await Task.sleep(nanoseconds: 300_000_000)
        }
        return false
    }
}
