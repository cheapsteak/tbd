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
/// A block is front matter only when the very first line is `---` and a later
/// line is `---` or `...`. Without a closing line there is no front matter and
/// the source is left exactly as it was.
struct MarkdownFrontMatter: Equatable, Sendable {

    /// One top-level `key: value` line and the indented lines that continue it.
    struct Entry: Equatable, Sendable {
        let key: String
        /// The rest of the key's own line, trimmed. Empty for `key:`, and for
        /// a block scalar whose `|` or `>` indicator introduces `continuation`.
        let value: String
        /// The lines that continue the value — a nested map or list, a block
        /// scalar — with their common indentation removed. Nil when the value
        /// is the one line.
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
              isDelimiter(opening.content, closing: false)
        else { return (nil, markdown) }

        var lines: [Substring] = []
        cursor = opening.next
        while let line = nextLine(in: markdown, from: cursor) {
            if isDelimiter(line.content, closing: true) {
                let frontMatter = MarkdownFrontMatter(
                    yaml: lines.joined(separator: "\n"),
                    entries: readEntries(lines)
                )
                return (frontMatter, String(markdown[line.next...]))
            }
            lines.append(line.content)
            cursor = line.next
        }
        return (nil, markdown)
    }

    /// The header shown above the rendered body: a `<dl>` of the entries, the
    /// raw YAML in a `<pre>` when there are no readable entries, and nothing at
    /// all for an empty block. Every piece of file text in it is HTML-escaped:
    /// this markup is TBD's own and bypasses comrak's safe mode, so nothing
    /// from the file may reach it raw.
    var html: String {
        guard let entries else {
            return #"<pre class="tbd-front-matter">"# + Self.escape(yaml) + "</pre>"
        }
        guard !entries.isEmpty else { return "" }
        let rows = entries.map { entry -> String in
            let more = entry.continuation.map { "<pre>" + Self.escape($0) + "</pre>" } ?? ""
            return "<dt>" + Self.escape(entry.key) + "</dt><dd>" + Self.escape(entry.value)
                + more + "</dd>"
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
            } else if let last = groups.last, continues(last.value, with: line) {
                groups[groups.count - 1].more.append(line)
            } else if isBlank(line) {
                continue   // blank lines before the first key
            } else {
                return nil
            }
        }
        return groups.map { group in
            let more = dedented(group.more)
            let isBlockIndicator = group.value.first.map { "|>".contains($0) } == true
                && group.value.dropFirst().allSatisfy { "+-0123456789".contains($0) }
            return Entry(
                key: group.key,
                value: more != nil && isBlockIndicator ? "" : group.value,
                continuation: more
            )
        }
    }

    /// A column-0 `key: value` line, split at the first colon that is followed
    /// by whitespace or the end of the line, so a value such as
    /// `https://example.com` does not split the key.
    private static func keyValue(_ line: Substring) -> (key: String, value: String)? {
        guard let first = line.first, !first.isWhitespace, !isSequenceItem(line),
              !"#[{?".contains(first)
        else { return nil }
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

    /// Whether `line` continues a key whose own line held `value`: an indented
    /// or blank line always does, and a column-0 `- item` does when the key's
    /// value is empty, which is YAML's compact way to give a key a list.
    private static func continues(_ value: String, with line: Substring) -> Bool {
        guard let first = line.first else { return true }
        return first.isWhitespace || (value.isEmpty && isSequenceItem(line))
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

    /// `---`, or for a closing line also `...`, with nothing else on the line
    /// except trailing spaces or tabs.
    private static func isDelimiter(_ line: Substring, closing: Bool) -> Bool {
        var content = line
        while content.last == " " || content.last == "\t" { content.removeLast() }
        return content == "---" || (closing && content == "...")
    }
}
