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
    if raw.isEmpty { throw ChannelNameError.empty }
    if raw.first?.isWhitespace == true || raw.last?.isWhitespace == true {
        throw ChannelNameError.leadingOrTrailingWhitespace
    }

    // Reject forbidden characters before normalization so error messages
    // reference the original character the user typed.
    for ch in raw {
        for scalar in ch.unicodeScalars {
            if scalar.value == 0x2F           // '/'
                || scalar.value == 0x5C       // '\\'
                || scalar.value <= 0x1F       // C0 controls + NUL
                || scalar.value == 0x7F {     // DEL
                throw ChannelNameError.forbiddenCharacter(ch)
            }
        }
    }

    let folded = raw.precomposedStringWithCanonicalMapping.localizedLowercase

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
