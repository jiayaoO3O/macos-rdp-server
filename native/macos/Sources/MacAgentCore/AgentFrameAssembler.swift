import Foundation

public struct AgentFrameMetadata: Equatable {
    public let generation: UInt64
    public let frameID: UInt64
    public let width: UInt32
    public let height: UInt32
    public let bytesPerPixel: UInt8

    public init(generation: UInt64, frameID: UInt64, width: UInt32,
                height: UInt32, bytesPerPixel: UInt8) {
        self.generation = generation
        self.frameID = frameID
        self.width = width
        self.height = height
        self.bytesPerPixel = bytesPerPixel
    }
}

public struct AgentFrameChunk {
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

public struct AgentFrame {
    public let metadata: AgentFrameMetadata
    public let pixels: Data
}

public enum AgentFrameError: Error, Equatable {
    case staleGeneration
    case frameInFlight
    case invalidFrame
    case invalidChunk
}

public struct AgentFrameAssembler {
    public static let maxFrameDimension: UInt32 = 16_384

    private(set) public var generation: UInt64
    private let maxFrameBytes: UInt64
    private var metadata: AgentFrameMetadata?
    private var pixels = Data()
    private var seen: [Bool] = []
    private var received: UInt64 = 0

    public init(generation: UInt64, maxFrameBytes: UInt64) {
        self.generation = generation
        self.maxFrameBytes = maxFrameBytes
    }

    public mutating func setGeneration(_ generation: UInt64) {
        self.generation = generation
        reset()
    }

    public mutating func begin(_ value: AgentFrameMetadata) throws {
        guard value.generation == generation else { throw AgentFrameError.staleGeneration }
        guard value.frameID > 0, value.width > 0, value.height > 0,
              value.width <= Self.maxFrameDimension, value.height <= Self.maxFrameDimension,
              value.bytesPerPixel > 0, value.bytesPerPixel <= 4 else {
            throw AgentFrameError.invalidFrame
        }
        guard metadata == nil else { throw AgentFrameError.frameInFlight }

        let (pixelsCount, overflow1) = UInt64(value.width).multipliedReportingOverflow(by: UInt64(value.height))
        let (byteCount, overflow2) = pixelsCount.multipliedReportingOverflow(by: UInt64(value.bytesPerPixel))
        guard !overflow1, !overflow2, byteCount > 0, byteCount <= maxFrameBytes,
              byteCount <= UInt64(Int.max) else {
            throw AgentFrameError.invalidFrame
        }
        metadata = value
        pixels = Data(repeating: 0, count: Int(byteCount))
        seen = Array(repeating: false, count: Int(byteCount))
        received = 0
    }

    public mutating func append(_ chunk: AgentFrameChunk) throws {
        guard let active = metadata else { throw AgentFrameError.invalidChunk }
        guard chunk.generation == generation, chunk.generation == active.generation else {
            throw AgentFrameError.staleGeneration
        }
        let start = Int(chunk.offset)
        let end = start.addingReportingOverflow(chunk.data.count)
        guard chunk.frameID == active.frameID, !chunk.data.isEmpty,
              chunk.offset % UInt32(active.bytesPerPixel) == 0,
              !end.overflow, end.partialValue <= pixels.count else {
            throw AgentFrameError.invalidChunk
        }
        guard !seen[start..<end.partialValue].contains(true) else {
            throw AgentFrameError.invalidChunk
        }
        pixels.replaceSubrange(start..<end.partialValue, with: chunk.data)
        for index in start..<end.partialValue { seen[index] = true }
        received += UInt64(chunk.data.count)
    }

    public mutating func commit() -> AgentFrame? {
        guard let active = metadata, received == UInt64(pixels.count) else { return nil }
        let frame = AgentFrame(metadata: active, pixels: pixels)
        reset()
        return frame
    }

    private mutating func reset() {
        metadata = nil
        pixels = Data()
        seen = []
        received = 0
    }
}
