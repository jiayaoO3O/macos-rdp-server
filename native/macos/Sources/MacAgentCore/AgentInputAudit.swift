public struct AgentInputAudit {
    private var loggedKinds = Set<AgentInputKind>()

    public init() {}

    public mutating func shouldLog(_ kind: AgentInputKind) -> Bool {
        loggedKinds.insert(kind).inserted
    }

    public static func label(for kind: AgentInputKind) -> String {
        switch kind {
        case .mouse: return "mouse"
        case .scancode: return "scancode"
        case .unicode: return "unicode"
        case .releaseAll: return "release_all"
        }
    }
}

public enum RDPWheel {
    /// Raw RDP wheel rotation: PTR_FLAGS_WHEEL (0x0200) plus a 9-bit signed
    /// rotation in units of 120 per notch (positive = wheel rotated away from
    /// the user, i.e. "scroll up" in Windows).
    public static func delta(flags: UInt16) -> Int? {
        guard flags & 0x0200 != 0 else { return nil }
        let value = Int(flags & 0x01ff)
        return (value & 0x0100) != 0 ? value - 0x0200 : value
    }

    /// Windows-convention scroll amount for a macOS CGEvent (`.line` units).
    ///
    /// Field report 2026-11-08: scrolling on macOS moved the opposite way from
    /// Windows. macOS posts a positive wheel1 for a scroll that Windows calls
    /// "down", so the sign is inverted here to keep the Windows feel the user
    /// asked for ("要兼容win的滚轮模式"). RDP rotation is 120 units per notch;
    /// converting to one line per notch avoids posting 120 lines for a single
    /// click of the wheel. A sub-notch rotation (some clients send smaller
    /// values) still produces one line in the matching direction.
    public static func macOSWheel1(flags: UInt16) -> Int32? {
        guard let rotation = delta(flags: flags), rotation != 0 else { return nil }
        let notches = rotation / 120
        let lines = notches != 0 ? notches : (rotation > 0 ? 1 : -1)
        return Int32(-lines)
    }
}
