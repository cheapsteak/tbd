import Foundation

/// Strips ANSI/OSC escape sequences from terminal capture text.
///
/// Closed-terminal history files are captured with escapes intact (`capture-pane
/// -e`) so the raw file stays a faithful replay/fidelity source — the revive
/// path `cat`s it back and colors render. The read-only history viewer, which
/// cannot interpret escapes, strips them here for plain-text display.
/// (Deliberate v1: colors in the viewer can come later.)
public enum ANSIEscape {
    /// CSI (`ESC [ … final-byte`) and OSC (`ESC ] … BEL|ST`) sequences.
    /// Mirrors the scrubber pattern used elsewhere in TBD.
    private static let regex = try! NSRegularExpression(
        pattern: "\u{1B}\\[[0-9;?]*[ -/]*[@-~]|\u{1B}\\][^\u{07}\u{1B}]*(?:\u{07}|\u{1B}\\\\)"
    )

    /// Remove all ANSI/OSC escape sequences, leaving the visible text.
    public static func strip(_ s: String) -> String {
        let range = NSRange(s.startIndex..., in: s)
        return regex.stringByReplacingMatches(in: s, range: range, withTemplate: "")
    }
}
