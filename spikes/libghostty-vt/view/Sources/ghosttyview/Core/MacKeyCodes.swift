// Adapted from tkzmux c961533 Sources/TkzTerminalCore/MacKeyCodes.swift (MIT, see third_party/tkzmux). PORT comments mark vt-1.0.0 changes.
// MacKeyCodes.swift — macOS virtual keycode (`NSEvent.keyCode`, Carbon `kVK_*`) → `GhosttyKey`.
//
// Deliberately AppKit/Carbon-free: the `kVK_*` values are hardcoded as named constants (with the
// Carbon name in a comment) so this table lives in TkzTerminalCore and unit-tests headlessly.
// The mapping follows the W3C UI Events `code` values that `GhosttyKey` is derived from; the
// keycode ↔ DOM-code column was cross-checked against libghostty-vt's `src/input/keycodes.zig`
// (itself derived from Chromium's `dom_code_data.inc`). Written from scratch, not copied.
//
// Virtual keycodes are *physical* and layout independent: keycode 0 is the key labelled "A" on a
// US layout and "Q" on AZERTY, and both report `GHOSTTY_KEY_A`. Layout-dependent text reaches the
// encoder through `KeyPress.text` / `KeyPress.unshiftedCodepoint` instead.
import GhosttyVt

/// The macOS virtual keycode table.
public enum MacKeyCodes {
    /// Map a macOS virtual keycode (`NSEvent.keyCode`) to a layout-independent `GhosttyKey`.
    ///
    /// Returns `GHOSTTY_KEY_UNIDENTIFIED` for keycodes with no libghostty equivalent (unused
    /// codes, and the JIS "eisu" key, which has no entry in `GhosttyKey`). Passing
    /// `GHOSTTY_KEY_UNIDENTIFIED` to the encoder is safe: it then encodes from `text` alone.
    public static func key(forVirtualKeyCode keyCode: UInt16) -> GhosttyKey {
        switch keyCode {
        // MARK: Writing system keys — letters (W3C § 3.1.1)
        case 0x00: return GHOSTTY_KEY_A            // kVK_ANSI_A
        case 0x0B: return GHOSTTY_KEY_B            // kVK_ANSI_B
        case 0x08: return GHOSTTY_KEY_C            // kVK_ANSI_C
        case 0x02: return GHOSTTY_KEY_D            // kVK_ANSI_D
        case 0x0E: return GHOSTTY_KEY_E            // kVK_ANSI_E
        case 0x03: return GHOSTTY_KEY_F            // kVK_ANSI_F
        case 0x05: return GHOSTTY_KEY_G            // kVK_ANSI_G
        case 0x04: return GHOSTTY_KEY_H            // kVK_ANSI_H
        case 0x22: return GHOSTTY_KEY_I            // kVK_ANSI_I
        case 0x26: return GHOSTTY_KEY_J            // kVK_ANSI_J
        case 0x28: return GHOSTTY_KEY_K            // kVK_ANSI_K
        case 0x25: return GHOSTTY_KEY_L            // kVK_ANSI_L
        case 0x2E: return GHOSTTY_KEY_M            // kVK_ANSI_M
        case 0x2D: return GHOSTTY_KEY_N            // kVK_ANSI_N
        case 0x1F: return GHOSTTY_KEY_O            // kVK_ANSI_O
        case 0x23: return GHOSTTY_KEY_P            // kVK_ANSI_P
        case 0x0C: return GHOSTTY_KEY_Q            // kVK_ANSI_Q
        case 0x0F: return GHOSTTY_KEY_R            // kVK_ANSI_R
        case 0x01: return GHOSTTY_KEY_S            // kVK_ANSI_S
        case 0x11: return GHOSTTY_KEY_T            // kVK_ANSI_T
        case 0x20: return GHOSTTY_KEY_U            // kVK_ANSI_U
        case 0x09: return GHOSTTY_KEY_V            // kVK_ANSI_V
        case 0x0D: return GHOSTTY_KEY_W            // kVK_ANSI_W
        case 0x07: return GHOSTTY_KEY_X            // kVK_ANSI_X
        case 0x10: return GHOSTTY_KEY_Y            // kVK_ANSI_Y
        case 0x06: return GHOSTTY_KEY_Z            // kVK_ANSI_Z

        // MARK: Writing system keys — digit row
        case 0x1D: return GHOSTTY_KEY_DIGIT_0      // kVK_ANSI_0
        case 0x12: return GHOSTTY_KEY_DIGIT_1      // kVK_ANSI_1
        case 0x13: return GHOSTTY_KEY_DIGIT_2      // kVK_ANSI_2
        case 0x14: return GHOSTTY_KEY_DIGIT_3      // kVK_ANSI_3
        case 0x15: return GHOSTTY_KEY_DIGIT_4      // kVK_ANSI_4
        case 0x17: return GHOSTTY_KEY_DIGIT_5      // kVK_ANSI_5
        case 0x16: return GHOSTTY_KEY_DIGIT_6      // kVK_ANSI_6
        case 0x1A: return GHOSTTY_KEY_DIGIT_7      // kVK_ANSI_7
        case 0x1C: return GHOSTTY_KEY_DIGIT_8      // kVK_ANSI_8
        case 0x19: return GHOSTTY_KEY_DIGIT_9      // kVK_ANSI_9

        // MARK: Writing system keys — punctuation
        case 0x32: return GHOSTTY_KEY_BACKQUOTE      // kVK_ANSI_Grave
        case 0x1B: return GHOSTTY_KEY_MINUS          // kVK_ANSI_Minus
        case 0x18: return GHOSTTY_KEY_EQUAL          // kVK_ANSI_Equal
        case 0x21: return GHOSTTY_KEY_BRACKET_LEFT   // kVK_ANSI_LeftBracket
        case 0x1E: return GHOSTTY_KEY_BRACKET_RIGHT  // kVK_ANSI_RightBracket
        case 0x2A: return GHOSTTY_KEY_BACKSLASH      // kVK_ANSI_Backslash
        case 0x29: return GHOSTTY_KEY_SEMICOLON      // kVK_ANSI_Semicolon
        case 0x27: return GHOSTTY_KEY_QUOTE          // kVK_ANSI_Quote
        case 0x2B: return GHOSTTY_KEY_COMMA          // kVK_ANSI_Comma
        case 0x2F: return GHOSTTY_KEY_PERIOD         // kVK_ANSI_Period
        case 0x2C: return GHOSTTY_KEY_SLASH          // kVK_ANSI_Slash

        // MARK: International writing system keys
        case 0x0A: return GHOSTTY_KEY_INTL_BACKSLASH // kVK_ISO_Section (ISO §/± key, left of "1")
        case 0x5D: return GHOSTTY_KEY_INTL_YEN       // kVK_JIS_Yen
        case 0x5E: return GHOSTTY_KEY_INTL_RO        // kVK_JIS_Underscore
        case 0x68: return GHOSTTY_KEY_KANA_MODE      // kVK_JIS_Kana (W3C "Lang1")
        // 0x66 kVK_JIS_Eisu (W3C "Lang2") has no GhosttyKey equivalent → unidentified.

        // MARK: Functional keys (W3C § 3.1.2)
        case 0x24: return GHOSTTY_KEY_ENTER          // kVK_Return
        case 0x30: return GHOSTTY_KEY_TAB            // kVK_Tab
        case 0x31: return GHOSTTY_KEY_SPACE          // kVK_Space
        case 0x33: return GHOSTTY_KEY_BACKSPACE      // kVK_Delete (the ⌫ key)
        case 0x35: return GHOSTTY_KEY_ESCAPE         // kVK_Escape
        case 0x6E: return GHOSTTY_KEY_CONTEXT_MENU   // kVK_PC_ApplicationKey (external PC keyboards)

        // MARK: Modifier keys, both sides
        case 0x38: return GHOSTTY_KEY_SHIFT_LEFT     // kVK_Shift
        case 0x3C: return GHOSTTY_KEY_SHIFT_RIGHT    // kVK_RightShift
        case 0x3B: return GHOSTTY_KEY_CONTROL_LEFT   // kVK_Control
        case 0x3E: return GHOSTTY_KEY_CONTROL_RIGHT  // kVK_RightControl
        case 0x3A: return GHOSTTY_KEY_ALT_LEFT       // kVK_Option
        case 0x3D: return GHOSTTY_KEY_ALT_RIGHT      // kVK_RightOption
        case 0x37: return GHOSTTY_KEY_META_LEFT      // kVK_Command
        case 0x36: return GHOSTTY_KEY_META_RIGHT     // kVK_RightCommand
        case 0x39: return GHOSTTY_KEY_CAPS_LOCK      // kVK_CapsLock
        case 0x3F: return GHOSTTY_KEY_FN             // kVK_Function

        // MARK: Control pad (W3C § 3.2)
        case 0x72: return GHOSTTY_KEY_INSERT         // kVK_Help (labelled Insert on PC keyboards)
        case 0x73: return GHOSTTY_KEY_HOME           // kVK_Home
        case 0x74: return GHOSTTY_KEY_PAGE_UP        // kVK_PageUp
        case 0x75: return GHOSTTY_KEY_DELETE         // kVK_ForwardDelete
        case 0x77: return GHOSTTY_KEY_END            // kVK_End
        case 0x79: return GHOSTTY_KEY_PAGE_DOWN      // kVK_PageDown

        // MARK: Arrow pad (W3C § 3.3)
        case 0x7B: return GHOSTTY_KEY_ARROW_LEFT     // kVK_LeftArrow
        case 0x7C: return GHOSTTY_KEY_ARROW_RIGHT    // kVK_RightArrow
        case 0x7D: return GHOSTTY_KEY_ARROW_DOWN     // kVK_DownArrow
        case 0x7E: return GHOSTTY_KEY_ARROW_UP       // kVK_UpArrow

        // MARK: Numpad (W3C § 3.4)
        case 0x52: return GHOSTTY_KEY_NUMPAD_0       // kVK_ANSI_Keypad0
        case 0x53: return GHOSTTY_KEY_NUMPAD_1       // kVK_ANSI_Keypad1
        case 0x54: return GHOSTTY_KEY_NUMPAD_2       // kVK_ANSI_Keypad2
        case 0x55: return GHOSTTY_KEY_NUMPAD_3       // kVK_ANSI_Keypad3
        case 0x56: return GHOSTTY_KEY_NUMPAD_4       // kVK_ANSI_Keypad4
        case 0x57: return GHOSTTY_KEY_NUMPAD_5       // kVK_ANSI_Keypad5
        case 0x58: return GHOSTTY_KEY_NUMPAD_6       // kVK_ANSI_Keypad6
        case 0x59: return GHOSTTY_KEY_NUMPAD_7       // kVK_ANSI_Keypad7
        case 0x5B: return GHOSTTY_KEY_NUMPAD_8       // kVK_ANSI_Keypad8
        case 0x5C: return GHOSTTY_KEY_NUMPAD_9       // kVK_ANSI_Keypad9
        case 0x41: return GHOSTTY_KEY_NUMPAD_DECIMAL   // kVK_ANSI_KeypadDecimal
        case 0x43: return GHOSTTY_KEY_NUMPAD_MULTIPLY  // kVK_ANSI_KeypadMultiply
        case 0x45: return GHOSTTY_KEY_NUMPAD_ADD       // kVK_ANSI_KeypadPlus
        case 0x4B: return GHOSTTY_KEY_NUMPAD_DIVIDE    // kVK_ANSI_KeypadDivide
        case 0x4C: return GHOSTTY_KEY_NUMPAD_ENTER     // kVK_ANSI_KeypadEnter
        case 0x4E: return GHOSTTY_KEY_NUMPAD_SUBTRACT  // kVK_ANSI_KeypadMinus
        case 0x51: return GHOSTTY_KEY_NUMPAD_EQUAL     // kVK_ANSI_KeypadEquals
        case 0x5F: return GHOSTTY_KEY_NUMPAD_COMMA     // kVK_JIS_KeypadComma
        // Apple labels 0x47 "Clear"; the W3C/Chromium tables and libghostty call it NumLock.
        case 0x47: return GHOSTTY_KEY_NUM_LOCK         // kVK_ANSI_KeypadClear

        // MARK: Function keys (W3C § 3.5)
        case 0x7A: return GHOSTTY_KEY_F1             // kVK_F1
        case 0x78: return GHOSTTY_KEY_F2             // kVK_F2
        case 0x63: return GHOSTTY_KEY_F3             // kVK_F3
        case 0x76: return GHOSTTY_KEY_F4             // kVK_F4
        case 0x60: return GHOSTTY_KEY_F5             // kVK_F5
        case 0x61: return GHOSTTY_KEY_F6             // kVK_F6
        case 0x62: return GHOSTTY_KEY_F7             // kVK_F7
        case 0x64: return GHOSTTY_KEY_F8             // kVK_F8
        case 0x65: return GHOSTTY_KEY_F9             // kVK_F9
        case 0x6D: return GHOSTTY_KEY_F10            // kVK_F10
        case 0x67: return GHOSTTY_KEY_F11            // kVK_F11
        case 0x6F: return GHOSTTY_KEY_F12            // kVK_F12
        case 0x69: return GHOSTTY_KEY_F13            // kVK_F13 (PrintScreen on PC keyboards)
        case 0x6B: return GHOSTTY_KEY_F14            // kVK_F14 (ScrollLock)
        case 0x71: return GHOSTTY_KEY_F15            // kVK_F15 (Pause)
        case 0x6A: return GHOSTTY_KEY_F16            // kVK_F16
        case 0x40: return GHOSTTY_KEY_F17            // kVK_F17
        case 0x4F: return GHOSTTY_KEY_F18            // kVK_F18
        case 0x50: return GHOSTTY_KEY_F19            // kVK_F19
        case 0x5A: return GHOSTTY_KEY_F20            // kVK_F20

        // MARK: Media keys (W3C § 3.6)
        case 0x48: return GHOSTTY_KEY_AUDIO_VOLUME_UP    // kVK_VolumeUp
        case 0x49: return GHOSTTY_KEY_AUDIO_VOLUME_DOWN  // kVK_VolumeDown
        case 0x4A: return GHOSTTY_KEY_AUDIO_VOLUME_MUTE  // kVK_Mute

        default: return GHOSTTY_KEY_UNIDENTIFIED
        }
    }
}
