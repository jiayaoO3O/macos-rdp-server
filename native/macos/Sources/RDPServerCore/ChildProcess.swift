import Foundation
import Darwin

enum ChildProcessError: Error, CustomStringConvertible, Sendable {
    case launch(String)

    var description: String {
        switch self {
        case .launch(let message): return message
        }
    }
}

/// One managed child process with stdout/stderr appended to a log file.
///
/// Termination is always SIGTERM first, then SIGKILL after the grace period, so
/// the Worker can clean up its listener and the Agent can restore the display
/// arrangement.
final class ChildProcess {
    let process: Process
    let executablePath: String
    let logURL: URL
    private let lock = NSLock()
    private var recordedStatus: Int32?
    private let onExit: (@Sendable () -> Void)?

    var pid: Int32 { process.processIdentifier }
    var isRunning: Bool { process.isRunning }

    var terminationStatus: Int32? {
        lock.lock()
        defer { lock.unlock() }
        return recordedStatus
    }

    init(executable: URL,
         arguments: [String],
         environment: [String: String],
         logURL: URL,
         onExit: (@Sendable () -> Void)? = nil) throws {
        self.executablePath = executable.path
        self.logURL = logURL
        self.onExit = onExit

        let directory = logURL.deletingLastPathComponent()
        if !FileManager.default.fileExists(atPath: directory.path) {
            do {
                try FileManager.default.createDirectory(at: directory,
                                                        withIntermediateDirectories: true,
                                                        attributes: [.posixPermissions: 0o700])
            } catch {
                throw ChildProcessError.launch("cannot create log directory: \(error.localizedDescription)")
            }
        }
        let fd = open(logURL.path, O_WRONLY | O_CREAT | O_APPEND | O_CLOEXEC, 0o600)
        guard fd >= 0 else {
            throw ChildProcessError.launch("cannot open \(logURL.lastPathComponent): errno \(errno)")
        }
        close(fd)
        _ = chmod(logURL.path, 0o600)
        guard let handle = try? FileHandle(forWritingTo: logURL) else {
            throw ChildProcessError.launch("cannot open \(logURL.lastPathComponent) for writing")
        }
        _ = try? handle.seekToEnd()

        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        process.environment = environment
        process.standardOutput = handle
        process.standardError = handle
        process.standardInput = FileHandle.nullDevice
        self.process = process
        process.terminationHandler = { [weak self] finished in
            guard let self else { return }
            self.lock.lock()
            self.recordedStatus = finished.terminationStatus
            self.lock.unlock()
            self.onExit?()
        }
        do {
            try process.run()
        } catch {
            throw ChildProcessError.launch("cannot launch \(executable.lastPathComponent): \(error.localizedDescription)")
        }
    }

    /// SIGTERM, wait up to graceSeconds, then SIGKILL. Always reaps the child.
    @discardableResult
    func terminate(graceSeconds: Double) -> Int32 {
        if process.isRunning {
            process.terminate()
            let deadline = Date().addingTimeInterval(graceSeconds)
            while process.isRunning && Date() < deadline {
                usleep(20_000)
            }
            if process.isRunning {
                kill(process.processIdentifier, SIGKILL)
            }
        }
        process.waitUntilExit()
        let status = process.terminationStatus
        lock.lock()
        recordedStatus = status
        lock.unlock()
        return status
    }
}
