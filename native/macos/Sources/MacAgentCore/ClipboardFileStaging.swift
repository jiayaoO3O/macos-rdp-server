import Darwin
import Foundation

// Local->remote (direction 2) file staging for TCC / Full Disk Access.
//
// Mass storage / TCC problem: the Worker process cannot reliably open files that
// live in a TCC-protected user folder (~/Desktop, ~/Documents, iCloud Drive, ...)
// even when it runs as the same user; only the Agent app can practically be
// granted Full Disk Access. Instead of advertising the original path, the Agent
// streams a private copy into its own temp directory and advertises the staged
// path, so the Worker never needs access to the original location.
//
// Contract addendum: docs/DESIGN-2026-11-08-clipboard-files.md (§9 "TCC").
//
// Properties:
//   * staging root: NSTemporaryDirectory()/rdp-clipboard-out/<uuid>/ (0700) with
//     files 0600, created O_CREAT|O_EXCL|O_WRONLY|O_NOFOLLOW,
//   * 64 KiB streaming copy (never loads a whole file into memory), source opened
//     O_RDONLY|O_NOFOLLOW|O_CLOEXEC + fstat regular-file check,
//   * the contract limits (100 files, <2 GiB per file, <=4 GiB total, name/path
//     rules) are validated before the first byte is copied,
//   * the advertised IPC type-16 entry keeps the original basename but its path
//     points at the staged copy; the staged size is verified to equal the
//     advertised size (a file changing during the copy aborts the offer),
//   * the offer directory is deleted on any staging error; successful offers
//     rotate "current + previous" and the older directory is deleted when the
//     next offer is staged (same policy as the direction-1 temp dirs).

/// A staging directory created by `ClipboardLocalFileStagingFileSystem`.
public struct ClipboardStagingDirectory: Equatable {
    public let identifier: Int
    public let url: URL

    public init(identifier: Int, url: URL) {
        self.identifier = identifier
        self.url = url
    }
}

/// A staged file opened for writing.
public struct ClipboardStagingFileHandle: Equatable {
    public let identifier: Int

    public init(identifier: Int) {
        self.identifier = identifier
    }
}

/// A source file opened for reading.
public struct ClipboardStagingSourceHandle: Equatable {
    public let identifier: Int

    public init(identifier: Int) {
        self.identifier = identifier
    }
}

public enum ClipboardLocalFileStagingError: Error, Equatable {
    /// The Agent itself could not read the original file (TCC denial, EACCES,
    /// symlink rejected by O_NOFOLLOW, not a regular file, ...). `name` is a
    /// sanitized single path component suitable for a log line.
    case unreadable(name: String, errno: Int32)
    case readFailed(errno: Int32)
    /// The source changed size while it was being copied.
    case sizeMismatch(name: String, expected: UInt64, actual: UInt64)
    case invalidStagedName(String)
    case fileSystem(String)
}

/// Injectable file IO for the direction-2 stager: staging sink plus source
/// reads. The default POSIX implementation is
/// `PosixClipboardLocalFileStagingFileSystem`; tests inject an in-memory
/// implementation so the copy/limit/cleanup logic runs without real files.
public protocol ClipboardLocalFileStagingFileSystem {
    func createOfferDirectory() throws -> ClipboardStagingDirectory
    func createFile(named name: String,
                    in directory: ClipboardStagingDirectory) throws -> ClipboardStagingFileHandle
    func append(_ data: Data, to handle: ClipboardStagingFileHandle) throws
    func finish(_ handle: ClipboardStagingFileHandle) throws -> URL
    func discard(_ handle: ClipboardStagingFileHandle)
    func removeDirectory(_ directory: ClipboardStagingDirectory)
    /// Opens the original local file read-only, without following symlinks.
    /// Throws `ClipboardLocalFileStagingError.unreadable` on failure.
    func openSource(path: String) throws -> ClipboardStagingSourceHandle
    /// Reads the next chunk; returns empty `Data` at EOF.
    func readSourceChunk(_ handle: ClipboardStagingSourceHandle,
                         maxLength: Int) throws -> Data
    func closeSource(_ handle: ClipboardStagingSourceHandle)
}

public struct ClipboardLocalFileStagedOffer {
    /// The direction-2 offer whose type-16 paths point at the staged copies.
    public let offer: ClipboardLocalFileOffer
    public let stagedURLs: [URL]

    public init(offer: ClipboardLocalFileOffer, stagedURLs: [URL]) {
        self.offer = offer
        self.stagedURLs = stagedURLs
    }
}

/// Stages local clipboard files into the Agent's temp directory and builds the
/// direction-2 offer that advertises the staged copies (one offer per local
/// clipboard change). Not thread-safe by design: call it from one serial context
/// (the Agent's capture/clipboard path). All limits/name checks happen before
/// any file is created.
public final class ClipboardLocalFileOfferStager {
    /// Streaming copy granularity (design: never load a whole file in memory).
    public static let copyChunkBytes = 64 * 1024

    private let fileSystem: ClipboardLocalFileStagingFileSystem
    private var currentDirectory: ClipboardStagingDirectory?
    private var previousDirectory: ClipboardStagingDirectory?

    public init(fileSystem: ClipboardLocalFileStagingFileSystem) {
        self.fileSystem = fileSystem
    }

    public var currentOfferDirectoryURL: URL? { currentDirectory?.url }
    public var previousOfferDirectoryURL: URL? { previousDirectory?.url }

    /// Validates the pasteboard file list, copies every file into a new staging
    /// directory and returns the complete direction-2 offer. On any error the
    /// partial directory is deleted and the error is rethrown; the previously
    /// staged offer directories are left untouched.
    public func stage(
        urls: [URL],
        source: ClipboardLocalFileSource = FileManagerClipboardLocalFileSource()
    ) throws -> ClipboardLocalFileStagedOffer {
        // Contract limits/name/path validation first: a rejected list must not
        // create any directory.
        let metadata = try ClipboardLocalFileOfferBuilder.validate(urls: urls, source: source)
        let directory = try fileSystem.createOfferDirectory()
        do {
            var stagedURLs: [URL] = []
            stagedURLs.reserveCapacity(metadata.count)
            for (index, file) in metadata.enumerated() {
                let stagedName = Self.stagedFileName(index: index, name: file.name)
                let stagedURL = try copy(file: file, stagedName: stagedName,
                                         into: directory)
                stagedURLs.append(stagedURL)
            }
            let offer = ClipboardLocalFileOfferBuilder.makeOffer(
                metadata: metadata, paths: stagedURLs.map(\.path))
            rotate(directory)
            return ClipboardLocalFileStagedOffer(offer: offer, stagedURLs: stagedURLs)
        } catch {
            fileSystem.removeDirectory(directory)
            throw error
        }
    }

    /// Deletes all staging directories (session teardown). Safe to call more
    /// than once; the next stage() starts from scratch.
    public func removeAllDirectories() {
        if let previous = previousDirectory {
            fileSystem.removeDirectory(previous)
            previousDirectory = nil
        }
        if let current = currentDirectory {
            fileSystem.removeDirectory(current)
            currentDirectory = nil
        }
    }

    // MARK: - copy

    private func copy(file: ClipboardLocalFileMetadata, stagedName: String,
                      into directory: ClipboardStagingDirectory) throws -> URL {
        let sourceHandle: ClipboardStagingSourceHandle
        do {
            sourceHandle = try fileSystem.openSource(path: file.path)
        } catch let error as ClipboardLocalFileStagingError {
            throw error
        } catch {
            throw ClipboardLocalFileStagingError.unreadable(name: file.name, errno: 0)
        }
        defer { fileSystem.closeSource(sourceHandle) }

        var handle: ClipboardStagingFileHandle?
        do {
            let created = try fileSystem.createFile(named: stagedName, in: directory)
            handle = created
            var copied: UInt64 = 0
            while true {
                let chunk = try fileSystem.readSourceChunk(
                    sourceHandle, maxLength: Self.copyChunkBytes)
                if chunk.isEmpty { break }
                copied += UInt64(chunk.count)
                guard copied <= file.size else {
                    throw ClipboardLocalFileStagingError.sizeMismatch(
                        name: file.name, expected: file.size, actual: copied)
                }
                try fileSystem.append(chunk, to: created)
            }
            guard copied == file.size else {
                throw ClipboardLocalFileStagingError.sizeMismatch(
                    name: file.name, expected: file.size, actual: copied)
            }
            let url = try fileSystem.finish(created)
            handle = nil
            return url
        } catch {
            if let handle {
                fileSystem.discard(handle)
            }
            if let staging = error as? ClipboardLocalFileStagingError {
                throw staging
            }
            throw ClipboardLocalFileStagingError.fileSystem(String(describing: error))
        }
    }

    /// Rotates staging directories: at most current + previous are kept; the
    /// older one is deleted when a new offer is staged successfully.
    private func rotate(_ directory: ClipboardStagingDirectory) {
        if let previous = previousDirectory {
            fileSystem.removeDirectory(previous)
            previousDirectory = nil
        }
        if let current = currentDirectory {
            previousDirectory = current
        }
        currentDirectory = directory
    }

    // MARK: - staged names

    /// `"<index>-<sanitized name>"`, truncated to the 255-byte name limit at a
    /// UTF-8 boundary. The index prefix makes duplicate basenames from different
    /// folders unique inside the staging directory; the advertised entry name
    /// (original basename) and the fileIndex keep the wire identity.
    ///
    /// Length is measured in the *decomposed* (NFD) form because macOS URL/
    /// filesystem APIs canonicalise file names to NFD: e.g. "ä" (2 NFC bytes)
    /// becomes 3 NFD bytes, so measuring NFC would let a 254-byte name expand
    /// past the 255-byte filesystem component limit.
    public static func stagedFileName(index: Int, name: String) -> String {
        let prefix = "\(index)-"
        let prefixBytes = prefix.decomposedStringWithCanonicalMapping.utf8.count
        let maximumNameBytes = AgentIPCCodec.maxClipboardNameBytes - prefixBytes
        var result = prefix
        var used = prefixBytes
        guard maximumNameBytes > 0 else { return prefix }
        for scalar in name.unicodeScalars {
            let scalarText = String(scalar)
            let cost = scalarText.decomposedStringWithCanonicalMapping.utf8.count
            if used + cost > maximumNameBytes { break }
            result.unicodeScalars.append(scalar)
            used += cost
        }
        return result
    }
}

// MARK: - POSIX implementation (default)

/// Default `ClipboardLocalFileStagingFileSystem`: `NSTemporaryDirectory()/
/// rdp-clipboard-out/<uuid>/`, mode 0700 dirs and 0600 files, O_EXCL/O_NOFOLLOW
/// staging writes, and O_RDONLY|O_NOFOLLOW streaming source reads (64 KiB
/// chunks). The source is verified to be a regular file after open (defense
/// against a symlink/FIFO swap between the stat and the open).
public final class PosixClipboardLocalFileStagingFileSystem:
    ClipboardLocalFileStagingFileSystem {
    public static var defaultRootDirectory: URL {
        URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("rdp-clipboard-out", isDirectory: true)
    }

    private let rootDirectory: URL
    private var nextIdentifier = 0
    private var stagingDescriptors: [Int: Int32] = [:]
    private var stagedURLs: [Int: URL] = [:]
    private var sourceDescriptors: [Int: Int32] = [:]

    public init(rootDirectory: URL =
                PosixClipboardLocalFileStagingFileSystem.defaultRootDirectory) {
        self.rootDirectory = rootDirectory
    }

    public func createOfferDirectory() throws -> ClipboardStagingDirectory {
        try prepareRootDirectory()
        let directoryURL = rootDirectory.appendingPathComponent(UUID().uuidString,
                                                                isDirectory: true)
        let path = directoryURL.path
        guard path.withCString({ mkdir($0, mode_t(0o700)) }) == 0 else {
            throw ClipboardLocalFileStagingError.fileSystem("mkdir errno=\(errno)")
        }
        _ = path.withCString { chmod($0, mode_t(0o700)) }
        nextIdentifier += 1
        return ClipboardStagingDirectory(identifier: nextIdentifier, url: directoryURL)
    }

    public func createFile(named name: String,
                           in directory: ClipboardStagingDirectory) throws
        -> ClipboardStagingFileHandle {
        guard AgentClipboardFileValidation.isValidName(name) else {
            throw ClipboardLocalFileStagingError.invalidStagedName(name)
        }
        let fileURL = directory.url.appendingPathComponent(name, isDirectory: false)
        let path = fileURL.path
        guard path.utf8.count < 1024 else {
            throw ClipboardLocalFileStagingError.invalidStagedName(name)
        }
        let flags = O_CREAT | O_EXCL | O_WRONLY | O_NOFOLLOW
        let fd = path.withCString { open($0, flags, mode_t(0o600)) }
        guard fd >= 0 else {
            throw ClipboardLocalFileStagingError.fileSystem("open errno=\(errno)")
        }
        _ = fchmod(fd, mode_t(0o600))
        nextIdentifier += 1
        let handle = ClipboardStagingFileHandle(identifier: nextIdentifier)
        stagingDescriptors[handle.identifier] = fd
        stagedURLs[handle.identifier] = fileURL
        return handle
    }

    public func append(_ data: Data, to handle: ClipboardStagingFileHandle) throws {
        guard let fd = stagingDescriptors[handle.identifier] else {
            throw ClipboardLocalFileStagingError.fileSystem("write EBADF")
        }
        try data.withUnsafeBytes { rawBuffer in
            guard let base = rawBuffer.baseAddress, rawBuffer.count > 0 else { return }
            var offset = 0
            while offset < rawBuffer.count {
                let written = Darwin.write(fd, base.advanced(by: offset),
                                           rawBuffer.count - offset)
                if written < 0 {
                    if errno == EINTR { continue }
                    throw ClipboardLocalFileStagingError.fileSystem("write errno=\(errno)")
                }
                if written == 0 {
                    throw ClipboardLocalFileStagingError.fileSystem("write errno=EIO")
                }
                offset += written
            }
        }
    }

    public func finish(_ handle: ClipboardStagingFileHandle) throws -> URL {
        guard let fd = stagingDescriptors.removeValue(forKey: handle.identifier),
              let url = stagedURLs.removeValue(forKey: handle.identifier) else {
            throw ClipboardLocalFileStagingError.fileSystem("close EBADF")
        }
        guard Darwin.close(fd) == 0 else {
            throw ClipboardLocalFileStagingError.fileSystem("close errno=\(errno)")
        }
        return url
    }

    public func discard(_ handle: ClipboardStagingFileHandle) {
        guard let fd = stagingDescriptors.removeValue(forKey: handle.identifier) else { return }
        stagedURLs.removeValue(forKey: handle.identifier)
        _ = Darwin.close(fd)
    }

    public func removeDirectory(_ directory: ClipboardStagingDirectory) {
        guard isOwnedDirectory(directory.url) else { return }
        try? FileManager.default.removeItem(at: directory.url)
    }

    public func openSource(path: String) throws -> ClipboardStagingSourceHandle {
        let flags = O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK
        let fd = path.withCString { open($0, flags) }
        guard fd >= 0 else {
            throw ClipboardLocalFileStagingError.unreadable(
                name: Self.sanitizedBasename(path), errno: errno)
        }
        var status = stat()
        guard fstat(fd, &status) == 0,
              (status.st_mode & S_IFMT) == S_IFREG else {
            let error = errno
            _ = Darwin.close(fd)
            throw ClipboardLocalFileStagingError.unreadable(
                name: Self.sanitizedBasename(path), errno: error)
        }
        nextIdentifier += 1
        let handle = ClipboardStagingSourceHandle(identifier: nextIdentifier)
        sourceDescriptors[handle.identifier] = fd
        return handle
    }

    public func readSourceChunk(_ handle: ClipboardStagingSourceHandle,
                                maxLength: Int) throws -> Data {
        guard let fd = sourceDescriptors[handle.identifier] else {
            throw ClipboardLocalFileStagingError.readFailed(errno: EBADF)
        }
        guard maxLength > 0 else { return Data() }
        var buffer = [UInt8](repeating: 0, count: maxLength)
        while true {
            let read = buffer.withUnsafeMutableBytes { rawBuffer -> Int in
                guard let base = rawBuffer.baseAddress else { return 0 }
                return Darwin.read(fd, base, maxLength)
            }
            if read < 0 {
                if errno == EINTR { continue }
                throw ClipboardLocalFileStagingError.readFailed(errno: errno)
            }
            if read == 0 { return Data() }
            return Data(buffer[0..<read])
        }
    }

    public func closeSource(_ handle: ClipboardStagingSourceHandle) {
        guard let fd = sourceDescriptors.removeValue(forKey: handle.identifier) else { return }
        _ = Darwin.close(fd)
    }

    // MARK: - helpers

    private func prepareRootDirectory() throws {
        let manager = FileManager.default
        var isDirectory: ObjCBool = false
        if manager.fileExists(atPath: rootDirectory.path, isDirectory: &isDirectory) {
            guard isDirectory.boolValue else {
                throw ClipboardLocalFileStagingError.fileSystem("mkdir ENOTDIR")
            }
        } else if rootDirectory.path.withCString({ mkdir($0, mode_t(0o700)) }) != 0 {
            throw ClipboardLocalFileStagingError.fileSystem("mkdir errno=\(errno)")
        }
        _ = rootDirectory.path.withCString { chmod($0, mode_t(0o700)) }
    }

    private func isOwnedDirectory(_ url: URL) -> Bool {
        let root = rootDirectory.standardizedFileURL.path
        let path = url.standardizedFileURL.path
        guard path.hasPrefix(root + "/") else { return false }
        let name = String(path.dropFirst(root.count + 1))
        return !name.isEmpty && !name.contains("/") && UUID(uuidString: name) != nil
    }

    /// Log-safe basename: valid single component or the literal "file".
    static func sanitizedBasename(_ path: String) -> String {
        let name = URL(fileURLWithPath: path, isDirectory: false).lastPathComponent
        return AgentClipboardFileValidation.isValidName(name) ? name : "file"
    }
}
