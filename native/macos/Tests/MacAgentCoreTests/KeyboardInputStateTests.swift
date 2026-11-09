import Foundation

/// Pure-logic tests for the keyboard state machine (KeyboardInputState.swift):
/// scancode-keyed press table, release fallback when the client flips the
/// extended flag, unmappable/EXTENDED1 handling, the unconditional modifier
/// sweep and the conservative stuck-modifier guard.
///
/// 2026-11-08 field report: typing through RDP with a Chinese IME sometimes
/// swallowed characters and made a typed letter behave like modifier+key.
enum KeyboardInputStateTests {
    static func run() throws {
        testScancodeMappingRoundTrip()
        testNonExtendedMappingIsInjective()
        testWindowsKeyFamiliesAgree()
        testInjectedEventFlagsMapping()
        testWindowKeyQuickRelease()
        testWinVThenTypingStaysPlain()
        testWindowSpaceIsPlainSpace()
        testWindowKeyRepeatAfterReleaseIgnored()
        testExtendedOnlyAndNumpadMappings()
        testDeliberatelyUnmappedScancodes()
        testReleaseFallsBackWhenExtendedFlagFlips()
        testUnknownScancodeDoesNotDisturbOtherKeys()
        testExtended1FamilyIsDropped()
        testDuplicateKeyDownIsIdempotent()
        testPublishedReleaseResynchronises()
        testReleaseAllSweepsEveryModifier()
        testStuckModifierGuardReleasesHeldOption()
        testStuckModifierGuardCanBeDisabled()
        testStuckModifierGuardIgnoresShiftAndCaps()
        testStuckModifierGuardIgnoresAutoRepeat()
        testStuckModifierGuardRestartsAfterRelease()
        testTraceLines()
        testUnicodeTraceNeverLogsCode()
        testRateLimitedLogGate()
    }

    // MARK: - Mapping completeness

    private static func testScancodeMappingRoundTrip() {
        var mappedCount = 0
        for scancode in UInt16(0x00)...UInt16(0xff) {
            for extended in [false, true] {
                guard let virtualKey = MacKeyMap.virtualKey(scancode: scancode, extended: extended) else {
                    continue
                }
                mappedCount += 1
                var state = KeyboardInputState()
                let down = state.handleScancode(scancode: scancode,
                                                flags: extended ? MacKeyMap.flagExtended : 0,
                                                nowMilliseconds: 0)
                precondition(down.effects.count == 1)
                guard case let .key(downKey, isDown) = down.effects[0] else {
                    preconditionFailure("scancode 0x\(hex(scancode)) did not produce a key effect")
                }
                precondition(downKey == virtualKey && isDown)
                precondition(state.pressedKeyCount == 1)
                let up = state.handleScancode(scancode: scancode,
                                              flags: (extended ? MacKeyMap.flagExtended : 0) |
                                                     MacKeyMap.flagRelease,
                                              nowMilliseconds: 1)
                precondition(up.effects == [.key(virtualKey: virtualKey, down: false)])
                precondition(state.pressedKeyCount == 0,
                             "scancode 0x\(hex(scancode)) ext=\(extended) left a pressed key")
            }
        }
        // The table is expected to cover the main keyboard, keypad, F1-F20 and
        // the Windows keys; a regression that empties it must fail the test.
        precondition(mappedCount >= 100, "only \(mappedCount) scancode families are mapped")
    }

    private static func testNonExtendedMappingIsInjective() {
        var seen: [UInt16: UInt16] = [:]
        for scancode in UInt16(0x00)...UInt16(0xff) {
            guard let virtualKey = MacKeyMap.virtualKey(scancode: scancode, extended: false) else {
                continue
            }
            if let previous = seen[virtualKey] {
                preconditionFailure("non-extended scancodes 0x\(hex(previous)) and " +
                                    "0x\(hex(scancode)) both map to 0x\(hex(virtualKey))")
            }
            seen[virtualKey] = scancode
        }
    }

    private static func testInjectedEventFlagsMapping() {
        // Explicit flags only model real modifiers; device bits (Fn/NumericPad)
        // must never appear (field 2026-11-08: a stale Fn flag made a plain e
        // open the macOS Emoji & Symbols panel = Fn+E).
        precondition(KeyboardModifierFlags.from(pressedVirtualKeys: []).cgEventFlagsRawValue == 0)
        precondition(KeyboardModifierFlags.from(pressedVirtualKeys: [0x37]).cgEventFlagsRawValue
            == 0x00100000)
        precondition(KeyboardModifierFlags.from(pressedVirtualKeys: [0x36]).command)
        precondition(KeyboardModifierFlags.from(pressedVirtualKeys: [0x3a]).cgEventFlagsRawValue
            == 0x00080000)
        precondition(KeyboardModifierFlags.from(pressedVirtualKeys: [0x3d]).option)
        precondition(KeyboardModifierFlags.from(pressedVirtualKeys: [0x3b]).cgEventFlagsRawValue
            == 0x00040000)
        precondition(KeyboardModifierFlags.from(pressedVirtualKeys: [0x3e]).control)
        precondition(KeyboardModifierFlags.from(pressedVirtualKeys: [0x38]).cgEventFlagsRawValue
            == 0x00020000)
        precondition(KeyboardModifierFlags.from(pressedVirtualKeys: [0x3c]).shift)
        precondition(KeyboardModifierFlags.from(pressedVirtualKeys: [0x39]).cgEventFlagsRawValue
            == 0x00010000)
        let all = KeyboardModifierFlags.from(pressedVirtualKeys: [0x37, 0x3a, 0x3b, 0x38, 0x39])
        precondition(all.cgEventFlagsRawValue == 0x001F0000)
        precondition(all.cgEventFlagsRawValue & 0x00A00000 == 0,
                     "Fn/NumericPad device bits must never be derived")
        precondition(KeyboardModifierFlags.from(pressedVirtualKeys: [0x0e, 0x31])
            .cgEventFlagsRawValue == 0)
    }

    private static func testWindowKeyQuickRelease() {
        // Field 2026-11-08 (real mstsc session): the client sent Win-down and the
        // matching Win-up only arrived 10.4 s later while the user typed 47 keys,
        // all of which became Cmd+<key>. A Window key acts as a shortcut for its
        // FIRST key only; Cmd is released immediately after that key-down.
        var state = KeyboardInputState()
        let winDown = state.handleScancode(scancode: 0x5b, flags: MacKeyMap.flagExtended,
                                           nowMilliseconds: 1_000)
        precondition(winDown.effects == [.key(virtualKey: 0x37, down: true)])
        let keyDown = state.handleScancode(scancode: 0x2c, flags: 0, nowMilliseconds: 1_050)
        precondition(keyDown.effects == [.key(virtualKey: 0x06, down: true),
                                         .key(virtualKey: 0x37, down: false)],
                     "Win-sourced Cmd must be released right after the first key-down")
        precondition(keyDown.winCommandReleases.count == 1)
        precondition(keyDown.winCommandReleases[0].reason == "first_key")
        precondition(keyDown.winCommandReleases[0].heldMilliseconds == 50)
        let keyUp = state.handleScancode(scancode: 0x2c, flags: MacKeyMap.flagRelease,
                                         nowMilliseconds: 1_090)
        precondition(keyUp.effects == [.key(virtualKey: 0x06, down: false)])
        // The next keys of the same hold are plain typing (no Cmd).
        let next = state.handleScancode(scancode: 0x12, flags: 0, nowMilliseconds: 1_100)
        precondition(next.effects == [.key(virtualKey: 0x0e, down: true)],
                     "keys after the first combo key must be plain typing")
        precondition(next.winCommandReleases.isEmpty)
        // Client auto-repeat of the still-held Win key must not re-press Cmd, and
        // the late Win-up is consumed without an extra press.
        let repeated = state.handleScancode(scancode: 0x5b, flags: MacKeyMap.flagExtended,
                                            nowMilliseconds: 1_200)
        precondition(repeated.effects.isEmpty, "auto-repeat while Win is held must not re-press Cmd")
        let winUp = state.handleScancode(scancode: 0x5b,
                                         flags: MacKeyMap.flagRelease | MacKeyMap.flagExtended,
                                         nowMilliseconds: 1_300)
        precondition(winUp.effects.isEmpty)
        // A genuinely new Window press later re-arms normally.
        let later = state.handleScancode(scancode: 0x5b, flags: MacKeyMap.flagExtended,
                                         nowMilliseconds: 5_000)
        precondition(later.effects == [.key(virtualKey: 0x37, down: true)])
    }

    private static func testWinVThenTypingStaysPlain() {
        // Field report 21:47: after Win+V (paste via Cmd+V) the user typed 'e' and
        // got a system panel because Win was still logically down. Win+V uses the
        // one-shot combo; the following letters must be plain.
        var state = KeyboardInputState()
        _ = state.handleScancode(scancode: 0x5b, flags: MacKeyMap.flagExtended, nowMilliseconds: 0)
        let pasteDown = state.handleScancode(scancode: 0x2f, flags: 0, nowMilliseconds: 10)
        precondition(pasteDown.effects == [.key(virtualKey: 0x09, down: true),
                                           .key(virtualKey: 0x37, down: false)],
                     "Win+V must paste once, then release Cmd")
        _ = state.handleScancode(scancode: 0x2f, flags: MacKeyMap.flagRelease, nowMilliseconds: 20)
        let typedE = state.handleScancode(scancode: 0x12, flags: 0, nowMilliseconds: 30)
        precondition(typedE.effects == [.key(virtualKey: 0x0e, down: true)],
                     "after Win+V the next letter must not become Cmd+letter")
        let winUp = state.handleScancode(scancode: 0x5b,
                                         flags: MacKeyMap.flagRelease | MacKeyMap.flagExtended,
                                         nowMilliseconds: 40)
        precondition(winUp.effects.isEmpty)
    }

    private static func testWindowSpaceIsPlainSpace() {
        // Win+Space is the Windows IME switch; on macOS it must not become
        // Cmd+Space (Spotlight). Cmd is released first, then a plain Space is
        // posted (which also selects the pinyin candidate).
        var state = KeyboardInputState()
        _ = state.handleScancode(scancode: 0x5b, flags: MacKeyMap.flagExtended, nowMilliseconds: 0)
        let spaceDown = state.handleScancode(scancode: 0x39, flags: 0, nowMilliseconds: 10)
        precondition(spaceDown.effects == [.key(virtualKey: 0x37, down: false),
                                           .key(virtualKey: 0x31, down: true)],
                     "Win+Space must become a plain Space, not Cmd+Space")
        precondition(spaceDown.winCommandReleases.count == 1)
    }

    private static func testWindowKeyRepeatAfterReleaseIgnored() {
        var state = KeyboardInputState()
        _ = state.handleScancode(scancode: 0x5c, flags: MacKeyMap.flagExtended, nowMilliseconds: 0)
        let release = state.handleScancode(scancode: 0x2c, flags: 0, nowMilliseconds: 10)
        precondition(release.winCommandReleases.count == 1)
        _ = state.handleScancode(scancode: 0x2c, flags: MacKeyMap.flagRelease, nowMilliseconds: 15)
        // Right-Win repeats and its eventual up are swallowed.
        for t in [30, 40, 50] {
            let repeatDown = state.handleScancode(scancode: 0x5c, flags: MacKeyMap.flagExtended,
                                                  nowMilliseconds: UInt64(t))
            precondition(repeatDown.effects.isEmpty)
        }
        let up = state.handleScancode(scancode: 0x5c,
                                      flags: MacKeyMap.flagRelease | MacKeyMap.flagExtended,
                                      nowMilliseconds: 60)
        precondition(up.effects.isEmpty)
        precondition(state.pressedKeyCount == 0)
    }

    private static func testWindowsKeyFamiliesAgree() {
        // Win keys are accepted with and without the extended flag and must map
        // to the same Command key either way (the old log had
        // unsupported_RDP_scancode_0x5b before commit 18e1c3c).
        precondition(MacKeyMap.virtualKey(scancode: 0x5b, extended: false) == 0x37)
        precondition(MacKeyMap.virtualKey(scancode: 0x5b, extended: true) == 0x37)
        precondition(MacKeyMap.virtualKey(scancode: 0x5c, extended: false) == 0x36)
        precondition(MacKeyMap.virtualKey(scancode: 0x5c, extended: true) == 0x36)
    }

    private static func testExtendedOnlyAndNumpadMappings() {
        // Keypad numeric block (NumLock on).
        precondition(MacKeyMap.virtualKey(scancode: 0x47, extended: false) == 0x59) // 7
        precondition(MacKeyMap.virtualKey(scancode: 0x50, extended: false) == 0x54) // 2
        precondition(MacKeyMap.virtualKey(scancode: 0x52, extended: false) == 0x52) // 0
        precondition(MacKeyMap.virtualKey(scancode: 0x53, extended: false) == 0x41) // .
        precondition(MacKeyMap.virtualKey(scancode: 0x37, extended: false) == 0x43) // *
        precondition(MacKeyMap.virtualKey(scancode: 0x4a, extended: false) == 0x4e) // -
        precondition(MacKeyMap.virtualKey(scancode: 0x4e, extended: false) == 0x45) // +
        precondition(MacKeyMap.virtualKey(scancode: 0x1c, extended: true) == 0x4c)  // keypad enter
        // E0 35 (keypad /) must be kVK_ANSI_KeypadDivide 0x4b, not keypad Enter
        // 0x4c: conflating them injected Enter for a '/' key press.
        precondition(MacKeyMap.virtualKey(scancode: 0x35, extended: true) == 0x4b)  // keypad /
        precondition(MacKeyMap.virtualKey(scancode: 0x35, extended: true) !=
                     MacKeyMap.virtualKey(scancode: 0x1c, extended: true))
        // NumLock maps onto Keypad Clear (macOS has no NumLock state).
        precondition(MacKeyMap.virtualKey(scancode: 0x45, extended: false) == 0x47)
        // F13-F20 exist on Apple keyboards and get their real virtual keycodes.
        precondition(MacKeyMap.virtualKey(scancode: 0x64, extended: false) == 0x69) // F13
        precondition(MacKeyMap.virtualKey(scancode: 0x65, extended: false) == 0x6b) // F14
        precondition(MacKeyMap.virtualKey(scancode: 0x66, extended: false) == 0x71) // F15
        precondition(MacKeyMap.virtualKey(scancode: 0x67, extended: false) == 0x6a) // F16
        precondition(MacKeyMap.virtualKey(scancode: 0x68, extended: false) == 0x40) // F17
        precondition(MacKeyMap.virtualKey(scancode: 0x69, extended: false) == 0x4f) // F18
        precondition(MacKeyMap.virtualKey(scancode: 0x6a, extended: false) == 0x50) // F19
        precondition(MacKeyMap.virtualKey(scancode: 0x6b, extended: false) == 0x5a) // F20
        // Extended navigation cluster still wins over the keypad meaning.
        precondition(MacKeyMap.virtualKey(scancode: 0x47, extended: true) == 0x73) // home
        precondition(MacKeyMap.virtualKey(scancode: 0x52, extended: true) == 0x72) // insert
    }

    private static func testDeliberatelyUnmappedScancodes() {
        for (scancode, extended) in [(UInt16(0x46), false),   // ScrollLock
                                     (0x54, false),           // SysRq
                                     (0x63, false),           // Help
                                     (0x5d, false),           // Menu/Apps
                                     (0x5e, false),           // Power
                                     (0x5f, false),           // Sleep
                                     (0x37, true),            // PrintScreen
                                     (0x6c, false),           // F21
                                     (0x6f, false)] {         // F24
            precondition(MacKeyMap.virtualKey(scancode: scancode, extended: extended) == nil,
                         "0x\(hex(scancode)) should be deliberately unmapped")
            precondition(MacKeyMap.isDeliberatelyUnmapped(scancode: scancode, extended: extended),
                         "0x\(hex(scancode)) is unmapped but not declared deliberate")
        }
    }

    // MARK: - Release robustness

    private static func testReleaseFallsBackWhenExtendedFlagFlips() {
        // Ext -> non-ext release (keypad Enter vs Enter).
        var state = KeyboardInputState()
        let down = state.handleScancode(scancode: 0x1c, flags: MacKeyMap.flagExtended,
                                        nowMilliseconds: 0)
        precondition(down.effects == [.key(virtualKey: 0x4c, down: true)])
        let up = state.handleScancode(scancode: 0x1c, flags: MacKeyMap.flagRelease,
                                      nowMilliseconds: 1)
        precondition(up.effects == [.key(virtualKey: 0x4c, down: false)],
                     "release with the other extended family did not release keypad enter")
        precondition(state.pressedKeyCount == 0)

        // Non-ext -> ext release (normal Enter).
        var other = KeyboardInputState()
        precondition(other.handleScancode(scancode: 0x1c, flags: 0, nowMilliseconds: 0).effects ==
                     [.key(virtualKey: 0x24, down: true)])
        precondition(other.handleScancode(scancode: 0x1c,
                                          flags: MacKeyMap.flagRelease | MacKeyMap.flagExtended,
                                          nowMilliseconds: 1).effects ==
                     [.key(virtualKey: 0x24, down: false)])
        precondition(other.pressedKeyCount == 0)
    }

    private static func testUnknownScancodeDoesNotDisturbOtherKeys() {
        var state = KeyboardInputState()
        // User holds Shift while an unmapped key arrives: the old receiver
        // threw and answered with releaseAll(), silently releasing Shift.
        _ = state.handleScancode(scancode: 0x2a, flags: 0, nowMilliseconds: 0)
        let first = state.handleScancode(scancode: 0x46, flags: 0, nowMilliseconds: 1)
        precondition(first.effects.isEmpty)
        precondition(first.firstUnsupported?.scancode == 0x46)
        let second = state.handleScancode(scancode: 0x46, flags: 0, nowMilliseconds: 2)
        precondition(second.firstUnsupported == nil, "unsupported scancode must log once")
        let up = state.handleScancode(scancode: 0x46, flags: MacKeyMap.flagRelease,
                                      nowMilliseconds: 3)
        precondition(up.effects.isEmpty)
        precondition(state.pressedVirtualKeys == [0x38], "unmapped key disturbed another press")
        // Every event of an unmapped key is rejected (make, repeat, break).
        precondition(state.rejectedScancodeCount == 3)
        let shiftUp = state.handleScancode(scancode: 0x2a, flags: MacKeyMap.flagRelease,
                                           nowMilliseconds: 4)
        precondition(shiftUp.effects == [.key(virtualKey: 0x38, down: false)])
    }

    private static func testExtended1FamilyIsDropped() {
        // Pause/Break is sent as E1 1D 45: the 0x1D would map to Left Control
        // if the EXTENDED1 flag were ignored. Both events of the sequence must
        // be dropped and never inject a modifier.
        var state = KeyboardInputState()
        let first = state.handleScancode(scancode: 0x1d,
                                         flags: MacKeyMap.flagExtended1,
                                         nowMilliseconds: 0)
        precondition(first.effects.isEmpty, "E1-prefix 0x1d injected a key")
        precondition(first.firstUnsupported?.extended1 == true)
        let second = state.handleScancode(scancode: 0x45,
                                          flags: MacKeyMap.flagExtended1,
                                          nowMilliseconds: 1)
        precondition(second.effects.isEmpty)
        let release = state.handleScancode(scancode: 0x1d,
                                           flags: MacKeyMap.flagExtended1 | MacKeyMap.flagRelease,
                                           nowMilliseconds: 2)
        precondition(release.effects.isEmpty)
        precondition(state.pressedKeyCount == 0)
        for modifier in KeyboardModifierKey.allCases {
            precondition(state.pressedVirtualKeys.contains(modifier.rawValue) == false)
        }
    }

    private static func testDuplicateKeyDownIsIdempotent() {
        var state = KeyboardInputState()
        let first = state.handleScancode(scancode: 0x20, flags: 0, nowMilliseconds: 0)
        let repeatEvent = state.handleScancode(scancode: 0x20,
                                               flags: MacKeyMap.flagDown, nowMilliseconds: 1)
        precondition(first.effects == [.key(virtualKey: 0x02, down: true)])
        precondition(repeatEvent.effects == [.key(virtualKey: 0x02, down: true)])
        precondition(state.pressedKeyCount == 1)
        _ = state.handleScancode(scancode: 0x20, flags: MacKeyMap.flagRelease, nowMilliseconds: 2)
        precondition(state.pressedKeyCount == 0)
    }

    private static func testPublishedReleaseResynchronises() {
        // A key-up for a key the Agent never saw pressed must still be posted:
        // it is harmless and helps clear state after a dropped key-down.
        var state = KeyboardInputState()
        let up = state.handleScancode(scancode: 0x20, flags: MacKeyMap.flagRelease,
                                      nowMilliseconds: 0)
        precondition(up.effects == [.key(virtualKey: 0x02, down: false)])
        precondition(state.pressedKeyCount == 0)
    }

    // MARK: - Release all / modifier sweep

    private static func testReleaseAllSweepsEveryModifier() {
        var state = KeyboardInputState()
        _ = state.handleScancode(scancode: 0x5b, flags: MacKeyMap.flagExtended, nowMilliseconds: 0)
        _ = state.handleScancode(scancode: 0x2a, flags: 0, nowMilliseconds: 1)
        _ = state.handleUnicode(code: 0x41, flags: 0)
        let result = state.releaseAll()
        precondition(result.pressedKeys == 2)
        precondition(result.pressedUnicode == 1)
        // 9 modifier key-ups minus the 2 modifiers already released by the table.
        precondition(result.sweptModifiers == 7)
        var keyUps: [UInt16] = []
        var unicodeUps = 0
        for effect in result.effects {
            if case let .key(virtualKey, down) = effect {
                precondition(down == false)
                keyUps.append(virtualKey)
            } else if case let .unicode(_, down) = effect {
                precondition(down == false)
                unicodeUps += 1
            }
        }
        precondition(unicodeUps == 1)
        precondition(Set(keyUps).count == keyUps.count, "releaseAll posted a duplicate key-up")
        for modifier in KeyboardModifierKey.allCases {
            precondition(keyUps.contains(modifier.rawValue),
                         "releaseAll missed modifier 0x\(hex(modifier.rawValue))")
        }
        precondition(state.pressedKeyCount == 0 && state.pressedUnicodeCount == 0)

        // Idempotent: a second sweep posts only the unconditional modifier ups.
        let second = state.releaseAll()
        precondition(second.pressedKeys == 0 && second.pressedUnicode == 0)
        precondition(second.sweptModifiers == KeyboardModifierKey.allCases.count)
        precondition(second.effects.count == KeyboardModifierKey.allCases.count)
    }

    // MARK: - Stuck-modifier guard

    private static func testStuckModifierGuardReleasesHeldOption() {
        // Command is only produced by the Win key, which has its dedicated quick
        // release; the generic guard is exercised with Option (Alt), which the
        // client can also leave stuck after an IME/hotkey combination.
        var state = KeyboardInputState(
            guardConfig: StuckModifierGuardConfig(enabled: true, heldMilliseconds: 1_000,
                                                  keyDownsSincePress: 3))
        _ = state.handleScancode(scancode: 0x38, flags: 0, nowMilliseconds: 0)
        for (offset, scancode) in [UInt16(0x1e), 0x1f, 0x20, 0x21].enumerated() {
            let result = state.handleScancode(scancode: scancode, flags: 0,
                                              nowMilliseconds: UInt64(offset) * 10)
            precondition(result.stuckModifierReleases.isEmpty, "guard fired before the threshold")
        }
        // Threshold crossing: the fifth new non-modifier key-down after 1.5 s.
        let result = state.handleScancode(scancode: 0x22, flags: 0, nowMilliseconds: 1_500)
        precondition(result.stuckModifierReleases.count == 1)
        let release = result.stuckModifierReleases[0]
        precondition(release.virtualKey == 0x3a)
        precondition(release.role == .option)
        precondition(release.heldMilliseconds == 1_500)
        precondition(release.keyDownsSincePress == 5)
        precondition(result.effects.contains(.key(virtualKey: 0x3a, down: false)),
                     "guard did not post the Option key-up")
        precondition(state.pressedVirtualKeys.contains(0x3a) == false)
        // The letter that triggered the guard is still a normal key-down.
        precondition(result.effects.contains(.key(virtualKey: 0x05, down: true)))
    }

    private static func testStuckModifierGuardCanBeDisabled() {
        var state = KeyboardInputState(
            guardConfig: StuckModifierGuardConfig(enabled: false, heldMilliseconds: 0,
                                                  keyDownsSincePress: 1))
        _ = state.handleScancode(scancode: 0x38, flags: 0, nowMilliseconds: 0)
        let result = state.handleScancode(scancode: 0x20, flags: 0, nowMilliseconds: 10_000)
        precondition(result.stuckModifierReleases.isEmpty)
        precondition(state.pressedVirtualKeys.contains(0x3a))
    }

    private static func testStuckModifierGuardIgnoresShiftAndCaps() {
        var state = KeyboardInputState(
            guardConfig: StuckModifierGuardConfig(enabled: true, heldMilliseconds: 0,
                                                  keyDownsSincePress: 1))
        _ = state.handleScancode(scancode: 0x2a, flags: 0, nowMilliseconds: 0)  // left shift
        _ = state.handleScancode(scancode: 0x3a, flags: 0, nowMilliseconds: 0)  // caps lock
        let result = state.handleScancode(scancode: 0x20, flags: 0, nowMilliseconds: 10_000)
        precondition(result.stuckModifierReleases.isEmpty,
                     "the guard must never auto-release Shift/Caps Lock")
        precondition(state.pressedVirtualKeys.contains(0x38))
        precondition(state.pressedVirtualKeys.contains(0x39))
    }

    private static func testStuckModifierGuardIgnoresAutoRepeat() {
        var state = KeyboardInputState(
            guardConfig: StuckModifierGuardConfig(enabled: true, heldMilliseconds: 0,
                                                  keyDownsSincePress: 3))
        _ = state.handleScancode(scancode: 0x38, flags: 0, nowMilliseconds: 0)
        var tripped = false
        for index in 0..<30 {
            let result = state.handleScancode(scancode: 0x20,
                                              flags: MacKeyMap.flagDown,
                                              nowMilliseconds: 10_000 + UInt64(index))
            tripped = tripped || !result.stuckModifierReleases.isEmpty
        }
        precondition(tripped == false, "auto-repeat of one key tripped the guard")
        precondition(state.pressedVirtualKeys.contains(0x3a))
    }

    private static func testStuckModifierGuardRestartsAfterRelease() {
        var state = KeyboardInputState(
            guardConfig: StuckModifierGuardConfig(enabled: true, heldMilliseconds: 1_000,
                                                  keyDownsSincePress: 3))
        _ = state.handleScancode(scancode: 0x38, flags: 0, nowMilliseconds: 0)
        _ = state.handleScancode(scancode: 0x1e, flags: 0, nowMilliseconds: 10)
        _ = state.handleScancode(scancode: 0x1f, flags: 0, nowMilliseconds: 20)
        // A real release resets the timer: the next press starts from zero.
        _ = state.handleScancode(scancode: 0x38, flags: MacKeyMap.flagRelease, nowMilliseconds: 30)
        _ = state.handleScancode(scancode: 0x38, flags: 0, nowMilliseconds: 40)
        _ = state.handleScancode(scancode: 0x20, flags: 0, nowMilliseconds: 50)
        _ = state.handleScancode(scancode: 0x21, flags: 0, nowMilliseconds: 60)
        let result = state.handleScancode(scancode: 0x22, flags: 0, nowMilliseconds: 70)
        precondition(result.stuckModifierReleases.isEmpty)
        precondition(state.pressedVirtualKeys.contains(0x3a))
    }

    // MARK: - Trace formatting

    private static func testTraceLines() {
        let systemFlags = KeyboardModifierFlags(command: false, option: true, control: false,
                                                shift: true, capsLock: false)
        let line = InputTraceFormatter.scancodeLine(
            flags: MacKeyMap.flagExtended, identity: KeyboardScancodeIdentity(scancode: 0x20,
                                                                            extended: true),
            mappedVirtualKey: 0x02, down: true, systemFlags: systemFlags, pressedKeys: 1)
        precondition(line.contains("event=input_trace"))
        precondition(line.contains("kind=scancode"))
        precondition(line.contains("flags=0x0100"))
        precondition(line.contains("code=0x20"))
        precondition(line.contains("ext=1"))
        precondition(line.contains("mapped=0x02"))
        precondition(line.contains("down=1"))
        precondition(line.contains("sys=cmd:0,opt:1,ctrl:0,shift:1,caps:0"))
        precondition(line.contains("pressed_keys=1"))

        let unmapped = InputTraceFormatter.scancodeLine(
            flags: 0, identity: KeyboardScancodeIdentity(scancode: 0x46, extended: false),
            mappedVirtualKey: nil, down: false, systemFlags: .none, pressedKeys: 0)
        precondition(unmapped.contains("mapped=none") && unmapped.contains("down=0"))

        let release = InputTraceFormatter.releaseAllLine(
            reason: "termination",
            result: KeyboardReleaseAllResult(effects: [], pressedKeys: 2, pressedUnicode: 1,
                                             sweptModifiers: 7),
            systemFlags: KeyboardModifierFlags.none)
        precondition(release.contains("event=input_release_all reason=termination"))
        precondition(release.contains("pressed_keys=2"))
        precondition(release.contains("swept=7"))

        let stuck = InputTraceFormatter.stuckModifierLine(
            KeyboardStuckModifierRelease(virtualKey: 0x37, role: .command,
                                         heldMilliseconds: 12_345, keyDownsSincePress: 13),
            systemFlags: systemFlags)
        precondition(stuck.contains("event=input_stuck_modifier_released"))
        precondition(stuck.contains("key=0x37"))
        precondition(stuck.contains("role=command"))
        precondition(stuck.contains("held_ms=12345"))
        precondition(stuck.contains("events_since=13"))

        let dropped = InputTraceFormatter.droppedLine(reason: "invalid_coordinates", suppressed: 42)
        precondition(dropped.contains("event=remote_input_dropped"))
        precondition(dropped.contains("reason=invalid_coordinates"))
        precondition(dropped.contains("suppressed=42"))
    }

    private static func testUnicodeTraceNeverLogsCode() {
        // Unicode codes are typed text: the trace must only show flags/kind.
        let line = InputTraceFormatter.unicodeLine(flags: 0x8000, down: false,
                                                   systemFlags: .none, pressedUnicode: 0)
        precondition(line.contains("kind=unicode"))
        precondition(line.contains("flags=0x8000"))
        precondition(!line.contains("code=0x"), "unicode trace leaked the typed character code")
        precondition(!line.contains("0x41"))
    }

    // MARK: - Rate limiting

    private static func testRateLimitedLogGate() {
        var gate = RateLimitedLogGate(intervalMilliseconds: 5_000)
        precondition(gate.allow(nowMilliseconds: 1_000))
        precondition(!gate.allow(nowMilliseconds: 1_001))
        precondition(!gate.allow(nowMilliseconds: 5_999))
        precondition(gate.takeSuppressedCount() == 2)
        precondition(gate.takeSuppressedCount() == 0)
        precondition(gate.allow(nowMilliseconds: 6_000))
        // A clock that goes backwards must not wedge the gate.
        precondition(gate.allow(nowMilliseconds: 10))
    }

    private static func hex(_ value: UInt16) -> String {
        String(format: "%02x", Int(value))
    }
}
