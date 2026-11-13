// Adapted from tkzmux c961533 Sources/TkzTerminalCore/KeyEncoder.swift (MIT, see LICENSE-tkzmux.txt). PORT comments mark vt-1.0.0 changes.
// KeyEncoder.swift — key press → pty bytes, via libghostty-vt's key encoder.
//
// `KeyPress` is plain data with no AppKit types, so the whole encoding path is unit-testable
// without a window. `TerminalInputController` builds a `KeyPress` from an `NSEvent` and calls
// `GhosttyTerminal.encodeKey`, which calls this under the terminal's lock.
import GhosttyVt

// MARK: - Modifiers

/// Keyboard modifiers, mirroring `GhosttyMods` (`key/event.h`) bit for bit.
///
/// The `*Right` bits are *sides*, not extra modifiers: `.altRight` is only meaningful when `.alt`
/// is also set, and its absence means "left". libghostty cannot represent "both sides pressed"
/// and does not need to.
package struct KeyModifiers: OptionSet, Sendable, Hashable {
    package let rawValue: UInt16
    package init(rawValue: UInt16) { self.rawValue = rawValue }

    package static let shift = KeyModifiers(rawValue: UInt16(GHOSTTY_MODS_SHIFT))
    package static let control = KeyModifiers(rawValue: UInt16(GHOSTTY_MODS_CTRL))
    /// Option on macOS.
    package static let alt = KeyModifiers(rawValue: UInt16(GHOSTTY_MODS_ALT))
    /// Command on macOS.
    package static let super_ = KeyModifiers(rawValue: UInt16(GHOSTTY_MODS_SUPER))
    package static let capsLock = KeyModifiers(rawValue: UInt16(GHOSTTY_MODS_CAPS_LOCK))
    static let numLock = KeyModifiers(rawValue: UInt16(GHOSTTY_MODS_NUM_LOCK))

    /// Set when the pressed Shift is the right-hand one. Only read when `.shift` is set.
    package static let shiftRight = KeyModifiers(rawValue: UInt16(GHOSTTY_MODS_SHIFT_SIDE))
    /// Set when the pressed Control is the right-hand one. Only read when `.control` is set.
    package static let controlRight = KeyModifiers(rawValue: UInt16(GHOSTTY_MODS_CTRL_SIDE))
    /// Set when the pressed Option is the right-hand one. Only read when `.alt` is set.
    package static let altRight = KeyModifiers(rawValue: UInt16(GHOSTTY_MODS_ALT_SIDE))
    /// Set when the pressed Command is the right-hand one. Only read when `.super_` is set.
    package static let superRight = KeyModifiers(rawValue: UInt16(GHOSTTY_MODS_SUPER_SIDE))
}

// MARK: - Option-as-Alt

/// How the macOS Option key is treated, mirroring `GhosttyOptionAsAlt` (`key/encoder.h`).
///
/// Note the library spells the "both sides" case `TRUE`, not `both`.
package enum OptionAsAlt: Sendable, Hashable {
    /// Option is never Alt: macOS' own Unicode translation wins (Option+B → `∫`).
    case never
    /// Both Option keys act as Alt (`GHOSTTY_OPTION_AS_ALT_TRUE`); Option+B → `ESC b`.
    case both
    /// Only the left Option key acts as Alt.
    case left
    /// Only the right Option key acts as Alt.
    case right

    var cValue: GhosttyOptionAsAlt {
        switch self {
        case .never: return GHOSTTY_OPTION_AS_ALT_FALSE
        case .both: return GHOSTTY_OPTION_AS_ALT_TRUE
        case .left: return GHOSTTY_OPTION_AS_ALT_LEFT
        case .right: return GHOSTTY_OPTION_AS_ALT_RIGHT
        }
    }

    /// Whether the Option key held in `mods` should behave as Alt under this setting.
    ///
    /// The view layer needs this *before* it asks macOS to translate the key: see
    /// ``KeyEncoder/translationModifiers(for:optionAsAlt:)``.
    package func applies(to mods: KeyModifiers) -> Bool {
        guard mods.contains(.alt) else { return false }
        switch self {
        case .never: return false
        case .both: return true
        case .left: return !mods.contains(.altRight)
        case .right: return mods.contains(.altRight)
        }
    }
}

// MARK: - KeyPress

/// One keyboard event, in a form the encoder understands — plain data, no AppKit.
///
/// This is the seam the view layer fills in. Field semantics (and exactly what the AppKit layer
/// must supply) are spelled out per field below.
package struct KeyPress: Sendable, Hashable {
    /// Press / repeat / release, mirroring `GhosttyKeyAction`.
    ///
    /// AppKit: `keyDown` with `isARepeat == false` → `.press`, `keyDown` with `isARepeat` →
    /// `.repeated`, `keyUp` → `.release`. `flagsChanged` produces `.press` or `.release` of the
    /// modifier key itself, depending on whether its bit appeared or disappeared.
    /// Releases only produce bytes when the kitty `REPORT_EVENTS` flag is on; in legacy mode the
    /// encoder returns nothing for them, which is normal, not an error.
    package enum Action: Sendable, Hashable {
        case press
        case repeated
        case release

        var cValue: GhosttyKeyAction {
            switch self {
            case .press: return GHOSTTY_KEY_ACTION_PRESS
            case .repeated: return GHOSTTY_KEY_ACTION_REPEAT
            case .release: return GHOSTTY_KEY_ACTION_RELEASE
            }
        }
    }

    /// See ``KeyPress/Action``: press, repeat, or release.
    var action: Action

    /// The physical, layout-independent key.
    ///
    /// AppKit: `MacKeyCodes.key(forVirtualKeyCode: UInt16(event.keyCode))`.
    /// `GHOSTTY_KEY_UNIDENTIFIED` is legal — the encoder then works from `text` alone.
    var key: GhosttyKey

    /// The modifiers held down, including side bits.
    ///
    /// AppKit: from `event.modifierFlags` — `.shift`/`.control`/`.option`/`.command`/`.capsLock`
    /// map to `.shift`/`.control`/`.alt`/`.super_`/`.capsLock`. The side bits are *not* exposed by
    /// `NSEvent.ModifierFlags`; take them from the raw flags with the IOKit device masks
    /// `NX_DEVICERSHIFTKEYMASK`, `NX_DEVICERCTLKEYMASK`, `NX_DEVICERALTKEYMASK` and
    /// `NX_DEVICERCMDKEYMASK` (declared in `IOKit/hidsystem/IOLLEvent.h`; use the symbols, never
    /// literals):
    /// `if event.modifierFlags.rawValue & UInt(NX_DEVICERALTKEYMASK) != 0 { mods.insert(.altRight) }`.
    /// Side bits matter for `optionAsAlt == .left/.right`.
    var mods: KeyModifiers

    /// The modifiers macOS already spent producing `text`.
    ///
    /// AppKit has no API for this; use Ghostty's long-standing heuristic — everything except
    /// Control and Command contributed to the translation, applied to the *translation*
    /// modifiers rather than the raw ones:
    /// `consumedMods = KeyEncoder.translationModifiers(for: mods, optionAsAlt: setting)
    ///                     .subtracting([.control, .super_])`.
    /// libghostty computes `effectiveMods = mods − consumedMods` whenever `text` is non-empty, so
    /// a modifier reported as consumed disappears from the escape sequence. That is why the
    /// option-as-alt case only works when Option is left *unconsumed* — see
    /// ``KeyEncoder/translationModifiers(for:optionAsAlt:)``.
    var consumedMods: KeyModifiers

    /// The text the layout produced for this key, UTF-8, or `""` for none.
    ///
    /// **Must be filtered** (`key/event.h` is explicit): never pass C0 controls (U+0000–U+001F),
    /// U+007F, or macOS function-key PUA codepoints (U+F700–U+F8FF). AppKit: start from
    /// `event.characters`; if it is a single scalar below 0x20, re-read it as
    /// `event.characters(byApplyingModifiers: event.modifierFlags.subtracting(.control))`; if the
    /// single scalar is in U+F700–U+F8FF, pass `""`. Control-character encoding (Ctrl-A → 0x01)
    /// is libghostty's job, derived from `key` + `mods`, not something you pass as text.
    /// As a safety net, `KeyEncoder` applies the same filter itself (`KeyEncoder.filteredText`).
    ///
    /// When Option is acting as Alt, translate *without* Option:
    /// `event.characters(byApplyingModifiers: KeyEncoder.translationModifiers(for: mods,
    /// optionAsAlt: setting))` (converted back to `NSEvent.ModifierFlags`) — Option+B must arrive
    /// here as `"b"`, not `"∫"`.
    var text: String

    /// The codepoint the physical key produces with no modifiers at all, or 0 if unknown.
    ///
    /// AppKit: `event.characters(byApplyingModifiers: [])?.unicodeScalars.first?.value ?? 0`
    /// on `keyDown`/`keyUp` only. Use `byApplyingModifiers: []` rather than
    /// `charactersIgnoringModifiers`, whose behaviour changes when Control is held.
    /// This is what makes Option+B encode as `ESC b` (unshifted `b`) rather than `ESC ∫`.
    var unshiftedCodepoint: UInt32

    /// True while an input method is composing (marked text is on screen).
    ///
    /// AppKit: true when `inputContext.handleEvent` left marked text, i.e. the key belongs to a
    /// dead-key or IME sequence. The encoder suppresses output for composing presses so the
    /// preedit is not echoed to the pty.
    var composing: Bool

    package init(
        action: Action = .press,
        key: GhosttyKey,
        mods: KeyModifiers = [],
        consumedMods: KeyModifiers = [],
        text: String = "",
        unshiftedCodepoint: UInt32 = 0,
        composing: Bool = false
    ) {
        self.action = action
        self.key = key
        self.mods = mods
        self.consumedMods = consumedMods
        self.text = text
        self.unshiftedCodepoint = unshiftedCodepoint
        self.composing = composing
    }
}

// MARK: - KeyEncoder

/// Encodes ``KeyPress`` values into the bytes to write to the pty.
///
/// Owns a `GhosttyKeyEncoder` and a reusable `GhosttyKeyEvent`. **Not thread-safe and not
/// `Sendable`**: the underlying C objects have no internal synchronisation, and the encoder's
/// options are re-derived from the terminal on every `encode` call. `InputBinding` owns the one
/// instance, bound to its terminal, and calls `encode` only under the terminal's lock; nothing
/// else may touch it.
package final class KeyEncoder {
    private let encoder: GhosttyKeyEncoderHandle
    private let event: GhosttyKeyEvent

    init() throws {
        encoder = try GhosttyKeyEncoderHandle()

        var event: GhosttyKeyEvent?
        try ghosttyCheck(ghostty_key_event_new(nil, &event), "ghostty_key_event_new")
        guard let event else {
            throw GhosttyCallError(result: GHOSTTY_OUT_OF_MEMORY, operation: "ghostty_key_event_new")
        }
        self.event = event
    }

    deinit { ghostty_key_event_free(event) }

    /// How many bytes of text the reusable event still points at. Zero between calls: `encode`
    /// clears the text before the buffer it lent goes away. Tests read it.
    var eventTextLength: Int { ghostty_key_event_get_utf8(event).len }

    /// Encode one key press against a terminal's current state.
    ///
    /// The encoder's protocol options (DECCKM, keypad application mode, mode 1036 alt-escape
    /// prefix, xterm `modifyOtherKeys`, and the kitty keyboard flags) are read from `terminal` on
    /// every call via `ghostty_key_encoder_setopt_from_terminal`, so the caller never has to track
    /// mode changes. That call documents that it *resets* `MACOS_OPTION_AS_ALT` to
    /// `GHOSTTY_OPTION_AS_ALT_FALSE` ("the `macos_option_as_alt` option cannot be determined from
    /// terminal state and is reset … Use ghostty_key_encoder_setopt() to set it afterward"), so
    /// this method always re-applies `optionAsAlt` afterwards. Getting that order wrong silently
    /// breaks every Option binding.
    ///
    /// The result then goes through ``legacyControlBytes(replacing:kittyFlags:)``, which turns
    /// Ctrl-I, Ctrl-M, Ctrl-[ and Ctrl-Shift-letter back into control bytes for a program that never
    /// asked for CSI u, and ``legacyShiftedEnterOrEscape(replacing:kittyFlags:)``, which sends
    /// Shift-Enter and Shift-Escape as the plain key for a program that asked for neither Kitty flags
    /// nor modifyOtherKeys level 2.
    ///
    /// - Returns: the bytes to write to the pty. **An empty array is a normal result**, not an
    ///   error: bare modifier presses, releases in legacy mode, and composing keys produce nothing.
    /// - Throws: ``GhosttyCallError`` if libghostty fails for any reason other than buffer size.
    func encode(
        _ press: KeyPress,
        terminal: VtTerminal,
        optionAsAlt: OptionAsAlt = .never
    ) throws -> [UInt8] {
        // Every field is set on every call: the event object is reused, so anything left unset
        // would carry over from the previous press.
        _ = ghostty_key_event_set_action(event, press.action.cValue)
        _ = ghostty_key_event_set_key(event, press.key)
        _ = ghostty_key_event_set_mods(event, press.mods.rawValue)
        _ = ghostty_key_event_set_consumed_mods(event, press.consumedMods.rawValue)
        _ = ghostty_key_event_set_composing(event, press.composing)
        _ = ghostty_key_event_set_unshifted_codepoint(event, press.unshiftedCodepoint)

        // `set_utf8` does not copy: the pointer must stay valid until `encode` has run, so the
        // whole option/encode sequence happens inside `withUTF8`. The event outlives this call,
        // so its text is cleared before `withUTF8` ends, on every path out. Otherwise the event
        // would hold a pointer into a buffer Swift has already freed.
        var text = Self.filteredText(press.text)
        return try text.withUTF8 { buffer -> [UInt8] in
            // PORT: set_utf8 takes one GhosttyString, not (ptr, len). Every setter now returns a result.
            try ghosttyCheck(
                ghostty_key_event_set_utf8(event, GhosttyString(ptr: buffer.baseAddress, len: buffer.count)),
                "ghostty_key_event_set_utf8")
            defer { _ = ghostty_key_event_set_utf8(event, GhosttyString(ptr: nil, len: 0)) }

            // PORT: setopt* became set*. set_from_terminal resets option-as-alt, so re-apply it after.
            try ghosttyCheck(ghostty_key_encoder_set_from_terminal(encoder.raw, terminal), "key_encoder_set_from_terminal")
            var asAlt = optionAsAlt.cValue
            try ghosttyCheck(
                ghostty_key_encoder_set(encoder.raw, GHOSTTY_KEY_ENCODER_OPT_MACOS_OPTION_AS_ALT, &asAlt),
                "key_encoder_set(OPTION_AS_ALT)")

            let encoded = try encodeCurrentEvent()
            let kittyFlags = GhosttyTerminalState(raw: terminal).kittyKeyboardFlags
            if let control = Self.legacyControlBytes(replacing: encoded, kittyFlags: kittyFlags) {
                return control
            }
            // A probe that fails sends libghostty's own form rather than dropping the key.
            if let plain = Self.legacyShiftedEnterOrEscape(replacing: encoded, kittyFlags: kittyFlags),
               (try? modifyOtherKeysState2IsSet()) == false {
                return plain
            }
            return encoded
        }
    }

    /// The bytes SwiftTerm sends for Shift-Enter and Shift-Escape, in place of the xterm form
    /// libghostty sends for them, for a program that asked for neither Kitty flags nor xterm's
    /// modifyOtherKeys.
    ///
    /// libghostty's legacy table sends Shift-Enter as `CSI 27;2;13~` and Shift-Escape as
    /// `CSI 27;2;27~` whatever the program asked for. SwiftTerm sends the plain key, because macOS
    /// binds Shift-Return to the same `insertNewline:` as Return and Shift-Escape to the same
    /// `cancelOperation:` as Escape; a shell sent the CSI form prints `27;2;13~`. With Alt held too
    /// (`CSI 27;4;…~`) an ESC goes before the key, as SwiftTerm sends it while Option is Meta, and
    /// as libghostty sends Alt-Enter whatever Option is.
    ///
    /// Only the parsing: the caller still checks modifyOtherKeys level 2, under which the CSI form
    /// is what the program asked for.
    ///
    /// - Returns: the bytes to send instead, or nil to send `encoded` unchanged.
    static func legacyShiftedEnterOrEscape(replacing encoded: [UInt8], kittyFlags: UInt8) -> [UInt8]? {
        guard kittyFlags == 0 else { return nil }
        // ESC [ 27 ; <modifiers> ; <key> ~
        guard encoded.count >= 9, encoded[0] == 0x1B, encoded[1] == UInt8(ascii: "["),
              encoded.last == UInt8(ascii: "~") else { return nil }
        let fields = encoded[2..<(encoded.count - 1)]
            .split(separator: UInt8(ascii: ";"), omittingEmptySubsequences: false)
        guard fields.count == 3, decimal(fields[0]) == 27, let modifiers = decimal(fields[1]),
              let key = decimal(fields[2]), key == 0x0D || key == 0x1B else { return nil }
        switch modifiers {
        case 2: return [UInt8(key)]        // Shift
        case 4: return [0x1B, UInt8(key)]  // Shift and Alt
        default: return nil
        }
    }

    /// Whether the program set xterm's modifyOtherKeys to level 2, which libghostty's C API has no
    /// getter for. Encodes Shift-Backspace on the encoder as `set_from_terminal` left it: `DEL`
    /// normally, `CSI 27;2;127~` at level 2.
    ///
    /// Overwrites the reusable event; `encode` sets every field again on its next call.
    private func modifyOtherKeysState2IsSet() throws -> Bool {
        _ = ghostty_key_event_set_action(event, GHOSTTY_KEY_ACTION_PRESS)
        _ = ghostty_key_event_set_key(event, GHOSTTY_KEY_BACKSPACE)
        _ = ghostty_key_event_set_mods(event, KeyModifiers.shift.rawValue)
        _ = ghostty_key_event_set_consumed_mods(event, 0)
        _ = ghostty_key_event_set_composing(event, false)
        _ = ghostty_key_event_set_unshifted_codepoint(event, 0)
        try ghosttyCheck(
            ghostty_key_event_set_utf8(event, GhosttyString(ptr: nil, len: 0)), "ghostty_key_event_set_utf8")
        return try encodeCurrentEvent() != [0x7F]
    }

    /// Control bytes in place of the CSI u that libghostty encoded some Ctrl keys as, for a program
    /// that never asked for CSI u.
    ///
    /// libghostty's legacy encoder follows the fixterms spec in two places a shell cannot read:
    ///   * It leaves Ctrl-I, Ctrl-M and Ctrl-[ out of its control-character table on purpose
    ///     (`key_encode.zig`: "purposely NOT handled here"), and sends `CSI 105;5u`, `CSI 109;5u`
    ///     and `CSI 91;5u`. In zsh, Ctrl-M prints `09;5u`, and a later Return runs `5u` as a
    ///     command. These go out as Tab, Return and Esc.
    ///   * It sends Ctrl-Shift-letter as CSI u (`CSI 118;6u` for Ctrl-Shift-V), so a program can
    ///     tell it from Ctrl-letter. Only a program that set Kitty flags reads that form, so these go
    ///     out as the letter's control byte, which every program reads.
    ///
    /// xterm, Terminal.app and SwiftTerm send the control byte in both cases, and so does this.
    /// Only those exact forms are replaced, and only while the program has set no Kitty flags:
    ///   * Under Kitty flags, the CSI u is what the program asked for.
    ///   * Under xterm's modifyOtherKeys 2, libghostty sends `CSI 27;5;105~`, which the program
    ///     also asked for. It does not match the form.
    ///
    /// Caps Lock gives `CSI 73;5u` (an upper-case I), and maps the same way. With Alt held as
    /// Meta (`;7u`), the C0 byte follows an ESC, as libghostty does for every other control key.
    ///
    /// - Returns: the bytes to send instead, or nil to send `encoded` unchanged.
    static func legacyControlBytes(replacing encoded: [UInt8], kittyFlags: UInt8) -> [UInt8]? {
        guard kittyFlags == 0 else { return nil }
        // ESC [ <codepoint> ; <modifiers> u
        guard encoded.count >= 6, encoded[0] == 0x1B, encoded[1] == UInt8(ascii: "["),
              encoded.last == UInt8(ascii: "u") else { return nil }
        let fields = encoded[2..<(encoded.count - 1)]
            .split(separator: UInt8(ascii: ";"), omittingEmptySubsequences: false)
        guard fields.count == 2, let codepoint = decimal(fields[0]), let modifiers = decimal(fields[1])
        else { return nil }

        switch modifiers {
        case 5, 7:
            // Ctrl, or Ctrl and Alt: the three keys missing from libghostty's table.
            let control: UInt8
            switch codepoint {
            case 0x69, 0x49: control = 0x09  // i, or I under Caps Lock: Tab
            case 0x6D, 0x4D: control = 0x0D  // m, or M under Caps Lock: Return
            case 0x5B: control = 0x1B        // [: Esc
            default: return nil
            }
            return modifiers == 7 ? [0x1B, control] : [control]
        case 6:
            // Ctrl and Shift: any letter, as its control byte.
            guard (0x41...0x5A).contains(codepoint) || (0x61...0x7A).contains(codepoint) else { return nil }
            return [UInt8(codepoint) & 0x1F]
        default:
            return nil
        }
    }

    /// A run of ASCII digits as a number, or nil for anything else.
    private static func decimal(_ digits: ArraySlice<UInt8>) -> Int? {
        guard !digits.isEmpty, digits.count <= 6 else { return nil }
        var value = 0
        for byte in digits {
            guard (UInt8(ascii: "0")...UInt8(ascii: "9")).contains(byte) else { return nil }
            value = value * 10 + Int(byte - UInt8(ascii: "0"))
        }
        return value
    }

    /// Encode the already-configured event, growing the buffer once if libghostty asks for more.
    private func encodeCurrentEvent() throws -> [UInt8] {
        var stack = [UInt8](repeating: 0, count: 128)
        var written = 0
        let result = stack.withUnsafeMutableBufferPointer { buffer in
            ghostty_key_encoder_encode(encoder.raw, event, buffer.baseAddress, buffer.count, &written)
        }

        if result == GHOSTTY_SUCCESS {
            return Self.bytes(of: stack, count: written)
        }
        guard result == GHOSTTY_OUT_OF_SPACE else {
            throw GhosttyCallError(result: result, operation: "ghostty_key_encoder_encode")
        }

        // `written` now holds the required size.
        var heap = [UInt8](repeating: 0, count: max(written, 1))
        var written2 = 0
        let retry = heap.withUnsafeMutableBufferPointer { buffer in
            ghostty_key_encoder_encode(encoder.raw, event, buffer.baseAddress, buffer.count, &written2)
        }
        try ghosttyCheck(retry, "ghostty_key_encoder_encode")
        return Self.bytes(of: heap, count: written2)
    }

    private static func bytes(of buffer: [UInt8], count: Int) -> [UInt8] {
        guard count > 0 else { return [] }
        return Array(buffer[0..<count])
    }

    /// The modifiers macOS should translate the key with, given an option-as-alt setting.
    ///
    /// libghostty-vt's encoder knows about option-as-alt, but it cannot re-run the keyboard
    /// layout: it only ever sees the `text` the platform already produced. So the *view* must do
    /// half the work, exactly as Ghostty's own AppKit layer does (it calls
    /// `ghostty_surface_key_translation_mods`, an apprt API that is not part of libghostty-vt):
    ///
    /// * Option acting as Alt → drop Option before translating, so `text` is the plain letter
    ///   (`"b"`) and Option is *not* in `consumedMods`. The encoder then sees `alt` in the
    ///   effective mods and emits the ESC prefix — Option+B → `ESC b`.
    /// * Option not acting as Alt → translate with Option, so `text` is the composed character
    ///   (`"∫"`) and Option *is* consumed. The encoder passes the text straight through.
    ///
    /// Feed the result to `NSEvent.characters(byApplyingModifiers:)` and use it as the base for
    /// ``KeyPress/consumedMods``. Nothing else changes.
    package static func translationModifiers(
        for mods: KeyModifiers,
        optionAsAlt: OptionAsAlt
    ) -> KeyModifiers {
        optionAsAlt.applies(to: mods) ? mods.subtracting([.alt, .altRight]) : mods
    }

    /// Enforce `ghostty_key_event_set_utf8`'s contract: no C0 controls, no DEL, no macOS
    /// function-key PUA codepoints. Idempotent for text the view layer already filtered.
    static func filteredText(_ text: String) -> String {
        guard text.unicodeScalars.count == 1, let scalar = text.unicodeScalars.first else {
            return text
        }
        if scalar.value < 0x20 || scalar.value == 0x7F { return "" }
        if (0xF700...0xF8FF).contains(scalar.value) { return "" }
        return text
    }
}
