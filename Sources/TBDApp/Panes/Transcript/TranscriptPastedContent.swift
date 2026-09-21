import Foundation

/// Splits a user prompt at Claude Code's terminal-paste wrappers.
///
/// ## The format
///
/// Claude Code stores what the user pasted into the terminal INSIDE the prompt
/// text, wrapped in a tag pair whose closing tag repeats the opening tag's id
/// (so it is not well-formed XML):
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
/// removed. The transcript renders the pasted text as its own monospaced block
/// under a small "pasted" caption instead of showing the raw tags.
///
/// Only USER prompts are split — an assistant message quoting the syntax is
/// prose, and callers gate on the role.
///
/// ## What stays verbatim
///
/// Anything that is not a complete, unambiguous span is left as typed text,
/// tags included, so nothing the user wrote is ever dropped:
///
/// * an opening tag with no closing tag carrying the SAME id;
/// * an opening tag whose id is not exactly four lowercase hex digits;
/// * an opening tag whose body would contain another valid opening tag before
///   its close. The OUTER tag is then left verbatim and scanning resumes just
///   after it, so an inner span that is itself complete is still recognised.
///
/// A closing tag with a DIFFERENT id is not a close for this span: the search
/// looks only for the matching id, so a mismatched close is simply part of the
/// pasted text (or of the typed text, outside any span), and a later close with
/// the right id still ends the span.
///
/// ## Whitespace around a span
///
/// The newlines separating a span from the typed text around it are separators:
/// a typed run is trimmed of newlines on the side that touches a paste, and a
/// run left with nothing but whitespace is dropped. Text with no recognised span
/// comes back as ONE `.typed` segment holding the input verbatim.
enum TranscriptPastedContent {
    enum Segment: Equatable {
        /// Text the user typed. Still markdown, still subject to image-marker
        /// splitting.
        case typed(String)
        /// Text the user pasted, wrapper newlines removed. Never markdown.
        case pasted(id: String, text: String)
    }

    private static let openPrefix = "<pasted_content id=\""
    private static let tagSuffix = "\">"
    private static let idLength = 4
    private static let hexDigits: Set<Character> = Set("0123456789abcdef")

    /// Splits `text` into ordered typed / pasted segments. See the type's doc
    /// comment for the rules.
    ///
    /// Fast path: text without the opening-tag prefix returns `[.typed(text)]`
    /// after one substring search, so the common prompt pays nothing more.
    static func split(_ text: String) -> [Segment] {
        guard text.contains(openPrefix) else { return [.typed(text)] }

        var segments: [Segment] = []
        var typedStart = text.startIndex
        var searchFrom = text.startIndex
        var sawPaste = false

        func appendTyped(_ run: Substring, beforePaste: Bool) {
            var run = run
            if sawPaste { while let first = run.first, first.isNewline { run = run.dropFirst() } }
            if beforePaste { while let last = run.last, last.isNewline { run = run.dropLast() } }
            guard !run.allSatisfy(\.isWhitespace) else { return }
            segments.append(.typed(String(run)))
        }

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
            appendTyped(text[typedStart..<open.range.lowerBound], beforePaste: true)
            segments.append(.pasted(
                id: open.id,
                text: strippingWrapperNewlines(text[open.range.upperBound..<close.lowerBound])))
            sawPaste = true
            typedStart = close.upperBound
            searchFrom = close.upperBound
        }

        guard sawPaste else { return [.typed(text)] }
        appendTyped(text[typedStart...], beforePaste: false)
        return segments
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
    /// user's paste and is kept.
    private static func strippingWrapperNewlines(_ body: Substring) -> String {
        var body = body
        if let first = body.first, first == "\n" || first == "\r\n" { body = body.dropFirst() }
        if let last = body.last, last == "\n" || last == "\r\n" { body = body.dropLast() }
        return String(body)
    }
}
