import Foundation

/// Pure, unit-testable helpers for the hibernation safety rail that depends on
/// disk state rather than the DB row: transcript-tail parseability.
///
/// Conservative: when the signal is ambiguous it returns the
/// hibernation-blocking answer, because the cost of a wrong hibernate (an
/// unresumable session) outweighs the cost of skipping one idle terminal this
/// sweep.
///
/// Nothing here reads the terminal's screen. The only guard a park has for
/// text typed into the composer and not sent is the session mod, which saves
/// it; see `ComposerDraftParkGate`.
public enum HibernationSafetyChecks {

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
