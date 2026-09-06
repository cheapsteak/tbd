import Foundation
import TBDShared

/// The inline `[Image #N]` placeholder, and what it means at send time.
///
/// **The token is the anchor.** It decides whether an image is sent and where it
/// sits among the words; the draft's side map only says which file each number
/// points at. So a token the person deleted drops its image, and a token they
/// edited so it no longer matches is literal text that drops its image too —
/// the rule Claude Code's own composer applies to the same placeholders. The
/// alternative, a chip strip with no inline anchors, was rejected because it
/// gives no way to refer to an image at a point in the sentence.
///
/// Every range is UTF-16, matching `NSTextView` selection coordinates.
enum ComposerTokens {
    struct Token: Equatable {
        let number: Int
        let range: NSRange
    }

    static func text(for number: Int) -> String { "[Image #\(number)]" }

    /// Deliberately anchored and exact: `[Image #` then digits then `]`. A looser
    /// pattern would swallow `[Image #1x]`, which is a token the person edited
    /// and therefore must NOT resolve.
    private static let pattern = try? NSRegularExpression(
        pattern: #"\[Image #(\d+)\]"#, options: [])

    static func scan(_ text: String) -> [Token] {
        guard let pattern else { return [] }
        let ns = text as NSString
        return pattern.matches(in: text, range: NSRange(location: 0, length: ns.length))
            .compactMap { match in
                guard match.numberOfRanges == 2,
                      let number = Int(ns.substring(with: match.range(at: 1)))
                else { return nil }
                return Token(number: number, range: match.range)
            }
    }

    /// Split at the tokens that resolve, in order. Text between them is a text
    /// part; an empty one is skipped rather than sent as an empty paste.
    ///
    /// A token with no staged file is left in place as literal text: a part
    /// pointing at nothing would arrive as a broken path in the message.
    static func parts(text: String, paths: [Int: String]) -> [SendPart] {
        let ns = text as NSString
        var result: [SendPart] = []
        var cursor = 0
        for token in scan(text) {
            guard let path = paths[token.number] else { continue }
            if token.range.location > cursor {
                let slice = ns.substring(
                    with: NSRange(
                        location: cursor, length: token.range.location - cursor))
                if !slice.isEmpty { result.append(.text(slice)) }
            }
            result.append(.imagePath(path))
            cursor = token.range.location + token.range.length
        }
        if cursor < ns.length {
            let tail = ns.substring(from: cursor)
            if !tail.isEmpty { result.append(.text(tail)) }
        }
        return result
    }

    /// The not-running form: every resolving token replaced inline with its
    /// quoted absolute path.
    ///
    /// An argument prompt cannot carry image attachments at all, so this is what
    /// a woken session receives. The sentence reads the same, and Claude reads
    /// the files with its Read tool — whose image reads are capped near 500 KB,
    /// which is why the composer says so on the send button.
    static func flattened(text: String, paths: [Int: String]) -> String {
        let ns = text as NSString
        var result = ""
        var cursor = 0
        for token in scan(text) {
            guard let path = paths[token.number] else { continue }
            if token.range.location > cursor {
                result += ns.substring(
                    with: NSRange(location: cursor, length: token.range.location - cursor))
            }
            result += "'" + path.replacingOccurrences(of: "'", with: #"'\''"#) + "'"
            cursor = token.range.location + token.range.length
        }
        if cursor < ns.length { result += ns.substring(from: cursor) }
        return result
    }

    /// Which staged numbers the text still anchors. The strip greys out the rest
    /// as "not in message", so nothing is dropped silently.
    static func attachedNumbers(in text: String) -> Set<Int> {
        Set(scan(text).map(\.number))
    }
}
