import Foundation
import TBDShared

/// Chooses the transcript file for a terminal's Claude session.
enum ClaudeTranscriptLocator {
    /// `terminal.transcriptPath` when non-empty; else
    /// `<project directory>/<claudeSessionID>.jsonl`, where the project
    /// directory is the one `ClaudeProjectDirectory.resolve(worktreePath:)`
    /// finds under the profile's `projects/` root, or failing that under
    /// `projectsBase`; nil when the terminal has no `claudeSessionID` or no
    /// project directory resolves under either root.
    ///
    /// The stored path is the absolute path captured by the SessionStart hook.
    /// It is immune to `/clear` and `/compact` rollovers that move the session
    /// away from the cwd-derived project directory, so it wins. The fallback
    /// serves terminals that have not received a hook event yet.
    ///
    /// A terminal on a model profile runs Claude with that profile's
    /// `CLAUDE_CONFIG_DIR`, so its JSONL is under the profile's `projects/`,
    /// and that root is searched first. It is only a first try, because a
    /// profile with no isolated config dir (Bedrock) runs Claude in the host
    /// store and has no project directory under its own root; the search then
    /// falls through to `projectsBase`, in the order a fork's source search
    /// (`RPCRouter.locateForkSourceTranscript`) tries the same two roots.
    ///
    /// - Parameters:
    ///   - projectsBase: the `projects/` root to search, or `nil` for the host
    ///     Claude store's. Tests pass a temporary root.
    ///   - profileProjectsBase: the `projects/` root of the terminal's model
    ///     profile, tried before `projectsBase`, or `nil` for a terminal with
    ///     no profile. The router passes
    ///     `RPCRouter.claudeProjectsRoot(forProfileID:)`.
    static func filePath(
        terminal: TBDShared.Terminal,
        worktreePath: String,
        projectsBase: URL? = nil,
        profileProjectsBase: URL? = nil
    ) -> String? {
        guard let sessionID = terminal.claudeSessionID else { return nil }
        if let storedPath = terminal.transcriptPath, !storedPath.isEmpty {
            return storedPath
        }
        let profileProjectDir = profileProjectsBase.flatMap {
            ClaudeProjectDirectory.resolve(worktreePath: worktreePath, projectsBase: $0)
        }
        guard let projectDir = profileProjectDir ?? ClaudeProjectDirectory.resolve(
            worktreePath: worktreePath, projectsBase: projectsBase
        ) else { return nil }
        return projectDir.appendingPathComponent("\(sessionID).jsonl").path
    }
}
