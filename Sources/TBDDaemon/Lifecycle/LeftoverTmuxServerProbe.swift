import Darwin
import Foundation
import TBDShared

/// What a socket probe established about the tmux server a live tmux row
/// names.
enum LeftoverTmuxServerState: Sendable, Equatable {
    /// Something may still be serving the socket. Every answer that is not
    /// positive evidence of absence lands here, a successful connect included.
    case running
    /// Nothing is bound at the socket path, or nothing accepts on it. The
    /// server is gone, and so is every session it carried.
    case absent
}

/// The tmux server a live tmux row names, and what the probe said about it.
struct LeftoverTmuxServerSighting: Sendable, Equatable {
    /// The server's name, as `tmux -L` takes it.
    let server: String
    let state: LeftoverTmuxServerState
}

/// Whether the tmux server behind a live tmux row is still running, read off
/// its socket without running the tmux binary.
///
/// TBD no longer drives tmux. It cannot show, send to, park or end a tmux
/// session. A tmux server started by an earlier build can outlive `tbd update`
/// until the Mac restarts, though, so a row can still be live with its agent
/// running there. This probe tells the two cases apart:
///
/// - **Absent** — the row is parked, keeping its session id, and from there
///   the ordinary path moves it: a wake refuses and names
///   `tbd terminal migrate`, the migration rewrites the parked row, and a wake
///   opens it on the pty holder.
/// - **Running** — the row stays live. The app shows a notice in place of the
///   terminal (`LeftoverTmuxSession.notice(server:)`), and the migration and
///   every other request that would have to reach the session refuse with
///   `LeftoverTmuxSession.stillRunningRefusal(terminalID:server:)`.
///
/// It runs wherever reconcile does: at daemon startup, on demand (`tbd
/// cleanup`, a repo add), and every hour in `Daemon.performOrphanMaintenance`,
/// whose `reconcileScratchTerminals` pass probes the servers of scratch
/// worktrees' live tmux rows while the GC switch is on. It also runs when a
/// person asks to check again (`terminal.recreateWindow`) or to migrate the
/// row.
///
/// **This probe is a transition measure; on 2027-01-15 it is replaced by
/// parking on sight**, which parks every live tmux row without asking its
/// socket anything. By then no tmux server started before the pty holder
/// became the only spawn path (2026-11-14) should still be running, because a
/// restart ends one. Until then a row is parked only on positive evidence that
/// its server is gone, because parking a row whose agent still runs lets a
/// later wake start a second agent on the same session id. See
/// `docs/specs/2026-10-11-holder-transport-migration-design.md`, "A live row
/// whose tmux server outlived the update".
struct LeftoverTmuxServerProbe: Sendable {
    /// The state of the tmux server with this name (`tmux -L <name>`).
    let state: @Sendable (_ server: String) async -> LeftoverTmuxServerState

    /// How long the probe's connection may wait for a read. It reads nothing:
    /// an `AF_UNIX` connect on Darwin is answered or refused outright and never
    /// queues behind a listener, so the connect itself is the whole probe.
    static let receiveTimeout: Duration = .seconds(2)

    /// The directory tmux falls back to when `TMUX_TMPDIR` names nothing it
    /// can use: `/tmp`, which tmux resolves to its real path.
    static let defaultTemporaryDirectory = "/private/tmp"

    /// Every socket a tmux server named `server` may be listening on: the
    /// one under `TMUX_TMPDIR`, when that value resolves, and always the one
    /// under the fallback root, `<root>/tmux-<uid>/<server>`. Duplicates are
    /// dropped, so a `TMUX_TMPDIR` that resolves to the fallback root gives
    /// one path.
    ///
    /// tmux reads `TMUX_TMPDIR` as one path (a `:` in it does not make a
    /// list) and runs it through `realpath(3)`. When that succeeds the socket
    /// goes under the resolved directory; when it fails — a missing
    /// directory, or a `~/` path, which tmux does not expand here — tmux falls
    /// back to `/tmp` without a word. So this resolves the value the same way
    /// and drops it when the resolve fails. A relative value resolves against
    /// the daemon's working directory, which is the one tmux resolved it
    /// against: the daemon ran every tmux client in its own working
    /// directory. The fallback is probed even when the value resolves,
    /// because the two places cannot both be known to be empty any other way,
    /// and a running server read as gone is the one mistake this probe must
    /// not make.
    ///
    /// `environment` must be the environment TBD ran tmux with. The daemon ran
    /// every tmux client with its own environment, so the daemon's
    /// `TMUX_TMPDIR` is the one that placed the socket, whatever the person's
    /// shell says. `fallbackRoot` is a seam for tests.
    static func candidateSocketPaths(
        server: String,
        environment: [String: String],
        fallbackRoot: String = defaultTemporaryDirectory,
        uid: uid_t = getuid()
    ) -> [String] {
        var directories: [String] = []
        if let configured = environment["TMUX_TMPDIR"], !configured.isEmpty,
           let resolved = resolvedPath(configured) {
            directories.append(resolved)
        }
        if !directories.contains(fallbackRoot) {
            directories.append(fallbackRoot)
        }
        return directories.map { "\($0)/tmux-\(uid)/\(server)" }
    }

    /// `path` with every symlink and relative component resolved, or nil
    /// when it does not name something that exists — `realpath(3)`, which is
    /// what tmux runs on `TMUX_TMPDIR`.
    static func resolvedPath(_ path: String) -> String? {
        guard let resolved = realpath(path, nil) else { return nil }
        defer { free(resolved) }
        return String(cString: resolved)
    }

    /// The probe the daemon runs: a plain connect to each candidate socket,
    /// each closed at once.
    static func production(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        fallbackRoot: String = defaultTemporaryDirectory
    ) -> LeftoverTmuxServerProbe {
        LeftoverTmuxServerProbe { server in
            await state(ofSocketsAt: candidateSocketPaths(
                server: server, environment: environment, fallbackRoot: fallbackRoot))
        }
    }

    /// The server is gone only when every candidate socket is positively
    /// absent. One candidate that answers, or fails in any way that is not
    /// evidence of absence, reads as running, and the rest are not asked.
    static func state(ofSocketsAt socketPaths: [String]) async -> LeftoverTmuxServerState {
        guard !socketPaths.isEmpty else { return .running }
        for socketPath in socketPaths {
            if await state(ofSocketAt: socketPath) == .running {
                return .running
            }
        }
        return .absent
    }

    /// The state of whatever is behind one socket path. Connects, asks nothing
    /// and closes.
    ///
    /// The connect is `HolderClient.connectOnly`, so its failures arrive as
    /// the same `HolderClient.Error.cannotConnect` every holder probe reads,
    /// and `classify(connecting:)` reads them by the same rules.
    static func state(ofSocketAt socketPath: String) async -> LeftoverTmuxServerState {
        let client = HolderClient(socketPath: socketPath, receiveTimeout: receiveTimeout)
        let state = await classify { try await client.connectOnly() }
        await client.close()
        return state
    }

    /// What one connection attempt says about the server.
    ///
    /// The errno rules are `HolderRegistry.exitProbeOutcome(for:)`'s, the one
    /// place they live: only `ENOENT` and `ECONNREFUSED` are evidence that
    /// nothing is listening. A successful connect, any other errno, and a
    /// socket path too long to try are all `running`, because none of them is
    /// evidence that the session ended, and parking a row whose agent still
    /// runs is the one mistake this probe must not make.
    static func classify(
        connecting connect: () async throws -> Void
    ) async -> LeftoverTmuxServerState {
        do {
            try await connect()
            return .running
        } catch {
            switch HolderRegistry.exitProbeOutcome(for: error) {
            case .established:
                return .absent
            case .retry, .keep:
                return .running
            }
        }
    }
}
