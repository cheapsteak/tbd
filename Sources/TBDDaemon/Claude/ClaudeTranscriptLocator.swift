import Foundation
import TBDShared

/// Chooses the transcript file for a terminal's Claude session.
enum ClaudeTranscriptLocator {
    /// `terminal.transcriptPath` when non-empty; else
    /// `<project directory>/<claudeSessionID>.jsonl` under a `projects/`
    /// root, where `ClaudeProjectDirectory.resolve(worktreePath:)` finds the
    /// project directory. Nil when the terminal has no `claudeSessionID`.
    ///
    /// The stored path is the absolute path captured by the SessionStart hook.
    /// It is immune to `/clear` and `/compact` rollovers that move the session
    /// away from the cwd-derived project directory, so it wins. The fallback
    /// serves terminals that have not received a hook event yet.
    ///
    /// With no profile root, the fallback is the host root's answer: the path
    /// under `projectsBase`'s project directory, or nil when none resolves
    /// there. It does not check that the file exists.
    ///
    /// A terminal on a model profile runs Claude with that profile's
    /// `CLAUDE_CONFIG_DIR`, so its JSONL is under the profile's `projects/`.
    /// That is usually a symlink into the host store, so a profile root whose
    /// symlink-resolved path is the host root's is the same root, and the
    /// answer is the host root's, again with no check. When the two roots
    /// really differ, the profile root is tried first. A project directory
    /// there is not enough, because a profile with no isolated config dir
    /// (Bedrock) runs Claude in the host store, and its own root can hold the
    /// worktree's project directory without this session's file. So each root
    /// must hold `<claudeSessionID>.jsonl` itself, in the order and by the
    /// test a fork's source search (`RPCRouter.locateForkSourceTranscript`)
    /// applies to the same two roots, which it also dedupes by resolved path.
    /// When neither holds the file, the answer is the host root's.
    ///
    /// - Parameters:
    ///   - projectsBase: the host `projects/` root. It is required, so the
    ///     caller's injected root always decides and the locator never looks
    ///     up the host store itself. The router passes
    ///     `RPCRouter.claudeProjectsRoot(forProfileID: nil)`, its injected
    ///     config-dir manager's root; tests pass a temporary root.
    ///   - profileProjectsBase: the `projects/` root of the terminal's model
    ///     profile, tried before `projectsBase` when it is a different
    ///     directory, or `nil` for a terminal with no profile. The router
    ///     passes `RPCRouter.claudeProjectsRoot(forProfileID:)`.
    static func filePath(
        terminal: TBDShared.Terminal,
        worktreePath: String,
        projectsBase: URL,
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
        guard let profileProjectsBase,
              resolvedPath(profileProjectsBase) != resolvedPath(projectsBase) else { return hostPath }

        let profilePath = ClaudeProjectDirectory.resolve(
            worktreePath: worktreePath, projectsBase: profileProjectsBase
        )?.appendingPathComponent(fileName).path
        for candidate in [profilePath, hostPath].compactMap({ $0 })
        where FileManager.default.fileExists(atPath: candidate) {
            return candidate
        }
        return hostPath
    }

    /// `root`'s path with its symlinks resolved, as a fork's source search
    /// compares `projects/` roots.
    private static func resolvedPath(_ root: URL) -> String {
        root.resolvingSymlinksInPath().standardizedFileURL.path
    }
}
