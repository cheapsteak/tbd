// Sources/TBDApp/Panes/Transcript/LocalFileLinker.swift
import Foundation

/// Pure helper that scans a markdown string for bare absolute POSIX paths
/// (e.g. `/Users/...`, `/private/tmp/...`) and rewrites them as markdown
/// links pointing at a custom `tbd-file:` URL scheme. The overlay view
/// installs an `OpenURLAction` that intercepts that scheme and pushes a
/// file frame onto the overlay coordinator.
///
/// Inline code spans, fenced code blocks, and existing markdown links are
/// left untouched. `fileExists` lets callers stub the filesystem for tests
/// and avoids false-positive linkification of `/foo/bar`-shaped strings
/// that don't refer to a real file.
enum LocalFileLinker {
    /// Linkifies bare absolute paths in `text`. The default `fileExists`
    /// queries `FileManager.default`.
    static func linkify(
        _ text: String,
        fileExists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }
    ) -> String {
        if text.isEmpty { return text }

        var result = ""
        result.reserveCapacity(text.count)

        // Tokenize into runs that should be passed through verbatim (fenced
        // blocks, inline code, existing links) and runs that are eligible
        // for path linkification.
        for segment in protectSegments(in: text) {
            switch segment {
            case .verbatim(let s):
                result.append(s)
            case .eligible(let s):
                result.append(linkifyEligible(s, fileExists: fileExists))
            }
        }
        return result
    }

    // MARK: - Segmentation

    private enum Segment {
        case verbatim(String)
        case eligible(String)
    }

    /// Splits `text` so that fenced code blocks, inline code spans, and
    /// existing markdown links are emitted as `.verbatim`; everything else
    /// is `.eligible`. Linear scan, no regex backtracking.
    private static func protectSegments(in text: String) -> [Segment] {
        var segments: [Segment] = []
        var eligibleBuffer = ""
        let chars = Array(text)
        var i = 0

        func flushEligible() {
            if !eligibleBuffer.isEmpty {
                segments.append(.eligible(eligibleBuffer))
                eligibleBuffer.removeAll(keepingCapacity: true)
            }
        }

        while i < chars.count {
            // Fenced code block: ``` at start of line, consume through the
            // matching ``` on its own line (or end of input).
            if isAtLineStart(chars, i), startsWith(chars, i, "```") {
                flushEligible()
                let start = i
                i += 3
                // Consume to end of opening fence line.
                while i < chars.count && chars[i] != "\n" { i += 1 }
                if i < chars.count { i += 1 } // newline
                // Consume body until closing fence on its own line.
                while i < chars.count {
                    if isAtLineStart(chars, i), startsWith(chars, i, "```") {
                        i += 3
                        while i < chars.count && chars[i] != "\n" { i += 1 }
                        if i < chars.count { i += 1 }
                        break
                    }
                    i += 1
                }
                segments.append(.verbatim(String(chars[start..<i])))
                continue
            }

            // Inline code: a backtick run; consume until matching run.
            if chars[i] == "`" {
                let runLen = backtickRun(chars, i)
                let start = i
                i += runLen
                while i < chars.count {
                    if chars[i] == "`" {
                        let close = backtickRun(chars, i)
                        if close == runLen {
                            i += close
                            break
                        }
                        i += close
                        continue
                    }
                    i += 1
                }
                flushEligible()
                segments.append(.verbatim(String(chars[start..<i])))
                continue
            }

            // Existing markdown link `[text](url)` — consume the whole thing.
            if chars[i] == "[" {
                if let end = matchMarkdownLink(chars, i) {
                    flushEligible()
                    segments.append(.verbatim(String(chars[i..<end])))
                    i = end
                    continue
                }
            }

            eligibleBuffer.append(chars[i])
            i += 1
        }
        flushEligible()
        return segments
    }

    private static func isAtLineStart(_ chars: [Character], _ i: Int) -> Bool {
        i == 0 || chars[i - 1] == "\n"
    }

    private static func startsWith(_ chars: [Character], _ i: Int, _ s: String) -> Bool {
        let sChars = Array(s)
        if i + sChars.count > chars.count { return false }
        for k in 0..<sChars.count where chars[i + k] != sChars[k] { return false }
        return true
    }

    private static func backtickRun(_ chars: [Character], _ i: Int) -> Int {
        var n = 0
        while i + n < chars.count && chars[i + n] == "`" { n += 1 }
        return n
    }

    /// Returns the index *after* `](url)` if `chars[i...]` starts with a
    /// well-formed inline markdown link; nil otherwise.
    private static func matchMarkdownLink(_ chars: [Character], _ i: Int) -> Int? {
        guard i < chars.count, chars[i] == "[" else { return nil }
        var j = i + 1
        // Bracket body: forbid line breaks; allow nested brackets one deep.
        var depth = 1
        while j < chars.count {
            let c = chars[j]
            if c == "\n" { return nil }
            if c == "[" { depth += 1 }
            if c == "]" {
                depth -= 1
                if depth == 0 { j += 1; break }
            }
            j += 1
        }
        guard depth == 0, j < chars.count, chars[j] == "(" else { return nil }
        j += 1
        // URL body: stop at ')' or newline.
        while j < chars.count, chars[j] != ")" {
            if chars[j] == "\n" { return nil }
            j += 1
        }
        guard j < chars.count, chars[j] == ")" else { return nil }
        return j + 1
    }

    // MARK: - Path linkification within eligible text

    /// Path token chars: alphanumerics, `_`, `-`, `.`, `+`, `/`. Stops at
    /// whitespace, quotes, parens, brackets, angle brackets. Trailing
    /// punctuation (`. , : ; )`) is stripped to keep it outside the link.
    private static func linkifyEligible(
        _ text: String,
        fileExists: (String) -> Bool
    ) -> String {
        let chars = Array(text)
        var out = ""
        out.reserveCapacity(text.count)
        var i = 0
        while i < chars.count {
            if chars[i] == "/", isPathStart(chars, i) {
                // Collect strict path chars (no spaces).
                var j = i + 1
                while j < chars.count, isPathChar(chars[j]) { j += 1 }

                // Try strict candidate first (trim trailing punctuation).
                var strictEnd = j
                while strictEnd > i + 1,
                      isTrailingPunctuation(chars[strictEnd - 1]) {
                    strictEnd -= 1
                }
                let strictCandidate = String(chars[i..<strictEnd])
                if strictCandidate.count > 1, fileExists(strictCandidate) {
                    let encoded = strictCandidate
                        .addingPercentEncoding(withAllowedCharacters: .urlPathAllowed)
                        ?? strictCandidate
                    out.append("[\(strictCandidate)](tbd-file:\(encoded))")
                    i = strictEnd
                    continue
                }

                // Strict candidate not found; try extending through spaces to
                // handle paths with embedded spaces (common on macOS). Extend
                // up to the next hard boundary (newline, quote, angle bracket).
                var extEnd = j
                while extEnd < chars.count, !isHardBoundary(chars[extEnd]) {
                    let c = chars[extEnd]
                    if c.isWhitespace {
                        // Peek ahead: if the next non-space chars look like a
                        // continuing path component, consume the space and keep
                        // going; otherwise stop.
                        var peek = extEnd + 1
                        while peek < chars.count && chars[peek] == " " { peek += 1 }
                        if peek < chars.count && isPathChar(chars[peek]) {
                            extEnd = peek
                            while extEnd < chars.count && isPathChar(chars[extEnd]) { extEnd += 1 }
                            continue
                        } else {
                            break
                        }
                    }
                    extEnd += 1
                }

                // For the extended candidate, try progressively shorter
                // substrings (by trimming trailing words) until fileExists.
                if extEnd > j {
                    var candidate: String? = nil
                    var endTry = extEnd
                    while endTry > j {
                        var trimEnd = endTry
                        while trimEnd > i + 1, isTrailingPunctuation(chars[trimEnd - 1]) {
                            trimEnd -= 1
                        }
                        let s = String(chars[i..<trimEnd])
                        if s.count > 1, fileExists(s) {
                            candidate = s
                            endTry = trimEnd
                            break
                        }
                        // Back off to just before the last space.
                        endTry -= 1
                        while endTry > j && chars[endTry - 1] != " " { endTry -= 1 }
                        if endTry <= j { break }
                        endTry -= 1 // skip the space
                    }
                    if let found = candidate {
                        let encoded = found
                            .addingPercentEncoding(withAllowedCharacters: .urlPathAllowed)
                            ?? found
                        out.append("[\(found)](tbd-file:\(encoded))")
                        i = endTry
                        continue
                    }
                }

                out.append(contentsOf: chars[i..<j])
                i = j
                continue
            }
            out.append(chars[i])
            i += 1
        }
        return out
    }

    private static func isHardBoundary(_ c: Character) -> Bool {
        c == "\n" || c == "\"" || c == "'" || c == "<" || c == ">" || c == "[" || c == "]"
    }

    /// `/` is a path start if it is at the beginning of the eligible run,
    /// preceded by whitespace, or by a non-path "boundary" punctuation.
    /// Rejects `//` and `://` (URL-shaped).
    private static func isPathStart(_ chars: [Character], _ i: Int) -> Bool {
        if i + 1 < chars.count, chars[i + 1] == "/" { return false } // "//..."
        if i > 0, chars[i - 1] == ":" { return false }              // "scheme:/..."
        if i == 0 { return true }
        let prev = chars[i - 1]
        if prev.isWhitespace { return true }
        // Allow when preceded by typical sentence punctuation.
        return "(\"'<[,;".contains(prev) || prev == "\n"
    }

    private static func isPathChar(_ c: Character) -> Bool {
        if c.isLetter || c.isNumber { return true }
        return "._-+/".contains(c)
    }

    private static func isTrailingPunctuation(_ c: Character) -> Bool {
        ".,:;)".contains(c)
    }
}
