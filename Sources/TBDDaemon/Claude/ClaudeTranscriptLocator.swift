import Foundation
import TBDShared

/// Chooses the transcript file for a terminal's Claude session.
enum ClaudeTranscriptLocator {
    /// `terminal.transcriptPath` when non-empty; else
    /// `<ClaudeProjectDirectory.resolve(worktreePath:)>/<claudeSessionID>.jsonl`;
    /// nil when the terminal has no `claudeSessionID` or the project directory
    /// cannot be resolved.
    ///
    /// The stored path is the absolute path captured by the SessionStart hook.
    /// It is immune to `/clear` and `/compact` rollovers that move the session
    /// away from the cwd-derived project directory, so it wins. The fallback
    /// serves terminals that have not received a hook event yet.
    ///
    /// - Parameter projectsBase: the `projects/` root to search, or `nil` for
    ///   the host Claude store's. Tests pass a temporary root.
    static func filePath(
        terminal: TBDShared.Terminal,
        worktreePath: String,
        projectsBase: URL? = nil
    ) -> String? {
        guard let sessionID = terminal.claudeSessionID else { return nil }
        if let storedPath = terminal.transcriptPath, !storedPath.isEmpty {
            return storedPath
        }
        guard let projectDir = ClaudeProjectDirectory.resolve(
            worktreePath: worktreePath, projectsBase: projectsBase
        ) else { return nil }
        return projectDir.appendingPathComponent("\(sessionID).jsonl").path
    }
}
