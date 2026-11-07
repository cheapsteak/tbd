import Foundation
import TBDShared

/// Chooses the transcript file for a terminal's Claude session.
enum ClaudeTranscriptLocator {
    /// `terminal.transcriptPath` when non-empty; else
    /// `<project directory>/<claudeSessionID>.jsonl` under the first root,
    /// the profile's `projects/` and then `projectsBase`, where
    /// `ClaudeProjectDirectory.resolve(worktreePath:)` finds the project
    /// directory and that file exists. When no root holds the file, the
    /// host-root lookup decides as if no profile root were given: the path
    /// under `projectsBase`'s project directory, or nil when none resolves
    /// there. Nil, too, when the terminal has no `claudeSessionID`.
    ///
    /// The stored path is the absolute path captured by the SessionStart hook.
    /// It is immune to `/clear` and `/compact` rollovers that move the session
    /// away from the cwd-derived project directory, so it wins. The fallback
    /// serves terminals that have not received a hook event yet.
    ///
    /// A terminal on a model profile runs Claude with that profile's
    /// `CLAUDE_CONFIG_DIR`, so its JSONL is under the profile's `projects/`,
    /// and that root is tried first. A project directory there is not enough,
    /// because a profile with no isolated config dir (Bedrock) runs Claude in
    /// the host store, and its own root can hold the worktree's project
    /// directory without this session's file. So each root must hold
    /// `<claudeSessionID>.jsonl` itself, in the order and by the test a fork's
    /// source search (`RPCRouter.locateForkSourceTranscript`) applies to the
    /// same two roots.
    ///
    /// - Parameters:
    ///   - projectsBase: the host `projects/` root, or `nil` for the host
    ///     Claude store's as `ClaudeProjectDirectory.resolve` finds it. The
    ///     router passes `RPCRouter.claudeProjectsRoot(forProfileID: nil)`, so
    ///     its injected config-dir manager decides; tests pass a temporary
    ///     root.
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
        let fileName = "\(sessionID).jsonl"
        let hostPath = ClaudeProjectDirectory.resolve(
            worktreePath: worktreePath, projectsBase: projectsBase
        )?.appendingPathComponent(fileName).path
        let profilePath = profileProjectsBase.flatMap {
            ClaudeProjectDirectory.resolve(worktreePath: worktreePath, projectsBase: $0)
        }?.appendingPathComponent(fileName).path
        for candidate in [profilePath, hostPath].compactMap({ $0 })
        where FileManager.default.fileExists(atPath: candidate) {
            return candidate
        }
        return hostPath
    }
}
