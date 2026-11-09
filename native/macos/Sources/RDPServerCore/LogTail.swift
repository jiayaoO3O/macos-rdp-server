import Foundation
import Darwin

/// Incremental reader for append-only Worker/Agent log files.
///
/// Used by the readiness wait and by the 1 s monitor tick: it remembers the byte
/// offset and only parses newly appended lines. Log lines are plain text, one
/// event per line ("event=snake_case key=value"); non-event lines (for example
/// the Go "P0 worker: ..." banner) are ignored by the callers.
final class LogTail {
    let url: URL
    private var offset: UInt64 = 0
    private var partial = Data()
    private let maximumLineBytes = 64 << 10

    init(url: URL) {
        self.url = url
    }

    /// Start reading after the current end of file (only new output).
    func seekToEnd() {
        offset = SecureFile.fileSize(at: url)
        partial.removeAll(keepingCapacity: true)
    }

    func poll() -> [String] {
        let size = SecureFile.fileSize(at: url)
        if size < offset {
            // The file was rotated or truncated: restart from the beginning.
            offset = 0
            partial.removeAll(keepingCapacity: true)
        }
        guard let handle = try? FileHandle(forReadingFrom: url) else { return [] }
        defer { try? handle.close() }
        do {
            try handle.seek(toOffset: offset)
        } catch {
            return []
        }
        var received = Data()
        var exhausted = false
        while !exhausted {
            let chunk: Data?
            do {
                chunk = try handle.read(upToCount: 1 << 18)
            } catch {
                break
            }
            guard let chunk, !chunk.isEmpty else { exhausted = true; break }
            received.append(chunk)
            offset += UInt64(chunk.count)
            if received.count >= 4 << 20 { break }
        }
        guard !received.isEmpty else { return [] }
        partial.append(received)
        var lines: [String] = []
        while let index = partial.firstIndex(of: 0x0A) {
            let lineData = partial[partial.startIndex..<index]
            lines.append(String(decoding: lineData, as: UTF8.self))
            partial.removeSubrange(partial.startIndex...index)
        }
        if partial.count > maximumLineBytes {
            lines.append(String(decoding: partial, as: UTF8.self))
            partial.removeAll(keepingCapacity: true)
        }
        return lines
    }

    /// Last lines of a file without loading the whole thing.
    static func tailLines(of url: URL, limit: Int, maximumBytes: Int = 256 << 10) -> [String] {
        guard limit > 0, let handle = try? FileHandle(forReadingFrom: url) else { return [] }
        defer { try? handle.close() }
        let size = SecureFile.fileSize(at: url)
        let start = size > UInt64(maximumBytes) ? size - UInt64(maximumBytes) : 0
        do {
            try handle.seek(toOffset: start)
        } catch {
            return []
        }
        guard let data = try? handle.readToEnd() else { return [] }
        let text = String(decoding: data, as: UTF8.self)
        var lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        if !lines.isEmpty, lines.last?.isEmpty == true {
            lines.removeLast()
        }
        if start > 0, !lines.isEmpty {
            lines.removeFirst()
        }
        return Array(lines.suffix(limit))
    }

    /// Move an oversized log to ".1" (only safe while the writer is stopped).
    static func rotateIfNeeded(_ url: URL, maximumBytes: UInt64 = 32 << 20) {
        guard SecureFile.fileSize(at: url) > maximumBytes else { return }
        let archived = URL(fileURLWithPath: url.path + ".1")
        SecureFile.removeIfPresent(archived)
        if rename(url.path, archived.path) != 0 {
            // Do not delete anything if the rotation failed: the log still matters.
            return
        }
        _ = chmod(archived.path, 0o600)
    }
}

/// Append-only menu app diagnostics (size-bounded, no secrets and no absolute
/// user paths: only event= lines about lifecycle decisions).
struct AppLog: Sendable {
    let url: URL
    let maximumBytes: UInt64

    init(url: URL, maximumBytes: UInt64 = 4 << 20) {
        self.url = url
        self.maximumBytes = maximumBytes
    }

    func append(_ line: String) {
        if SecureFile.fileSize(at: url) > maximumBytes {
            LogTail.rotateIfNeeded(url, maximumBytes: maximumBytes)
        }
        let milliseconds = Int64(Date().timeIntervalSince1970 * 1000)
        let text = "\(milliseconds) \(line)\n"
        let data = Data(text.utf8)
        let fd = open(url.path, O_WRONLY | O_CREAT | O_APPEND | O_CLOEXEC, 0o600)
        guard fd >= 0 else { return }
        defer { close(fd) }
        data.withUnsafeBytes { buffer in
            guard let base = buffer.baseAddress else { return }
            var offset = 0
            while offset < buffer.count {
                let count = write(fd, base.advanced(by: offset), buffer.count - offset)
                if count < 0 {
                    if errno == EINTR { continue }
                    return
                }
                offset += count
            }
        }
    }
}
