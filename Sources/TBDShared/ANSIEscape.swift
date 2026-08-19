import Foundation

/// Strips ANSI/OSC escape sequences from terminal capture text.
///
/// Closed-terminal history files are captured with escapes intact (`capture-pane
/// -e`) so the raw file stays a faithful replay/fidelity source — the revive
/// path `cat`s it back and colors render. The read-only history viewer, which
/// cannot interpret escapes, strips them here for plain-text display.
/// (Deliberate v1: colors in the viewer can come later.)
public enum ANSIEscape {
    /// Three forms, matched in this order so the more specific CSI/OSC
    /// alternatives claim their sequences before the generic fallback can:
    ///
    /// 1. CSI (`ESC [ … final-byte`) — parameter bytes widened to the full
    ///    ECMA-48 range `0-9 : ; < = > ?` (0x30-0x3F), not just digits and
    ///    `?`. Real CLIs emit private-prefixed forms like `ESC [ < u` (Kitty
    ///    keyboard protocol queries) and `ESC [ > 4;2 m` (modifyOtherKeys) —
    ///    `<`, `>` and `=` are legal CSI parameter bytes, and without them
    ///    here the whole sequence fails to match and survives verbatim.
    /// 2. OSC (`ESC ] … BEL|ST`).
    /// 3. Generic two-byte-or-more escape sequences with no `[` or `]`:
    ///    `ESC` + zero or more intermediate bytes (0x20-0x2F, e.g. the `(`
    ///    / `)` charset-selector introducer) + one final byte. The final-byte
    ///    class excludes `[` and `]` (0x30-0x5A, 0x5C, 0x5E-0x7E, skipping
    ///    0x5B and 0x5D) even though both fall inside the raw 0x30-0x7E
    ///    final-byte range: those two bytes are precisely what introduces CSI
    ///    and OSC, so a genuine bracket-less escape's final byte is never one
    ///    of them. Without the exclusion, a malformed or truncated CSI/OSC
    ///    run — one that never reaches a valid final byte, so alternatives 1
    ///    and 2 fail — would fall through to this alternative and match only
    ///    the two-byte `ESC [` / `ESC ]` lead-in, leaving the truncated
    ///    remainder behind as literal text: worse than leaving the whole
    ///    malformed run untouched. With the exclusion, a malformed run falls
    ///    through all three alternatives and survives whole. Covers
    ///    `ESC 7` / `ESC 8` (save/restore cursor) and `ESC ( B` / `ESC ) 0`
    ///    (charset designation) — none of which start with, or ever end in,
    ///    `[` or `]`, so alternatives 1 and 2 never see them and excluding
    ///    those bytes from the final-byte class costs them nothing.
    ///
    /// Accepted consequence: a stray literal `ESC` that isn't part of any
    /// real sequence consumes the one character immediately after it (e.g.
    /// `ESC` + `A` strips to nothing), where the old CSI/OSC-only pattern
    /// left both untouched. This is inherent to recognizing two-byte escapes
    /// at all — `ESC A` is a well-formed escape sequence, and a stripper
    /// cannot distinguish it from a stray `ESC` followed by an unrelated
    /// letter. Stripping it is the correct reading; this is not a bug to
    /// "fix" with heuristics that guess intent.
    ///
    /// Mirrors the scrubber pattern used elsewhere in TBD, widened against a
    /// real `claude --cloud` capture whose first line survived stripping
    /// intact because of exactly the gaps closed above.
    private static let regex = try! NSRegularExpression(
        pattern: "\u{1B}\\[[0-9:;<=>?]*[ -/]*[@-~]"
            + "|\u{1B}\\][^\u{07}\u{1B}]*(?:\u{07}|\u{1B}\\\\)"
            + "|\u{1B}[ -/]*[0-Z\\\\^-~]"
    )

    /// Remove all ANSI/OSC escape sequences, leaving the visible text.
    public static func strip(_ s: String) -> String {
        let range = NSRange(s.startIndex..., in: s)
        return regex.stringByReplacingMatches(in: s, range: range, withTemplate: "")
    }
}
