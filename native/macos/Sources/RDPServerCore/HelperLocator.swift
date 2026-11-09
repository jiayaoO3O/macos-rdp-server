import Foundation
import Darwin

/// Locates the external helper binaries the app drives:
///
/// 1. RDPSERVER_HELPERS_DIR (absolute directory, used by tests and packaging),
/// 2. <App>.app/Contents/Helpers when running from a bundle,
/// 3. <repo>/bin when running the SwiftPM release binary from a checkout,
/// 4. the executable's own directory (last resort).
///
/// Expected layout, matching the DMG packager:
///
///     Contents/Helpers/rdp-worker
///     Contents/Helpers/rdpctl
///     Contents/Helpers/RDPAgent.app/Contents/MacOS/rdp-agent
public struct HelperLocator: Sendable {
    public enum Source: String, Sendable {
        case environment
        case bundle
        case repository
        case executableDirectory
    }

    public let helpersDirectory: URL
    public let source: Source
    public let repositoryRoot: URL?

    public init(helpersDirectory: URL, source: Source = .environment, repositoryRoot: URL? = nil) {
        self.helpersDirectory = helpersDirectory.standardizedFileURL
        self.source = source
        self.repositoryRoot = repositoryRoot
    }

    public static func resolve(environment: [String: String] = ProcessInfo.processInfo.environment,
                               executableURL: URL? = Bundle.main.executableURL,
                               bundleURL: URL? = Bundle.main.bundleURL) -> HelperLocator {
        if let value = environment["RDPSERVER_HELPERS_DIR"], value.hasPrefix("/") {
            let directory = URL(fileURLWithPath: value, isDirectory: true)
            if isDirectory(directory) {
                return HelperLocator(helpersDirectory: directory, source: .environment)
            }
        }

        let appBundle = appBundleURL(executableURL: executableURL, bundleURL: bundleURL)
        if let appBundle {
            let helpers = appBundle.appendingPathComponent("Contents/Helpers", isDirectory: true)
            if isDirectory(helpers) {
                return HelperLocator(helpersDirectory: helpers, source: .bundle,
                                     repositoryRoot: repositoryRoot(startingFrom: [appBundle]))
            }
        }

        let searchRoots = [executableURL?.deletingLastPathComponent(), appBundle].compactMap { $0 }
        if let root = repositoryRoot(startingFrom: searchRoots) {
            return HelperLocator(helpersDirectory: root.appendingPathComponent("bin", isDirectory: true),
                                 source: .repository, repositoryRoot: root)
        }

        let directory = executableURL?.deletingLastPathComponent()
            ?? URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        return HelperLocator(helpersDirectory: directory, source: .executableDirectory)
    }

    public var workerExecutable: URL { helpersDirectory.appendingPathComponent("rdp-worker") }
    public var rdpctlExecutable: URL { helpersDirectory.appendingPathComponent("rdpctl") }
    public var agentBundle: URL { helpersDirectory.appendingPathComponent("RDPAgent.app", isDirectory: true) }
    public var bundledAgentExecutable: URL {
        agentBundle.appendingPathComponent("Contents/MacOS/rdp-agent")
    }
    public var looseAgentExecutable: URL { helpersDirectory.appendingPathComponent("rdp-agent") }

    /// The Agent executable whose TCC identity receives Screen Recording and
    /// Accessibility grants: the nested app bundle when present.
    public var agentExecutable: URL? {
        for candidate in [bundledAgentExecutable, looseAgentExecutable] where isExecutable(candidate) {
            return candidate
        }
        return nil
    }

    public var workerAvailable: Bool { isExecutable(workerExecutable) }
    public var rdpctlAvailable: Bool { isExecutable(rdpctlExecutable) }
    public var agentAvailable: Bool { agentExecutable != nil }
    public var opensslAvailable: Bool { isExecutable(HelperLocator.opensslExecutable) }

    public static let opensslExecutable = URL(fileURLWithPath: "/usr/bin/openssl")

    public var summary: String {
        "helpers=\(helpersDirectory.path) source=\(source.rawValue)"
    }

    /// Environment handed to helper processes: no inherited surprises, but
    /// enough for macOS frameworks and logging.
    public var baseEnvironment: [String: String] {
        var environment: [String: String] = [
            "PATH": "/usr/bin:/bin:/usr/sbin:/sbin:/usr/local/bin:/opt/homebrew/bin",
        ]
        let inherited = ProcessInfo.processInfo.environment
        for key in ["HOME", "TMPDIR", "LANG", "LC_ALL", "USER", "LOGNAME", "SHELL", "XPC_SERVICE_NAME"] {
            if let value = inherited[key], !value.isEmpty {
                environment[key] = value
            }
        }
        // Diagnostic pass-through (dev/field tracing, e.g. RDP_AGENT_INPUT_TRACE=1
        // or RDP_INPUT_TRACE=1). Only RDP_* variables are forwarded, and the
        // shipping app normally has none set, so default behaviour is unchanged.
        for (key, value) in inherited where key.hasPrefix("RDP_") && !value.isEmpty {
            environment[key] = value
        }
        return environment
    }

    private static func isDirectory(_ url: URL) -> Bool {
        var info = stat()
        guard url.path.withCString({ lstat($0, &info) }) == 0 else { return false }
        return info.st_mode & 0o170000 == 0o040000
    }

    /// Follows symlinks on purpose: the dev helpers directory links to bin/,
    /// and the packaged app uses real files. Only execution permission matters
    /// here; the private data directory has its own stricter 0600 rules.
    private func isExecutable(_ url: URL) -> Bool {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory),
              !isDirectory.boolValue else {
            return false
        }
        return FileManager.default.isExecutableFile(atPath: url.path)
    }

    private static func appBundleURL(executableURL: URL?, bundleURL: URL?) -> URL? {
        if let bundleURL, bundleURL.path.hasSuffix(".app") {
            return bundleURL
        }
        guard let executableURL else { return nil }
        var candidate = executableURL.deletingLastPathComponent()
        for _ in 0..<3 {
            if candidate.path.hasSuffix(".app") { return candidate }
            let parent = candidate.deletingLastPathComponent()
            if parent.path == candidate.path { break }
            candidate = parent
        }
        return nil
    }

    private static func repositoryRoot(startingFrom roots: [URL]) -> URL? {
        let fileManager = FileManager.default
        for root in roots {
            var candidate = root
            for _ in 0..<8 {
                let goMod = candidate.appendingPathComponent("go.mod")
                let package = candidate.appendingPathComponent("native/macos/Package.swift")
                if fileManager.fileExists(atPath: goMod.path),
                   fileManager.fileExists(atPath: package.path) {
                    return candidate
                }
                let parent = candidate.deletingLastPathComponent()
                if parent.path == candidate.path { break }
                candidate = parent
            }
        }
        return nil
    }
}
