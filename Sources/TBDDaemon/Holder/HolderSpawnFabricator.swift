import Foundation
import TBDKernel

/// Stands in for a holder process at both ends of its life, so a unit test can
/// put a session on the holder transport without launching `TBDHolder`.
///
/// **Production never supplies one.** `Daemon.swift` builds its registry with
/// a `HolderSpawner` and no fabricator, and every branch that reads one is
/// unreachable there. It is an injection seam of the kind `ProcessSignaller`
/// is, sized for tests that spawn through `WorktreeLifecycle.spawnTerminal`,
/// directly or through the RPC handlers and worktree-creation paths that call
/// it. Without one, such a test can avoid launching `TBDHolder` only by
/// building no registry, which sends the spawn down that function's tmux arm.
///
/// It sits inside `HolderRegistry` rather than in front of it because every
/// one of those paths holds a concrete `HolderRegistry?` — the router's, the
/// lifecycle's, the one `TerminalSpawnTransport.holder` carries — and goes on
/// using that same registry after the spawn: to tear the session down, to ask
/// for its reader, to mark it let go. A registry that fabricates its spawns is
/// still the real registry for all of that, so `TerminalSpawnTransport.decide`
/// and `spawnTerminal` run unchanged.
///
/// A registry given a fabricator never consults its `HolderSpawner`:
///
///   - **`spawn`** asks the fabricator for the handle and returns it. Nothing
///     is handed over, so no reader is published: `reader(for:)` and
///     `adoptedProcess(for:)` answer nil for the session. A remembered status
///     is cleared rather than replaced, because a status may only come from a
///     holder's own answer (see `WorktreeLifecycle.holderRowVerdict`), and the
///     let-go mark is cleared as a real spawn clears it.
///   - **A live fabricated session refuses a second spawn**
///     (`sessionAlreadyRegistered`) until a teardown lets it go, as an occupied
///     slot does for a real one.
///   - **Every teardown** — `abandon` in each of its spellings and
///     `abandonVerifiedJob` — does the registry's own bookkeeping (the let-go
///     mark, the release, the cleared status) and then hands the handle to the
///     fabricator instead of telling a holder to forget and killing a job. A
///     fabricated pid is therefore never signalled through the registry.
///     `abandonVerifiedJob` still reports a row that recorded no child pid or
///     no start time, from the same gates the real teardown uses.
protocol HolderSpawnFabricator: Sendable {
    /// Stands in for `HolderSpawner.spawn` and the hand-over after it. Returns
    /// the handle the caller records, or throws as a failed spawn would.
    ///
    /// `environment` is the registry's own, which the rendezvous paths derive
    /// from, so a fabricated handle can name the socket path a real holder
    /// for this session would have bound.
    func spawn(
        terminalID: UUID, launch: HolderLaunchRequest, environment: [String: String]
    ) async throws -> HolderHandle

    /// Stands in for telling the holder to forget its pty and killing its job.
    /// The handle is the one `spawn` returned, or one rebuilt from a row's
    /// recorded pids by the teardowns that start from a row.
    func abandon(terminalID: UUID, handle: HolderHandle) async
}
