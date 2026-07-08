import Foundation

/// Resolves candidate paths for the TBDDaemon binary, supporting both app-sibling
/// and source-worktree locations. Used by both the app's auto-spawn and the
/// daemon client's fallback startup.
enum DaemonCandidateFinder {
    /// Build a list of candidate daemon binary paths to search in order.
    ///
    /// Candidates include:
    /// 1. The app executable's sibling directory (the .app bundle's MacOS/)
    /// 2. The source worktree's `.build/debug/TBDDaemon` (if known)
    ///
    /// Paths are returned as absolute strings for immediate filesystem checks;
    /// they are NOT yet resolved for symlinks. The caller is responsible for
    /// verifying executability via `FileManager.isExecutableFile(atPath:)`.
    ///
    /// - Parameters:
    ///   - appExecutablePath: The path to the running app executable
    ///     (e.g., `"/Applications/TBD.app/Contents/MacOS/TBDApp"`).
    ///     Nil inputs return only worktree candidates.
    ///   - sourceWorktreePath: The absolute path of the worktree that built
    ///     this app, e.g. `"/Users/me/tbd/worktrees/mywork"`.
    ///     Nil inputs skip worktree-derived candidates.
    ///
    /// - Returns: An array of candidate daemon paths, in search order. Empty
    ///   if both inputs are nil.
    static func daemonCandidatePaths(
        appExecutablePath: String?,
        sourceWorktreePath: String?
    ) -> [String] {
        var candidates: [String] = []

        // First candidate: daemon next to the app executable
        if let execPath = appExecutablePath {
            let siblingPath = (execPath as NSString).deletingLastPathComponent + "/TBDDaemon"
            candidates.append(siblingPath)
        }

        // Second candidate: daemon in the source worktree's build directory
        if let worktreePath = sourceWorktreePath, !worktreePath.isEmpty {
            let worktreeDaemonPath = worktreePath + "/.build/debug/TBDDaemon"
            candidates.append(worktreeDaemonPath)
        }

        return candidates
    }
}
