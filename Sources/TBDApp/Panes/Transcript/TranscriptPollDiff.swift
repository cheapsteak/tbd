import TBDShared

/// Pure change-detection for the live-transcript poll loop
/// (`TableTranscriptPaneView`).
///
/// The poll loops call `changed(prev:new:)` from a detached task so the deep
/// array compare of a long transcript never burns main-thread time proving
/// "nothing changed" on every 1.5s tick (#129 territory).
enum TranscriptPollDiff {
    /// Cheap precheck: a count mismatch or a differing last item proves the
    /// transcript changed without touching the other N-1 elements (comparing
    /// the last item can still recurse into its subagent thread, so this is
    /// bounded by one item, not strictly O(1)). Returns
    /// `nil` when the cheap signals match — that does NOT prove equality,
    /// because the JSONL parser merges late tool results into earlier
    /// `toolCall` items, so a mid-array item can mutate while the tail stays
    /// identical.
    static func cheapChangeCheck(prev: [TranscriptItem], new: [TranscriptItem]) -> Bool? {
        if prev.count != new.count { return true }
        if prev.last != new.last { return true }
        return nil
    }

    /// Full change detection: cheap precheck first, deep compare only when
    /// the precheck is inconclusive.
    static func changed(prev: [TranscriptItem], new: [TranscriptItem]) -> Bool {
        cheapChangeCheck(prev: prev, new: new) ?? (prev != new)
    }
}
