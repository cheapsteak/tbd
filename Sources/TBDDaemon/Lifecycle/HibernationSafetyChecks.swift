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

    /// Whether a `capture-pane` snapshot of a Claude TUI shows the user has
    /// typed text into the prompt box that hasn't been submitted yet.
    ///
    /// Claude Code renders its input as a bordered box whose prompt line starts
    /// with `>`; an empty prompt shows only the placeholder. We look at the
    /// last non-empty lines for a `>` prompt marker followed by
    /// non-placeholder, non-whitespace content. This is a heuristic — the
    /// research flagged Chrome's "discarding lost my typed text" as the single
    /// biggest backlash — so anything that looks like pending input blocks
    /// hibernation.
    ///
    /// Returns `false` (no pending input → safe to hibernate) when the capture
    /// is empty or shows only an empty/placeholder prompt.
    public static func hasPendingInput(paneCapture: String) -> Bool {
        let lines = paneCapture
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { stripANSI(String($0)).trimmingCharacters(in: .whitespaces) }

        // Scan from the bottom for the prompt line (`>` or the box-drawn
        // variant). The first `>`-prefixed line from the bottom is the input.
        for line in lines.reversed() {
            guard let promptBody = promptBody(of: line) else { continue }
            // Strip both the whitespace and any trailing box-drawing gutter
            // (`… │`) so an empty prompt inside a box reads as empty.
            let cleaned = promptBody
                .trimmingCharacters(in: CharacterSet(charactersIn: "│|╭╮╰╯─ \t"))
            if cleaned.isEmpty { return false }
            // Common empty-prompt placeholders Claude shows.
            let placeholders = ["Try \"", "Ask Claude", "Type a message"]
            if placeholders.contains(where: { cleaned.hasPrefix($0) }) { return false }
            return true
        }
        return false
    }

    /// If `line` is a Claude prompt line (`>` possibly inside box-drawing
    /// characters), return the text after the `>`; otherwise nil.
    private static func promptBody(of line: String) -> String? {
        // Strip a leading box-drawing / vertical-bar gutter, then require `>`.
        var s = Substring(line)
        while let first = s.first, "│|╭╮╰╯─ ".contains(first) { s = s.dropFirst() }
        guard let gt = s.first, gt == ">" else { return nil }
        return String(s.dropFirst())
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
