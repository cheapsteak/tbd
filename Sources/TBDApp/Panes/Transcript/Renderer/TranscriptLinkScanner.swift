import Foundation

/// One token in transcript text that might name a file or a web page.
struct TranscriptLinkCandidate: Equatable {
    /// UTF-16 range into the scanned string — directly usable as an
    /// `NSAttributedString` range.
    let range: NSRange
    let token: String
    /// True for `http`/`https`, which open in a browser. `file://` is false:
    /// it resolves through `ClickedPathResolver` like any other path.
    let isURL: Bool
}

/// Finds path- and URL-shaped tokens in a plain string.
///
/// Pure and filesystem-free: a candidate is only *shaped* like a link. Whether
/// it names a real file is `ClickedPathResolver`'s question, asked later, so
/// the tokenization rules can be tested without touching disk.
enum TranscriptLinkScanner {
    /// The shared boundary set, plus `:` so a `:line:col` suffix stays attached
    /// (the resolver strips it before the existence check).
    ///
    /// The union is deliberately local: `:` is scanner-only, because the
    /// terminal's widener stops at it. Everything else comes from
    /// `ClickedPathResolver.pathTokenCharacters`, referenced rather than
    /// copied, so the two click surfaces cannot drift apart on where a path
    /// ends.
    private static let pathChars = ClickedPathResolver.pathTokenCharacters
        .union(CharacterSet(charactersIn: ":"))

    /// Characters that end a URL token.
    private static let urlTerminators = CharacterSet.whitespacesAndNewlines
        .union(CharacterSet(charactersIn: "<>\"'`"))

    /// Scheme prefixes pre-split into scalars.
    ///
    /// `scan` tests these prefixes once per token start, on the main thread,
    /// inside the cached compose path. Splitting a string literal into scalars
    /// at each of those tests allocated an array per call for a constant
    /// answer, so the split happens once here instead.
    private static let urlSchemeScalars: [[Unicode.Scalar]] = [
        Array("https://".unicodeScalars), Array("http://".unicodeScalars)
    ]
    private static let fileSchemeScalars: [[Unicode.Scalar]] = [
        Array("file://".unicodeScalars)
    ]

    static func scan(_ text: String) -> [TranscriptLinkCandidate] {
        if text.isEmpty { return [] }
        let scalars = Array(text.unicodeScalars)
        // UTF-16 offset of each scalar, so reported ranges survive emoji.
        var utf16Offsets = [Int](repeating: 0, count: scalars.count + 1)
        var running = 0
        for (i, s) in scalars.enumerated() {
            utf16Offsets[i] = running
            running += UTF16.width(s)
        }
        utf16Offsets[scalars.count] = running

        var out: [TranscriptLinkCandidate] = []
        var i = 0
        while i < scalars.count {
            guard isTokenStart(scalars, i) else { i += 1; continue }

            if let end = matchScheme(scalars, at: i, schemes: urlSchemeScalars) {
                appendCandidate(&out, scalars, utf16Offsets, i, end, isURL: true)
                i = end
                continue
            }
            if let end = matchScheme(scalars, at: i, schemes: fileSchemeScalars) {
                appendCandidate(&out, scalars, utf16Offsets, i, end, isURL: false)
                i = end
                continue
            }

            var end = i
            while end < scalars.count, pathChars.contains(scalars[end]) {
                // A colon extends the token only when a digit follows it, which
                // is what separates a `:line:col` suffix from grep and compiler
                // output. `Sources/A.swift:17:let x = 1` would otherwise widen
                // to `Sources/A.swift:17:let` and resolve to nothing — and that
                // paste is the shape the feature exists for.
                if scalars[end] == ":", !isASCIIDigit(scalars, end + 1) { break }
                end += 1
            }
            // Shape-test the TRIMMED extent, not the raw one. `see CLAUDE.md.`
            // at the end of a sentence widens to `CLAUDE.md.`, whose extension
            // is empty, so testing the raw token would reject a bare filename
            // for the crime of ending a sentence. `trimmedEnd` is idempotent —
            // `appendCandidate` calls it again on the same extent.
            let shapeEnd = trimmedEnd(scalars, i, end, isURL: false)
            if shapeEnd > i, looksLikeAPath(scalars, i, shapeEnd) {
                appendCandidate(&out, scalars, utf16Offsets, i, end, isURL: false)
                i = end
                continue
            }
            i = max(end, i + 1)
        }
        return out
    }

    // MARK: - Helpers

    /// A token may start at the string start, or after whitespace, opening
    /// punctuation, or one of `=,;:`.
    ///
    /// That last group carries more weight than it looks: `--file=docs/a.md`,
    /// `cat a.md,b.md` and `PATH=/usr/bin` are exactly the shapes that show up
    /// inside code blocks, and a whitespace-only rule skips every one of them.
    /// Widening is safe because the protection against re-splitting a matched
    /// URL into `//example.com/x` comes from `i = end` after a scheme match,
    /// not from this set.
    private static func isTokenStart(_ scalars: [Unicode.Scalar], _ i: Int) -> Bool {
        guard pathChars.contains(scalars[i]) else { return false }
        if i == 0 { return true }
        let prev = scalars[i - 1]
        if CharacterSet.whitespacesAndNewlines.contains(prev) { return true }
        return "([{<\"'`=,;:".unicodeScalars.contains(prev)
    }

    private static func matchScheme(
        _ scalars: [Unicode.Scalar], at i: Int, schemes: [[Unicode.Scalar]]
    ) -> Int? {
        for scheme in schemes where hasPrefix(scalars, i, scheme) {
            var end = i + scheme.count
            while end < scalars.count, !urlTerminators.contains(scalars[end]) { end += 1 }
            guard end > i + scheme.count else { return nil }
            return end
        }
        return nil
    }

    private static func hasPrefix(
        _ scalars: [Unicode.Scalar], _ i: Int, _ prefix: [Unicode.Scalar]
    ) -> Bool {
        guard i + prefix.count <= scalars.count else { return false }
        for k in 0..<prefix.count where scalars[i + k] != prefix[k] { return false }
        return true
    }

    private static func isASCIIDigit(_ scalars: [Unicode.Scalar], _ i: Int) -> Bool {
        guard i < scalars.count else { return false }
        return scalars[i] >= "0" && scalars[i] <= "9"
    }

    /// A bare word is only worth a `stat()` if it contains a `/` or ends in an
    /// extension. Without this, every ordinary word in the transcript becomes a
    /// filesystem query.
    ///
    /// A token with neither a slash nor a dot is deliberately never a
    /// candidate. That single rule is what keeps every English word out of the
    /// filesystem, and it knowingly excludes real extension-less files —
    /// `Makefile`, `LICENSE`. The trade is accepted: those are rare in
    /// transcript prose and ordinary words are not.
    private static func looksLikeAPath(
        _ scalars: [Unicode.Scalar], _ start: Int, _ end: Int
    ) -> Bool {
        let token = String(String.UnicodeScalarView(scalars[start..<end]))
        if token.contains("/") { return true }
        guard let dot = token.lastIndex(of: ".") else { return false }
        let tail = token[token.index(after: dot)...]
        if dot == token.startIndex {
            // A dotfile: `.gitignore`, `.envrc`. The remainder must be a plain
            // letter run, so `.2.3` and friends stay out. `.swiftlint.yml` does
            // not come through here — its last dot is not the first one, so it
            // takes the extension rule below.
            return !tail.isEmpty && tail.count <= 12 && tail.allSatisfy(\.isLetter)
        }
        // An extension may carry digits — `a.mp4`, `x.7z`, `main.py3`,
        // `Package.resolved` — but must contain at least one letter, which is
        // what keeps `v1.2.3` from being a candidate.
        return !tail.isEmpty
            && tail.count <= 8
            && tail.allSatisfy { $0.isLetter || $0.isNumber }
            && tail.contains(where: \.isLetter)
    }

    private static let openerForCloser: [Unicode.Scalar: Unicode.Scalar] = [
        ")": "(", "]": "[", "}": "{"
    ]

    /// Trailing sentence punctuation belongs to the prose, not the link.
    ///
    /// A closing bracket is stripped from a URL only when it is unbalanced
    /// within the token, so `https://en.wikipedia.org/wiki/Foo_(bar)` keeps its
    /// paren while `(see https://e.com/x)` does not keep one it never owned.
    /// Path tokens never reach a closing bracket — it is outside `pathChars` —
    /// so the balance check is URL-only.
    private static func trimmedEnd(
        _ scalars: [Unicode.Scalar], _ start: Int, _ end: Int, isURL: Bool
    ) -> Int {
        var e = end
        while e > start {
            let last = scalars[e - 1]
            if let opener = openerForCloser[last] {
                if isURL, isBalanced(scalars, start, e, opener: opener, closer: last) { break }
                e -= 1
                continue
            }
            // `!` and `?` are legal in a hostname, so a URL that ends a
            // sentence otherwise carries the punctuation into the host and
            // opens somewhere else entirely.
            guard ".,:;>!?\"'".unicodeScalars.contains(last) else { break }
            e -= 1
        }
        return e
    }

    private static func isBalanced(
        _ scalars: [Unicode.Scalar], _ start: Int, _ end: Int,
        opener: Unicode.Scalar, closer: Unicode.Scalar
    ) -> Bool {
        var depth = 0
        for k in start..<end {
            if scalars[k] == opener { depth += 1 }
            if scalars[k] == closer { depth -= 1 }
        }
        return depth == 0
    }

    private static func appendCandidate(
        _ out: inout [TranscriptLinkCandidate],
        _ scalars: [Unicode.Scalar],
        _ utf16Offsets: [Int],
        _ start: Int,
        _ end: Int,
        isURL: Bool
    ) {
        let trimmed = trimmedEnd(scalars, start, end, isURL: isURL)
        guard trimmed > start else { return }
        let token = String(String.UnicodeScalarView(scalars[start..<trimmed]))
        guard token.count > 1 else { return }
        let range = NSRange(
            location: utf16Offsets[start],
            length: utf16Offsets[trimmed] - utf16Offsets[start]
        )
        out.append(TranscriptLinkCandidate(range: range, token: token, isURL: isURL))
    }
}
