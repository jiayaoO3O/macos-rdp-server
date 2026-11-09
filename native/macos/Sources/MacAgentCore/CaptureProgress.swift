import Foundation

public struct CaptureProgress: Equatable {
    public private(set) var frameCount = 0
    public private(set) var width = 0
    public private(set) var height = 0

    public init() {}

    @discardableResult
    public mutating func record(width: Int, height: Int) -> Bool {
        guard width > 0, height > 0 else { return false }
        frameCount += 1
        self.width = width
        self.height = height
        return true
    }

    public func reached(targetFrameCount: Int) -> Bool {
        targetFrameCount > 0 && frameCount >= targetFrameCount
    }
}

/// Pixel format constant used by ScreenCaptureKit / CoreVideo for 32-bit BGRA.
public enum StreamPixelFormat {
    /// 'BGRA' as a big-endian FourCC, i.e. kCVPixelFormatType_32BGRA.
    public static let bgra: UInt32 = 0x42475241
    public static func isBGRA(_ format: UInt32) -> Bool { format == bgra }
}

/// Pure decision logic for the optional continuous SCStream capture path.
public struct StreamCaptureHealth: Equatable {
    public let startupTimeoutNanoseconds: UInt64
    public let minimumFrameCount: Int

    public init(startupTimeoutNanoseconds: UInt64 = 2_000_000_000,
                minimumFrameCount: Int = 1) {
        self.startupTimeoutNanoseconds = startupTimeoutNanoseconds
        self.minimumFrameCount = max(1, minimumFrameCount)
    }

    /// True when the stream has produced too few frames for too long, so the
    /// caller should fall back to the SCScreenshotManager loop.
    public func shouldFallBack(frameCount: Int, elapsedNanoseconds: UInt64) -> Bool {
        frameCount < minimumFrameCount && elapsedNanoseconds >= startupTimeoutNanoseconds
    }

    /// True when a delivered sample buffer can be forwarded to the RDP path.
    public static func isUsableFrame(pixelFormat: UInt32, width: Int, height: Int,
                                     maxDimension: UInt32) -> Bool {
        StreamPixelFormat.isBGRA(pixelFormat) &&
            width > 0 && height > 0 &&
            width <= Int(maxDimension) && height <= Int(maxDimension)
    }
}

/// Tracks whether the RDP-requested capture size differs from the size the
/// stream is currently configured for.
public struct StreamSizePlan: Equatable {
    public let requestedWidth: Int
    public let requestedHeight: Int
    public let configuredWidth: Int
    public let configuredHeight: Int

    public init(requestedWidth: Int, requestedHeight: Int,
                configuredWidth: Int, configuredHeight: Int) {
        self.requestedWidth = requestedWidth
        self.requestedHeight = requestedHeight
        self.configuredWidth = configuredWidth
        self.configuredHeight = configuredHeight
    }

    public var needsReconfigure: Bool {
        requestedWidth > 0 && requestedHeight > 0 &&
            (requestedWidth != configuredWidth || requestedHeight != configuredHeight)
    }

    /// Whether a delivered frame of this size can satisfy the requested size.
    public func accepts(frameWidth: Int, frameHeight: Int) -> Bool {
        requestedWidth > 0 && requestedHeight > 0 &&
            frameWidth == requestedWidth && frameHeight == requestedHeight
    }
}
