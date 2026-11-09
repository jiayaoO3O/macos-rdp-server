import Foundation

/// GUI-mode data directory resolution.
///
/// Headless modes are fully handled by RDPServerCore.RDPServerCLI (including
/// --data-dir / RDPSERVER_DATA_DIR precedence). GUI mode only needs the explicit
/// value to construct ServerManager; the dev mock bridge additionally needs a
/// concrete directory for its fake logs path.
struct CLIInvocation {
    /// Explicit --data-dir only; nil means "let the core resolve env/default".
    var dataDirectory: URL?
    /// Concrete directory used by the dev mock bridge and for display only.
    var displayDataDirectory: URL
    /// --show-popover: open the popover once at launch (dev/test, no effect on
    /// the service). Equivalent to clicking the status item.
    var openPopoverAtLaunch: Bool

    static func parseGUI(arguments: [String]) -> CLIInvocation {
        var explicit: URL?
        var openPopover = false
        var index = 0
        while index < arguments.count {
            let argument = arguments[index]
            if argument == "--show-popover" {
                openPopover = true
            }
            if argument == "--data-dir", index + 1 < arguments.count {
                explicit = url(from: arguments[index + 1])
                index += 2
                continue
            }
            if argument.hasPrefix("--data-dir=") {
                explicit = url(from: String(argument.dropFirst("--data-dir=".count)))
            }
            index += 1
        }
        let display: URL
        if let explicit {
            display = explicit
        } else if let environment = ProcessInfo.processInfo.environment["RDPSERVER_DATA_DIR"], !environment.isEmpty {
            display = url(from: environment)
        } else {
            let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
                ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support", isDirectory: true)
            display = support.appendingPathComponent("RDPServer", isDirectory: true)
        }
        return CLIInvocation(dataDirectory: explicit,
                              displayDataDirectory: display,
                              openPopoverAtLaunch: openPopover)
    }

    private static func url(from raw: String) -> URL {
        URL(fileURLWithPath: (raw as NSString).expandingTildeInPath, isDirectory: true)
    }
}
