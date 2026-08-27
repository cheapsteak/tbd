import Foundation
import TBDShared

/// The app-side equivalents of `terminal.transcriptItemFullBody` and
/// `session.messages`. Both are one-shot bounded reads with no cadence, so they
/// need none of `TranscriptSource`'s retained state — a plain namespace of
/// static reads is the whole implementation.
///
/// The daemon's `session.messages` guards its path against `~/.claude/projects`
/// because the app supplies it over RPC. Reading here retires that guard, and
/// deliberately: both path sources — a terminal's `transcriptPath` column and a
/// `SessionSummary.filePath` record — are produced by the daemon itself, so no
/// untrusted input reaches this call.
enum TranscriptDetailReader {

    /// Matches the daemon's placeholder exactly, so the two paths are
    /// indistinguishable to the cards that render the result.
    static let unavailable = "Output no longer available."

    /// The gate both `DaemonClient` entry points consult, kept here as one
    /// function so "when does the app read the file itself" is a single
    /// assertion rather than a survey of call sites.
    ///
    /// A missing or empty path leaves the caller on the RPC — a card whose
    /// terminal row has not loaded, or whose session has no JSONL yet, has
    /// nothing to read and must not be handed an empty-file result that the
    /// daemon would have answered properly.
    static func shouldReadAppSide(enabled: Bool, path: String?) -> Bool {
        guard enabled, let path, !path.isEmpty else { return false }
        return true
    }

    /// The un-truncated body for one transcript row, plus the injection
    /// metadata `attachment` rows carry. `includeBody: false` mirrors the RPC's
    /// metadata-only fetch and leaves a potentially huge body unread.
    static func fullBody(
        path: String,
        itemID: String,
        includeBody: Bool
    ) -> TerminalTranscriptItemFullBodyResult {
        let detail = TranscriptParser.lookupDetail(filePath: path, itemID: itemID)
        return TerminalTranscriptItemFullBodyResult(
            text: includeBody ? (detail.text ?? unavailable) : "",
            attachment: detail.attachment)
    }

    /// The whole transcript for a session file — the history pane's one read.
    static func messages(path: String) -> [TranscriptItem] {
        TranscriptParser.parse(filePath: path)
    }
}
