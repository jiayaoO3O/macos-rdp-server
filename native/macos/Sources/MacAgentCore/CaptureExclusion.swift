public enum CaptureExclusion {
    public static func excludes(bundleIdentifier: String) -> Bool {
        bundleIdentifier == "com.microsoft.rdc.macos"
    }
}
