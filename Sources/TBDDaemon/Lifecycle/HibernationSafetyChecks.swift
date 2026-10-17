import Foundation

/// Pure, unit-testable helpers for the two hibernation safety rails that
/// depend on live pane / disk state rather than the DB row: typed-but-unsent
/// input in the Claude prompt, and transcript-tail parseability.
///
/// Both are conservative: when the signal is ambiguous they return the
/// hibernation-blocking answer, because the cost of a wrong hibernate (eaten
/// keystrokes, an unresumable session) outweighs the cost of skipping one
/// idle terminal this sweep.
public enum HibernationSafetyChecks {

    // MARK: - Typed-but-unsent input

    /// The glyphs Claude Code draws at the start of its composer's prompt line:
    /// `>` in the bordered box of older releases, `❯` between the horizontal
    /// rules of current ones, and `!` in shell mode. A release that draws a new
    /// glyph is one entry here. A glyph this set does not know reads as no
    /// composer at all, which is the unsafe direction, so keep it complete.
    static let composerPromptGlyphs: Set<Character> = [">", "❯", "!"]

    /// Whether a `capture-pane` snapshot of a Claude TUI shows the user has
    /// typed text into the prompt box that hasn't been submitted yet.
    ///
    /// The composer's prompt line starts with one of `composerPromptGlyphs`,
    /// at column 0 or just inside a `│` box gutter, and a multi-line draft
    /// continues on the lines under it down to the composer's bottom edge (a
    /// line of box-drawing characters). We take the last prompt line on screen
    /// as the composer and read it with its continuation lines: any content
    /// that is not a known placeholder is pending input. This is a heuristic —
    /// the research flagged Chrome's "discarding lost my typed text" as the
    /// single biggest backlash — so anything that looks like pending input
    /// blocks hibernation. A grayed prompt suggestion reads as typed text here:
    /// escapes are stripped before the scan, and a holder screen carries none,
    /// so dimness never separates the two.
    ///
    /// Returns `false` (no pending input → safe to hibernate) when the capture
    /// is empty or shows only an empty/placeholder prompt.
    public static func hasPendingInput(paneCapture: String) -> Bool {
        let lines = paneCapture
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { stripANSI(String($0)) }

        // Scan from the bottom for the prompt line. The first prompt line from
        // the bottom is the composer.
        for index in lines.indices.reversed() {
            guard let promptBody = promptBody(of: lines[index]) else { continue }
            // A draft whose first line is blank still has its text on the
            // continuation lines, so read down to the composer's bottom edge.
            let continuation = lines[(index + 1)...].prefix { !isComposerEdge($0) }
            let draft = ([promptBody] + continuation).map {
                $0.trimmingCharacters(in: composerGutter)
            }
            guard draft.contains(where: { !$0.isEmpty }) else { return false }
            // Common empty-prompt placeholders Claude shows.
            let placeholders = ["Try \"", "Ask Claude", "Type a message"]
            let onlyPromptLine = draft.dropFirst().allSatisfy(\.isEmpty)
            if onlyPromptLine, placeholders.contains(where: { draft[0].hasPrefix($0) }) {
                return false
            }
            return true
        }
        return false
    }

    /// Whitespace (including the no-break space Claude Code draws after its
    /// prompt glyph) and the box-drawing gutter around a composer line, so an
    /// empty prompt inside a box reads as empty.
    private static let composerGutter = CharacterSet.whitespaces
        .union(CharacterSet(charactersIn: "│|╭╮╰╯─"))

    /// If `line` is a Claude prompt line (a prompt glyph at column 0, or just
    /// inside a `│` box gutter), return the text after the glyph; otherwise nil.
    ///
    /// Column 0 is load-bearing: the status lines under the composer are
    /// indented, and shell mode's reads `  ! for shell mode`.
    private static func promptBody(of line: String) -> String? {
        var s = Substring(line)
        if let first = s.first, "│|".contains(first) {
            s = s.dropFirst().drop(while: { $0.isWhitespace })
        }
        guard let glyph = s.first, composerPromptGlyphs.contains(glyph) else { return nil }
        return String(s.dropFirst())
    }

    /// Whether `line` is the composer's bottom edge: a line drawn only in
    /// box-drawing characters, either a bare rule or a box's `╰──╯`.
    private static func isComposerEdge(_ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        return !trimmed.isEmpty && trimmed.allSatisfy { "─╭╮╰╯".contains($0) }
    }

    private static func stripANSI(_ s: String) -> String {
        // Remove CSI escape sequences (ESC [ ... final-byte).
        var out = ""
        var iterator = s.unicodeScalars.makeIterator()
        var pending: Unicode.Scalar? = iterator.next()
        while let scalar = pending {
            if scalar == "\u{1B}" {
                // Skip until a letter (final byte of CSI) or end.
                var next = iterator.next()
                if next == "[" { next = iterator.next() }
                while let c = next, !("@" ... "~").contains(c) {
                    next = iterator.next()
                }
                pending = iterator.next()
            } else {
                out.unicodeScalars.append(scalar)
                pending = iterator.next()
            }
        }
        return out
    }

    // MARK: - Transcript tail validity

    /// Whether the last non-empty line of a transcript JSONL body is a complete,
    /// parseable JSON object. Killing Claude mid-write can leave a truncated
    /// final line that makes `--resume` fail (anthropics/claude-code#18880); we
    /// only hibernate when the tail is clean.
    ///
    /// An empty transcript is considered valid (nothing to corrupt — a fresh
    /// resume will simply find no prior turns). Callers that require a
    /// non-empty session should check separately.
    public static func isTranscriptTailValid(jsonlBody: String) -> Bool {
        let lastLine = jsonlBody
            .split(separator: "\n", omittingEmptySubsequences: true)
            .last
        guard let lastLine else { return true }  // empty file: nothing to corrupt
        guard let data = String(lastLine).data(using: .utf8) else { return false }
        return (try? JSONSerialization.jsonObject(with: data)) != nil
    }
}
