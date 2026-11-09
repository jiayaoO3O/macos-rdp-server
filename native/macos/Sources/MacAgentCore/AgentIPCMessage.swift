import Foundation

public enum AgentMessageType: UInt16 {
    case registerAgent = 1
    case frameReady
    case inputEvent
    case releaseInput
    case requestKeyframe
    case disconnect
    case frameChunk = 7
    case clipboardData = 8
    case captureSize = 9
    case frameDeltaBegin = 10
    case frameTile
    case frameDeltaEnd
    // Issue 3 file clipboard (docs/DESIGN-2026-11-08-clipboard-files.md §3).
    case clipboardFileOfferBegin = 13
    case clipboardFileChunk
    case clipboardFileOfferEnd
    case clipboardFileEntry
    // Auto display-mode matching: restore the saved original display mode.
    // Sent worker -> agent once on peer teardown, EMPTY (0-byte) payload
    // (docs/DESIGN-2026-11-08-virtual-display.md §2.2).
    case displayRestore = 17
}

public struct AgentIPCMessage: Equatable {
    public let type: AgentMessageType
    public let payload: Data

    public init(type: AgentMessageType, payload: Data = Data()) {
        self.type = type
        self.payload = payload
    }
}

public struct AgentFrameWireChunk {
    public let generation: UInt64
    public let frameID: UInt64
    public let offset: UInt32
    public let data: Data

    public init(generation: UInt64, frameID: UInt64, offset: UInt32, data: Data) {
        self.generation = generation
        self.frameID = frameID
        self.offset = offset
        self.data = data
    }
}

public enum AgentInputKind: UInt8 {
    case mouse = 1
    case scancode
    case unicode
    case releaseAll
}

public struct AgentInputEvent: Equatable {
    public let kind: AgentInputKind
    public let flags: UInt16
    public let code: UInt16
    public let x: UInt16
    public let y: UInt16

    public init(kind: AgentInputKind, flags: UInt16 = 0, code: UInt16 = 0,
                x: UInt16 = 0, y: UInt16 = 0) {
        self.kind = kind
        self.flags = flags
        self.code = code
        self.x = x
        self.y = y
    }
}

public enum AgentIPCError: Error, Equatable {
    case invalidMagic
    case unsupportedVersion(UInt16)
    case unknownMessageType(UInt16)
    case payloadTooLarge
    case invalidLength
    case invalidInputEvent
    case invalidDisplayRestore
}

// MARK: - Clipboard file IPC payloads (types 13..16)

/// Direction byte shared by file clipboard messages.
/// 1 = remote (Windows) -> local (macOS), 2 = local -> remote.
public enum AgentClipboardFileDirection: UInt8, Equatable {
    case remoteToLocal = 1
    case localToRemote = 2
}

/// Type 15 status: 0 complete, 1 cancelled (superseded), 2 error.
public enum AgentClipboardFileEndStatus: UInt8, Equatable {
    case complete = 0
    case cancelled = 1
    case error = 2
}

/// Type 13 payload: `u8 direction, u8 reserved=0, u16 fileCount, u64 totalBytes,
/// u32 flags` (16 bytes, big-endian).
public struct AgentClipboardFileOfferBegin: Equatable {
    public let direction: AgentClipboardFileDirection
    public let fileCount: UInt16
    public let totalBytes: UInt64
    public let flags: UInt32

    public init(direction: AgentClipboardFileDirection, fileCount: UInt16,
                totalBytes: UInt64, flags: UInt32 = 0) {
        self.direction = direction
        self.fileCount = fileCount
        self.totalBytes = totalBytes
        self.flags = flags
    }
}

/// Type 16 payload: 18-byte header followed by `nameUtf8[nameLen]` and
/// `pathUtf8[pathLen]`. Direction 1 carries no path; direction 2 requires an
/// absolute local path.
public struct AgentClipboardFileEntry: Equatable {
    public let direction: AgentClipboardFileDirection
    public let fileIndex: UInt32
    public let size: UInt64
    public let name: String
    public let path: String

    public init(direction: AgentClipboardFileDirection, fileIndex: UInt32, size: UInt64,
                name: String, path: String = "") {
        self.direction = direction
        self.fileIndex = fileIndex
        self.size = size
        self.name = name
        self.path = path
    }
}

/// Type 14 payload: `u32 fileIndex, u64 offset, then data` (big-endian).
public struct AgentClipboardFileChunk: Equatable {
    public let fileIndex: UInt32
    public let offset: UInt64
    public let data: Data

    public init(fileIndex: UInt32, offset: UInt64, data: Data) {
        self.fileIndex = fileIndex
        self.offset = offset
        self.data = data
    }
}

/// Type 15 payload: `u8 direction, u8 status, u16 errorCode, u32 fileCount`
/// (8 bytes, big-endian).
public struct AgentClipboardFileOfferEnd: Equatable {
    public let direction: AgentClipboardFileDirection
    public let status: AgentClipboardFileEndStatus
    public let errorCode: UInt16
    public let fileCount: UInt32

    public init(direction: AgentClipboardFileDirection, status: AgentClipboardFileEndStatus,
                errorCode: UInt16 = 0, fileCount: UInt32 = 0) {
        self.direction = direction
        self.status = status
        self.errorCode = errorCode
        self.fileCount = fileCount
    }
}

public enum AgentClipboardFileIPCError: Error, Equatable {
    case invalidOffer
    case invalidEntry
    case invalidChunk
    case invalidEnd
}

/// Result of tolerant frame decoding: unknown message types are reported
/// instead of thrown so a newer Worker cannot kill an older Agent.
public enum AgentIPCDecodeResult: Equatable {
    case message(AgentIPCMessage)
    case ignoredType(UInt16)
}

public enum AgentIPCCodec {
    public static let version: UInt16 = 1
    public static let headerSize = 12
    public static let maxPayloadSize = 64 * 1024
    public static let frameBeginPayloadSize = 25
    public static let frameChunkHeaderSize = 20
    public static let frameTileHeaderSize = 28
    public static let maxFrameChunkData = maxPayloadSize - frameChunkHeaderSize

    // Clipboard file transfer limits (docs/DESIGN-2026-11-08-clipboard-files.md
    // §3/§5). Both sides enforce them independently; these mirror the C worker
    // constants in internal/worker/clipboard_files.h.
    public static let maxClipboardFiles = 100
    /// Rejected when `size >= maxClipboardFileBytes` (matches the C worker,
    /// which refuses to serialize 2 GiB files without huge-file support).
    public static let maxClipboardFileBytes: UInt64 = 2 * 1024 * 1024 * 1024
    /// Rejected when `totalBytes > maxClipboardTotalBytes`.
    public static let maxClipboardTotalBytes: UInt64 = 4 * 1024 * 1024 * 1024
    public static let maxClipboardNameBytes = 255
    public static let maxClipboardPathBytes = 1023
    public static let clipboardFileOfferBeginPayloadSize = 16
    public static let clipboardFileChunkHeaderSize = 12
    public static let clipboardFileOfferEndPayloadSize = 8
    public static let clipboardFileEntryHeaderSize = 18
    public static let maxClipboardFileChunkData = maxPayloadSize - clipboardFileChunkHeaderSize

    public static func encode(_ message: AgentIPCMessage) throws -> Data {
        guard message.payload.count <= maxPayloadSize else { throw AgentIPCError.payloadTooLarge }

        var data = Data("RDPA".utf8)
        append(version, to: &data)
        append(message.type.rawValue, to: &data)
        append(UInt32(message.payload.count), to: &data)
        data.append(message.payload)
        return data
    }

    public static func decode(_ data: Data) throws -> AgentIPCMessage {
        let bytes = Array(data)
        guard bytes.count >= headerSize else { throw AgentIPCError.invalidLength }
        guard Array(bytes[0..<4]) == Array("RDPA".utf8) else { throw AgentIPCError.invalidMagic }

        let messageVersion = readUInt16(bytes, at: 4)
        guard messageVersion == version else { throw AgentIPCError.unsupportedVersion(messageVersion) }

        let rawType = readUInt16(bytes, at: 6)
        guard let type = AgentMessageType(rawValue: rawType) else {
            throw AgentIPCError.unknownMessageType(rawType)
        }

        let payloadSize = Int(readUInt32(bytes, at: 8))
        guard payloadSize <= maxPayloadSize else { throw AgentIPCError.payloadTooLarge }
        guard bytes.count == headerSize + payloadSize else { throw AgentIPCError.invalidLength }
        return AgentIPCMessage(type: type, payload: Data(bytes[headerSize...]))
    }

    /// Frame decoding that tolerates message types this Agent does not know.
    /// Used by the long-lived input receiver: a newer Worker sending a type this
    /// Agent was not built with must be ignored (design §3 compatibility), not
    /// thrown, because a throw used to kill the receiver and exit the Agent.
    /// Magic/version/length violations still throw.
    public static func decodeTolerant(_ data: Data) throws -> AgentIPCDecodeResult {
        let bytes = Array(data)
        guard bytes.count >= headerSize else { throw AgentIPCError.invalidLength }
        guard Array(bytes[0..<4]) == Array("RDPA".utf8) else { throw AgentIPCError.invalidMagic }

        let messageVersion = readUInt16(bytes, at: 4)
        guard messageVersion == version else { throw AgentIPCError.unsupportedVersion(messageVersion) }

        let payloadSize = Int(readUInt32(bytes, at: 8))
        guard payloadSize <= maxPayloadSize else { throw AgentIPCError.payloadTooLarge }
        guard bytes.count == headerSize + payloadSize else { throw AgentIPCError.invalidLength }

        let rawType = readUInt16(bytes, at: 6)
        guard let type = AgentMessageType(rawValue: rawType) else {
            return .ignoredType(rawType)
        }
        return .message(AgentIPCMessage(type: type, payload: Data(bytes[headerSize...])))
    }

    public static func encodeFrameBegin(_ metadata: AgentFrameMetadata) throws -> Data {
        guard metadata.generation > 0, metadata.frameID > 0, metadata.width > 0,
              metadata.height > 0, metadata.bytesPerPixel > 0, metadata.bytesPerPixel <= 4 else {
            throw AgentFrameError.invalidFrame
        }
        var data = Data()
        append(metadata.generation, to: &data)
        append(metadata.frameID, to: &data)
        append(metadata.width, to: &data)
        append(metadata.height, to: &data)
        data.append(metadata.bytesPerPixel)
        return data
    }

    public static func decodeFrameBegin(_ data: Data) throws -> AgentFrameMetadata {
        let bytes = Array(data)
        guard bytes.count == frameBeginPayloadSize else { throw AgentFrameError.invalidFrame }
        let metadata = AgentFrameMetadata(generation: readUInt64(bytes, at: 0),
                                          frameID: readUInt64(bytes, at: 8),
                                          width: readUInt32(bytes, at: 16),
                                          height: readUInt32(bytes, at: 20),
                                          bytesPerPixel: bytes[24])
        guard metadata.generation > 0, metadata.frameID > 0, metadata.width > 0,
              metadata.height > 0, metadata.bytesPerPixel > 0, metadata.bytesPerPixel <= 4 else {
            throw AgentFrameError.invalidFrame
        }
        return metadata
    }

    public static func encodeFrameDeltaBegin(_ metadata: AgentFrameMetadata,
                                             tileCount: UInt32) throws -> AgentIPCMessage {
        var payload = try encodeFrameBegin(metadata)
        append(tileCount, to: &payload)
        return AgentIPCMessage(type: .frameDeltaBegin, payload: payload)
    }

    public static func encodeFrameTilePrefix(generation: UInt64, frameID: UInt64,
                                             tile: AgentFrameTile) throws -> Data {
        guard generation > 0, frameID > 0, tile.x >= 0, tile.y >= 0,
              tile.x % 64 == 0, tile.y % 64 == 0,
              (1...64).contains(tile.width), (1...64).contains(tile.height),
              tile.pixels.count == tile.width * tile.height * 4,
              frameTileHeaderSize + tile.pixels.count <= maxPayloadSize else {
            throw AgentFrameError.invalidChunk
        }
        var prefix = Data("RDPA".utf8)
        append(version, to: &prefix)
        append(AgentMessageType.frameTile.rawValue, to: &prefix)
        append(UInt32(frameTileHeaderSize + tile.pixels.count), to: &prefix)
        append(generation, to: &prefix)
        append(frameID, to: &prefix)
        append(UInt32(tile.x), to: &prefix)
        append(UInt32(tile.y), to: &prefix)
        append(UInt16(tile.width), to: &prefix)
        append(UInt16(tile.height), to: &prefix)
        return prefix
    }

    public static func encodeFrameDeltaEnd(generation: UInt64, frameID: UInt64,
                                           tileCount: UInt32) -> AgentIPCMessage {
        var payload = Data()
        append(generation, to: &payload)
        append(frameID, to: &payload)
        append(tileCount, to: &payload)
        return AgentIPCMessage(type: .frameDeltaEnd, payload: payload)
    }

    public static func encodeFrameChunk(_ chunk: AgentFrameWireChunk) throws -> Data {
        guard chunk.generation > 0, chunk.frameID > 0, !chunk.data.isEmpty,
              chunk.data.count <= maxFrameChunkData else { throw AgentFrameError.invalidChunk }
        var payload = Data()
        append(chunk.generation, to: &payload)
        append(chunk.frameID, to: &payload)
        append(chunk.offset, to: &payload)
        payload.append(chunk.data)
        return payload
    }

    public static func encodeFrameChunkPrefix(generation: UInt64, frameID: UInt64,
                                              offset: UInt32, count: Int) throws -> Data {
        guard generation > 0, frameID > 0, count > 0, count <= maxFrameChunkData else {
            throw AgentFrameError.invalidChunk
        }
        var data = Data("RDPA".utf8)
        append(version, to: &data)
        append(AgentMessageType.frameChunk.rawValue, to: &data)
        append(UInt32(frameChunkHeaderSize + count), to: &data)
        append(generation, to: &data)
        append(frameID, to: &data)
        append(offset, to: &data)
        return data
    }

    public static func decodeFrameChunk(_ payload: Data) throws -> AgentFrameWireChunk {
        let bytes = Array(payload)
        guard bytes.count > frameChunkHeaderSize, bytes.count <= maxPayloadSize else {
            throw AgentFrameError.invalidChunk
        }
        let chunk = AgentFrameWireChunk(generation: readUInt64(bytes, at: 0),
                                        frameID: readUInt64(bytes, at: 8),
                                        offset: readUInt32(bytes, at: 16),
                                        data: Data(bytes[frameChunkHeaderSize...]))
        guard chunk.generation > 0, chunk.frameID > 0 else { throw AgentFrameError.invalidChunk }
        return chunk
    }

    public static func encodeCaptureSize(_ size: CaptureSizeRequest) -> Data {
        var data = Data()
        append(UInt32(size.width), to: &data)
        append(UInt32(size.height), to: &data)
        return data
    }

    public static func decodeCaptureSize(_ payload: Data) -> CaptureSizeRequest? {
        guard payload.count == 8 else { return nil }
        let bytes = Array(payload)
        return CaptureSizeRequest(width: Int(readUInt32(bytes, at: 0)),
                                  height: Int(readUInt32(bytes, at: 4)))
    }

    public static func encodeInputEvent(_ event: AgentInputEvent) -> Data {
        var payload = Data([event.kind.rawValue])
        append(event.flags, to: &payload)
        append(event.code, to: &payload)
        append(event.x, to: &payload)
        append(event.y, to: &payload)
        return payload
    }

    public static func decodeInputEvent(_ payload: Data) throws -> AgentInputEvent {
        let bytes = Array(payload)
        guard bytes.count == 9, let kind = AgentInputKind(rawValue: bytes[0]) else {
            throw AgentIPCError.invalidInputEvent
        }
        return AgentInputEvent(kind: kind, flags: readUInt16(bytes, at: 1),
                               code: readUInt16(bytes, at: 3),
                               x: readUInt16(bytes, at: 5), y: readUInt16(bytes, at: 7))
    }

    // MARK: - Clipboard file messages (types 13..16)

    public static func encodeClipboardFileOfferBegin(
        _ begin: AgentClipboardFileOfferBegin) throws -> Data {
        guard (1...maxClipboardFiles).contains(Int(begin.fileCount)),
              begin.totalBytes <= maxClipboardTotalBytes else {
            throw AgentClipboardFileIPCError.invalidOffer
        }
        var payload = Data([begin.direction.rawValue, 0])
        append(begin.fileCount, to: &payload)
        append(begin.totalBytes, to: &payload)
        append(begin.flags, to: &payload)
        return payload
    }

    public static func decodeClipboardFileOfferBegin(
        _ payload: Data) throws -> AgentClipboardFileOfferBegin {
        let bytes = Array(payload)
        guard bytes.count == clipboardFileOfferBeginPayloadSize,
              let direction = AgentClipboardFileDirection(rawValue: bytes[0]),
              bytes[1] == 0 else {
            throw AgentClipboardFileIPCError.invalidOffer
        }
        let fileCount = readUInt16(bytes, at: 2)
        let totalBytes = readUInt64(bytes, at: 4)
        let flags = readUInt32(bytes, at: 12)
        guard (1...maxClipboardFiles).contains(Int(fileCount)),
              totalBytes <= maxClipboardTotalBytes else {
            throw AgentClipboardFileIPCError.invalidOffer
        }
        return AgentClipboardFileOfferBegin(direction: direction, fileCount: fileCount,
                                            totalBytes: totalBytes, flags: flags)
    }

    public static func encodeClipboardFileEntry(
        _ entry: AgentClipboardFileEntry) throws -> Data {
        guard AgentClipboardFileValidation.isValidName(entry.name),
              entry.size < maxClipboardFileBytes else {
            throw AgentClipboardFileIPCError.invalidEntry
        }
        let nameBytes = Array(entry.name.utf8)
        let pathBytes = Array(entry.path.utf8)
        switch entry.direction {
        case .remoteToLocal:
            guard pathBytes.isEmpty else { throw AgentClipboardFileIPCError.invalidEntry }
        case .localToRemote:
            guard AgentClipboardFileValidation.isValidAbsolutePath(entry.path) else {
                throw AgentClipboardFileIPCError.invalidEntry
            }
        }
        var payload = Data([entry.direction.rawValue, 0])
        append(UInt16(nameBytes.count), to: &payload)
        append(entry.fileIndex, to: &payload)
        append(entry.size, to: &payload)
        append(UInt16(pathBytes.count), to: &payload)
        payload.append(contentsOf: nameBytes)
        payload.append(contentsOf: pathBytes)
        return payload
    }

    public static func decodeClipboardFileEntry(
        _ payload: Data) throws -> AgentClipboardFileEntry {
        let bytes = Array(payload)
        guard bytes.count >= clipboardFileEntryHeaderSize,
              let direction = AgentClipboardFileDirection(rawValue: bytes[0]),
              bytes[1] == 0 else {
            throw AgentClipboardFileIPCError.invalidEntry
        }
        let nameLength = Int(readUInt16(bytes, at: 2))
        let fileIndex = readUInt32(bytes, at: 4)
        let size = readUInt64(bytes, at: 8)
        let pathLength = Int(readUInt16(bytes, at: 16))
        guard (1...maxClipboardNameBytes).contains(nameLength),
              pathLength <= maxClipboardPathBytes,
              bytes.count == clipboardFileEntryHeaderSize + nameLength + pathLength,
              size < maxClipboardFileBytes else {
            throw AgentClipboardFileIPCError.invalidEntry
        }
        switch direction {
        case .remoteToLocal:
            guard pathLength == 0 else { throw AgentClipboardFileIPCError.invalidEntry }
        case .localToRemote:
            guard pathLength > 0 else { throw AgentClipboardFileIPCError.invalidEntry }
        }
        // The C worker validates the name/path character rules at parse time as
        // well; the Agent decodes the lengths/UTF-8 here and the assembly state
        // machine re-validates the name (defense in depth, design §5).
        let nameStart = clipboardFileEntryHeaderSize
        let pathStart = nameStart + nameLength
        guard let name = String(data: Data(bytes[nameStart..<pathStart]), encoding: .utf8) else {
            throw AgentClipboardFileIPCError.invalidEntry
        }
        let path: String
        if pathLength == 0 {
            path = ""
        } else {
            guard let decoded = String(data: Data(bytes[pathStart...]), encoding: .utf8) else {
                throw AgentClipboardFileIPCError.invalidEntry
            }
            path = decoded
        }
        return AgentClipboardFileEntry(direction: direction, fileIndex: fileIndex, size: size,
                                       name: name, path: path)
    }

    public static func encodeClipboardFileChunk(
        _ chunk: AgentClipboardFileChunk) throws -> Data {
        guard !chunk.data.isEmpty, chunk.data.count <= maxClipboardFileChunkData else {
            throw AgentClipboardFileIPCError.invalidChunk
        }
        var payload = Data()
        append(chunk.fileIndex, to: &payload)
        append(chunk.offset, to: &payload)
        payload.append(chunk.data)
        return payload
    }

    public static func decodeClipboardFileChunk(
        _ payload: Data) throws -> AgentClipboardFileChunk {
        let bytes = Array(payload)
        guard bytes.count > clipboardFileChunkHeaderSize,
              bytes.count <= maxPayloadSize else {
            throw AgentClipboardFileIPCError.invalidChunk
        }
        let dataLength = bytes.count - clipboardFileChunkHeaderSize
        guard dataLength <= maxClipboardFileChunkData else {
            throw AgentClipboardFileIPCError.invalidChunk
        }
        return AgentClipboardFileChunk(fileIndex: readUInt32(bytes, at: 0),
                                       offset: readUInt64(bytes, at: 4),
                                       data: Data(bytes[clipboardFileChunkHeaderSize...]))
    }

    public static func encodeClipboardFileOfferEnd(
        _ end: AgentClipboardFileOfferEnd) throws -> Data {
        var payload = Data([end.direction.rawValue, end.status.rawValue])
        append(end.errorCode, to: &payload)
        append(end.fileCount, to: &payload)
        return payload
    }

    public static func decodeClipboardFileOfferEnd(
        _ payload: Data) throws -> AgentClipboardFileOfferEnd {
        let bytes = Array(payload)
        guard bytes.count == clipboardFileOfferEndPayloadSize,
              let direction = AgentClipboardFileDirection(rawValue: bytes[0]),
              let status = AgentClipboardFileEndStatus(rawValue: bytes[1]) else {
            throw AgentClipboardFileIPCError.invalidEnd
        }
        return AgentClipboardFileOfferEnd(direction: direction, status: status,
                                          errorCode: readUInt16(bytes, at: 2),
                                          fileCount: readUInt32(bytes, at: 4))
    }

    // MARK: - Display mode restore (type 17)

    public static let displayRestorePayloadSize = 0

    /// Type 17 carries no payload: the Agent restores the display mode it saved
    /// before the auto display-mode switch (idempotent).
    public static func encodeDisplayRestore() -> Data {
        Data()
    }

    /// Strict decode: a type-17 payload must be empty. Returns nothing; throws
    /// `AgentIPCError.invalidDisplayRestore` for a non-empty payload.
    public static func decodeDisplayRestore(_ payload: Data) throws {
        guard payload.count == displayRestorePayloadSize else {
            throw AgentIPCError.invalidDisplayRestore
        }
    }

    private static func append<T: FixedWidthInteger>(_ value: T, to data: inout Data) {
        var bigEndian = value.bigEndian
        withUnsafeBytes(of: &bigEndian) { data.append(contentsOf: $0) }
    }

    private static func readUInt16(_ bytes: [UInt8], at offset: Int) -> UInt16 {
        (UInt16(bytes[offset]) << 8) | UInt16(bytes[offset + 1])
    }

    private static func readUInt64(_ bytes: [UInt8], at offset: Int) -> UInt64 {
        (UInt64(bytes[offset]) << 56) | (UInt64(bytes[offset + 1]) << 48) |
            (UInt64(bytes[offset + 2]) << 40) | (UInt64(bytes[offset + 3]) << 32) |
            (UInt64(bytes[offset + 4]) << 24) | (UInt64(bytes[offset + 5]) << 16) |
            (UInt64(bytes[offset + 6]) << 8) | UInt64(bytes[offset + 7])
    }

    private static func readUInt32(_ bytes: [UInt8], at offset: Int) -> UInt32 {
        (UInt32(bytes[offset]) << 24) | (UInt32(bytes[offset + 1]) << 16) |
            (UInt32(bytes[offset + 2]) << 8) | UInt32(bytes[offset + 3])
    }
}

/// Name/path rules shared by the clipboard file codec and the local offer
/// builder. These mirror the C worker validation in
/// `internal/worker/clipboard_files.h` (contract §5): a remote file name must be
/// one safe path component of at most 255 UTF-8 bytes, and a local->remote path
/// must be absolute, at most 1023 UTF-8 bytes and free of NUL/control bytes.
public enum AgentClipboardFileValidation {
    /// Non-ASCII control/formatting code points rejected by the worker too
    /// (design §5 "control chars"): C1 controls and bidi embedding/override
    /// marks. They can spoof or corrupt log lines and file names.
    private static func isUnsafeFormatScalar(_ value: UInt32) -> Bool {
        if value >= 0x80 && value <= 0x9F { return true }        // C1 controls
        if value == 0x200E || value == 0x200F { return true }     // LRM / RLM
        if value >= 0x202A && value <= 0x202E { return true }     // bidi embed/override
        if value >= 0x2066 && value <= 0x2069 { return true }     // bidi isolates
        return false
    }

    /// A safe single path component: 1...255 UTF-8 bytes, not empty, not "."
    /// or "..", no "/", "\\" or ":" and no NUL/control bytes, C1 or bidi
    /// formatting characters. A leading "-" is allowed. Swift strings are
    /// always valid Unicode, so invalid UTF-8 cannot be represented here; the
    /// wire decoder rejects it separately.
    public static func isValidName(_ name: String) -> Bool {
        let byteCount = name.utf8.count
        guard byteCount > 0, byteCount <= AgentIPCCodec.maxClipboardNameBytes,
              name != ".", name != ".." else {
            return false
        }
        for scalar in name.unicodeScalars {
            let value = scalar.value
            if value < 0x20 || value == 0x7F || value == UInt32(UInt8(ascii: "/"))
                || value == UInt32(UInt8(ascii: "\\")) || value == UInt32(UInt8(ascii: ":")) {
                return false
            }
            if isUnsafeFormatScalar(value) { return false }
        }
        return true
    }

    /// An absolute local file path of at most 1023 UTF-8 bytes with no
    /// NUL/control bytes, C1 or bidi formatting characters (the worker lstat's
    /// the file itself).
    public static func isValidAbsolutePath(_ path: String) -> Bool {
        let byteCount = path.utf8.count
        guard byteCount > 0, byteCount <= AgentIPCCodec.maxClipboardPathBytes,
              path.hasPrefix("/") else {
            return false
        }
        for scalar in path.unicodeScalars {
            let value = scalar.value
            if value < 0x20 || value == 0x7F {
                return false
            }
            if isUnsafeFormatScalar(value) { return false }
        }
        return true
    }
}
