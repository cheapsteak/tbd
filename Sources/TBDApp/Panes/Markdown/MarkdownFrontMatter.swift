import Foundation

/// A YAML front-matter block lifted off the top of a markdown source.
///
/// CommonMark has no front matter, so a file that opens with `---` renders as
/// a thematic break followed by a setext `<h2>` holding every YAML line run
/// together. comrak can recognise the block, but only through an option baked
/// into the prebuilt static library, and it would then drop the block instead
/// of showing it. So the builder splits it off before comrak sees the text and
/// shows it as a properties header above the body (`html`).
///
/// A block is front matter only when all of these hold:
/// - the very first line is `---` and the line after it is not blank;
/// - the first line that is not a column-0 `#` comment is a `key:` line, or
///   the block is empty;
/// - a later line closes it: `---`, or the first `...` when the block before
///   it is not empty and reads cleanly as keys;
/// - no code fence comes before the closer, except indented inside a `|` or
///   `>` block scalar.
///
/// Anything else is left exactly as it was: a document may open with a
/// thematic break, a banner or a heading between two rules, and a `---` inside
/// a fenced YAML example must not close a block that never was one.
struct MarkdownFrontMatter: Equatable, Sendable {

    /// One top-level `key: value` line and the indented lines that continue it.
    struct Entry: Equatable, Sendable {
        let key: String
        /// The rest of the key's own line, trimmed. Empty for `key:`, and for
        /// a block scalar's `|` or `>` indicator, which is syntax, not content.
        /// A plain scalar that runs onto indented lines is folded as YAML folds
        /// it: lines joined with a space, a line break for each blank line.
        let value: String
        /// The lines that continue the value — a nested map or list, a block
        /// scalar — with their common indentation removed. Nil when the value
        /// is the one line or was folded into `value`.
        let continuation: String?
    }

    /// The lines between the delimiters, joined with `\n` whatever the file's
    /// line endings were.
    let yaml: String
    /// The block read as top-level keys, in source order. Nil when it cannot be
    /// read that way (a top-level list, a column-0 comment, stray text); it is
    /// then shown as raw YAML instead.
    let entries: [Entry]?

    /// Splits `markdown` into its front matter, if any, and the body after it.
    /// A leading UTF-8 BOM is allowed before the opening `---`; anything else
    /// before it, a blank line included, means there is no front matter.
    static func split(_ markdown: String) -> (frontMatter: MarkdownFrontMatter?, body: String) {
        var cursor = markdown.startIndex
        if markdown.unicodeScalars.first == "\u{FEFF}" {
            cursor = markdown.unicodeScalars.index(after: cursor)
        }
        guard let opening = nextLine(in: markdown, from: cursor),
              delimiter(opening.content) == "---"
        else { return (nil, markdown) }
        // Pandoc's rule: a blank line straight after the opening `---` means
        // the document opens with a thematic break, not a metadata block.
        if let first = nextLine(in: markdown, from: opening.next), isBlank(first.content) {
            return (nil, markdown)
        }

        var lines: [Substring] = []
        var inBlockScalar = false
        var triedDots = false
        cursor = opening.next
        while let line = nextLine(in: markdown, from: cursor) {
            let content = line.content
            let marker = delimiter(content)
            // `...` also ends a YAML document, but a markdown line can be just
            // `...` too, so it closes only a non-empty block that reads cleanly
            // as keys. Only the first one is tried: a block that fails to read
            // keeps failing as it grows, and retrying at every later `...`
            // would make the scan quadratic. Spending that try on an empty
            // block is safe, because the stray `...` then becomes the block's
            // first line, so nothing after it can read as keys.
            var dotsEntries: [Entry]?
            if marker == "...", !triedDots {
                triedDots = true
                if !lines.isEmpty { dotsEntries = readEntries(lines) }
            }
            if marker == "---" || dotsEntries != nil {
                guard opensWithKey(lines) else { return (nil, markdown) }
                let frontMatter = MarkdownFrontMatter(
                    yaml: lines.joined(separator: "\n"),
                    entries: dotsEntries ?? readEntries(lines)
                )
                return (frontMatter, String(markdown[line.next...]))
            }
            // YAML has no code fences, so one means this is markdown, and the
            // `---` that would close it may sit inside the fence. The one
            // exception is an indented fence inside a `|` or `>` block scalar,
            // which is the scalar's text.
            let indented = content.first?.isWhitespace == true
            if isFence(content), !(inBlockScalar && indented) { return (nil, markdown) }
            if let pair = keyValue(content) {
                inBlockScalar = isBlockScalarIndicator(pair.value)
            } else if !content.isEmpty, !indented {
                inBlockScalar = false
            }
            lines.append(content)
            cursor = line.next
        }
        return (nil, markdown)
    }

    /// Whether the block reads as metadata: its first line that is not a
    /// column-0 `#` comment is a `key:` line. Otherwise it is a rule, a banner
    /// or a heading, then a rule. An empty block counts: `---` straight after
    /// `---` is the conventional empty front matter.
    private static func opensWithKey(_ lines: [Substring]) -> Bool {
        guard !lines.isEmpty else { return true }
        guard let first = lines.first(where: { !$0.hasPrefix("#") }) else { return false }
        return keyValue(first) != nil
    }

    /// The header shown above the rendered body, and nothing at all for an empty
    /// block. With entries it is a `<dl>`: a `<dt>` per key and a `<dd>` for its
    /// value, where a folded value of several paragraphs gets a `<p>` per
    /// paragraph (a run of blank lines is one paragraph break) and a nested or
    /// block-scalar value its lines in a `<pre>`. Without entries it is the raw
    /// YAML in a `<pre>`. Every piece of file text in it is HTML-escaped: this
    /// markup is TBD's own and bypasses comrak's safe mode, so nothing from the
    /// file may reach it raw.
    var html: String {
        guard let entries else {
            return #"<pre class="tbd-front-matter">"# + Self.escape(yaml) + "</pre>"
        }
        guard !entries.isEmpty else { return "" }
        let rows = entries.map { entry -> String in
            // A folded value's line breaks are paragraph breaks.
            let paragraphs = entry.value.split(separator: "\n")
            let value = paragraphs.count > 1
                ? paragraphs.map { "<p>" + Self.escape(String($0)) + "</p>" }.joined()
                : Self.escape(entry.value)
            let more = entry.continuation.map { "<pre>" + Self.escape($0) + "</pre>" } ?? ""
            return "<dt>" + Self.escape(entry.key) + "</dt><dd>" + value + more + "</dd>"
        }
        return #"<dl class="tbd-front-matter">"# + rows.joined() + "</dl>"
    }

    static func escape(_ text: String) -> String {
        text
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&#39;")
    }

    // MARK: - Reading the block

    /// Groups the lines under their top-level keys, or nil when some line is
    /// neither a key nor a continuation of one.
    private static func readEntries(_ lines: [Substring]) -> [Entry]? {
        var groups: [(key: String, value: String, more: [Substring])] = []
        for line in lines {
            if let pair = keyValue(line) {
                groups.append((key: pair.key, value: pair.value, more: []))
            } else if let lastValue = groups.last?.value, continues(lastValue, with: line) {
                groups[groups.count - 1].more.append(line)
            } else {
                return nil
            }
        }
        return groups.map { group in
            if isBlockScalarIndicator(group.value) {
                return Entry(key: group.key, value: "", continuation: dedented(group.more))
            }
            if !group.value.isEmpty, isPlainText(group.more) {
                return Entry(
                    key: group.key, value: folded(group.value, group.more), continuation: nil
                )
            }
            return Entry(key: group.key, value: group.value, continuation: dedented(group.more))
        }
    }

    /// Whether continuation lines are prose rather than structure: none is a
    /// nested `key:` line or a `- ` list item.
    private static func isPlainText(_ lines: [Substring]) -> Bool {
        lines.allSatisfy { line in
            let text = trimmed(line)
            return text.isEmpty || (keyValue(text) == nil && !isSequenceItem(text))
        }
    }

    /// A plain scalar's lines folded as YAML folds them: joined with a space,
    /// and a line break for each blank line between them.
    private static func folded(_ first: String, _ lines: [Substring]) -> String {
        var result = first
        var breaks = 0
        for line in lines {
            let text = trimmed(line)
            if text.isEmpty {
                breaks += 1
                continue
            }
            result += breaks > 0 ? String(repeating: "\n", count: breaks) : " "
            result += text
            breaks = 0
        }
        return result
    }

    /// Whether `value` is a block scalar's header — `|` or `>`, optional
    /// chomping and indentation indicators, optional ` # comment` — which is
    /// syntax, not content.
    private static func isBlockScalarIndicator(_ value: String) -> Bool {
        let text = Substring(value)
        let comment = text.indices.first { index in
            text[index] == "#" && index > text.startIndex
                && text[text.index(before: index)].isWhitespace
        }
        let indicator = trimmed(comment.map { text[..<$0] } ?? text)
        guard let first = indicator.first, "|>".contains(first) else { return false }
        return indicator.dropFirst().allSatisfy { "+-0123456789".contains($0) }
    }

    /// A column-0 `key: value` line, split at the first colon that is followed
    /// by whitespace or the end of the line, so a value such as
    /// `https://example.com` does not split the key. A quoted key (`"a: b": c`)
    /// ends at its closing quote and is shown without the quotes.
    private static func keyValue(_ line: Substring) -> (key: String, value: String)? {
        // A YAML indicator, or markdown syntax (`> quote`, `*emphasis*`,
        // `| table |`, `+ item`, `1. item`), cannot start a plain key.
        guard let first = line.first, !first.isWhitespace, !isSequenceItem(line),
              !isListItem(line), !"#[]{}?>|*!&%@`,".contains(first)
        else { return nil }
        if first == "\"" || first == "'" { return quotedKeyValue(line) }
        var searchFrom = line.startIndex
        while let colon = line[searchFrom...].firstIndex(of: ":") {
            let after = line.index(after: colon)
            if after == line.endIndex || line[after].isWhitespace {
                let key = trimmed(line[..<colon])
                guard !key.isEmpty else { return nil }
                return (String(key), String(trimmed(line[after...])))
            }
            searchFrom = after
        }
        return nil
    }

    /// `"key": value` or `'key': value`. A backslash escapes the next character
    /// in a double-quoted key and `''` is a quote in a single-quoted one, as in
    /// YAML; the key keeps those escapes as written. Nil when the quote never
    /// closes or no `: ` follows it.
    private static func quotedKeyValue(_ line: Substring) -> (key: String, value: String)? {
        guard let quote = line.first else { return nil }
        var index = line.index(after: line.startIndex)
        while index < line.endIndex {
            let character = line[index]
            if quote == "\"", character == "\\" {
                index = line.index(index, offsetBy: 2, limitedBy: line.endIndex) ?? line.endIndex
                continue
            }
            if character == quote {
                let next = line.index(after: index)
                if quote == "'", next < line.endIndex, line[next] == "'" {
                    index = line.index(after: next)
                    continue
                }
                let rest = trimmed(line[next...])
                guard rest.first == ":" else { return nil }
                let afterColon = rest.dropFirst()
                guard afterColon.isEmpty || afterColon.first?.isWhitespace == true else { return nil }
                let key = line[line.index(after: line.startIndex)..<index]
                guard !key.isEmpty else { return nil }
                return (String(key), String(trimmed(afterColon)))
            }
            index = line.index(after: index)
        }
        return nil
    }

    /// Whether `line` continues a key whose own line held `value`: an indented
    /// or blank line always does, and a column-0 `- item` does when the key's
    /// value is empty, which is YAML's compact way to give a key a list.
    private static func continues(_ value: String, with line: Substring) -> Bool {
        guard let first = line.first else { return true }
        return first.isWhitespace || (value.isEmpty && isSequenceItem(line))
    }

    /// A CommonMark fence opener or closer: up to three spaces, then ``` or ~~~.
    private static func isFence(_ line: Substring) -> Bool {
        let indent = line.prefix { $0 == " " }.count
        guard indent <= 3 else { return false }
        let rest = line.dropFirst(indent)
        return rest.hasPrefix("```") || rest.hasPrefix("~~~")
    }

    /// A markdown `+ item`, or an ordered `1. item` / `1) item` with up to nine
    /// digits, as CommonMark allows. `- item` is `isSequenceItem`, and `*` is
    /// refused as a YAML indicator.
    private static func isListItem(_ line: Substring) -> Bool {
        var rest = line
        if line.first == "+" {
            rest = line.dropFirst()
        } else {
            let digits = line.prefix { "0123456789".contains($0) }.count
            guard (1...9).contains(digits) else { return false }
            rest = line.dropFirst(digits)
            guard rest.first == "." || rest.first == ")" else { return false }
            rest = rest.dropFirst()
        }
        return rest.isEmpty || rest.first?.isWhitespace == true
    }

    private static func isSequenceItem(_ line: Substring) -> Bool {
        guard line.first == "-" else { return false }
        let rest = line.dropFirst()
        return rest.isEmpty || rest.first?.isWhitespace == true
    }

    private static func isBlank(_ line: Substring) -> Bool {
        line.allSatisfy { $0.isWhitespace }
    }

    private static func trimmed(_ text: Substring) -> Substring {
        var result = text
        while result.first?.isWhitespace == true { result.removeFirst() }
        while result.last?.isWhitespace == true { result.removeLast() }
        return result
    }

    /// The lines with leading and trailing blank lines dropped and their common
    /// indentation removed, joined with `\n`; nil when nothing is left.
    private static func dedented(_ lines: [Substring]) -> String? {
        var kept = lines[...]
        while let first = kept.first, isBlank(first) { kept.removeFirst() }
        while let last = kept.last, isBlank(last) { kept.removeLast() }
        guard !kept.isEmpty else { return nil }
        let indent = kept.filter { !isBlank($0) }
            .map { line in line.prefix { $0 == " " || $0 == "\t" }.count }
            .min() ?? 0
        return kept.map { isBlank($0) ? "" : String($0.dropFirst(indent)) }
            .joined(separator: "\n")
    }

    // MARK: - Lines

    /// The line starting at `start`, without its terminator, and the index just
    /// past the terminator. `\n`, `\r\n` and a lone `\r` each end a line, as
    /// they do for comrak. Nil only at the end of the text.
    private static func nextLine(
        in text: String, from start: String.Index
    ) -> (content: Substring, next: String.Index)? {
        guard start < text.endIndex else { return nil }
        let scalars = text.unicodeScalars
        var index = start
        while index < scalars.endIndex {
            let scalar = scalars[index]
            if scalar == "\n" || scalar == "\r" {
                var next = scalars.index(after: index)
                if scalar == "\r", next < scalars.endIndex, scalars[next] == "\n" {
                    next = scalars.index(after: next)
                }
                return (text[start..<index], next)
            }
            index = scalars.index(after: index)
        }
        return (text[start...], text.endIndex)
    }

    /// `---` or `...` when that is all the line holds apart from trailing
    /// spaces or tabs; nil for any other line.
    private static func delimiter(_ line: Substring) -> String? {
        var content = line
        while content.last == " " || content.last == "\t" { content.removeLast() }
        return content == "---" || content == "..." ? String(content) : nil
    }
}
