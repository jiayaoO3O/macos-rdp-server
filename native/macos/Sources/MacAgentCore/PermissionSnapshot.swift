public struct PermissionSnapshot: Equatable {
    public let screenRecording: Bool
    public let accessibility: Bool

    public init(screenRecording: Bool, accessibility: Bool) {
        self.screenRecording = screenRecording
        self.accessibility = accessibility
    }

    public var desktopReady: Bool { false }
    public var needsScreenRecordingRequest: Bool { !screenRecording }
    public var needsAccessibilityRequest: Bool { !accessibility }

    public var report: String {
        "screen_recording=\(screenRecording ? "granted" : "missing") " +
        "accessibility=\(accessibility ? "granted" : "missing") desktop_ready=false"
    }
}
