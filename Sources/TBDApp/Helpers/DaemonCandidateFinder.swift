import Foundation

/// Resolves candidate paths for the TBDDaemon binary, supporting both app-sibling
/// and source-worktree locations. Used by both the app's auto-spawn and the
/// daemon client's fallback startup.
enum DaemonCandidateFinder {
    /// Build a list of candidate daemon binary paths to search in order.
    ///
    /// Candidates include:
    /// 1. The app executable's sibling directory (the .app bundle's MacOS/)
    /// 2. The source worktree's `.build/<config>/TBDDaemon` (if known), trying
    ///    THIS app's own build configuration first and the other second.
    ///
    /// The configuration order matters. This list previously named only
    /// `debug`, so a release app that auto-spawned its daemon — which is what
    /// happens after a reboot, when the app launches with no daemon running —
    /// silently paired a release app with a DEBUG daemon. Preferring the
    /// matching configuration keeps a `--release` install release end-to-end,
    /// while the fallback means a developer who has only ever built one
    /// configuration still gets a daemon rather than an error.
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

        // Next candidates: the source worktree's build directories, this app's
        // own configuration first (see the note above).
        if let worktreePath = sourceWorktreePath, !worktreePath.isEmpty {
            for config in buildConfigurationSearchOrder {
                candidates.append(worktreePath + "/.build/\(config)/TBDDaemon")
            }
        }

        return candidates
    }

    /// Build configurations to search, matching this app's own first.
    ///
    /// `#if DEBUG` is the only thing the running app knows about how it was
    /// compiled; SwiftPM sets it for `-c debug` and not for `-c release`.
    /// Exposed (rather than inlined) so the ordering is assertable in tests,
    /// which can only observe the configuration they themselves run under.
    static var buildConfigurationSearchOrder: [String] {
        #if DEBUG
        ["debug", "release"]
        #else
        ["release", "debug"]
        #endif
    }
}
