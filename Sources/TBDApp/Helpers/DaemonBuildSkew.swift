import Foundation
import TBDShared

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
    /// SwiftPM build configurations `scripts/restart.sh` can launch a daemon
    /// from. A release-built daemon from this app's own worktree is a
    /// deliberate `--release` restart, not cross-build skew.
    static let buildConfigurations = ["debug", "release"]

    /// Human-readable warning when the daemon binary doesn't belong to this
    /// app's build; nil when it matches or when identity can't be established
    /// (older daemon without the field, unbundled app with no source path).
    ///
    /// Acceptable daemon locations for this app:
    /// - `appSiblingDaemonPath`: TBDDaemon next to the app executable — the
    ///   binary `startDaemonAndConnect()` itself would spawn.
    /// - `<sourceWorktreePath>/.build/<config>/TBDDaemon` for each build
    ///   configuration `scripts/restart.sh` can launch — `debug` by default,
    ///   `release` under its `--release` flag. Both belong to the worktree
    ///   that built this app (the app itself runs from /Applications, not
    ///   from that worktree), so neither is skew.
    ///
    /// Before any path is compared, the two build stamps are: when both name
    /// the same clean commit from the same source worktree, it is the same
    /// build wherever the daemon binary sits (see `isSameStampedBuild`).
    ///
    /// `resolvePath` is an injection seam so tests can exercise both branches
    /// with fabricated paths; production uses `defaultResolvePath`.
    static func warningMessage(
        daemonExecutablePath: String?,
        appSiblingDaemonPath: String?,
        sourceWorktreePath: String?,
        appIdentity: BuildIdentity? = nil,
        daemonIdentity: BuildIdentity? = nil,
        resolvePath: (String) -> String = defaultResolvePath
    ) -> String? {
        guard let daemonPath = daemonExecutablePath, !daemonPath.isEmpty else {
            // Older daemon that predates the field — can't tell, stay quiet.
            return nil
        }
        if isSameStampedBuild(app: appIdentity, daemon: daemonIdentity, resolvePath: resolvePath) {
            return nil
        }
        var candidates: [String] = []
        if let sibling = appSiblingDaemonPath, !sibling.isEmpty {
            candidates.append(sibling)
        }
        if let worktree = sourceWorktreePath, !worktree.isEmpty {
            for config in buildConfigurations {
                candidates.append(worktree + "/.build/\(config)/TBDDaemon")
            }
        }
        guard !candidates.isEmpty else { return nil }
        let resolvedDaemon = resolvePath(daemonPath)
        if candidates.contains(where: { resolvePath($0) == resolvedDaemon }) {
            return nil
        }
        return "Daemon is from a different build: \(daemonPath). "
            + "Run scripts/restart.sh from the worktree you're working in."
    }

    /// Whether the app and the daemon are provably one build: both identities
    /// read from a build stamp (not a possibly-stale worktree HEAD), neither
    /// dirty, the same commit, and the same source worktree.
    ///
    /// The path comparison alone misfires while `scripts/update.sh` installs a
    /// release download. The daemon runs from `<clone>/.build/release`, a link
    /// into `~/tbd/updates/prebuilt/<commit>/`, and the update hands that link
    /// back to SwiftPM while it compiles `TBDApp` (removed, then pointed at
    /// SwiftPM's own directory) for as long as the compile waits for the
    /// shared build slot. In that window the expected path no longer resolves
    /// to the running daemon, so a matched pair read as skew. The stamps do not
    /// move with the link. A different worktree, a different commit, or a
    /// dirty tree still falls through to the path check.
    static func isSameStampedBuild(
        app: BuildIdentity?,
        daemon: BuildIdentity?,
        resolvePath: (String) -> String = defaultResolvePath
    ) -> Bool {
        guard let app, let daemon,
              app.origin == .stamp, daemon.origin == .stamp,
              !app.dirty, !daemon.dirty,
              app.commit == daemon.commit,
              let appWorktree = app.sourceWorktree, !appWorktree.isEmpty,
              let daemonWorktree = daemon.sourceWorktree, !daemonWorktree.isEmpty
        else { return false }
        return resolvePath(appWorktree) == resolvePath(daemonWorktree)
    }

    /// Resolve symlinks and standardize so equivalent spellings of the same
    /// binary compare equal (restart.sh and the daemon both report
    /// symlink-resolved absolute paths, but belt-and-suspenders).
    static func defaultResolvePath(_ path: String) -> String {
        URL(fileURLWithPath: path).resolvingSymlinksInPath().standardizedFileURL.path
    }
}
