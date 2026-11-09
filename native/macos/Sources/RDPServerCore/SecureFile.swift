import Foundation
import Darwin

/// Errors raised by private-file helpers. Messages never contain secrets.
public enum SecureFileError: Error, CustomStringConvertible, Equatable, Sendable {
    case io(String)

    public var description: String {
        switch self {
        case .io(let message): return message
        }
    }
}

/// Small helpers for private (0600) files and 0700 directories.
///
/// The menu bar app owns a private data directory; every file it writes must be
/// mode 0600 and every directory 0700 (the Worker refuses to load anything
/// else). Writes go through a temporary file + rename so a crash never leaves a
/// half-written configuration behind.
enum SecureFile {
    static func writeAtomically(_ data: Data, to url: URL, mode: mode_t = 0o600) throws {
        let directory = url.deletingLastPathComponent()
        let temporary = directory.appendingPathComponent(
            ".\(url.lastPathComponent).tmp.\(getpid()).\(UInt32.random(in: 0...UInt32.max))")
        let fd = temporary.withUnsafeFileSystemRepresentation { path -> Int32 in
            guard let path else { return -1 }
            return open(path, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, mode)
        }
        guard fd >= 0 else {
            throw SecureFileError.io("open \(url.lastPathComponent): errno \(errno)")
        }
        var failure: String?
        if fchmod(fd, mode) != 0 {
            failure = "fchmod \(url.lastPathComponent): errno \(errno)"
        }
        if failure == nil {
            let written = data.withUnsafeBytes { buffer -> Int in
                guard let base = buffer.baseAddress else { return 0 }
                var offset = 0
                while offset < buffer.count {
                    let count = write(fd, base.advanced(by: offset), buffer.count - offset)
                    if count < 0 {
                        if errno == EINTR { continue }
                        return -1
                    }
                    offset += count
                }
                return offset
            }
            if written != data.count {
                failure = "write \(url.lastPathComponent): errno \(errno)"
            } else if fsync(fd) != 0 {
                failure = "fsync \(url.lastPathComponent): errno \(errno)"
            }
        }
        close(fd)
        if let failure {
            unlink(temporary.path)
            throw SecureFileError.io(failure)
        }
        if rename(temporary.path, url.path) != 0 {
            let code = errno
            unlink(temporary.path)
            throw SecureFileError.io("rename \(url.lastPathComponent): errno \(code)")
        }
    }

    static func writeString(_ value: String, to url: URL, mode: mode_t = 0o600) throws {
        try writeAtomically(Data(value.utf8), to: url, mode: mode)
    }

    static func setMode(_ url: URL, mode: mode_t = 0o600) throws {
        guard Darwin.chmod(url.path, mode) == 0 else {
            throw SecureFileError.io("chmod \(url.lastPathComponent): errno \(errno)")
        }
    }

    static func readData(at url: URL, maxBytes: Int = 4 << 20) throws -> Data {
        let size = fileSize(at: url)
        guard size <= UInt64(maxBytes) else {
            throw SecureFileError.io("\(url.lastPathComponent) is too large to read")
        }
        do {
            return try Data(contentsOf: url)
        } catch {
            throw SecureFileError.io("read \(url.lastPathComponent): \(error.localizedDescription)")
        }
    }

    static func readString(at url: URL, maxBytes: Int = 4 << 20) throws -> String {
        let data = try readData(at: url, maxBytes: maxBytes)
        guard let text = String(data: data, encoding: .utf8) else {
            throw SecureFileError.io("\(url.lastPathComponent) is not valid UTF-8")
        }
        return text
    }

    static func fileSize(at url: URL) -> UInt64 {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              let number = attributes[.size] as? NSNumber else {
            return 0
        }
        return number.uint64Value
    }

    static func exists(_ url: URL) -> Bool {
        var info = stat()
        return url.path.withCString { lstat($0, &info) } == 0
    }

    static func fileType(at url: URL) -> mode_t? {
        var info = stat()
        guard url.path.withCString({ lstat($0, &info) }) == 0 else { return nil }
        return info.st_mode & 0o170000
    }

    static func isRegularFile(_ url: URL) -> Bool {
        fileType(at: url) == 0o100000
    }

    static func fileMode(at url: URL) -> mode_t? {
        var info = stat()
        guard url.path.withCString({ lstat($0, &info) }) == 0 else { return nil }
        return info.st_mode & 0o777
    }

    static func ownerID(at url: URL) -> uid_t? {
        var info = stat()
        guard url.path.withCString({ lstat($0, &info) }) == 0 else { return nil }
        return info.st_uid
    }

    static func isOwnedRegularFile(_ url: URL, mode: mode_t) -> Bool {
        guard isRegularFile(url), ownerID(at: url) == geteuid(), fileMode(at: url) == mode else {
            return false
        }
        return true
    }

    static func removeIfPresent(_ url: URL) {
        unlink(url.path)
    }
}
