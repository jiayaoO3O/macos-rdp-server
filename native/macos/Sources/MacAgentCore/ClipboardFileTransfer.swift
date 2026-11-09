import Darwin
import Foundation

// Bidirectional file clipboard support for the Agent (Issue 3).
//
// Binding contract: docs/DESIGN-2026-11-08-clipboard-files.md.
//
// This file contains only side-effect-free/pure logic plus two injectable
// protocols, so every rule of the contract can be unit-tested without a real
// NSPasteboard, a real IPC socket or a running Worker:
//
//   * `ClipboardLocalFileOfferBuilder` (direction 2, macOS -> Windows): turn the
//     local pasteboard file URLs into the type 13 begin / type 16 entries /
//     type 15 end message sequence, enforcing the count/size/name limits.
//   * `ClipboardFileAssembler` (direction 1, Windows -> macOS): state machine
//     over begin/entry/chunk/end that validates the offer and writes the files
//     into a private temporary directory through
//     `ClipboardFileAssemblyFileSystem`. The default implementation is
//     `PosixClipboardFileAssemblyFileSystem` (0700 dirs, 0600 files,
//     O_CREAT|O_EXCL|O_WRONLY|O_NOFOLLOW).
//   * `ClipboardPasteboardBridge` / `ClipboardLocalClipboardDetector`: the thin
//     pasteboard surface the Agent's ClipboardMonitor needs; the real
//     NSPasteboard implementation lives in rdp-agent/main.swift.
//
// Logging and pasteboard mutation are deliberately out of this file: the Agent
// maps returned events to `event=...` lines and pasteboard writes.

// MARK: - Local -> remote offer (direction 2)

/// Metadata for one local clipboard file. `name` is the last path component and
/// `path` the absolute path handed to the Worker, which serves the bytes.
public struct ClipboardLocalFileMetadata: Equatable {
    public let name: String
    public let path: String
    public let size: UInt64

    public init(name: String, path: String, size: UInt64) {
        self.name = name
        self.path = path
        self.size = size
    }
}

/// Injectable metadata source for the local offer builder. The real
/// implementation stats the file; tests inject a fake.
public protocol ClipboardLocalFileSource {
    /// Returns nil when the URL is not a regular readable file (directory,
    /// symlink, missing or unreadable).
    func metadata(for url: URL) -> ClipboardLocalFileMetadata?
}

/// Default `ClipboardLocalFileSource` backed by `FileManager`.
public struct FileManagerClipboardLocalFileSource: ClipboardLocalFileSource {
    public init() {}

    public func metadata(for url: URL) -> ClipboardLocalFileMetadata? {
        guard url.isFileURL else { return nil }
        let path = url.path
        guard path.hasPrefix("/") else { return nil }
        // Reject symlinks and directories: the Worker must serve a regular file
        // and the Agent must not advertise a link to somewhere else (security,
        // design §5 local->remote bullet 1).
        guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey,
                                                             .isSymbolicLinkKey,
                                                             .fileSizeKey]),
              values.isRegularFile == true,
              values.isSymbolicLink != true,
              let size = values.fileSize, size >= 0,
              FileManager.default.isReadableFile(atPath: path) else {
            return nil
        }
        return ClipboardLocalFileMetadata(name: url.lastPathComponent, path: path,
                                          size: UInt64(size))
    }
}

public enum ClipboardLocalFileOfferError: Error, Equatable {
    case empty
    case tooManyFiles
    case invalidFile(index: Int)
    case invalidName(index: Int)
    case invalidPath(index: Int)
    case fileTooLarge(index: Int)
    case totalTooLarge
}

/// A complete direction-2 metadata offer. Only metadata crosses the IPC socket;
/// the Worker reads the bytes from `path` on demand.
public struct ClipboardLocalFileOffer: Equatable {
    public let begin: AgentClipboardFileOfferBegin
    public let entries: [AgentClipboardFileEntry]
    public let end: AgentClipboardFileOfferEnd

    public init(begin: AgentClipboardFileOfferBegin,
                entries: [AgentClipboardFileEntry],
                end: AgentClipboardFileOfferEnd) {
        self.begin = begin
        self.entries = entries
        self.end = end
    }

    /// begin, every entry in fileIndex order, end (design §3 order).
    public func messages() throws -> [AgentIPCMessage] {
        var messages: [AgentIPCMessage] = []
        messages.reserveCapacity(entries.count + 2)
        messages.append(AgentIPCMessage(type: .clipboardFileOfferBegin,
                                        payload: try AgentIPCCodec.encodeClipboardFileOfferBegin(begin)))
        for entry in entries {
            messages.append(AgentIPCMessage(type: .clipboardFileEntry,
                                            payload: try AgentIPCCodec.encodeClipboardFileEntry(entry)))
        }
        messages.append(AgentIPCMessage(type: .clipboardFileOfferEnd,
                                        payload: try AgentIPCCodec.encodeClipboardFileOfferEnd(end)))
        return messages
    }
}

/// Builds the macOS -> Windows (direction 2) file offer from pasteboard URLs.
///
/// `validate` performs the contract limit/name/path checks once (the stager in
/// ClipboardFileStaging.swift reuses it before copying); `makeOffer` assembles
/// the begin/entries/end payloads with the paths that will be sent on the wire
/// (the original paths without staging, the staged paths with staging).
public enum ClipboardLocalFileOfferBuilder {
    /// Validates the local pasteboard file list against the contract limits and
    /// returns one metadata record per URL, in fileIndex order.
    public static func validate(
        urls: [URL],
        source: ClipboardLocalFileSource = FileManagerClipboardLocalFileSource()
    ) throws -> [ClipboardLocalFileMetadata] {
        guard !urls.isEmpty else { throw ClipboardLocalFileOfferError.empty }
        guard urls.count <= AgentIPCCodec.maxClipboardFiles else {
            throw ClipboardLocalFileOfferError.tooManyFiles
        }

        var metadata: [ClipboardLocalFileMetadata] = []
        metadata.reserveCapacity(urls.count)
        var totalBytes: UInt64 = 0

        for (index, url) in urls.enumerated() {
            guard let file = source.metadata(for: url) else {
                throw ClipboardLocalFileOfferError.invalidFile(index: index)
            }
            guard AgentClipboardFileValidation.isValidName(file.name) else {
                throw ClipboardLocalFileOfferError.invalidName(index: index)
            }
            guard AgentClipboardFileValidation.isValidAbsolutePath(file.path) else {
                throw ClipboardLocalFileOfferError.invalidPath(index: index)
            }
            guard file.size < AgentIPCCodec.maxClipboardFileBytes else {
                throw ClipboardLocalFileOfferError.fileTooLarge(index: index)
            }
            let (sum, overflow) = totalBytes.addingReportingOverflow(file.size)
            guard !overflow, sum <= AgentIPCCodec.maxClipboardTotalBytes else {
                throw ClipboardLocalFileOfferError.totalTooLarge
            }
            totalBytes = sum
            metadata.append(file)
        }
        return metadata
    }

    /// Builds the direction-2 offer for already validated metadata and the paths
    /// that must be advertised (same count, same order).
    public static func makeOffer(metadata: [ClipboardLocalFileMetadata],
                                 paths: [String]) -> ClipboardLocalFileOffer {
        precondition(metadata.count == paths.count)
        var entries: [AgentClipboardFileEntry] = []
        entries.reserveCapacity(metadata.count)
        var totalBytes: UInt64 = 0
        for (index, file) in metadata.enumerated() {
            totalBytes += file.size
            entries.append(AgentClipboardFileEntry(direction: .localToRemote,
                                                   fileIndex: UInt32(index),
                                                   size: file.size,
                                                   name: file.name,
                                                   path: paths[index]))
        }
        let begin = AgentClipboardFileOfferBegin(
            direction: .localToRemote,
            fileCount: UInt16(entries.count),
            totalBytes: totalBytes)
        let end = AgentClipboardFileOfferEnd(direction: .localToRemote,
                                             status: .complete,
                                             fileCount: UInt32(entries.count))
        return ClipboardLocalFileOffer(begin: begin, entries: entries, end: end)
    }

    public static func build(
        urls: [URL],
        source: ClipboardLocalFileSource = FileManagerClipboardLocalFileSource()
    ) throws -> ClipboardLocalFileOffer {
        let metadata = try validate(urls: urls, source: source)
        return makeOffer(metadata: metadata, paths: metadata.map(\.path))
    }
}

// MARK: - Pasteboard bridge

/// The pasteboard surface the Agent's ClipboardMonitor uses. The real
/// implementation wraps `NSPasteboard.general` (rdp-agent/main.swift); tests
/// inject a fake so no real clipboard is touched.
public protocol ClipboardPasteboardBridge: AnyObject {
    var changeCount: Int { get }
    /// All file URLs currently on the pasteboard, or nil/empty when the
    /// clipboard does not hold file URLs.
    func readFileURLs() -> [URL]?
    func readText() -> String?
    /// clearContents() + writeObjects([NSURL...]).
    func writeFileURLs(_ urls: [URL]) -> Bool
    /// clearContents() + setString().
    func writeText(_ text: String) -> Bool
}

/// Pure conversion of pasteboard object arrays / property lists into file URLs.
public enum ClipboardPasteboardFileURLs {
    /// Accepts `URL`, `NSURL` and absolute `String` path objects (the legacy
    /// `NSFilenamesPboardType` property list is an array of String paths).
    /// Returns nil when no file URL is present.
    public static func fileURLs(from objects: [Any]?) -> [URL]? {
        guard let objects, !objects.isEmpty else { return nil }
        var urls: [URL] = []
        urls.reserveCapacity(objects.count)
        for object in objects {
            if let url = object as? URL {
                if url.isFileURL { urls.append(url) }
            } else if let url = object as? NSURL {
                let converted = url as URL
                if converted.isFileURL { urls.append(converted) }
            } else if let path = object as? String {
                if path.hasPrefix("/") {
                    urls.append(URL(fileURLWithPath: path, isDirectory: false))
                }
            }
        }
        return urls.isEmpty ? nil : urls
    }
}

public enum ClipboardLocalClipboardContent: Equatable {
    case text(String)
    case files([URL])
    case empty
}

/// Decides what a clipboard change should be forwarded as. Files win over text
/// when both are present (design §3: file offers replace the type-8 message for
/// the same change; a file change never also sends text and vice versa).
public enum ClipboardLocalClipboardDetector {
    public static func content(fileURLs: [URL]?, text: String?) -> ClipboardLocalClipboardContent {
        if let fileURLs, !fileURLs.isEmpty {
            return .files(fileURLs)
        }
        if let text, !text.isEmpty {
            return .text(text)
        }
        return .empty
    }
}

/// Applies the assembled remote file list to the pasteboard so Finder paste
/// works (clearContents + writeObjects, design §2.1 step 6).
public enum ClipboardRemotePasteboardWriter {
    @discardableResult
    public static func applyFileURLs(_ urls: [URL],
                                     to pasteboard: ClipboardPasteboardBridge) -> Bool {
        guard !urls.isEmpty else { return false }
        return pasteboard.writeFileURLs(urls)
    }
}

// MARK: - Remote -> local assembly (direction 1)

public struct ClipboardOfferDirectory: Equatable {
    public let identifier: Int
    public let url: URL

    public init(identifier: Int, url: URL) {
        self.identifier = identifier
        self.url = url
    }
}

public struct ClipboardFileAssemblyHandle: Equatable {
    public let identifier: Int

    public init(identifier: Int) {
        self.identifier = identifier
    }
}

/// Injectable file IO for the remote offer assembler. The default POSIX
/// implementation creates 0700 directories and 0600 files with O_EXCL; tests
/// inject an in-memory implementation and assert the exact call sequence.
public protocol ClipboardFileAssemblyFileSystem {
    func createOfferDirectory() throws -> ClipboardOfferDirectory
    func createFile(named name: String,
                    in directory: ClipboardOfferDirectory) throws -> ClipboardFileAssemblyHandle
    func append(_ data: Data, to handle: ClipboardFileAssemblyHandle) throws
    func finish(_ handle: ClipboardFileAssemblyHandle) throws -> URL
    func discard(_ handle: ClipboardFileAssemblyHandle)
    func removeDirectory(_ directory: ClipboardOfferDirectory)
}

public enum ClipboardFileAssemblyFailure: Error, Equatable {
    case invalidMessage
    case wrongDirection
    case unexpectedEntry
    case unexpectedChunk
    case invalidFileCount
    case tooManyFiles
    case totalTooLarge
    case duplicateEntry(index: UInt32)
    case entryIndexOutOfRange(index: UInt32)
    case invalidName(index: UInt32)
    case fileTooLarge(index: UInt32)
    case entriesExceedTotal(index: UInt32)
    case missingEntry(index: UInt32)
    case outOfOrderChunk(index: UInt32)
    case chunkGap(index: UInt32, expected: UInt64, actual: UInt64)
    case chunkOverlap(index: UInt32, expected: UInt64, actual: UInt64)
    case chunkOverflow(index: UInt32, expectedLength: UInt64, actualLength: Int)
    case fileSystem(String)
    case incompleteOffer(received: UInt64, expected: UInt64)
    case totalSizeMismatch(entries: UInt64, advertised: UInt64)
    case cancelledByPeer(errorCode: UInt16)
    case failedByPeer(errorCode: UInt16)
    case backpressure

    /// `reason=<token>` value for the Agent's grep-able log line (design §4).
    public var logReason: String {
        switch self {
        case .invalidMessage: return "bad_format"
        case .wrongDirection: return "wrong_direction"
        case .unexpectedEntry: return "unexpected_entry"
        case .unexpectedChunk: return "unexpected_chunk"
        case .invalidFileCount: return "invalid_file_count"
        case .tooManyFiles: return "too_many_files"
        case .totalTooLarge: return "too_large"
        case .duplicateEntry: return "duplicate_entry"
        case .entryIndexOutOfRange: return "bad_index"
        case .invalidName: return "bad_name"
        case .fileTooLarge: return "too_large"
        case .entriesExceedTotal: return "size_mismatch"
        case .missingEntry: return "missing_entry"
        case .outOfOrderChunk: return "bad_range"
        case .chunkGap: return "bad_range"
        case .chunkOverlap: return "bad_range"
        case .chunkOverflow: return "size_mismatch"
        case .fileSystem: return "io_failed"
        case .incompleteOffer: return "size_mismatch"
        case .totalSizeMismatch: return "size_mismatch"
        case .cancelledByPeer: return "cancelled"
        case .failedByPeer: return "peer_failed"
        case .backpressure: return "ipc_backpressure"
        }
    }
}

public enum ClipboardFileAssemblyEvent: Equatable {
    case offerStarted(fileCount: Int, totalBytes: UInt64)
    case fileFinished(index: UInt32, size: UInt64, url: URL)
    case offerCompleted(urls: [URL], totalBytes: UInt64)
    case offerCancelled
    case offerFailed(ClipboardFileAssemblyFailure)
}

/// State machine for a direction-1 (Windows -> macOS) file offer.
///
/// Enforced rules (design §2.1/§3/§5):
///   * one active offer per direction; a new begin implicitly cancels it,
///   * begin: fileCount 1...100 and totalBytes <= 4 GiB,
///   * entries: unique index < fileCount, safe single-component name (the
///     sanitized name is the only thing used for the file), size < 2 GiB,
///     running sum <= advertised total,
///   * chunks: strictly fileIndex order, each file starts at offset 0,
///     contiguous offsets (gap/overlap rejected), never past the advertised
///     file size, nonzero payload,
///   * end complete: every file received exactly its advertised size and the
///     summed sizes equal the advertised total, otherwise the offer fails,
///   * on cancel/error the offer directory is deleted; a new offer deletes the
///     oldest of the current/previous directories (at most two are kept).
///
/// The class is not thread-safe by design: run it on one serial queue (the
/// Agent uses `DispatchQueue(label: "rdp-agent.clipboard-files")`).
public final class ClipboardFileAssembler {
    private struct ActiveOffer {
        let fileCount: UInt32
        let totalBytes: UInt64
        let directory: ClipboardOfferDirectory
        var entries: [UInt32: AgentClipboardFileEntry]
        var entryBytes: UInt64
        var finishedURLs: [UInt32: URL]
        var currentIndex: UInt32
        var currentOffset: UInt64
        var currentHandle: ClipboardFileAssemblyHandle?
    }

    private let fileSystem: ClipboardFileAssemblyFileSystem
    private var active: ActiveOffer?
    private var currentDirectory: ClipboardOfferDirectory?
    private var previousDirectory: ClipboardOfferDirectory?

    public init(fileSystem: ClipboardFileAssemblyFileSystem) {
        self.fileSystem = fileSystem
    }

    public var isAssembling: Bool { active != nil }
    public var currentOfferDirectoryURL: URL? { currentDirectory?.url }
    public var previousOfferDirectoryURL: URL? { previousDirectory?.url }

    /// Handles one IPC message; returns the events the Agent should log/act on.
    /// Unknown message types return no events.
    public func handle(_ message: AgentIPCMessage) -> [ClipboardFileAssemblyEvent] {
        switch message.type {
        case .clipboardFileOfferBegin:
            return handleBegin(message.payload)
        case .clipboardFileEntry:
            return handleEntry(message.payload)
        case .clipboardFileChunk:
            return handleChunk(message.payload)
        case .clipboardFileOfferEnd:
            return handleEnd(message.payload)
        default:
            return []
        }
    }

    /// Aborts the active offer (e.g. IPC queue backpressure) and cleans up.
    public func abort(reason: ClipboardFileAssemblyFailure) -> [ClipboardFileAssemblyEvent] {
        guard active != nil else { return [] }
        let events = cancelActive() + [.offerFailed(reason)]
        return events
    }

    // MARK: begin

    private func handleBegin(_ payload: Data) -> [ClipboardFileAssemblyEvent] {
        let begin: AgentClipboardFileOfferBegin
        do {
            begin = try AgentIPCCodec.decodeClipboardFileOfferBegin(payload)
        } catch {
            return [.offerFailed(.invalidMessage)]
        }
        // The Agent only reassembles direction 1 (remote -> local); a direction-2
        // begin would be a Worker/Agent role confusion and is ignored.
        guard begin.direction == .remoteToLocal else { return [] }

        var events: [ClipboardFileAssemblyEvent] = []
        if active != nil {
            // "A begin message implicitly cancels any offer still in progress in
            // the same direction." (design §3)
            events.append(.offerCancelled)
            events.append(contentsOf: cancelActive())
        }
        guard begin.fileCount > 0 else { return events + [.offerFailed(.invalidFileCount)] }
        guard Int(begin.fileCount) <= AgentIPCCodec.maxClipboardFiles else {
            return events + [.offerFailed(.tooManyFiles)]
        }
        guard begin.totalBytes <= AgentIPCCodec.maxClipboardTotalBytes else {
            return events + [.offerFailed(.totalTooLarge)]
        }

        let directory: ClipboardOfferDirectory
        do {
            directory = try startOfferDirectory()
        } catch {
            return events + [.offerFailed(.fileSystem(String(describing: error)))]
        }
        active = ActiveOffer(fileCount: UInt32(begin.fileCount),
                            totalBytes: begin.totalBytes,
                            directory: directory,
                            entries: [:],
                            entryBytes: 0,
                            finishedURLs: [:],
                            currentIndex: 0,
                            currentOffset: 0,
                            currentHandle: nil)
        events.append(.offerStarted(fileCount: Int(begin.fileCount),
                                    totalBytes: begin.totalBytes))
        return events
    }

    /// Rotates the temp directories, keeping at most current + previous
    /// (design §3 limit bullet). The new directory is created first so a
    /// creation failure never deletes an older directory the pasteboard may
    /// still reference.
    private func startOfferDirectory() throws -> ClipboardOfferDirectory {
        let directory = try fileSystem.createOfferDirectory()
        if let previous = previousDirectory {
            fileSystem.removeDirectory(previous)
            previousDirectory = nil
        }
        if let current = currentDirectory {
            previousDirectory = current
        }
        currentDirectory = directory
        return directory
    }

    // MARK: entry

    private func handleEntry(_ payload: Data) -> [ClipboardFileAssemblyEvent] {
        guard var offer = active else { return [.offerFailed(.unexpectedEntry)] }
        let entry: AgentClipboardFileEntry
        do {
            entry = try AgentIPCCodec.decodeClipboardFileEntry(payload)
        } catch {
            return fail(&offer, .invalidMessage)
        }
        guard entry.direction == .remoteToLocal else {
            return fail(&offer, .wrongDirection)
        }
        guard entry.fileIndex < offer.fileCount else {
            return fail(&offer, .entryIndexOutOfRange(index: entry.fileIndex))
        }
        guard offer.entries[entry.fileIndex] == nil else {
            return fail(&offer, .duplicateEntry(index: entry.fileIndex))
        }
        // Only the sanitized last path component is ever used as a file name;
        // reject anything that is not one safe component (design §5).
        guard AgentClipboardFileValidation.isValidName(entry.name) else {
            return fail(&offer, .invalidName(index: entry.fileIndex))
        }
        guard entry.size < AgentIPCCodec.maxClipboardFileBytes else {
            return fail(&offer, .fileTooLarge(index: entry.fileIndex))
        }
        let (sum, overflow) = offer.entryBytes.addingReportingOverflow(entry.size)
        guard !overflow, sum <= offer.totalBytes else {
            return fail(&offer, .entriesExceedTotal(index: entry.fileIndex))
        }
        offer.entries[entry.fileIndex] = entry
        offer.entryBytes = sum
        active = offer
        return []
    }

    // MARK: chunk

    private func handleChunk(_ payload: Data) -> [ClipboardFileAssemblyEvent] {
        guard var offer = active else { return [.offerFailed(.unexpectedChunk)] }
        let chunk: AgentClipboardFileChunk
        do {
            chunk = try AgentIPCCodec.decodeClipboardFileChunk(payload)
        } catch {
            return fail(&offer, .invalidMessage)
        }
        var events: [ClipboardFileAssemblyEvent] = []
        // Zero-byte files complete without chunks: advance over them before the
        // first chunk of a later file arrives.
        if chunk.fileIndex > offer.currentIndex {
            if case .failure = advanceZeroSizedFiles(&offer, events: &events) {
                return fail(&offer, .outOfOrderChunk(index: chunk.fileIndex))
            }
        }
        guard chunk.fileIndex == offer.currentIndex else {
            return fail(&offer, .outOfOrderChunk(index: chunk.fileIndex))
        }
        guard let entry = offer.entries[chunk.fileIndex] else {
            return fail(&offer, .missingEntry(index: chunk.fileIndex))
        }
        if chunk.offset < offer.currentOffset {
            return fail(&offer, .chunkOverlap(index: chunk.fileIndex,
                                              expected: offer.currentOffset,
                                              actual: chunk.offset))
        }
        if chunk.offset > offer.currentOffset {
            return fail(&offer, .chunkGap(index: chunk.fileIndex,
                                          expected: offer.currentOffset,
                                          actual: chunk.offset))
        }
        guard chunk.data.count > 0 else { return fail(&offer, .unexpectedChunk) }
        let remaining = entry.size - offer.currentOffset
        guard UInt64(chunk.data.count) <= remaining else {
            return fail(&offer, .chunkOverflow(index: chunk.fileIndex,
                                               expectedLength: remaining,
                                               actualLength: chunk.data.count))
        }

        do {
            if offer.currentHandle == nil {
                offer.currentHandle = try fileSystem.createFile(named: entry.name,
                                                                in: offer.directory)
            }
            guard let handle = offer.currentHandle else {
                return fail(&offer, .fileSystem("missing_handle"))
            }
            try fileSystem.append(chunk.data, to: handle)
            offer.currentOffset += UInt64(chunk.data.count)
            if offer.currentOffset == entry.size {
                let url = try fileSystem.finish(handle)
                offer.currentHandle = nil
                offer.finishedURLs[chunk.fileIndex] = url
                events.append(.fileFinished(index: chunk.fileIndex, size: entry.size, url: url))
                offer.currentIndex += 1
                offer.currentOffset = 0
                if case .failure = advanceZeroSizedFiles(&offer, events: &events) {
                    return fail(&offer, .fileSystem("missing_handle"))
                }
            }
        } catch {
            return fail(&offer, .fileSystem(String(describing: error)))
        }
        active = offer
        return events
    }

    /// Completes consecutive zero-byte file entries (they have no chunks) and
    /// returns the next index that still needs data.
    private func advanceZeroSizedFiles(_ offer: inout ActiveOffer,
                                       events: inout [ClipboardFileAssemblyEvent]) -> Result<Void, ClipboardFileAssemblyFailure> {
        while offer.currentIndex < offer.fileCount {
            guard let entry = offer.entries[offer.currentIndex] else { return .success(()) }
            guard entry.size == 0 else { return .success(()) }
            do {
                let handle = try fileSystem.createFile(named: entry.name, in: offer.directory)
                let url = try fileSystem.finish(handle)
                offer.finishedURLs[offer.currentIndex] = url
                events.append(.fileFinished(index: offer.currentIndex, size: entry.size, url: url))
                offer.currentIndex += 1
                offer.currentOffset = 0
            } catch {
                return .failure(.fileSystem(String(describing: error)))
            }
        }
        return .success(())
    }

    // MARK: end

    private func handleEnd(_ payload: Data) -> [ClipboardFileAssemblyEvent] {
        guard var offer = active else {
            // An error/cancel end after a failed offer is benign.
            return []
        }
        let end: AgentClipboardFileOfferEnd
        do {
            end = try AgentIPCCodec.decodeClipboardFileOfferEnd(payload)
        } catch {
            return fail(&offer, .invalidMessage)
        }
        guard end.direction == .remoteToLocal else {
            return fail(&offer, .wrongDirection)
        }
        if end.status == .cancelled {
            return [.offerCancelled] + cancelActive()
        }
        if end.status == .error {
            return fail(&offer, .failedByPeer(errorCode: end.errorCode))
        }
        // status == .complete: every file must have arrived byte-exact.
        var events: [ClipboardFileAssemblyEvent] = []
        if case let .failure(reason) = advanceZeroSizedFiles(&offer, events: &events) {
            return fail(&offer, reason)
        }
        guard offer.entries.count == Int(offer.fileCount) else {
            return fail(&offer, .missingEntry(index: offer.currentIndex))
        }
        guard offer.entryBytes == offer.totalBytes else {
            return fail(&offer, .totalSizeMismatch(entries: offer.entryBytes,
                                                   advertised: offer.totalBytes))
        }
        guard offer.finishedURLs.count == Int(offer.fileCount) else {
            return fail(&offer, .incompleteOffer(received: offer.entryBytes,
                                                 expected: offer.totalBytes))
        }
        var urls: [URL] = []
        urls.reserveCapacity(Int(offer.fileCount))
        for index in 0..<offer.fileCount {
            guard let url = offer.finishedURLs[index] else {
                return fail(&offer, .missingEntry(index: index))
            }
            urls.append(url)
        }
        let totalBytes = offer.totalBytes
        active = nil
        // The completed directory stays as `currentDirectory` because the
        // pasteboard now references its file URLs.
        events.append(.offerCompleted(urls: urls, totalBytes: totalBytes))
        return events
    }

    // MARK: cleanup

    /// Discards the active offer's open file and deletes its directory.
    private func cancelActive() -> [ClipboardFileAssemblyEvent] {
        guard let offer = active else { return [] }
        if let handle = offer.currentHandle {
            fileSystem.discard(handle)
        }
        fileSystem.removeDirectory(offer.directory)
        active = nil
        if currentDirectory == offer.directory {
            currentDirectory = nil
        }
        return []
    }

    /// Fails the offer with `reason`, cleaning up its directory.
    private func fail(_ offer: inout ActiveOffer,
                      _ reason: ClipboardFileAssemblyFailure) -> [ClipboardFileAssemblyEvent] {
        active = offer
        _ = cancelActive()
        return [.offerFailed(reason)]
    }
}

// MARK: - POSIX file system (default implementation)

/// Creates the Agent's private temp tree: `NSTemporaryDirectory()/rdp-clipboard/
/// <uuid>/` with mode 0700, and files opened `O_CREAT|O_EXCL|O_WRONLY|
/// O_NOFOLLOW` with mode 0600 (design §3/§5).
public final class PosixClipboardFileAssemblyFileSystem: ClipboardFileAssemblyFileSystem {
    public enum Failure: Error, Equatable {
        case systemCall(String, Int32)
        case invalidName(String)
        case pathTooLong(String)
    }

    public static var defaultRootDirectory: URL {
        URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("rdp-clipboard", isDirectory: true)
    }

    private let rootDirectory: URL
    private var nextDirectoryIdentifier = 0
    private var nextHandleIdentifier = 0
    private var descriptors: [Int: Int32] = [:]
    private var fileURLs: [Int: URL] = [:]

    public init(rootDirectory: URL = PosixClipboardFileAssemblyFileSystem.defaultRootDirectory) {
        self.rootDirectory = rootDirectory
    }

    public func createOfferDirectory() throws -> ClipboardOfferDirectory {
        try prepareRootDirectory()
        let directoryURL = rootDirectory.appendingPathComponent(UUID().uuidString,
                                                                isDirectory: true)
        let path = directoryURL.path
        let result = path.withCString { mkdir($0, mode_t(0o700)) }
        guard result == 0 else {
            throw Failure.systemCall("mkdir", errno)
        }
        // The mode argument is masked by the umask; force the exact mode.
        _ = path.withCString { chmod($0, mode_t(0o700)) }
        nextDirectoryIdentifier += 1
        return ClipboardOfferDirectory(identifier: nextDirectoryIdentifier, url: directoryURL)
    }

    public func createFile(named name: String,
                           in directory: ClipboardOfferDirectory) throws -> ClipboardFileAssemblyHandle {
        guard AgentClipboardFileValidation.isValidName(name) else {
            throw Failure.invalidName(name)
        }
        let fileURL = directory.url.appendingPathComponent(name, isDirectory: false)
        let path = fileURL.path
        guard path.utf8.count < 1024 else { throw Failure.pathTooLong(path) }
        let flags = O_CREAT | O_EXCL | O_WRONLY | O_NOFOLLOW
        let fd = path.withCString { open($0, flags, mode_t(0o600)) }
        guard fd >= 0 else {
            throw Failure.systemCall("open", errno)
        }
        _ = fchmod(fd, mode_t(0o600))
        nextHandleIdentifier += 1
        let handle = ClipboardFileAssemblyHandle(identifier: nextHandleIdentifier)
        descriptors[handle.identifier] = fd
        fileURLs[handle.identifier] = fileURL
        return handle
    }

    public func append(_ data: Data, to handle: ClipboardFileAssemblyHandle) throws {
        guard let fd = descriptors[handle.identifier] else {
            throw Failure.systemCall("write", EBADF)
        }
        try data.withUnsafeBytes { rawBuffer in
            guard let base = rawBuffer.baseAddress, rawBuffer.count > 0 else { return }
            var offset = 0
            while offset < rawBuffer.count {
                let written = Darwin.write(fd, base.advanced(by: offset),
                                           rawBuffer.count - offset)
                if written < 0 {
                    if errno == EINTR { continue }
                    throw Failure.systemCall("write", errno)
                }
                if written == 0 { throw Failure.systemCall("write", EIO) }
                offset += written
            }
        }
    }

    public func finish(_ handle: ClipboardFileAssemblyHandle) throws -> URL {
        guard let fd = descriptors.removeValue(forKey: handle.identifier),
              let url = fileURLs.removeValue(forKey: handle.identifier) else {
            throw Failure.systemCall("close", EBADF)
        }
        guard Darwin.close(fd) == 0 else {
            throw Failure.systemCall("close", errno)
        }
        return url
    }

    public func discard(_ handle: ClipboardFileAssemblyHandle) {
        guard let fd = descriptors.removeValue(forKey: handle.identifier) else { return }
        fileURLs.removeValue(forKey: handle.identifier)
        _ = Darwin.close(fd)
    }

    public func removeDirectory(_ directory: ClipboardOfferDirectory) {
        guard isOwnedDirectory(directory.url) else { return }
        try? FileManager.default.removeItem(at: directory.url)
    }

    private func prepareRootDirectory() throws {
        let manager = FileManager.default
        var isDirectory: ObjCBool = false
        if manager.fileExists(atPath: rootDirectory.path, isDirectory: &isDirectory) {
            guard isDirectory.boolValue else {
                throw Failure.systemCall("mkdir", ENOTDIR)
            }
        } else {
            let result = rootDirectory.path.withCString { mkdir($0, mode_t(0o700)) }
            guard result == 0 else {
                throw Failure.systemCall("mkdir", errno)
            }
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
}
