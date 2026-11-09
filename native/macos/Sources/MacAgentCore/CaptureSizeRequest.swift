import Foundation

public struct CaptureSizeRequest: Equatable {
    public let width: Int
    public let height: Int

    public init?(width: Int, height: Int) {
        guard width > 0, height > 0, width <= 16_384, height <= 16_384,
              UInt64(width) * UInt64(height) * 4 <= 64 * 1024 * 1024 else { return nil }
        self.width = width
        self.height = height
    }
}

public final class CaptureSizeState: @unchecked Sendable {
    private let lock = NSLock()
    private var size: CaptureSizeRequest

    public init(width: Int, height: Int) {
        size = CaptureSizeRequest(width: width, height: height)!
    }

    public func snapshot() -> CaptureSizeRequest {
        lock.lock()
        defer { lock.unlock() }
        return size
    }

    public func update(_ request: CaptureSizeRequest) {
        lock.lock()
        size = request
        lock.unlock()
    }
}
