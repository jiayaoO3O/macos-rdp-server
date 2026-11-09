public enum MacKeyMap {
    /// RDP keyboard flags (freerdp/input.h). KeyboardEvent/UnicodeKeyboardEvent
    /// carry the raw KBD_FLAGS_* bits; the Agent's keyboard state machine decodes
    /// them from the IPC payload.
    public static let flagExtended: UInt16 = 0x0100
    public static let flagExtended1: UInt16 = 0x0200
    /// Presence means the client repeated an already-down key (auto repeat).
    public static let flagDown: UInt16 = 0x4000
    public static let flagRelease: UInt16 = 0x8000

    /// Map one RDP scancode (PC set 1) to a macOS virtual keycode.
    ///
    /// Returns nil for keys macOS cannot represent. Callers must treat nil as
    /// "ignore this event" (log once, keep other pressed keys untouched);  a
    /// missing mapping is a normal client key (media/browser/JP keys), not an
    /// error.
    ///
    /// The extended-flag handling below is deliberate: the same scancode means
    /// different keys with and without 0x0100 (Enter vs keypad Enter, Control vs
    /// right Control, ...). The Windows keys are accepted in both families
    /// because clients differ on whether they set the extended bit for them.
    public static func virtualKey(scancode: UInt16, extended: Bool) -> UInt16? {
        if extended {
            switch scancode {
            case 0x1c: return 0x4c // keypad enter
            case 0x1d: return 0x3e // right control
            case 0x35: return 0x4b // keypad divide (kVK_ANSI_KeypadDivide)
            // 0x37 extended is Print Screen: macOS has no equivalent (kept
            // deliberately unmapped below; mapping it to F13 would collide with
            // the real F13 scancode 0x64).
            case 0x38: return 0x3d // right option
            case 0x47: return 0x73 // home
            case 0x48: return 0x7e // up
            case 0x49: return 0x74 // page up
            case 0x4b: return 0x7b // left
            case 0x4d: return 0x7c // right
            case 0x4f: return 0x77 // end
            case 0x50: return 0x7d // down
            case 0x51: return 0x79 // page down
            case 0x52: return 0x72 // insert
            case 0x53: return 0x75 // forward delete
            // Windows keys: the RDP client sends VK_LWIN/VK_RWIN (scancodes
            // 0x5B/0x5C, usually with the extended flag); map them onto the
            // macOS Command keys so Win+<key> shortcuts work.
            case 0x5b: return 0x37 // left Windows -> left command
            case 0x5c: return 0x36 // right Windows -> right command
            default: return nil
            }
        }

        switch scancode {
        case 0x01: return 0x35 // escape
        case 0x02: return 0x12 // 1
        case 0x03: return 0x13 // 2
        case 0x04: return 0x14 // 3
        case 0x05: return 0x15 // 4
        case 0x06: return 0x17 // 5
        case 0x07: return 0x16 // 6
        case 0x08: return 0x1a // 7
        case 0x09: return 0x1c // 8
        case 0x0a: return 0x19 // 9
        case 0x0b: return 0x1d // 0
        case 0x0c: return 0x1b // minus
        case 0x0d: return 0x18 // equals
        case 0x0e: return 0x33 // delete
        case 0x0f: return 0x30 // tab
        case 0x10: return 0x0c // Q
        case 0x11: return 0x0d // W
        case 0x12: return 0x0e // E
        case 0x13: return 0x0f // R
        case 0x14: return 0x11 // T
        case 0x15: return 0x10 // Y
        case 0x16: return 0x20 // U
        case 0x17: return 0x22 // I
        case 0x18: return 0x1f // O
        case 0x19: return 0x23 // P
        case 0x1a: return 0x21 // left bracket
        case 0x1b: return 0x1e // right bracket
        case 0x1c: return 0x24 // return
        case 0x1d: return 0x3b // left control
        case 0x1e: return 0x00 // A
        case 0x1f: return 0x01 // S
        case 0x20: return 0x02 // D
        case 0x21: return 0x03 // F
        case 0x22: return 0x05 // G
        case 0x23: return 0x04 // H
        case 0x24: return 0x26 // J
        case 0x25: return 0x28 // K
        case 0x26: return 0x25 // L
        case 0x27: return 0x29 // semicolon
        case 0x28: return 0x27 // apostrophe
        case 0x29: return 0x32 // grave
        case 0x2a: return 0x38 // left shift
        case 0x2b: return 0x2a // backslash
        case 0x2c: return 0x06 // Z
        case 0x2d: return 0x07 // X
        case 0x2e: return 0x08 // C
        case 0x2f: return 0x09 // V
        case 0x30: return 0x0b // B
        case 0x31: return 0x2d // N
        case 0x32: return 0x2e // M
        case 0x33: return 0x2b // comma
        case 0x34: return 0x2f // period
        case 0x35: return 0x2c // slash
        case 0x36: return 0x3c // right shift
        case 0x37: return 0x43 // keypad multiply (NumLock on)
        case 0x38: return 0x3a // left option
        case 0x39: return 0x31 // space
        case 0x3a: return 0x39 // caps lock
        case 0x3b: return 0x7a // F1
        case 0x3c: return 0x78 // F2
        case 0x3d: return 0x63 // F3
        case 0x3e: return 0x76 // F4
        case 0x3f: return 0x60 // F5
        case 0x40: return 0x61 // F6
        case 0x41: return 0x62 // F7
        case 0x42: return 0x64 // F8
        case 0x43: return 0x65 // F9
        case 0x44: return 0x6d // F10
        // NumLock has no macOS equivalent state. Keypad Clear is the harmless
        // physical key in that position; mapping it keeps NumLock press/release
        // symmetric instead of dropping it or turning it into a modifier.
        case 0x45: return 0x47 // NumLock -> keypad clear
        // ScrollLock (0x46), SysRq (0x54), Help (0x63), media/browser and JP
        // keys have no macOS equivalent: return nil and let the caller ignore
        // them (never throw, never release other keys).
        case 0x47: return 0x59 // keypad 7
        case 0x48: return 0x5b // keypad 8
        case 0x49: return 0x5c // keypad 9
        case 0x4a: return 0x4e // keypad minus
        case 0x4b: return 0x56 // keypad 4
        case 0x4c: return 0x57 // keypad 5
        case 0x4d: return 0x58 // keypad 6
        case 0x4e: return 0x45 // keypad plus
        case 0x4f: return 0x53 // keypad 1
        case 0x50: return 0x54 // keypad 2
        case 0x51: return 0x55 // keypad 3
        case 0x52: return 0x52 // keypad 0
        case 0x53: return 0x41 // keypad decimal
        case 0x57: return 0x67 // F11
        case 0x58: return 0x6f // F12
        // Windows keys, also accepted without the extended flag.
        case 0x5b: return 0x37 // left Windows -> left command
        case 0x5c: return 0x36 // right Windows -> right command
        case 0x64: return 0x69 // F13
        case 0x65: return 0x6b // F14
        case 0x66: return 0x71 // F15
        case 0x67: return 0x6a // F16
        case 0x68: return 0x40 // F17
        case 0x69: return 0x4f // F18
        case 0x6a: return 0x50 // F19
        case 0x6b: return 0x5a // F20
        default: return nil
        }
    }

    /// True when this scancode family is deliberately unmapped because macOS has
    /// no equivalent key. Kept next to the mapping so the soundness test can
    /// assert "not mapped" rather than silently assuming.
    public static func isDeliberatelyUnmapped(scancode: UInt16, extended: Bool) -> Bool {
        if extended {
            switch scancode {
            case 0x37, 0x45, 0x46, 0x54, 0x56, 0x5d, 0x5f, 0x63: return true
            case 0x6c, 0x6d, 0x6e, 0x6f: return true // F21-F24: no macOS virtual key
            default: return false
            }
        }
        switch scancode {
        case 0x46, 0x54, 0x56, 0x5d, 0x5e, 0x5f, 0x63: return true
        case 0x6c, 0x6d, 0x6e, 0x6f: return true // F21-F24
        default: return false
        }
    }
}
