import Foundation

public enum ChannelNameError: Error, Equatable, Sendable {
    case empty
    case leadingOrTrailingWhitespace
    case reservedName(String)
    case forbiddenCharacter(Character)
    case tooLongGraphemes(Int)
    case tooLongBytes(Int)
}

/// Validate, normalize, and case-fold a channel name. Returns the canonical
/// storage form. Throws `ChannelNameError` if the name is invalid.
///
/// See `docs/superpowers/specs/2026-05-10-channels-design.md` for the
/// rationale behind each rule.
public func validateChannelName(_ raw: String) throws -> String {
    // Strip a single leading '#' for Slack-style ergonomics. This lets
    // `tbd channels post #help …` and `tbd channels post help …` resolve
    // to the same channel. We only strip ONE — `##foo` is still rejected
    // by the forbidden-character check below (well, `#` isn't forbidden,
    // so `##foo` becomes `#foo` and is accepted as a literal channel name
    // — that's intentional; it just means "Slack-prefix UX, not literal").
    let input = raw.hasPrefix("#") ? String(raw.dropFirst()) : raw

    if input.isEmpty { throw ChannelNameError.empty }
    if input.first?.isWhitespace == true || input.last?.isWhitespace == true {
        throw ChannelNameError.leadingOrTrailingWhitespace
    }

    // Reject forbidden characters before normalization so error messages
    // reference the original character the user typed.
    for ch in input {
        for scalar in ch.unicodeScalars {
            if scalar.value == 0x2F           // '/'
                || scalar.value == 0x5C       // '\\'
                || scalar.value <= 0x1F       // C0 controls + NUL
                || scalar.value == 0x7F {     // DEL
                throw ChannelNameError.forbiddenCharacter(ch)
            }
        }
    }

    let folded = input.precomposedStringWithCanonicalMapping.lowercased()

    if folded == "." || folded == ".." || folded == "_archive" {
        throw ChannelNameError.reservedName(folded)
    }

    let graphemeCount = folded.count
    if graphemeCount > 64 {
        throw ChannelNameError.tooLongGraphemes(graphemeCount)
    }
    let byteCount = folded.utf8.count
    if byteCount > 200 {
        throw ChannelNameError.tooLongBytes(byteCount)
    }

    return folded
}
