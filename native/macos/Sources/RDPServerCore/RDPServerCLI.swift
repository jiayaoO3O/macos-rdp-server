import Foundation

/// Headless CLI surface shared by the RDPServer executable and tests.
///
/// The menu bar executable calls this first; a nil return means "not a core CLI
/// invocation, launch the GUI". The contract:
///
///     RDPServer --status [--data-dir PATH]      one JSON object, exit 0/1
///     RDPServer --self-test [--data-dir PATH]   one JSON object, exit 0 iff ok
///     RDPServer --version                       version string, exit 0
///
/// Environment: RDPSERVER_DATA_DIR (data dir default), RDPSERVER_HELPERS_DIR
/// (helper directory override), RDPSERVER_SELFTEST_START=1 (self test also
/// starts and stops the real Worker + Agent in the isolated directory).
public enum RDPServerCLI {
    private enum Mode {
        case none
        case status
        case selfTest
    }

    public static func run(arguments: [String],
                           environment: [String: String] = ProcessInfo.processInfo.environment) -> Int32? {
        var mode: Mode = .none
        var dataDirectory: URL?
        var helpersDirectory: URL?
        var index = 0
        while index < arguments.count {
            let argument = arguments[index]
            switch argument {
            case "--status":
                mode = .status
            case "--self-test":
                mode = .selfTest
            case "--version":
                print("RDPServer \(RDPServerCoreVersion.value)")
                return 0
            case "--help", "-h":
                print(usage)
                return 0
            case "--data-dir", "--helpers-dir":
                guard index + 1 < arguments.count else {
                    fail("missing value for \(argument)")
                    return 2
                }
                let value = arguments[index + 1]
                let url = URL(fileURLWithPath: value)
                guard url.path.hasPrefix("/") else {
                    fail("\(argument) requires an absolute path")
                    return 2
                }
                if argument == "--data-dir" { dataDirectory = url } else { helpersDirectory = url }
                index += 2
                continue
            default:
                if argument.hasPrefix("--data-dir=") {
                    let value = String(argument.dropFirst("--data-dir=".count))
                    let url = URL(fileURLWithPath: value)
                    guard url.path.hasPrefix("/") else {
                        fail("--data-dir requires an absolute path")
                        return 2
                    }
                    dataDirectory = url
                } else if argument.hasPrefix("--helpers-dir=") {
                    let value = String(argument.dropFirst("--helpers-dir=".count))
                    let url = URL(fileURLWithPath: value)
                    guard url.path.hasPrefix("/") else {
                        fail("--helpers-dir requires an absolute path")
                        return 2
                    }
                    helpersDirectory = url
                } else {
                    // Not a core CLI flag: the executable owns the GUI path.
                    return nil
                }
            }
            index += 1
        }

        switch mode {
        case .none:
            return nil
        case .status:
            let report = StatusReport.headless(dataDirectory: dataDirectory, environment: environment)
            do {
                print(try report.jsonString())
            } catch {
                fail("cannot encode status: \(error)")
                return 1
            }
            if let lastError = report.lastError {
                fail("status: \(lastError)")
            }
            return report.ok ? 0 : 1
        case .selfTest:
            let startService = environment["RDPSERVER_SELFTEST_START"] == "1"
            let report = SelfTest.run(dataDirectory: dataDirectory,
                                      helpersDirectory: helpersDirectory,
                                      startService: startService,
                                      environment: environment)
            for check in report.checks {
                let status = check.ok ? "ok" : "FAIL"
                fail("check \(status) \(check.name)\(check.detail.map { ": \($0)" } ?? "")")
            }
            do {
                print(try report.jsonString())
            } catch {
                fail("cannot encode self test: \(error)")
                return 1
            }
            return report.ok ? 0 : 1
        }
    }

    private static func fail(_ message: String) {
        FileHandle.standardError.write(Data(("RDPServer: " + message + "\n").utf8))
    }

    private static let usage = """
    Usage: RDPServer [--status | --self-test] [--data-dir PATH] [--helpers-dir PATH]

      --status       Print one JSON status object and exit. Never starts the
                     service and never creates/modifies the data directory.
      --self-test    Run headless self checks against an isolated data directory.
                     Exit code 0 iff every check passes.
      --data-dir P   Private data directory (absolute). Default: $RDPSERVER_DATA_DIR
                     or ~/Library/Application Support/RDPServer.
      --helpers-dir P  Helper binary directory (rdp-worker, rdpctl, RDPAgent.app).
                     Default: $RDPSERVER_HELPERS_DIR, the app bundle's
                     Contents/Helpers, or the checkout's bin/ directory.
      --version      Print the core version and exit.
      --help         Print this help and exit.

    Environment:
      RDPSERVER_DATA_DIR       data directory default
      RDPSERVER_HELPERS_DIR    helper directory override
      RDPSERVER_SELFTEST_START set to 1 to let --self-test start/stop the service

    Without --status/--self-test the executable launches the menu bar UI.
    """
}
