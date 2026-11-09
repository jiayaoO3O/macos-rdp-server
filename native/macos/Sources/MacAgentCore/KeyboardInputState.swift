import Foundation

/// Snapshot of the macOS system modifier state.
///
/// This is an injected value (the platform layer reads
/// `CGEventSource.flagsState(.combinedSessionState)`) so this module stays
/// pure and unit-testable. It is used only for diagnostics: posting a modifier
/// key event with a nil event source is delivered to applications as a
/// `flagsChanged` event but does NOT update this combined session state, so a
/// stale injected modifier is visible to the focused app/IME while `sys=` here
/// still reports "up". Do not drive behaviour from it.
public struct KeyboardModifierFlags: Equatable {
    public let command: Bool
    public let option: Bool
    public let control: Bool
    public let shift: Bool
    public let capsLock: Bool

    public init(command: Bool = false, option: Bool = false, control: Bool = false,
                shift: Bool = false, capsLock: Bool = false) {
        self.command = command
        self.option = option
        self.control = control
        self.shift = shift
        self.capsLock = capsLock
    }

    public static let none = KeyboardModifierFlags()

    /// Build the flag set from the modifier virtual keys an injection currently
    /// holds down. Only Cmd/Option/Control/Shift/Caps are represented; device
    /// bits such as SecondaryFn/NumericPad are deliberately never derived here.
    /// Field 2026-11-08: nil-source CGEvents inherited a stale maskSecondaryFn
    /// bit, so a plain e arrived as Fn+E and opened the macOS Emoji & Symbols
    /// panel; the agent now stamps explicit flags on every event.
    public static func from(pressedVirtualKeys keys: Set<UInt16>) -> KeyboardModifierFlags {
        func held(_ candidates: [UInt16]) -> Bool { candidates.contains { keys.contains($0) } }
        return KeyboardModifierFlags(
            command: held([0x37, 0x36]),
            option: held([0x3a, 0x3d]),
            control: held([0x3b, 0x3e]),
            shift: held([0x38, 0x3c]),
            capsLock: held([0x39]))
    }

    /// Raw CGEventFlags bits. Kept numeric so this Foundation-only module stays
    /// unit-testable without CoreGraphics.
    public var cgEventFlagsRawValue: UInt64 {
        var raw: UInt64 = 0
        if command { raw |= 0x00100000 }   // kCGEventFlagMaskCommand
        if option { raw |= 0x00080000 }    // kCGEventFlagMaskAlternate
        if control { raw |= 0x00040000 }   // kCGEventFlagMaskControl
        if shift { raw |= 0x00020000 }     // kCGEventFlagMaskShift
        if capsLock { raw |= 0x00010000 }  // kCGEventFlagMaskAlphaShift
        return raw
    }

    /// Compact trace field, e.g. `cmd:0,opt:1,ctrl:0,shift:0,caps:0`.
    public var logValue: String {
        func bit(_ value: Bool) -> String { value ? "1" : "0" }
        return "cmd:\(bit(command)),opt:\(bit(option)),ctrl:\(bit(control))," +
               "shift:\(bit(shift)),caps:\(bit(capsLock))"
    }
}

/// The macOS virtual keycodes that represent modifiers in the RDP->CGEvent path
/// (MacKeyMap maps the RDP scancodes onto these).
public enum KeyboardModifierKey: UInt16, CaseIterable {
    case leftCommand = 0x37
    case rightCommand = 0x36
    case leftOption = 0x3a
    case rightOption = 0x3d
    case leftControl = 0x3b
    case rightControl = 0x3e
    case leftShift = 0x38
    case rightShift = 0x3c
    case capsLock = 0x39

    public var role: KeyboardModifierRole {
        switch self {
        case .leftCommand, .rightCommand: return .command
        case .leftOption, .rightOption: return .option
        case .leftControl, .rightControl: return .control
        case .leftShift, .rightShift: return .shift
        case .capsLock: return .capsLock
        }
    }
}

public enum KeyboardModifierRole: String, CaseIterable, Equatable {
    case command
    case option
    case control
    case shift
    case capsLock

    /// The conservative stuck-modifier guard only considers Cmd/Option/Control:
    /// a stuck Shift is visible (wrong case) and a stuck Caps Lock is a visible
    /// toggle, while a stuck Cmd/Option silently turns normal typing into
    /// application shortcuts (field report 2026-11-08: 'd' behaving like Cmd+D
    /// while typing with a Chinese IME).
    public var isGuarded: Bool {
        switch self {
        case .command, .option, .control: return true
        case .shift, .capsLock: return false
        }
    }
}

/// One RDP scancode event identity. `extended` is KBD_FLAGS_EXTENDED (0x0100)
/// and `extended1` is KBD_FLAGS_EXTENDED1 (0x0200, the E1-prefix family used by
/// Pause/Break): the same byte means a different key in each family, so the
/// press table is keyed by the whole identity.
public struct KeyboardScancodeIdentity: Hashable, Equatable {
    public let scancode: UInt16
    public let extended: Bool
    public let extended1: Bool

    public init(scancode: UInt16, extended: Bool, extended1: Bool = false) {
        self.scancode = scancode
        self.extended = extended
        self.extended1 = extended1
    }

    public var logValue: String {
        String(format: "code=0x%02x ext=%d ext1=%d", Int(scancode),
               extended ? 1 : 0, extended1 ? 1 : 0)
    }
}

/// One CGEvent that the platform layer must post.
public enum KeyboardEffect: Equatable {
    case key(virtualKey: UInt16, down: Bool)
    case unicode(code: UInt16, down: Bool)
}

/// A modifier that was pressed by the remote client, held long enough and
/// across enough non-modifier key-downs to conclude its key-up was lost.
public struct KeyboardStuckModifierRelease: Equatable {
    public let virtualKey: UInt16
    public let role: KeyboardModifierRole
    public let heldMilliseconds: UInt64
    public let keyDownsSincePress: Int

    public init(virtualKey: UInt16, role: KeyboardModifierRole,
                heldMilliseconds: UInt64, keyDownsSincePress: Int) {
        self.virtualKey = virtualKey
        self.role = role
        self.heldMilliseconds = heldMilliseconds
        self.keyDownsSincePress = keyDownsSincePress
    }
}

/// Command released early because it came from a Window key (0x5B/0x5C) that
/// the RDP client kept down beyond the combination. Field report 2026-11-08
/// (real Windows 11 mstsc session): the client sent Win-down and only sent the
/// matching Win-up 10.4 s later while the user typed 47 keys, so every glyph
/// arrived as Cmd+<key> (cut/select-all/Spotlight/emoji shortcuts fired and
/// text was swallowed). Win+<key> shortcuts still work: the release happens
/// after the combination's key-up (or after a second typed key as backstop).
public struct KeyboardWinCommandRelease: Equatable {
    public let virtualKey: UInt16
    public let heldMilliseconds: UInt64
    public let nonModifierDownsSincePress: Int
    /// "combo_complete" | "typing"
    public let reason: String

    public init(virtualKey: UInt16, heldMilliseconds: UInt64,
                nonModifierDownsSincePress: Int, reason: String) {
        self.virtualKey = virtualKey
        self.heldMilliseconds = heldMilliseconds
        self.nonModifierDownsSincePress = nonModifierDownsSincePress
        self.reason = reason
    }
}

public struct KeyboardScancodeResult: Equatable {
    public let effects: [KeyboardEffect]
    /// Set only the first time this identity is rejected, so the receiver can
    /// log it once per key instead of per auto-repeat.
    public let firstUnsupported: KeyboardScancodeIdentity?
    public let stuckModifierReleases: [KeyboardStuckModifierRelease]
    public let winCommandReleases: [KeyboardWinCommandRelease]

    public init(effects: [KeyboardEffect] = [], firstUnsupported: KeyboardScancodeIdentity? = nil,
                stuckModifierReleases: [KeyboardStuckModifierRelease] = [],
                winCommandReleases: [KeyboardWinCommandRelease] = []) {
        self.effects = effects
        self.firstUnsupported = firstUnsupported
        self.stuckModifierReleases = stuckModifierReleases
        self.winCommandReleases = winCommandReleases
    }
}

public struct KeyboardUnicodeResult: Equatable {
    public let effects: [KeyboardEffect]

    public init(effects: [KeyboardEffect]) {
        self.effects = effects
    }
}

public struct KeyboardReleaseAllResult: Equatable {
    public let effects: [KeyboardEffect]
    public let pressedKeys: Int
    public let pressedUnicode: Int
    /// Number of unconditional modifier key-ups included in `effects` (the
    /// sweep that clears a flagsChanged-style stale modifier in the focused app
    /// even when our press table never saw the key-down).
    public let sweptModifiers: Int

    public init(effects: [KeyboardEffect], pressedKeys: Int, pressedUnicode: Int,
                sweptModifiers: Int) {
        self.effects = effects
        self.pressedKeys = pressedKeys
        self.pressedUnicode = pressedUnicode
        self.sweptModifiers = sweptModifiers
    }
}

/// Optional stuck-modifier safety net. Default ON (field report 2026-11-08):
/// typing through RDP with a Chinese IME occasionally lost a modifier key-up,
/// after which every later keystroke behaved like a shortcut. Disable with
/// `RDP_AGENT_STUCK_MODIFIER_GUARD=0`.
///
/// Thresholds are deliberately conservative so legitimate long holds are not
/// broken: Cmd/Option/Control must stay down for at least 10 s *and* at least
/// 12 new non-modifier keys must be pressed in that window. A real Cmd/Option
/// combination held for 10 s while typing 12 different keys is vanishingly rare
/// (and the worst case is only that the modifier is released; the user presses
/// it again). Shift and Caps Lock are never auto-released.
public struct StuckModifierGuardConfig: Equatable {
    public let enabled: Bool
    public let heldMilliseconds: UInt64
    public let keyDownsSincePress: Int

    public init(enabled: Bool, heldMilliseconds: UInt64 = 10_000, keyDownsSincePress: Int = 12) {
        self.enabled = enabled
        self.heldMilliseconds = heldMilliseconds
        self.keyDownsSincePress = keyDownsSincePress
    }

    public static func resolve(environmentValue: String?) -> StuckModifierGuardConfig {
        StuckModifierGuardConfig(enabled: environmentValue != "0")
    }
}

/// Explicit opt-in diagnostic trace (`RDP_AGENT_INPUT_TRACE=1`): per-event
/// keyboard lines including scancodes. Off by default; the default audit log
/// stays "one line per input kind" and never records key codes or typed text.
public enum InputTraceFeatureGate {
    public static func isEnabled(environmentValue: String?) -> Bool {
        environmentValue == "1"
    }
}

/// Rate limiter for repeated drop/rejection log lines: allows one line per
/// interval and counts what was suppressed so the log stays honest without
/// flooding.
public struct RateLimitedLogGate: Equatable {
    public let intervalMilliseconds: UInt64
    private var lastAllowedMilliseconds: UInt64?
    private var suppressed = 0

    public init(intervalMilliseconds: UInt64 = 5_000) {
        self.intervalMilliseconds = intervalMilliseconds
    }

    public mutating func allow(nowMilliseconds: UInt64) -> Bool {
        if let last = lastAllowedMilliseconds,
           nowMilliseconds >= last,
           nowMilliseconds - last < intervalMilliseconds {
            suppressed += 1
            return false
        }
        lastAllowedMilliseconds = nowMilliseconds
        return true
    }

    /// Returns (and resets) the number of lines suppressed since the last call.
    public mutating func takeSuppressedCount() -> Int {
        defer { suppressed = 0 }
        return suppressed
    }
}

/// Pure keyboard state machine for the Agent input path.
///
/// Responsibilities:
/// - track presses by the full RDP scancode identity (scancode + extended
///   family) and always emit the matching key-up, including when a client sends
///   the key-up with a different extended flag than the key-down (previously an
///   orphaned key: `Enter` vs keypad-Enter, or a stuck modifier);
/// - report unmappable scancodes instead of throwing, and never disturb the
///   other pressed keys for them (an unmapped keypad/SysRq key used to throw,
///   and the old receiver answered every rejection with releaseAll());
/// - drop E1-prefix (KBD_FLAGS_EXTENDED1) events: interpreting their low byte
///   would turn Pause/Break (E1 1D 45) into a spurious Left Control press;
/// - keep unicode (typed text) presses separate and keyed by code unit;
/// - provide a full modifier sweep for release paths;
/// - run the conservative stuck-modifier guard.
///
/// Time is passed in by the caller (monotonic milliseconds) so tests are
/// deterministic.
public struct KeyboardInputState: Equatable {
    private struct PressRecord: Equatable {
        let identity: KeyboardScancodeIdentity
        let virtualKey: UInt16
        let modifierRole: KeyboardModifierRole?
        let pressedAtMilliseconds: UInt64
        var keyDownsSincePress: Int
        /// True when this press came from the Windows key (0x5B/0x5C), which the
        /// client can leave logically held across normal typing (field 2026-11-08).
        let isWindowKey: Bool
        /// Distinct non-modifier key-downs seen while this Window key is held.
        var nonModifierDownsSincePress: Int
    }

    /// True when any Cmd/Option/Control press is currently tracked. The agent
    /// uses this to resynchronise the WindowServer/AppKit modifier state before
    /// posting a plain key-down (field 2026-11-08: a stale injected Cmd/Ctrl made
    /// VS Code interpret a plain Space as the "Emoji & Symbols" shortcut).
    public var isGuardedModifierHeld: Bool {
        presses.values.contains { $0.modifierRole?.isGuarded == true }
    }

    public var guardConfig: StuckModifierGuardConfig
    private var presses: [KeyboardScancodeIdentity: PressRecord] = [:]
    private var unicodePresses: Set<UInt16> = []
    private var unsupportedIdentities: Set<KeyboardScancodeIdentity> = []
    private var unsupportedTotal = 0
    /// Window key identities whose Command was released early, with the time of
    /// suppression: their late key-up and auto-repeat are swallowed so Cmd cannot
    /// re-stick, while a genuinely new Window press (no event for >1.5 s) re-arms.
    private var suppressedWindowIdentities: [KeyboardScancodeIdentity: UInt64] = [:]

    public init(guardConfig: StuckModifierGuardConfig = StuckModifierGuardConfig(enabled: true)) {
        self.guardConfig = guardConfig
    }

    public var pressedKeyCount: Int { presses.count }
    public var pressedUnicodeCount: Int { unicodePresses.count }
    public var pressedVirtualKeys: [UInt16] { presses.values.map(\.virtualKey).sorted() }
    public var rejectedScancodeCount: Int { unsupportedTotal }

    /// Handle one keyboard IPC event (kind=scancode, kind=2 wire).
    public mutating func handleScancode(scancode: UInt16, flags: UInt16,
                                        nowMilliseconds: UInt64) -> KeyboardScancodeResult {
        let down = flags & MacKeyMap.flagRelease == 0
        let extended = flags & MacKeyMap.flagExtended != 0
        let extended1 = flags & MacKeyMap.flagExtended1 != 0

        // E1-prefixed keys (Pause/Break) have no macOS equivalent and their low
        // byte collides with real keys (0x1D would inject Left Control). Drop
        // the whole family.
        if extended1 {
            let identity = KeyboardScancodeIdentity(scancode: scancode,
                                                    extended: extended, extended1: true)
            return KeyboardScancodeResult(firstUnsupported: noteUnsupported(identity))
        }

        let identity = KeyboardScancodeIdentity(scancode: scancode, extended: extended)
        if down {
            // A Window key whose Command was already released early: swallow its
            // auto-repeat / repeated down events until the client finally sends
            // the matching key-up, otherwise Cmd would re-stick mid-typing. A
            // new press after >1.5 s of silence re-arms (the old key-up was lost
            // but the key is physically pressed again).
            if let suppressedAt = suppressedWindowIdentities[identity] {
                if nowMilliseconds >= suppressedAt && nowMilliseconds - suppressedAt < 1_500 {
                    return KeyboardScancodeResult()
                }
                suppressedWindowIdentities.removeValue(forKey: identity)
            }
            guard let virtualKey = MacKeyMap.virtualKey(scancode: scancode, extended: extended) else {
                return KeyboardScancodeResult(firstUnsupported: noteUnsupported(identity))
            }
            let alreadyDown = presses[identity] != nil
            if !alreadyDown {
                let role = KeyboardModifierKey(rawValue: virtualKey)?.role
                let isWindowKey = scancode == 0x5b || scancode == 0x5c
                presses[identity] = PressRecord(identity: identity, virtualKey: virtualKey,
                                                modifierRole: role,
                                                pressedAtMilliseconds: nowMilliseconds,
                                                keyDownsSincePress: 0,
                                                isWindowKey: isWindowKey,
                                                nonModifierDownsSincePress: 0)
                // Count only new non-modifier presses (not auto-repeat) towards
                // the guard: fast typing with a real modifier held must not
                // trip it.
                if role == nil {
                    for key in Array(presses.keys) {
                        guard let current = presses[key],
                              current.modifierRole?.isGuarded == true else { continue }
                        presses[key]?.keyDownsSincePress = current.keyDownsSincePress + 1
                    }
                    for key in Array(presses.keys) where presses[key]?.isWindowKey == true {
                        presses[key]?.nonModifierDownsSincePress += 1
                    }
                }
            }
            let stuck = evaluateStuckModifiers(nowMilliseconds: nowMilliseconds)
            // A Window key is a shortcut for its FIRST key only: a client that
            // still holds Win while the user keeps typing (Windows clipboard
            // history Win+V, IME switcher Win+Space, or a lost key-up) must not
            // turn the following characters into Cmd+<key>. Release Cmd right
            // after the first key-down so the next key is plain typing.
            let windowReleased = evaluateWindowCommandReleases(nowMilliseconds: nowMilliseconds,
                                                               reason: "first_key",
                                                               minimumNonModifierDowns: 1)
            var effects: [KeyboardEffect] = []
            if !windowReleased.isEmpty && virtualKey == 0x31 {
                // Win+Space is the Windows IME switch: do not turn it into
                // Cmd+Space (Spotlight). Post the Cmd-up first, then a plain
                // Space (which also selects the pinyin candidate).
                effects.append(contentsOf: windowReleased.map { .key(virtualKey: $0.virtualKey, down: false) })
                effects.append(.key(virtualKey: virtualKey, down: true))
            } else {
                effects.append(.key(virtualKey: virtualKey, down: true))
                effects.append(contentsOf: windowReleased.map { .key(virtualKey: $0.virtualKey, down: false) })
            }
            effects.append(contentsOf: stuck.map { .key(virtualKey: $0.virtualKey, down: false) })
            return KeyboardScancodeResult(effects: effects,
                                          stuckModifierReleases: stuck,
                                          winCommandReleases: windowReleased)
        }

        // Release. Prefer the exact identity that was pressed; if the client
        // flipped the extended flag between down and up, fall back to the other
        // family so the mapped key is still released (no orphaned modifier).
        let fallbackIdentity = KeyboardScancodeIdentity(scancode: scancode, extended: !extended)
        if let record = presses.removeValue(forKey: identity)
            ?? presses.removeValue(forKey: fallbackIdentity) {
            var effects: [KeyboardEffect] = [.key(virtualKey: record.virtualKey, down: false)]
            var windowReleased: [KeyboardWinCommandRelease] = []
            // Combo completed: the first non-modifier key-up while a Window key
            // is still held releases the Window-sourced Command, so a client
            // that keeps Win down across typing cannot turn the next 46 keys
            // into Cmd+<key> shortcuts.
            if record.modifierRole == nil {
                windowReleased = evaluateWindowCommandReleases(nowMilliseconds: nowMilliseconds,
                                                               reason: "combo_complete",
                                                               minimumNonModifierDowns: 1)
                effects.append(contentsOf: windowReleased.map { .key(virtualKey: $0.virtualKey, down: false) })
            }
            return KeyboardScancodeResult(effects: effects, winCommandReleases: windowReleased)
        }
        if suppressedWindowIdentities.removeValue(forKey: identity) != nil {
            return KeyboardScancodeResult()
        }
        if suppressedWindowIdentities.removeValue(forKey: fallbackIdentity) != nil {
            return KeyboardScancodeResult()
        }
        // Nothing tracked: still post the key-up mapped from either family. This
        // is a harmless resynchronisation step (a key-up for a key that is not
        // down produces a flagsChanged-style "no modifiers" event) and helps
        // clear state after a lost key-down.
        if let virtualKey = MacKeyMap.virtualKey(scancode: scancode, extended: extended)
            ?? MacKeyMap.virtualKey(scancode: scancode, extended: !extended) {
            return KeyboardScancodeResult(effects: [.key(virtualKey: virtualKey, down: false)])
        }
        return KeyboardScancodeResult(firstUnsupported: noteUnsupported(identity))
    }

    /// Handle one unicode IPC event (kind=unicode, kind=3 wire). The code is a
    /// UTF-16 code unit of typed text: callers must never log it.
    public mutating func handleUnicode(code: UInt16, flags: UInt16) -> KeyboardUnicodeResult {
        let down = flags & MacKeyMap.flagRelease == 0
        if down {
            unicodePresses.insert(code)
        } else {
            unicodePresses.remove(code)
        }
        return KeyboardUnicodeResult(effects: [.unicode(code: code, down: down)])
    }

    /// Release everything and sweep all modifier keys.
    ///
    /// The sweep posts a key-up for Cmd/Option/Control/Shift/Caps even when the
    /// press table never saw the key-down: nil-source modifier events are
    /// delivered to applications as flagsChanged events but do not update
    /// WindowServer's combined state, so an unmatched injected modifier can be
    /// stuck in the focused app/IME. A key-up for a key that is not down is a
    /// no-op for normal typing and clears that stale flagsChanged state (the
    /// same effect as the user pressing a real key on the Mac).
    public mutating func releaseAll() -> KeyboardReleaseAllResult {
        var effects: [KeyboardEffect] = []
        for record in presses.values.sorted(by: {
            ($0.identity.scancode, $0.identity.extended ? 1 : 0) <
            ($1.identity.scancode, $1.identity.extended ? 1 : 0)
        }) {
            effects.append(.key(virtualKey: record.virtualKey, down: false))
        }
        for code in unicodePresses.sorted() {
            effects.append(.unicode(code: code, down: false))
        }
        let released = Set(effects.compactMap { effect -> UInt16? in
            if case let .key(virtualKey, down: false) = effect { return virtualKey }
            return nil
        })
        var swept = 0
        for modifier in KeyboardModifierKey.allCases where !released.contains(modifier.rawValue) {
            effects.append(.key(virtualKey: modifier.rawValue, down: false))
            swept += 1
        }
        let counts = (presses.count, unicodePresses.count)
        presses.removeAll()
        unicodePresses.removeAll()
        suppressedWindowIdentities.removeAll()
        return KeyboardReleaseAllResult(effects: effects, pressedKeys: counts.0,
                                        pressedUnicode: counts.1, sweptModifiers: swept)
    }

    private mutating func noteUnsupported(_ identity: KeyboardScancodeIdentity) -> KeyboardScancodeIdentity? {
        unsupportedTotal += 1
        return unsupportedIdentities.insert(identity).inserted ? identity : nil
    }

    /// Release Command when it came from a Window key that the client is still
    /// holding after a real combination key was pressed. Called on the combo's
    /// first key-up (minimumNonModifierDowns=1) and as a backstop on typed keys
    /// (minimumNonModifierDowns=2). The identity is remembered so the client's
    /// late Window key-up (and any repeat) is swallowed instead of re-sticking Cmd.
    private mutating func evaluateWindowCommandReleases(
        nowMilliseconds: UInt64, reason: String,
        minimumNonModifierDowns: Int) -> [KeyboardWinCommandRelease] {
        var releases: [KeyboardWinCommandRelease] = []
        for key in Array(presses.keys) {
            guard let record = presses[key], record.isWindowKey,
                  record.nonModifierDownsSincePress >= minimumNonModifierDowns else { continue }
            presses.removeValue(forKey: key)
            suppressedWindowIdentities[key] = nowMilliseconds
            releases.append(KeyboardWinCommandRelease(
                virtualKey: record.virtualKey,
                heldMilliseconds: nowMilliseconds >= record.pressedAtMilliseconds
                    ? nowMilliseconds - record.pressedAtMilliseconds : 0,
                nonModifierDownsSincePress: record.nonModifierDownsSincePress,
                reason: reason))
        }
        return releases.sorted { $0.virtualKey < $1.virtualKey }
    }

    private mutating func evaluateStuckModifiers(
        nowMilliseconds: UInt64) -> [KeyboardStuckModifierRelease] {
        guard guardConfig.enabled else { return [] }
        var releases: [KeyboardStuckModifierRelease] = []
        for key in Array(presses.keys) {
            guard let record = presses[key],
                  let role = record.modifierRole, role.isGuarded else { continue }
            guard record.keyDownsSincePress >= guardConfig.keyDownsSincePress else { continue }
            guard nowMilliseconds >= record.pressedAtMilliseconds,
                  nowMilliseconds - record.pressedAtMilliseconds >= guardConfig.heldMilliseconds
            else { continue }
            presses.removeValue(forKey: key)
            releases.append(KeyboardStuckModifierRelease(
                virtualKey: record.virtualKey, role: role,
                heldMilliseconds: nowMilliseconds - record.pressedAtMilliseconds,
                keyDownsSincePress: record.keyDownsSincePress))
        }
        return releases.sorted { $0.virtualKey < $1.virtualKey }
    }
}

/// Compact, privacy-aware formatting for the opt-in input trace.
public enum InputTraceFormatter {
    public static func scancodeLine(flags: UInt16, identity: KeyboardScancodeIdentity,
                                    mappedVirtualKey: UInt16?, down: Bool,
                                    systemFlags: KeyboardModifierFlags,
                                    pressedKeys: Int) -> String {
        let mapped = mappedVirtualKey.map { String(format: "mapped=0x%02x", Int($0)) } ?? "mapped=none"
        return String(format: "event=input_trace kind=scancode flags=0x%04x ", Int(flags)) +
               identity.logValue + " " + mapped + " down=" + (down ? "1" : "0") +
               " sys=" + systemFlags.logValue + " pressed_keys=" + String(pressedKeys)
    }

    /// Unicode events carry typed text: never render the code, flags only.
    public static func unicodeLine(flags: UInt16, down: Bool,
                                   systemFlags: KeyboardModifierFlags,
                                   pressedUnicode: Int) -> String {
        String(format: "event=input_trace kind=unicode flags=0x%04x ", Int(flags)) +
        "down=" + (down ? "1" : "0") + " sys=" + systemFlags.logValue +
        " pressed_unicode=" + String(pressedUnicode)
    }

    public static func rejectedLine(reason: String, identity: KeyboardScancodeIdentity?,
                                    systemFlags: KeyboardModifierFlags?) -> String {
        var line = "event=input_rejected reason=\(reason)"
        if let identity { line += " " + identity.logValue }
        if let systemFlags { line += " sys=\(systemFlags.logValue)" }
        return line
    }

    public static func droppedLine(reason: String, suppressed: Int = 0) -> String {
        var line = "event=remote_input_dropped reason=\(reason)"
        if suppressed > 0 { line += " suppressed=\(suppressed)" }
        return line
    }

    public static func releaseAllLine(reason: String, result: KeyboardReleaseAllResult,
                                      systemFlags: KeyboardModifierFlags?) -> String {
        var line = "event=input_release_all reason=\(reason) pressed_keys=\(result.pressedKeys) " +
                   "pressed_unicode=\(result.pressedUnicode) swept=\(result.sweptModifiers)"
        if let systemFlags { line += " sys=\(systemFlags.logValue)" }
        return line
    }

    public static func winCommandReleaseLine(_ release: KeyboardWinCommandRelease,
                                            systemFlags: KeyboardModifierFlags) -> String {
        String(format: "event=input_win_command_released key=0x%02x ", Int(release.virtualKey)) +
        "held_ms=\(release.heldMilliseconds) keys=\(release.nonModifierDownsSincePress) " +
        "reason=\(release.reason) sys=\(systemFlags.logValue)"
    }

    public static func stuckModifierLine(_ release: KeyboardStuckModifierRelease,
                                         systemFlags: KeyboardModifierFlags) -> String {
        String(format: "event=input_stuck_modifier_released key=0x%02x ", Int(release.virtualKey)) +
        "role=\(release.role.rawValue) held_ms=\(release.heldMilliseconds) " +
        "events_since=\(release.keyDownsSincePress) sys=\(systemFlags.logValue)"
    }
}
