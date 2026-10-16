import Foundation

/// Removes Claude Code's terminal-paste wrappers from a user prompt.
///
/// ## The format
///
/// Claude Code stores what arrived as a bracketed paste INSIDE the prompt text,
/// wrapped in a tag pair whose closing tag repeats the opening tag's id (so it
/// is not well-formed XML):
///
///     look at this:
///
///     <pasted_content id="62f5">
///     /Users/acme/tbd/worktrees/acme-app/20260921-stiff-seahorse
///     </pasted_content id="62f5">
///
///     why is it here?
///
/// The id is four lowercase hex digits. A newline follows the opening tag and
/// precedes the closing one; those two newlines are wrapper, not paste, and are
/// removed along with the tags.
///
/// The transcript composer delivers every message as a bracketed paste, so a
/// wrapped span is usually the user's own typed message. The transcript
/// therefore renders the span's text exactly like typed text — markdown, still
/// subject to image-marker splitting — and only the tags are dropped.
///
/// Only USER prompts are unwrapped — an assistant message quoting the syntax is
/// prose, and callers gate on the role.
///
/// ## What stays verbatim
///
/// Anything that is not a complete, unambiguous span is left as it is, tags
/// included, so nothing the user wrote is ever dropped:
///
/// * an opening tag with no closing tag carrying the SAME id;
/// * an opening tag whose id is not exactly four lowercase hex digits;
/// * an opening tag whose body would contain another valid opening tag before
///   its close. The OUTER tag is then left verbatim and scanning resumes just
///   after it, so an inner span that is itself complete is still recognised.
///
/// A closing tag with a DIFFERENT id is not a close for this span: the search
/// looks only for the matching id, so a mismatched close is simply part of the
/// span's text (or of the text outside any span), and a later close with the
/// right id still ends the span.
///
/// ## Whitespace
///
/// When at least one span is recognised, the result loses its leading blank
/// lines and its trailing whitespace, so a message the composer sent reads as
/// the user wrote it rather than opening on the wrapper's line breaks. Text with
/// no recognised span comes back verbatim.
enum TranscriptPastedContent {
    private static let openPrefix = "<pasted_content id=\""
    private static let tagSuffix = "\">"
    private static let idLength = 4
    private static let hexDigits: Set<Character> = Set("0123456789abcdef")

    /// `text` with every recognised span's wrapper removed. See the type's doc
    /// comment for the rules.
    ///
    /// Fast path: text without the opening-tag prefix is returned as-is after
    /// one substring search, so the common prompt pays nothing more.
    static func unwrap(_ text: String) -> String {
        guard text.contains(openPrefix) else { return text }

        var out = ""
        var typedStart = text.startIndex
        var searchFrom = text.startIndex
        var sawPaste = false

        while let open = openingTag(in: text, from: searchFrom, before: text.endIndex) {
            let closeTag = "</pasted_content id=\"\(open.id)\">"
            guard let close = text.range(of: closeTag, range: open.range.upperBound..<text.endIndex) else {
                // Unmatched: leave the tag as typed text and keep scanning.
                searchFrom = open.range.upperBound
                continue
            }
            if openingTag(in: text, from: open.range.upperBound, before: close.lowerBound) != nil {
                // Another span opens inside this one: ambiguous, so this opening
                // tag stays verbatim and the inner one gets its own chance.
                searchFrom = open.range.upperBound
                continue
            }
            out += text[typedStart..<open.range.lowerBound]
            out += strippingWrapperNewlines(text[open.range.upperBound..<close.lowerBound])
            sawPaste = true
            typedStart = close.upperBound
            searchFrom = close.upperBound
        }

        guard sawPaste else { return text }
        out += text[typedStart...]
        return trimmingOuterBlankSpace(out)
    }

    /// The first valid opening tag starting at or after `from` and ending at or
    /// before `limit`, with its id.
    private static func openingTag(
        in text: String,
        from: String.Index,
        before limit: String.Index
    ) -> (range: Range<String.Index>, id: String)? {
        var cursor = from
        while cursor < limit, let prefix = text.range(of: openPrefix, range: cursor..<limit) {
            let idEnd = text.index(prefix.upperBound, offsetBy: idLength, limitedBy: limit) ?? limit
            let id = text[prefix.upperBound..<idEnd]
            if id.count == idLength, id.allSatisfy({ hexDigits.contains($0) }),
               text[idEnd..<limit].hasPrefix(tagSuffix) {
                let end = text.index(idEnd, offsetBy: tagSuffix.count)
                return (prefix.lowerBound..<end, String(id))
            }
            cursor = prefix.upperBound
        }
        return nil
    }

    /// Removes exactly one newline after the opening tag and one before the
    /// closing tag — the wrapper's own line breaks. Anything beyond that is the
    /// user's text and is kept.
    private static func strippingWrapperNewlines(_ body: Substring) -> Substring {
        var body = body
        if let first = body.first, first == "\n" || first == "\r\n" { body = body.dropFirst() }
        if let last = body.last, last == "\n" || last == "\r\n" { body = body.dropLast() }
        return body
    }

    /// Drops whole leading lines that hold only whitespace, and all trailing
    /// whitespace. Indentation on the first non-blank line is kept, since
    /// markdown gives it meaning.
    private static func trimmingOuterBlankSpace(_ text: String) -> String {
        var start = text.startIndex
        var cursor = text.startIndex
        while cursor < text.endIndex, text[cursor].isWhitespace {
            if text[cursor].isNewline { start = text.index(after: cursor) }
            cursor = text.index(after: cursor)
        }
        var end = text.endIndex
        while end > start, text[text.index(before: end)].isWhitespace { end = text.index(before: end) }
        return String(text[start..<end])
    }
}
