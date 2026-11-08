import Foundation

/// The one rule for a paired phone's message text, wherever the text goes:
/// the send rail (`sendFromPairedPhone`), a wake's prompt, a remote session's
/// message, a new worktree's first message and a new remote session's first
/// message. Every path that carries a phone's text holds it to this rule and
/// answers with these refusals, so the phone hears the same words for the
/// same text whichever path it took.
///
/// `vetted(_:)` applies the whole rule: every CRLF becomes a bare LF
/// (`lineEndingsNormalized`), then a blank message is refused (`isBlank`),
/// then one holding a control character (`hasControlCharacter`).
///
/// Each path needs it for its own reason. A message pasted into a pane, or
/// pasted by a remote provider into its session, reaches an agent whose
/// bracketed paste is off as keys: ESC as Escape, ETX as Ctrl-C, a CR as an
/// Enter partway through. A first message or a wake's prompt rides the
/// argument list of the process that starts the session, and an argument is
/// a C string, which cannot hold a NUL; it also becomes the session's first
/// turn, so a blank one would start a turn on nothing.
///
/// It lives in `Base` because both the router (`Server`) and the phone app
/// service (`PhoneBridge`) apply it, and neither may name the other's code.
enum PhoneMessageText {
    /// What becomes of a phone's text under the rule.
    enum Vetted<Value> {
        /// Deliver this: the text with every CRLF made a bare LF, or what
        /// was built from it.
        case deliver(Value)
        /// Deliver nothing, and answer with this refusal.
        case refused(String)
    }

    /// What a paired phone hears when its message is blank: empty, or only
    /// whitespace and invisible format characters.
    static let emptyRefusal = "a phone message cannot be empty"

    /// What a paired phone hears when its message holds a control character.
    static let controlCharacterRefusal = "a phone message cannot contain control characters"

    /// `text` held to the whole rule: every CRLF made a bare LF, then a blank
    /// message refused, then one holding a control character refused.
    static func vetted(_ text: String) -> Vetted<String> {
        let normalized = lineEndingsNormalized(text)
        if isBlank(normalized) {
            return .refused(emptyRefusal)
        }
        if hasControlCharacter(normalized) {
            return .refused(controlCharacterRefusal)
        }
        return .deliver(normalized)
    }

    /// A first message that may be absent, as a wake or a worktree create
    /// carries it. Nil or empty is no message, so no rule applies and it is
    /// delivered as it came; any other text is `vetted(_:)`.
    static func vettedFirstMessage(_ text: String?) -> Vetted<String?> {
        guard let text, !text.isEmpty else { return .deliver(text) }
        switch vetted(text) {
        case .deliver(let normalized):
            return .deliver(normalized)
        case .refused(let reason):
            return .refused(reason)
        }
    }

    /// Whether `text`, a phone message or one of its text parts, types
    /// nothing a person could see: every scalar is whitespace, a format
    /// character (general category Cf, such as U+200B ZERO WIDTH SPACE,
    /// U+2060 WORD JOINER or U+FEFF, the byte-order mark), or a
    /// default-ignorable code point (such as U+3164 HANGUL FILLER, U+034F
    /// COMBINING GRAPHEME JOINER or a variation selector). Empty text is
    /// blank. Whitespace is the set the send core's shape check trims. One
    /// visible scalar makes the text non-blank, so a ZWJ inside an emoji
    /// sequence or a variation selector after a visible character keeps it.
    static func isBlank(_ text: String) -> Bool {
        text.unicodeScalars.allSatisfy { scalar in
            CharacterSet.whitespacesAndNewlines.contains(scalar)
                || scalar.properties.generalCategory == .format
                || scalar.properties.isDefaultIgnorableCodePoint
        }
    }

    /// `text` with every CRLF made a bare LF. A phone's keyboard or clipboard
    /// can end lines with CRLF, and the control-character check would
    /// otherwise refuse every such message for its CRs. A lone CR is kept,
    /// for that check to judge.
    static func lineEndingsNormalized(_ text: String) -> String {
        text.replacingOccurrences(of: "\r\n", with: "\n")
    }

    /// Whether `text`, a phone message or one of its text parts, holds a
    /// control character a phone message may not carry (`isRefusedControl`).
    static func hasControlCharacter(_ text: String) -> Bool {
        text.unicodeScalars.contains { scalar in isRefusedControl(scalar) }
    }

    /// Whether `scalar` is a control character a phone message may not carry:
    /// a C0 control (below U+0020) other than LF and tab, DEL (U+007F), or a
    /// C1 control (U+0080–U+009F). Any of them reaches a pane whose child has
    /// bracketed paste off as a key, not as text.
    private static func isRefusedControl(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x0A, 0x09: return false
        case 0x00..<0x20, 0x7F, 0x80...0x9F: return true
        default: return false
        }
    }
}

extension PhoneMessageText.Vetted: Equatable where Value: Equatable {}
extension PhoneMessageText.Vetted: Sendable where Value: Sendable {}
