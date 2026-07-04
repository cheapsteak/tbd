import Foundation

/// Detects cross-build skew between this app and the connected daemon.
///
/// Every worktree's `scripts/restart.sh` installs ITS build to
/// /Applications/TBD.app and restarts the ONE shared daemon, so a running app
/// can silently end up talking to a daemon built from a different worktree —
/// RPC decode mismatches and "Unknown method" errors that feel like "TBD is
/// out of sync". The daemon reports its own executable path in
/// `daemon.status`; comparing it against the builds this app could
/// legitimately be paired with makes the skew visible. Visibility only — the
/// app never kills or restarts a mismatched daemon.
enum DaemonBuildSkew {
    /// Human-readable warning when the daemon binary doesn't belong to this
    /// app's build; nil when it matches or when identity can't be established
    /// (older daemon without the field, unbundled app with no source path).
    ///
    /// Acceptable daemon locations for this app:
    /// - `appSiblingDaemonPath`: TBDDaemon next to the app executable — the
    ///   binary `startDaemonAndConnect()` itself would spawn.
    /// - `<sourceWorktreePath>/.build/debug/TBDDaemon`: the binary
    ///   `scripts/restart.sh` of the worktree that built this app launches
    ///   (the app itself runs from /Applications, not from that worktree).
    ///
    /// `resolvePath` is an injection seam so tests can exercise both branches
    /// with fabricated paths; production uses `defaultResolvePath`.
    static func warningMessage(
        daemonExecutablePath: String?,
        appSiblingDaemonPath: String?,
        sourceWorktreePath: String?,
        resolvePath: (String) -> String = defaultResolvePath
    ) -> String? {
        guard let daemonPath = daemonExecutablePath, !daemonPath.isEmpty else {
            // Older daemon that predates the field — can't tell, stay quiet.
            return nil
        }
        var candidates: [String] = []
        if let sibling = appSiblingDaemonPath, !sibling.isEmpty {
            candidates.append(sibling)
        }
        if let worktree = sourceWorktreePath, !worktree.isEmpty {
            candidates.append(worktree + "/.build/debug/TBDDaemon")
        }
        guard !candidates.isEmpty else { return nil }
        let resolvedDaemon = resolvePath(daemonPath)
        if candidates.contains(where: { resolvePath($0) == resolvedDaemon }) {
            return nil
        }
        return "Daemon is from a different build: \(daemonPath). "
            + "Run scripts/restart.sh from the worktree you're working in."
    }

    /// Resolve symlinks and standardize so equivalent spellings of the same
    /// binary compare equal (restart.sh and the daemon both report
    /// symlink-resolved absolute paths, but belt-and-suspenders).
    static func defaultResolvePath(_ path: String) -> String {
        URL(fileURLWithPath: path).resolvingSymlinksInPath().standardizedFileURL.path
    }
}
