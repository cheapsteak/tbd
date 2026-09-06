import Foundation

/// Whether the caret is inside a completion token, and which one.
///
/// **A suggestion, never a mode.** The menu opens on a sigil typed at the start
/// of the input, at the start of a line, or after whitespace — anywhere in the
/// text — and it never opens inside a word, which is what keeps `https://` and
/// `foo/bar` from stealing Return from somebody typing a URL. A space, or the
/// caret leaving the token, closes it.
///
/// Pure, and a function of the text alone. The stateful halves of the rule live
/// in the controller, because they are not properties of the string: Escape
/// closes the menu and keeps it closed for that token until the token changes,
/// and no menu opens or updates while an input method has marked text.
///
/// **Every offset is UTF-16.** `NSTextView` selection ranges are, and a range
/// computed in `Character` offsets replaces the wrong bytes the first time
/// somebody types an emoji.
enum CompletionTrigger {
    enum Kind: Equatable {
        /// `/` — commands, skills, plugin items.
        case command
        /// `@` — subagents, in the first version.
        case mention
    }

    struct Match: Equatable {
        let kind: Kind
        /// The sigil's index in the string's UTF-16 view.
        let sigilLocation: Int
        /// The whole token including the sigil, from the sigil to the caret.
        let tokenRange: NSRange
        /// What the person has typed after the sigil, up to the caret. Filtering
        /// follows the caret rather than the token's end, so backspacing into a
        /// token widens the match instead of keeping the old query.
        let query: String
    }

    /// Characters a completion token may not contain. A token ends at the first
    /// of these, which is what makes "a space closes it" true without a second
    /// rule.
    private static let terminators = CharacterSet.whitespacesAndNewlines

    static func detect(text: String, selectionLocation: Int) -> Match? {
        let ns = text as NSString
        guard selectionLocation >= 0, selectionLocation <= ns.length else { return nil }

        // Walk back from the caret to the token's start. Stop at whitespace (the
        // token ended) or at a sigil (found it).
        var index = selectionLocation
        while index > 0 {
            let scalarRange = ns.rangeOfComposedCharacterSequence(at: index - 1)
            let piece = ns.substring(with: scalarRange)
            if piece == "/" || piece == "@" {
                let sigilLocation = scalarRange.location
                // The sigil must start the input, start a line, or follow
                // whitespace. Anything else means it sits inside a word —
                // `https://`, `foo/bar`, `me@example.com` — and opening there is
                // the trap this rule exists to avoid.
                if sigilLocation > 0 {
                    let beforeRange = ns.rangeOfComposedCharacterSequence(at: sigilLocation - 1)
                    let before = ns.substring(with: beforeRange)
                    guard before.rangeOfCharacter(from: terminators) != nil else { return nil }
                }
                let queryRange = NSRange(
                    location: scalarRange.location + scalarRange.length,
                    length: selectionLocation - (scalarRange.location + scalarRange.length))
                return Match(
                    kind: piece == "/" ? .command : .mention,
                    sigilLocation: sigilLocation,
                    tokenRange: NSRange(
                        location: sigilLocation,
                        length: selectionLocation - sigilLocation),
                    query: ns.substring(with: queryRange))
            }
            if piece.rangeOfCharacter(from: terminators) != nil {
                // Whitespace before any sigil: the caret is not in a token.
                return nil
            }
            index = scalarRange.location
        }
        return nil
    }
}
