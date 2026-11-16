import Foundation
import TBDShared
import os

private let logger = Logger(subsystem: "com.tbd.daemon", category: "TransportMigration")

/// What one session's move to the pty holder came to.
///
/// Five cases rather than a `Bool` and an error, because a fleet-wide run's
/// product is its report: a person needs to know what did not move and why,
/// and "already there" is a different answer from "refused" even though
/// neither moved anything.
enum TransportMigrationOutcome: Sendable, Equatable {
    /// The row now reads holder-backed. A live session whose tmux server was
    /// gone was parked and woken on the holder, or started again there as a
    /// shell; a parked one was only rewritten.
    case migrated
    /// The row now reads holder-backed and its program was NOT started again:
    /// the rewrite landed and the wake that follows it did not.
    ///
    /// Its own case rather than a refusal, because the two mean opposite
    /// things to the person reading a report. A refusal leaves the session
    /// where it was; this one has moved it, and the cost is only that it comes
    /// back on the holder when next woken rather than now. Reported as a
    /// refusal it would read as "can't be moved" about a session that had
    /// moved, and the run's migrated count would undercount what it did.
    case movedNotResumed(reason: String)
    /// The row was already holder-backed. Nothing was read, parked or written.
    case alreadyHolder
    /// The session did not move, for a reason that names a state a person can
    /// change — a busy turn, a tab with nothing to move, a concurrent wake
    /// winning a compare-and-set. Retrying once that state changes is the
    /// remedy.
    ///
    /// **It does not promise that nothing happened.** Most skips are taken
    /// before anything was touched, but a live row whose tmux server was gone
    /// may have been parked before a race overtook the rewrite. Nothing was
    /// stopped by that park, since the server had already ended the session;
    /// the row stays parked on tmux, and the next run of the migration moves
    /// it as a parked row.
    case skipped(reason: String)
    /// The migration could not be attempted or could not be finished. Carries
    /// the reason. Retrying does not help until the named fact changes.
    case refused(reason: String)

    /// Whether this outcome claims to have left the row holder-backed. Decides
    /// how loudly a row that then could not be re-read is logged: a row absent
    /// after an outcome that moved nothing is ordinary — the not-found skip is
    /// exactly that — and surprising after one that did.
    var claimsTheRowMoved: Bool {
        switch self {
        case .migrated, .movedNotResumed: return true
        case .alreadyHolder, .skipped, .refused: return false
        }
    }
}

/// Moves a session from the tmux transport to the pty holder in place: same
/// row, same tab, same label and pin, same Claude session id and transcript.
///
/// TBD no longer drives tmux, so nothing here reaches a tmux server. A parked
/// row is only rewritten. A live row moves only once a socket probe has found
/// its tmux server gone (`LeftoverTmuxServerProbe`): a session with a
/// conversation to resume is parked with its identity kept, rewritten and
/// woken on the holder — the park, rewrite and wake the in-place profile swap
/// also composes, with a different column rewritten — and a shell gets a fresh
/// login shell on the holder in the same working directory, recorded in one
/// guarded write (`HibernationCoordinator.moveRunningShellToHolder`). While
/// the server still runs, the move refuses and says how to end it.
/// See `docs/specs/2026-10-11-holder-transport-migration-design.md`.
///
/// **Claim-free but ordered.** No lock or claim spans the composition. Every
/// race it has is closed by the park and the rewrite each being a
/// compare-and-set (`WorktreeLifecycle.parkLeftoverTmuxRow`,
/// `TerminalStore.setParkedTransport`): a wake or a replacement that wins
/// rejects the write atomically, and the session is reported as skipped with
/// the row consistent by construction. A wake that lands *after* the rewrite
/// has woken the session on the holder, which is the end state this was
/// asking for.
///
/// **Nothing unwinds.** Earlier successes in a fleet run are finished
/// sessions, not steps in a transaction, and a wake that fails after the
/// rewrite leaves a row parked and recorded as holder-backed — a state the
/// ordinary wake path already handles, so the worst case is a session that
/// comes back on the holder later rather than now.
actor TerminalTransportMigrator {

    /// The operations a migration composes, injected as closures.
    ///
    /// Closures rather than a protocol for the same reason the rest of this
    /// subsystem uses them (`HolderRegistry.listTerminals`,
    /// `HibernationCoordinator.setHolderProcessIsLive`): the collaborators are
    /// concrete types with no abstraction worth minting, and what a test of
    /// *this* composition needs is to observe the order and the arguments of
    /// the calls, not to re-prove the probe, the park and the wake.
    struct Operations: Sendable {
        /// Whether a holder can be STARTED. `HolderRegistry.canSpawn`, which
        /// is a strictly narrower fact than "a registry exists": a daemon
        /// whose `TBDHolder` binary has moved still builds a registry, because
        /// adopting an already-running holder needs no executable.
        let canSpawnHolder: @Sendable () -> Bool
        /// The tmux server a live tmux row names and what the socket probe
        /// says about it, or nil when the row's worktree could not be read to
        /// name one. `WorktreeLifecycle.leftoverTmuxServerSighting(for:)`.
        let tmuxServerSighting: @Sendable (Terminal) async -> LeftoverTmuxServerSighting?
        /// Park a live tmux row whose server the probe found gone, keeping its
        /// session identity, and say what happened.
        /// `WorktreeLifecycle.parkLeftoverTmuxRow(_:)`.
        let parkLeftover: @Sendable (Terminal) async throws -> LeftoverTmuxParkOutcome
        /// The ordinary wake. Everything above its single transport branch is
        /// already transport-independent — profile, environment, settings
        /// overlay, trust seed, transcript sync and the `claude --resume`
        /// argv — so a migrated session resumes through the same code any
        /// other wake uses, and this composition has no spawn command of its
        /// own to compose or to get wrong.
        let wake: @Sendable (UUID) async -> WakeResult
        /// Move a live row that has no conversation to resume, once its tmux
        /// server is gone: start a fresh login shell on a holder in the same
        /// working directory, and record the move in one guarded write.
        /// Nothing is parked and nothing is woken — a park exists to carry a
        /// conversation across a respawn, and this row names none.
        let moveRunningShell: @Sendable (Terminal) async -> ShellTransportMoveOutcome

        static func production(
            hibernation: HibernationCoordinator,
            holderRegistry: HolderRegistry?,
            lifecycle: WorktreeLifecycle
        ) -> Operations {
            Operations(
                canSpawnHolder: { holderRegistry?.canSpawn == true },
                tmuxServerSighting: { await lifecycle.leftoverTmuxServerSighting(for: $0) },
                parkLeftover: { try await lifecycle.parkLeftoverTmuxRow($0) },
                wake: { await hibernation.wake(terminalID: $0) },
                moveRunningShell: {
                    await hibernation.moveRunningShellToHolder(terminal: $0)
                })
        }
    }

    /// The refusal when no holder can be started at all. Reached before any
    /// park, so the row is left exactly as it was. Phrased from the same fact
    /// as the holder wake's own refusal.
    static let holderUnspawnableRefusal =
        "The TBDHolder helper is missing beside the daemon, so no holder can be started for this session; nothing was changed."

    /// The refusal when a live tmux row's worktree cannot be read, so there is
    /// no tmux server to probe. Nothing is known about the session, so
    /// nothing is touched.
    static let worktreeUnreadableRefusal =
        "This session's worktree could not be read, so TBD could not tell whether its tmux "
        + "server is still running; nothing was changed."

    /// The refusal for a request that would start, restart or replace the
    /// process behind a row still on the tmux transport: a wake, a window
    /// recreate, an in-place profile swap, Continue in Claude.
    ///
    /// TBD opens sessions only on the pty holder, so none of those can run on
    /// such a row; migrating it is the way forward, and this says how. It names
    /// the session, because `tbd terminal migrate` takes its id. `retry` is the
    /// action to take again once the row is on the holder, written to follow
    /// "then", as in "wake it again".
    static func migrateFirstRefusal(terminalID: UUID, retry: String) -> String {
        "Terminal \(terminalID.uuidString) runs on the tmux transport, which TBD no longer "
            + "starts sessions on. Run `tbd terminal migrate \(terminalID.uuidString)` "
            + "(or `tbd terminal migrate --all`) to move it to the pty holder, then \(retry)."
    }

    /// The skip when a compare-and-set found the row had moved. Nothing was
    /// written, and the row is consistent whichever way the race went.
    static let raceSkip = "Session changed while migrating"

    /// The skip for a row the database no longer holds, or could not be read.
    static let notFoundSkip = "Terminal not found"

    private let db: TBDDatabase
    private let operations: Operations

    init(db: TBDDatabase, operations: Operations) {
        self.db = db
        self.operations = operations
    }

    // MARK: - One session

    /// Move one session to the pty holder.
    ///
    /// The order is the contract, and two steps of it are pinned by tests: a
    /// live row's tmux server is probed before anything else is decided about
    /// it, so a session still running in tmux is refused whatever else is
    /// true of it; and the holder-unspawnable refusal comes **before** any
    /// park, so a refusal can never leave a parked row behind.
    func migrate(terminalID: UUID) async -> TransportMigrationOutcome {
        guard let terminal = try? await db.terminals.get(id: terminalID) else {
            return .skipped(reason: Self.notFoundSkip)
        }
        if terminal.transport == .holder {
            return .alreadyHolder
        }
        guard terminal.isParked else {
            return await migrateLiveRow(terminal)
        }

        switch TransportMigrationEligibility.decide(terminal) {
        case .alreadyHolder:
            return .alreadyHolder
        case .skip(let reason):
            logger.debug("transport migration: skipping \(terminalID, privacy: .public) — \(reason, privacy: .public)")
            return .skipped(reason: reason)
        case .eligible:
            break
        }
        guard operations.canSpawnHolder() else {
            logger.warning("transport migration: refusing \(terminalID, privacy: .public) — no holder can be started")
            return .refused(reason: Self.holderUnspawnableRefusal)
        }

        // A parked session is only rewritten. Nothing is running, so there is
        // nothing to stop and nothing to respawn; its next ordinary wake lands
        // on the holder.
        switch await rewriteToHolder(terminal) {
        case .written:
            break
        case .lostTheRace:
            return .skipped(reason: Self.raceSkip)
        case .failed(let reason):
            return .refused(reason: reason)
        }
        logger.info("transport migration: parked terminal \(terminalID, privacy: .public) now reads holder-backed; nothing was spawned")
        return .migrated
    }

    /// Move a row that still reads as live on tmux.
    ///
    /// TBD can neither reach nor stop a tmux session, so the row moves only
    /// once its tmux server is positively gone. While the server may still be
    /// running, the row is refused with the command that ends it, whatever
    /// else is true of it: nothing about it can change until tmux has stopped.
    ///
    /// Once the server is gone, a session with a conversation to resume —
    /// Claude, or Codex with a recorded thread — is parked with its identity
    /// kept, which is what reconcile does for the same row, and then moved
    /// as a parked row is and woken on the holder. Any other row has nothing a
    /// park could keep: `TransportMigrationEligibility.nothingToResumeSkip`
    /// turns away the ones that must not become a bare login shell, each with
    /// its own reason, and a shell gets a fresh one on the holder.
    ///
    /// The row's recorded activity is not consulted. It describes a session
    /// that ended with its server, so a "working" state there is stale and
    /// would refuse a move that interrupts nothing.
    private func migrateLiveRow(_ terminal: Terminal) async -> TransportMigrationOutcome {
        let terminalID = terminal.id
        guard let sighting = await operations.tmuxServerSighting(terminal) else {
            logger.warning("transport migration: refusing \(terminalID, privacy: .public) — its worktree could not be read to name its tmux server")
            return .refused(reason: Self.worktreeUnreadableRefusal)
        }
        guard sighting.state == .absent else {
            logger.info("transport migration: refusing \(terminalID, privacy: .public) — its tmux server \(sighting.server, privacy: .public) may still be running")
            return .refused(reason: LeftoverTmuxSession.stillRunningRefusal(
                terminalID: terminalID, server: sighting.server))
        }

        guard terminal.recoveryResumePlan != nil else {
            if let reason = TransportMigrationEligibility.nothingToResumeSkip(terminal) {
                logger.debug("transport migration: skipping \(terminalID, privacy: .public) — \(reason, privacy: .public)")
                return .skipped(reason: reason)
            }
            guard operations.canSpawnHolder() else {
                logger.warning("transport migration: refusing \(terminalID, privacy: .public) — no holder can be started")
                return .refused(reason: Self.holderUnspawnableRefusal)
            }
            // A shell tab whose row carries a session id — what `SessionStart`
            // leaves for a Claude started by hand inside it — is still a
            // shell, and moves as one.
            if case .notAClaudeTab(let kind) = terminal.claudeResumeDecision {
                logger.debug("transport migration: \(terminalID, privacy: .public) is a \(kind.rawValue, privacy: .public) tab carrying a session id; it moves as a shell and the id is not resumed")
            }
            switch await operations.moveRunningShell(terminal) {
            case .moved:
                logger.info("transport migration: terminal \(terminalID, privacy: .public) was started again as a shell on the pty holder")
                return .migrated
            case .lostTheRace:
                return .skipped(reason: Self.raceSkip)
            case .refused(let reason):
                return .refused(reason: reason)
            }
        }

        // Before the park, and the one ordering this composition commits to:
        // a gesture that cannot finish the move must not park the row.
        guard operations.canSpawnHolder() else {
            logger.warning("transport migration: refusing \(terminalID, privacy: .public) — no holder can be started")
            return .refused(reason: Self.holderUnspawnableRefusal)
        }
        let parked: Terminal
        do {
            switch try await operations.parkLeftover(terminal) {
            case .parked(let row?):
                parked = row
            case .parked(nil), .closed:
                // Closed before or during the park, or parked and then gone
                // before it could be read back.
                return .skipped(reason: Self.notFoundSkip)
            case .leftAlone, .superseded:
                return .skipped(reason: Self.raceSkip)
            }
        } catch {
            let detail = "\(error)"
            logger.error("transport migration: could not park terminal \(terminalID, privacy: .public) whose tmux server is gone: \(detail, privacy: .public)")
            return .refused(reason: "The park could not be recorded (\(detail)).")
        }
        // Compared against the row the park left: `setParkedTransport`
        // requires the row to read parked.
        switch await rewriteToHolder(parked) {
        case .written:
            break
        case .lostTheRace:
            return .skipped(reason: Self.raceSkip)
        case .failed(let reason):
            return .refused(reason: reason)
        }

        let woken = await operations.wake(terminalID)
        guard let failure = Self.wakeFailure(woken) else {
            logger.info("transport migration: terminal \(terminalID, privacy: .public) moved to the pty holder and resumed")
            return .migrated
        }
        // Nothing is unwound, and this is not a refusal: the row IS on the
        // holder, which the ordinary wake path already handles, so the only
        // cost is that the session comes back there when next woken rather
        // than now. The handler publishes the rewritten row for this outcome
        // too, so a client still reading `tmux` learns where it went.
        logger.warning("transport migration: terminal \(terminalID, privacy: .public) is recorded on the pty holder but was not resumed: \(failure, privacy: .public)")
        return .movedNotResumed(reason: failure)
    }

    // MARK: - The fleet

    /// Every session a fleet-wide run covers, in the order it covers them.
    ///
    /// The ids rather than the run, so the caller can **interleave per
    /// session**: the record of what a fleet gesture stopped belongs one row
    /// per terminal at that terminal's own act moment, and the rewritten row
    /// has to be published as each one finishes rather than after the whole
    /// loop — for `--all` over a real fleet, "after the loop" is the whole run,
    /// during which every mounted pane still reads a transport its session
    /// has left.
    ///
    /// **Every row, including the ones already on the holder.** A run's
    /// product is its report, and a session absent from it is indistinguishable
    /// from one the run never considered. A holder row costs nothing to
    /// report: `migrate` answers it from the row alone, with no probe, no
    /// park, no wake and no write.
    ///
    /// The caller moves them **sequentially**, deliberately: every migration
    /// of a live session is a respawn, and a machine with a large fleet must
    /// not be asked for many simultaneous ones.
    func fleetTerminalIDs() async -> [UUID] {
        guard let terminals = try? await db.terminals.list() else {
            logger.error("transport migration: could not list terminals; migrated nothing")
            return []
        }
        return terminals.map(\.id)
    }

    // MARK: - The rewrite

    /// What the compare-and-set did.
    ///
    /// Three cases rather than an optional, because the two ways it does not
    /// write mean opposite things to the person reading a report: a lost race
    /// is a state they can retry out of, and a failed write is a fact that has
    /// to change first.
    private enum RewriteOutcome {
        case written
        case lostTheRace
        case failed(String)
    }

    /// Rewrite one parked row's transport.
    private func rewriteToHolder(_ terminal: Terminal) async -> RewriteOutcome {
        do {
            guard try await db.terminals.setParkedTransport(
                id: terminal.id,
                expectedState: TerminalReplacementSnapshot(terminal: terminal),
                transport: .holder) != nil else {
                logger.warning("transport migration: the rewrite was refused for \(terminal.id, privacy: .public) — the row changed under the migration")
                return .lostTheRace
            }
            return .written
        } catch {
            // `"\(error)"` rather than `localizedDescription`: a GRDB
            // `DatabaseError` describes itself usefully and localizes into
            // "The operation couldn't be completed", which is the half a
            // person reading this reason does not need.
            let detail = "\(error)"
            logger.error("transport migration: the rewrite failed for \(terminal.id, privacy: .public): \(detail, privacy: .public)")
            return .failed("The move could not be recorded (\(detail)).")
        }
    }

    /// The wake half's failure, or nil when it woke.
    ///
    /// Every case is listed and there is no `default:`, deliberately: these
    /// strings are read by a person whose migration half-finished, and a
    /// catch-all would quietly render a new `WakeResult` case as a raw enum in
    /// front of them. A case added later is a compile error here instead.
    static func wakeFailure(_ result: WakeResult) -> String? {
        switch result {
        case .ok:
            return nil
        case .respawnFailed(let reason), .onTmux(let reason):
            return reason
        case .inFlight:
            return "another wake for this session was already running; it resumes on the pty holder"
        case .notHibernated:
            return "this session moved to the pty holder, but TBD no longer saw it as paused and did not resume it; focus the tab to start it there"
        case .sessionGone:
            return "this session moved to the pty holder, but the paused session could not be found to resume; focus the tab to start it there"
        case .notFound:
            return "this session moved to the pty holder, but its row could not be read back, so nothing was resumed"
        case .noSessionID:
            return "this session moved to the pty holder, but it names no conversation to resume; focus the tab to start a session there"
        case .notAClaudeTab(let kind):
            return "this session moved to the pty holder, but its tab is a \(kind.rawValue) tab, not a Claude tab, so nothing was resumed"
        case .worktreeMissing(let path):
            return "this session moved to the pty holder, but its worktree directory is missing (\(path)), so nothing was resumed"
        case .profileMissing(let profileID):
            return "this session moved to the pty holder, but its account could not be resolved (profile \(profileID.uuidString)), so it was not resumed"
        case .conditionNotMet:
            return "this session moved to the pty holder, but it no longer met the condition on this wake, so it was not resumed; focus the tab to start it there"
        }
    }
}
