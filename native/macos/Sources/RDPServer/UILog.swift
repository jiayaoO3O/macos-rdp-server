import Darwin
import Foundation

/// Append-only UI lifecycle log lines for headless verification of the menu bar
/// and popover (same file/format as the core's AppLog:
/// <data>/logs/app.log, "<epoch_ms> event=name k=v"). No secrets, no absolute
/// user paths; only state facts. Writing is best effort: a missing log directory
/// (dev mock bridge) is silently ignored.
enum UILog {
    private static var target: URL?
    private static let queue = DispatchQueue(label: "com.rdp-server.ui.log")

    static func configure(dataDirectory: URL) {
        let candidate = dataDirectory
            .appendingPathComponent("logs", isDirectory: true)
            .appendingPathComponent("app.log")
        let directory = candidate.deletingLastPathComponent()
        guard FileManager.default.fileExists(atPath: directory.path) else { return }
        target = candidate
    }

    static func event(_ name: String, _ fields: [String: String] = [:]) {
        var line = "event=" + name
        for key in fields.keys.sorted() {
            line += " " + key + "=" + sanitize(fields[key] ?? "")
        }
        write(line)
    }

    private static func sanitize(_ value: String) -> String {
        value
            .replacingOccurrences(of: " ", with: "_")
            .replacingOccurrences(of: "\n", with: "_")
            .replacingOccurrences(of: "\t", with: "_")
    }

    private static func write(_ line: String) {
        fputs(line + "\n", stderr)
        guard let url = target else { return }
        queue.async {
            let milliseconds = Int64(Date().timeIntervalSince1970 * 1000)
            let text = "\(milliseconds) \(line)\n"
            let descriptor = Darwin.open(url.path, O_WRONLY | O_CREAT | O_APPEND | O_CLOEXEC, 0o600)
            guard descriptor >= 0 else { return }
            defer { Darwin.close(descriptor) }
            let data = Data(text.utf8)
            data.withUnsafeBytes { buffer in
                guard let base = buffer.baseAddress else { return }
                var offset = 0
                while offset < buffer.count {
                    let count = Darwin.write(descriptor, base.advanced(by: offset), buffer.count - offset)
                    if count < 0 {
                        if errno == EINTR { continue }
                        return
                    }
                    offset += count
                }
            }
        }
    }
}
