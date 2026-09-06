import Foundation

/// Claude Code's `SessionEnd` hook `reason` field, read for one question: is the
/// PROCESS going away?
///
/// A `/clear` fires `SessionEnd` and then `SessionStart` inside one live process
/// — one conversation ends, another begins, and the pty is untouched. Parking on
/// that would refuse every subsequent send to a healthy session, which is worse
/// than the bug this exists to fix.
///
/// **A whitelist of leaving reasons, not a blacklist of staying ones.** An
/// unrecognized reason from a newer Claude Code is an admission of ignorance, and
/// ignorance must not park: the foreground-process rail in the send path still
/// catches a genuinely departed process, so a missed stamp degrades to the
/// pre-existing second check rather than to the pre-existing bug. TBD never
/// branches on hook *message* text (that would be screen-scraping with an extra
/// hop); `reason` is a closed machine vocabulary and is exactly what may be
/// matched.
public enum SessionEndReason {
    /// The reasons that mean the process is leaving. Enumerated exhaustively so
    /// adding one is a visible edit rather than a silent reclassification.
    static let leavingReasons: Set<String> = ["logout", "exit", "prompt_input_exit", "other"]

    /// Whether a `SessionEnd` with this `reason` should park the terminal.
    public static func parksTheTerminal(_ raw: String?) -> Bool {
        guard let raw else { return false }
        let normalized = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return leavingReasons.contains(normalized)
    }
}
