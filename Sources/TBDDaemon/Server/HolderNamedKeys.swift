import Foundation
import TBDShared

/// The holder transport's named-key table: one `terminal.send --keys` name to
/// the exact bytes a child reads for that key.
///
/// Split out of the send path for the same reason `HolderSendComposition` is —
/// it is the whole of a decision and none of the plumbing. Given a key's name
/// and the child's tracked modes there is exactly one right answer in bytes,
/// and a pure function over `Data` is the only thing worth asserting: `Up`
/// under DECCKM is `ESC O A` and nothing else, `Escape` is `ESC` in every mode.
///
/// The names are tmux's own `send-keys` spellings, because that is the
/// vocabulary every existing caller already types and the bytes below are the
/// ones tmux would have sent for them — the holder is a new transport for the
/// same key, not a new key. An unknown name returns `nil` so the caller can
/// refuse the whole send by that name, having written nothing.
///
/// **Two families depend on the child's modes; the rest do not.** With DECCKM
/// (`applicationCursor`) on, the arrows and Home/End take their SS3 forms
/// (`ESC O A`), which is what a full-screen TUI has asked for by turning the
/// mode on; off — and when no store answered, so `modes` is `nil` — they take
/// their CSI forms (`ESC [ A`), which a shell at its prompt reads. Every other
/// key is one fixed sequence regardless of mode, so a `nil` reading changes
/// nothing for it.
enum HolderNamedKeys {
    /// The bytes for one key name against the child's modes, or `nil` when the
    /// name is not one this table knows.
    static func bytes(for name: String, modes: TerminalScreen.ChildModes?) -> Data? {
        // A `C-x` control combo is its own small grammar, tried first so a name
        // like `C-[` never falls through to the named-key switch.
        if let controlByte = controlByte(for: name) {
            return Data([controlByte])
        }

        let applicationCursor = modes?.applicationCursor ?? false
        switch name {
        case "Enter", "Return": return Data([0x0d])
        case "Escape", "Esc": return Data([0x1b])
        case "Tab": return Data([0x09])
        case "BTab": return escaped("[Z")
        case "BSpace", "BackSpace": return Data([0x7f])
        case "Space": return Data([0x20])
        // The cursor-key family: SS3 under DECCKM, CSI otherwise.
        case "Up": return cursorKey("A", applicationCursor: applicationCursor)
        case "Down": return cursorKey("B", applicationCursor: applicationCursor)
        case "Right": return cursorKey("C", applicationCursor: applicationCursor)
        case "Left": return cursorKey("D", applicationCursor: applicationCursor)
        case "Home": return cursorKey("H", applicationCursor: applicationCursor)
        case "End": return cursorKey("F", applicationCursor: applicationCursor)
        // The editing and paging keys are `ESC [ … ~` in every mode.
        case "PageUp", "PPage": return escaped("[5~")
        case "PageDown", "NPage": return escaped("[6~")
        case "Insert", "IC": return escaped("[2~")
        case "Delete", "DC": return escaped("[3~")
        // F1–F4 are SS3; F5 up are `ESC [ … ~` with the usual gaps (no 16, 22).
        case "F1": return escaped("OP")
        case "F2": return escaped("OQ")
        case "F3": return escaped("OR")
        case "F4": return escaped("OS")
        case "F5": return escaped("[15~")
        case "F6": return escaped("[17~")
        case "F7": return escaped("[18~")
        case "F8": return escaped("[19~")
        case "F9": return escaped("[20~")
        case "F10": return escaped("[21~")
        case "F11": return escaped("[23~")
        case "F12": return escaped("[24~")
        default: return nil
        }
    }

    // MARK: - Building blocks

    /// `ESC` followed by the given ASCII tail.
    private static func escaped(_ tail: String) -> Data {
        var bytes = Data([0x1b])
        bytes.append(contentsOf: tail.utf8)
        return bytes
    }

    /// A cursor-key sequence for the trailing letter (`A`…`D`, `H`, `F`): `ESC O
    /// <final>` under DECCKM, `ESC [ <final>` otherwise. `0x4f` is `O`, `0x5b`
    /// is `[`.
    private static func cursorKey(_ final: Character, applicationCursor: Bool) -> Data {
        var bytes = Data([0x1b, applicationCursor ? 0x4f : 0x5b])
        bytes.append(contentsOf: String(final).utf8)
        return bytes
    }

    /// The single control byte for a `C-x` combo, or `nil` when `name` is not a
    /// `C-` combo this table knows.
    ///
    /// `C-a`…`C-z` are `0x01`…`0x1a`; the letter is case-insensitive, as it is
    /// in tmux. `C-Space` and `C-@` are NUL. The five punctuation combos are
    /// the C0 controls above the letters: `C-[` is ESC, then `C-\`, `C-]`,
    /// `C-^`, `C-_` are `0x1c`…`0x1f`.
    private static func controlByte(for name: String) -> UInt8? {
        guard name.hasPrefix("C-") else { return nil }
        let rest = name.dropFirst(2)
        if rest == "Space" || rest == "@" { return 0x00 }
        guard rest.count == 1, let ch = rest.first, let ascii = ch.asciiValue else { return nil }
        switch ch {
        case "a"..."z": return ascii - 0x60  // 'a' (0x61) → 0x01
        case "A"..."Z": return ascii - 0x40  // 'A' (0x41) → 0x01
        case "[": return 0x1b
        case "\\": return 0x1c
        case "]": return 0x1d
        case "^": return 0x1e
        case "_": return 0x1f
        default: return nil
        }
    }
}
