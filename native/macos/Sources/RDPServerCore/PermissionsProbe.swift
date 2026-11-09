import Foundation

/// Permission probing through the Agent bundle identity.
///
/// Screen Recording and Accessibility grants are attached to the TCC identity of
/// RDPAgent.app (com.rdp-server.agent), not to the menu bar app. The probe runs
/// that binary with RDP_AGENT_NO_PERMISSION_REQUEST=1 and parses its report:
///
///     screen_recording=granted accessibility=missing desktop_ready=false
public enum PermissionsProbe {
    public static func query(agentExecutable: URL?,
                             environment: [String: String] = HelperLocator.resolve().baseEnvironment,
                             timeout: Double = 5) -> PermissionSnapshot {
        guard let agentExecutable else {
            return PermissionSnapshot(isAvailable: false,
                                      lastError: "agent helper not found",
                                      checkedAt: Date())
        }
        var probeEnvironment = environment
        probeEnvironment["RDP_AGENT_NO_PERMISSION_REQUEST"] = "1"
        let result = ProcessRunner.run(executable: agentExecutable,
                                       arguments: ["status"],
                                       environment: probeEnvironment,
                                       timeout: timeout)
        if let launchError = result.launchError {
            return PermissionSnapshot(isAvailable: false,
                                      lastError: "agent status could not be started: \(launchError)",
                                      checkedAt: Date())
        }
        guard let parsed = parse(result.combinedOutput) else {
            let detail = result.timedOut ? "timed out" : "no permission report (status \(result.exitCode))"
            return PermissionSnapshot(isAvailable: false,
                                      lastError: detail,
                                      checkedAt: Date())
        }
        return PermissionSnapshot(screenRecording: parsed.screenRecording,
                                  accessibility: parsed.accessibility,
                                  isAvailable: true,
                                  lastError: result.exitCode == 0 ? nil : "agent status exited with \(result.exitCode)",
                                  checkedAt: Date())
    }

    /// Asks macOS to show the permission prompts (or open System Settings).
    /// The Agent's "request-permissions" command does the TCC call; older Agent
    /// binaries achieved the same by running "status" without the opt-out env.
    public static func request(agentExecutable: URL?,
                               environment: [String: String] = HelperLocator.resolve().baseEnvironment,
                               timeout: Double = 25) -> PermissionSnapshot {
        guard let agentExecutable else {
            return PermissionSnapshot(isAvailable: false,
                                      lastError: "agent helper not found",
                                      checkedAt: Date())
        }
        var requestEnvironment = environment
        requestEnvironment.removeValue(forKey: "RDP_AGENT_NO_PERMISSION_REQUEST")
        var result = ProcessRunner.run(executable: agentExecutable,
                                       arguments: ["request-permissions"],
                                       environment: requestEnvironment,
                                       timeout: timeout)
        if result.launchError != nil || (result.exitCode != 0 && parse(result.combinedOutput) == nil) {
            // Fallback for Agent builds without the explicit command: main()
            // requests missing permissions before running "status".
            result = ProcessRunner.run(executable: agentExecutable,
                                       arguments: ["status"],
                                       environment: requestEnvironment,
                                       timeout: timeout)
        }
        if let parsed = parse(result.combinedOutput) {
            return PermissionSnapshot(screenRecording: parsed.screenRecording,
                                      accessibility: parsed.accessibility,
                                      isAvailable: true,
                                      lastError: nil,
                                      checkedAt: Date())
        }
        return PermissionSnapshot(isAvailable: false,
                                  lastError: result.launchError ?? "permission request produced no report (status \(result.exitCode))",
                                  checkedAt: Date())
    }

    public static func parse(_ text: String) -> (screenRecording: Bool, accessibility: Bool)? {
        var screenRecording: Bool?
        var accessibility: Bool?
        for line in text.split(separator: "\n") {
            for token in line.split(separator: " ") {
                if token.hasPrefix("screen_recording=") {
                    screenRecording = token.hasSuffix("granted")
                } else if token.hasPrefix("accessibility=") {
                    accessibility = token.hasSuffix("granted")
                }
            }
        }
        guard let screenRecording, let accessibility else { return nil }
        return (screenRecording, accessibility)
    }

    /// Opens a URL through /usr/bin/open (no AppKit dependency in the core).
    @discardableResult
    public static func open(_ url: URL) -> Bool {
        let result = ProcessRunner.run(executable: URL(fileURLWithPath: "/usr/bin/open"),
                                       arguments: [url.absoluteString],
                                       environment: ["PATH": "/usr/bin:/bin"],
                                       timeout: 10)
        return result.launchError == nil && !result.timedOut && result.exitCode == 0
    }
}
