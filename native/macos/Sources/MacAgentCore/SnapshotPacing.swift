public enum SnapshotPacing {
    public static let defaultTargetFramesPerSecond = 30
    public static let minimumTargetFramesPerSecond = 1
    public static let maximumTargetFramesPerSecond = 120

    /// Nanoseconds between frames for a target rate, clamped to 1...120 fps.
    public static func intervalNanoseconds(targetFramesPerSecond: Int) -> UInt64 {
        let frames = min(max(targetFramesPerSecond, minimumTargetFramesPerSecond),
                         maximumTargetFramesPerSecond)
        return 1_000_000_000 / UInt64(frames)
    }

    /// Resolve the RDP_AGENT_TARGET_FPS environment value. Invalid/unset keeps
    /// the historical 30 fps default.
    public static func resolvedTargetFramesPerSecond(environmentValue: String?) -> Int {
        guard let value = environmentValue, let frames = Int(value),
              frames >= minimumTargetFramesPerSecond,
              frames <= maximumTargetFramesPerSecond else {
            return defaultTargetFramesPerSecond
        }
        return frames
    }

    public static func delayNanoseconds(elapsed: UInt64,
                                        intervalNanoseconds: UInt64) -> UInt64 {
        elapsed < intervalNanoseconds ? intervalNanoseconds - elapsed : 0
    }

    /// Historical 30 fps helper.
    public static func delayNanoseconds(elapsed: UInt64) -> UInt64 {
        delayNanoseconds(elapsed: elapsed,
                         intervalNanoseconds: intervalNanoseconds(targetFramesPerSecond: defaultTargetFramesPerSecond))
    }
}
