import Darwin
import Foundation

public final class AgentUnixSocket: @unchecked Sendable {
    private var descriptor: Int32
    private let stateLock = NSLock()

    public init(path: String) throws {
        let pathBytes = Array(path.utf8)
        guard path.hasPrefix("/"), pathBytes.count < 104 else {
            throw AgentUnixSocketError.invalidPath
        }
        let fd = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw AgentUnixSocketError.systemCall("socket", errno) }
        var noSignal: Int32 = 1
        guard setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSignal, socklen_t(MemoryLayout<Int32>.size)) == 0 else {
            let error = errno
            Darwin.close(fd)
            throw AgentUnixSocketError.systemCall("setsockopt", error)
        }
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        withUnsafeMutableBytes(of: &address.sun_path) { destination in
            destination.initializeMemory(as: UInt8.self, repeating: 0)
            destination.copyBytes(from: pathBytes)
        }
        let result = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { socketAddress in
                Darwin.connect(fd, socketAddress, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard result == 0 else {
            let error = errno
            Darwin.close(fd)
            throw AgentUnixSocketError.systemCall("connect", error)
        }
        descriptor = fd
    }

    deinit {
        close()
    }

    public func close() {
        stateLock.lock()
        defer { stateLock.unlock() }
        guard descriptor >= 0 else { return }
        _ = Darwin.shutdown(descriptor, SHUT_RDWR)
        Darwin.close(descriptor)
        descriptor = -1
    }

    public func send(_ message: AgentIPCMessage) throws {
        try writeAll(AgentIPCCodec.encode(message))
    }

    public func sendFrame(metadata: AgentFrameMetadata, pixels: Data) throws {
        let expected = UInt64(metadata.width) * UInt64(metadata.height) * UInt64(metadata.bytesPerPixel)
        guard expected == UInt64(pixels.count) else { throw AgentFrameError.invalidFrame }
        try send(AgentIPCMessage(type: .frameReady,
                                 payload: AgentIPCCodec.encodeFrameBegin(metadata)))
        var offset = 0
        try pixels.withUnsafeBytes { pixelBuffer in
            while offset < pixelBuffer.count {
                let count = min(AgentIPCCodec.maxFrameChunkData, pixelBuffer.count - offset)
                let prefix = try AgentIPCCodec.encodeFrameChunkPrefix(generation: metadata.generation,
                                                                      frameID: metadata.frameID,
                                                                      offset: UInt32(offset), count: count)
                try writeChunk(prefix: prefix, pixels: pixelBuffer, offset: offset, count: count)
                offset += count
            }
        }
    }

    public func sendFrameDelta(metadata: AgentFrameMetadata, tiles: [AgentFrameTile]) throws {
        guard !tiles.isEmpty, tiles.count <= Int(UInt32.max) else { throw AgentFrameError.invalidChunk }
        try send(try AgentIPCCodec.encodeFrameDeltaBegin(metadata, tileCount: UInt32(tiles.count)))
        for tile in tiles {
            let prefix = try AgentIPCCodec.encodeFrameTilePrefix(generation: metadata.generation,
                                                                 frameID: metadata.frameID, tile: tile)
            try tile.pixels.withUnsafeBytes { rawBuffer in
                try writeChunk(prefix: prefix, pixels: rawBuffer, offset: 0, count: rawBuffer.count)
            }
        }
        try send(AgentIPCCodec.encodeFrameDeltaEnd(generation: metadata.generation,
                                                   frameID: metadata.frameID,
                                                   tileCount: UInt32(tiles.count)))
    }

    private func writeChunk(prefix: Data, pixels: UnsafeRawBufferPointer, offset: Int, count: Int) throws {
        let fd = try currentDescriptor()
        try prefix.withUnsafeBytes { header in
            guard let headerBase = header.baseAddress, let pixelBase = pixels.baseAddress else {
                throw AgentUnixSocketError.closed
            }
            var sent = 0
            let total = header.count + count
            while sent < total {
                var vectors: [iovec] = []
                if sent < header.count {
                    vectors.append(iovec(iov_base: UnsafeMutableRawPointer(mutating: headerBase.advanced(by: sent)),
                                         iov_len: header.count - sent))
                }
                let pixelSent = max(0, sent - header.count)
                if pixelSent < count {
                    vectors.append(iovec(iov_base: UnsafeMutableRawPointer(mutating: pixelBase.advanced(by: offset + pixelSent)),
                                         iov_len: count - pixelSent))
                }
                let written = vectors.withUnsafeBufferPointer { Darwin.writev(fd, $0.baseAddress, Int32($0.count)) }
                if written < 0 {
                    if errno == EINTR { continue }
                    throw AgentUnixSocketError.systemCall("writev", errno)
                }
                if written == 0 { throw AgentUnixSocketError.closed }
                sent += written
            }
        }
    }

    public func receiveMessages(_ onMessage: (AgentIPCMessage) throws -> Void) throws {
        // Forward compatibility (design §3): a Worker released ahead of this
        // Agent may send message types we do not know. Throwing used to kill the
        // input receiver and exit the Agent, so unknown types are skipped with a
        // single grep-able log line per type instead.
        var unknownTypes = AgentIPCUnknownTypeLog()
        while true {
            let header = try readExact(AgentIPCCodec.headerSize)
            let length = (UInt32(header[8]) << 24) | (UInt32(header[9]) << 16) |
                (UInt32(header[10]) << 8) | UInt32(header[11])
            guard length <= AgentIPCCodec.maxPayloadSize else { throw AgentIPCError.payloadTooLarge }
            let payload = try readExact(Int(length))
            switch try AgentIPCCodec.decodeTolerant(Data(header + payload)) {
            case let .message(message):
                try onMessage(message)
            case let .ignoredType(rawType):
                if unknownTypes.shouldLog(rawType) {
                    fputs("event=ipc_message_ignored type=\(rawType)\n", stderr)
                }
            }
        }
    }

    private func writeAll(_ data: Data) throws {
        let fd = try currentDescriptor()
        try data.withUnsafeBytes { rawBuffer in
            guard let baseAddress = rawBuffer.baseAddress else { return }
            var offset = 0
            while offset < rawBuffer.count {
                let written = Darwin.send(fd,
                                          baseAddress.advanced(by: offset),
                                          rawBuffer.count - offset, 0)
                if written < 0 {
                    if errno == EINTR { continue }
                    throw AgentUnixSocketError.systemCall("send", errno)
                }
                if written == 0 { throw AgentUnixSocketError.closed }
                offset += written
            }
        }
    }

    private func currentDescriptor() throws -> Int32 {
        stateLock.lock()
        defer { stateLock.unlock() }
        guard descriptor >= 0 else { throw AgentUnixSocketError.closed }
        return descriptor
    }

    private func readExact(_ count: Int) throws -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: count)
        var offset = 0
        while offset < count {
            let received = bytes.withUnsafeMutableBytes { rawBuffer -> Int in
                guard let base = rawBuffer.baseAddress else { return 0 }
                do {
                    let fd = try currentDescriptor()
                    return Darwin.recv(fd, base.advanced(by: offset), count - offset, 0)
                } catch {
                    return -1
                }
            }
            if received < 0 {
                if errno == EINTR { continue }
                throw AgentUnixSocketError.systemCall("recv", errno)
            }
            if received == 0 { throw AgentUnixSocketError.closed }
            offset += received
        }
        return bytes
    }
}

public enum AgentUnixSocketError: Error, Equatable {
    case invalidPath
    case closed
    case systemCall(String, Int32)
}

/// Per-receiver dedupe of `event=ipc_message_ignored type=N` log lines: an
/// unknown type is reported once per connection, never once per message.
public struct AgentIPCUnknownTypeLog: Equatable {
    private var seen: Set<UInt16> = []

    public init() {}

    public mutating func shouldLog(_ rawType: UInt16) -> Bool {
        seen.insert(rawType).inserted
    }
}
