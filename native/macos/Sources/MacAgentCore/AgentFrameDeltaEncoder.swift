import Darwin
import Foundation

public struct AgentFrameTile {
    public let x: Int
    public let y: Int
    public let width: Int
    public let height: Int
    public let pixels: Data
}

public struct AgentFrameDeltaEncoder {
    private var previousPixels: Data?
    private var previousWidth = 0
    private var previousHeight = 0
    private var previousGeneration: UInt64 = 0
    private var changedRows: [Bool] = []

    public init() {}

    /// Encode the changed 64x64 tiles of a captured frame. This variant keeps a
    /// reference to the pixels argument as the next frame's comparison baseline.
    public mutating func encode(pixels: Data, width: Int, height: Int,
                                generation: UInt64) throws -> [AgentFrameTile] {
        let tiles = try compare(pixels: pixels, width: width, height: height,
                                generation: generation)
        previousPixels = pixels
        previousWidth = width
        previousHeight = height
        previousGeneration = generation
        return tiles
    }

    /// Buffer-recycling variant. On return the inout pixels argument holds the
    /// previous frame's backing store (or an empty Data), so the caller can
    /// capture the next frame into it without a fresh multi-megabyte allocation.
    public mutating func encode(pixels: inout Data, width: Int, height: Int,
                                generation: UInt64) throws -> [AgentFrameTile] {
        let tiles = try compare(pixels: pixels, width: width, height: height,
                                generation: generation)
        let recycled = previousPixels
        previousPixels = pixels
        pixels = recycled ?? Data()
        previousWidth = width
        previousHeight = height
        previousGeneration = generation
        return tiles
    }

    private mutating func compare(pixels: Data, width: Int, height: Int,
                                  generation: UInt64) throws -> [AgentFrameTile] {
        guard width > 0, height > 0, generation > 0,
              width <= Int(AgentFrameAssembler.maxFrameDimension),
              height <= Int(AgentFrameAssembler.maxFrameDimension),
              UInt64(width) * UInt64(height) * 4 == UInt64(pixels.count) else {
            throw AgentFrameError.invalidFrame
        }

        let comparable = previousPixels != nil && previousWidth == width &&
            previousHeight == height && previousGeneration == generation
        var tiles: [AgentFrameTile] = []
        let currentBytes = pixels.withUnsafeBytes { $0 }
        let columns = (width + 63) / 64
        let rows = (height + 63) / 64

        if comparable, let previousPixels,
           let currentBase = currentBytes.baseAddress,
           let previousBase = previousPixels.withUnsafeBytes({ $0 }).baseAddress {
            // Full-width row comparison first: on a mostly static desktop this
            // is one memcmp per row instead of one per tile-row.
            if changedRows.count != height {
                changedRows = Array(repeating: false, count: height)
            }
            var anyChanged = false
            let rowBytes = width * 4
            for row in 0..<height {
                let changed = memcmp(currentBase.advanced(by: row * rowBytes),
                                     previousBase.advanced(by: row * rowBytes),
                                     rowBytes) != 0
                changedRows[row] = changed
                anyChanged = anyChanged || changed
            }
            guard anyChanged else { return [] }

            for tileY in 0..<rows {
                let y = tileY * 64
                let tileHeight = min(64, height - y)
                var bandChanged = false
                for row in y..<(y + tileHeight) where changedRows[row] {
                    bandChanged = true
                    break
                }
                guard bandChanged else { continue }
                for tileX in 0..<columns {
                    let x = tileX * 64
                    let tileWidth = min(64, width - x)
                    var changed = false
                    for row in y..<(y + tileHeight) where changedRows[row] {
                        let offset = (row * width + x) * 4
                        if memcmp(currentBase.advanced(by: offset),
                                  previousBase.advanced(by: offset),
                                  tileWidth * 4) != 0 {
                            changed = true
                            break
                        }
                    }
                    guard changed else { continue }
                    tiles.append(Self.makeTile(current: currentBase, width: width, y: y, x: x,
                                               tileWidth: tileWidth, tileHeight: tileHeight))
                }
            }
            return tiles
        }

        // No usable baseline (first frame, generation or size change): send all tiles.
        guard let currentBase = currentBytes.baseAddress else { return [] }
        for tileY in 0..<rows {
            let y = tileY * 64
            let tileHeight = min(64, height - y)
            for tileX in 0..<columns {
                let x = tileX * 64
                let tileWidth = min(64, width - x)
                tiles.append(Self.makeTile(current: currentBase, width: width, y: y, x: x,
                                           tileWidth: tileWidth, tileHeight: tileHeight))
            }
        }
        return tiles
    }

    private static func makeTile(current: UnsafeRawPointer, width: Int, y: Int, x: Int,
                                 tileWidth: Int, tileHeight: Int) -> AgentFrameTile {
        var tilePixels = Data(count: tileWidth * tileHeight * 4)
        tilePixels.withUnsafeMutableBytes { destination in
            guard let dst = destination.baseAddress else { return }
            for row in 0..<tileHeight {
                let sourceOffset = ((y + row) * width + x) * 4
                memcpy(dst.advanced(by: row * tileWidth * 4),
                       current.advanced(by: sourceOffset), tileWidth * 4)
            }
        }
        return AgentFrameTile(x: x, y: y, width: tileWidth, height: tileHeight,
                              pixels: tilePixels)
    }
}
