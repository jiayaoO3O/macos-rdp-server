import Foundation
import Darwin

/// Runs a short-lived helper process with a timeout and captures its output.
/// Output is captured through private temp files instead of pipes so a chatty
/// helper can never deadlock the app.
enum ProcessRunner {
    struct Result: Sendable {
        let exitCode: Int32
        let stdout: String
        let stderr: String
        let timedOut: Bool
        let launchError: String?

        var combinedOutput: String { stdout + "\n" + stderr }
    }

    static func run(executable: URL,
                    arguments: [String],
                    environment: [String: String]? = nil,
                    currentDirectory: URL? = nil,
                    stdin: Data? = nil,
                    timeout: Double = 15) -> Result {
        let fileManager = FileManager.default
        let prefix = "rdp-core-\(UUID().uuidString)"
        let stdoutURL = fileManager.temporaryDirectory.appendingPathComponent(prefix + ".out")
        let stderrURL = fileManager.temporaryDirectory.appendingPathComponent(prefix + ".err")
        defer {
            try? fileManager.removeItem(at: stdoutURL)
            try? fileManager.removeItem(at: stderrURL)
        }

        for url in [stdoutURL, stderrURL] {
            let fd = open(url.path, O_WRONLY | O_CREAT | O_TRUNC | O_CLOEXEC, 0o600)
            if fd < 0 {
                return Result(exitCode: -1, stdout: "", stderr: "",
                              timedOut: false, launchError: "cannot create capture file: errno \(errno)")
            }
            close(fd)
        }
        guard let stdoutHandle = try? FileHandle(forWritingTo: stdoutURL),
              let stderrHandle = try? FileHandle(forWritingTo: stderrURL) else {
            return Result(exitCode: -1, stdout: "", stderr: "",
                          timedOut: false, launchError: "cannot open capture files")
        }

        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        if let environment { process.environment = environment }
        if let currentDirectory { process.currentDirectoryURL = currentDirectory }
        process.standardOutput = stdoutHandle
        process.standardError = stderrHandle
        process.standardInput = FileHandle.nullDevice

        var stdinHandle: FileHandle?
        if let stdin {
            let pipe = Pipe()
            process.standardInput = pipe
            stdinHandle = pipe.fileHandleForWriting
            _ = stdinHandle
            DispatchQueue.global().async {
                pipe.fileHandleForWriting.write(stdin)
                try? pipe.fileHandleForWriting.close()
            }
        }

        do {
            try process.run()
        } catch {
            try? stdoutHandle.close()
            try? stderrHandle.close()
            if let stdinHandle { try? stdinHandle.close() }
            return Result(exitCode: -1, stdout: "", stderr: "",
                          timedOut: false, launchError: error.localizedDescription)
        }

        let deadline = Date().addingTimeInterval(timeout)
        var timedOut = false
        while process.isRunning {
            if Date() >= deadline {
                timedOut = true
                kill(process.processIdentifier, SIGKILL)
                break
            }
            usleep(20_000)
        }
        process.waitUntilExit()
        try? stdoutHandle.close()
        try? stderrHandle.close()
        if let stdinHandle { try? stdinHandle.close() }

        let stdout = (try? String(contentsOf: stdoutURL, encoding: .utf8)) ?? ""
        let stderr = (try? String(contentsOf: stderrURL, encoding: .utf8)) ?? ""
        return Result(exitCode: process.terminationStatus,
                      stdout: stdout,
                      stderr: stderr,
                      timedOut: timedOut,
                      launchError: nil)
    }
}
