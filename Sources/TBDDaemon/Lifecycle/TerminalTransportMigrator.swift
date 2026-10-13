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
    /// The row now reads holder-backed and its program is running there. A
    /// running session was parked and woken on the holder; a parked one was
    /// only rewritten.
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
    /// change — a busy turn, a rail refusing the park, a concurrent wake
    /// winning the compare-and-set. Retrying once that state changes is the
    /// remedy.
    ///
    /// **It does not promise that nothing happened.** Most skips are refusals
    /// taken before anything was touched, but a park that succeeded and was
    /// then overtaken skips with the session's program already stopped, and
    /// such a session resumes on tmux when it is next woken. The reason says
    /// which of the two it was.
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
/// The composition is park, rewrite, wake — three verbs that already exist,
/// and the same shape as the in-place profile swap with a different column
/// rewritten. Nothing is extracted from a running tmux server; the session's
/// program is killed and started again on the holder, which is why this is
/// only ever reached from a gesture.
///
/// A running session with no conversation to resume takes a fourth verb
/// instead of those three: there is nothing a park could preserve, so its
/// program is stopped and a fresh login shell starts on the holder in the same
/// working directory, recorded in one guarded write
/// (`HibernationCoordinator.moveRunningShellToHolder`).
/// See `docs/specs/2026-10-11-holder-transport-migration-design.md`.
///
/// **Claim-free but ordered.** No lock or claim spans the composition. Every
/// race it has is closed by the rewrite being a compare-and-set
/// (`TerminalStore.setParkedTransport`): a wake or a replacement that wins
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

    /// The three operations a migration composes, injected as closures.
    ///
    /// Closures rather than a protocol for the same reason the rest of this
    /// subsystem uses them (`HolderRegistry.listTerminals`,
    /// `HibernationCoordinator.setHolderProcessIsLive`): the collaborators are
    /// two concrete actors with no abstraction worth minting, and what a test
    /// of *this* composition needs is to observe the order and the arguments
    /// of the three calls, not to re-prove the park and the wake.
    struct Operations: Sendable {
        /// Whether a holder can be STARTED. `HolderRegistry.canSpawn`, which
        /// is a strictly narrower fact than "a registry exists": a daemon
        /// whose `TBDHolder` binary has moved still builds a registry, because
        /// adopting an already-running holder needs no executable.
        let canSpawnHolder: @Sendable () -> Bool
        /// Park the session for the migration — `.manual` rails, so a rail's
        /// refusal becomes this session's skip reason.
        let park: @Sendable (UUID) async -> HibernateResult
        /// The ordinary wake. Everything above its single transport branch is
        /// already transport-independent — profile, environment, settings
        /// overlay, trust seed, transcript sync and the `claude --resume`
        /// argv — so a migrated session resumes through the same code any
        /// other wake uses, and this composition has no spawn command of its
        /// own to compose or to get wrong.
        let wake: @Sendable (UUID) async -> WakeResult
        /// The refusal owed to a parked row whose pane still has something
        /// running in it, or nil when the rewrite may proceed. Only an
        /// exit-stamped row can answer with a refusal.
        let paneBusyRefusal: @Sendable (Terminal) async -> String?
        /// Retire the tmux window the rewritten row leaves behind. Takes the
        /// row as it was BEFORE the rewrite, because the rewrite blanks the
        /// coordinates the window is named by.
        let retireWindow: @Sendable (Terminal) async -> Void
        /// Move a RUNNING session that has no conversation to resume: stop its
        /// program, start a fresh login shell on a holder in the same working
        /// directory, and record the move in one guarded write. Nothing is
        /// parked and nothing is woken — a park exists to carry a conversation
        /// across a respawn, and this row names none.
        let moveRunningShell: @Sendable (Terminal) async -> ShellTransportMoveOutcome

        static func production(
            hibernation: HibernationCoordinator,
            holderRegistry: HolderRegistry?
        ) -> Operations {
            Operations(
                canSpawnHolder: { holderRegistry?.canSpawn == true },
                park: { await hibernation.parkForTransportMigration(terminalID: $0) },
                wake: { await hibernation.wake(terminalID: $0) },
                paneBusyRefusal: {
                    await hibernation.transportMigrationPaneBusyRefusal(terminal: $0)
                },
                retireWindow: {
                    await hibernation.retireTmuxWindowAfterTransportMigration(terminal: $0)
                },
                moveRunningShell: {
                    await hibernation.moveRunningShellToHolder(terminal: $0)
                })
        }
    }

    /// The refusal when no holder can be started at all. Reached before any
    /// park, so the row is left exactly as it was — running or parked, on
    /// tmux. Phrased from the same fact as the holder wake's own refusal.
    static let holderUnspawnableRefusal =
        "The TBDHolder helper is missing beside the daemon, so no holder can be started for this session; nothing was changed."

    /// The skip when the compare-and-set found the row had moved. Nothing was
    /// written, and the row is consistent whichever way the race went.
    static let raceSkip = "Session changed while migrating"

    /// The skip for a row the database no longer holds, or could not be read.
    static let notFoundSkip = "Terminal not found"

    /// The skip when the park answered that one is already in flight. Not a
    /// refusal: the next run finds the row parked and takes the path with no
    /// process to interrupt.
    static let parkInFlightSkip =
        "Another pause of this session is in flight, or it was parked a moment ago; retry."

    /// The skip for a row that parked and then could not be read back. The one
    /// skip that says the session's program was stopped, so it has to say what
    /// becomes of it.
    static let unreadableAfterParkSkip =
        "This session was paused, but its row could not be read back, so it was not moved; it resumes on tmux when woken."

    private let db: TBDDatabase
    private let operations: Operations

    init(db: TBDDatabase, operations: Operations) {
        self.db = db
        self.operations = operations
    }

    // MARK: - One session

    /// Move one session to the pty holder.
    ///
    /// The order is the contract, and one step of it is pinned by a test: the
    /// holder-unspawnable refusal comes **before** any park, so a refusal can
    /// never leave a parked row behind.
    func migrate(terminalID: UUID) async -> TransportMigrationOutcome {
        guard let terminal = try? await db.terminals.get(id: terminalID) else {
            return .skipped(reason: Self.notFoundSkip)
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

        // Before the park, and the one ordering this composition commits to.
        // A session whose holder cannot be started must be left running on
        // tmux, not parked with nothing able to resume it.
        guard operations.canSpawnHolder() else {
            logger.warning("transport migration: refusing \(terminalID, privacy: .public) — no holder can be started")
            return .refused(reason: Self.holderUnspawnableRefusal)
        }

        // A running session with nothing to resume cannot take the park at
        // all: its program would be stopped with no way to bring it back, so
        // the park refuses it and the whole composition would skip. Such a
        // session moves plainly instead — its program is stopped and a fresh
        // login shell starts on the holder in the same working directory.
        //
        // The test is the row's own `claudeSessionID`, not `isClaudeResumable`,
        // because `performHibernate`'s refusal reads exactly this column: this
        // branch therefore takes precisely the rows the park would turn away.
        // What keeps it to SHELLS is `TransportMigrationEligibility`, above:
        // the four kinds of row that name no conversation and must not become
        // a bare login shell — a Codex tab, a Claude tab whose session has not
        // begun, and a hook tab of either kind — are each skipped there with
        // their own reason, so by here "no conversation" means "a shell". A running
        // Claude session with a conversation still goes park, rewrite, wake.
        //
        // The `isParked` half is belt-and-braces rather than a case that
        // arises: every park writes the session id it parks (`setHibernated`,
        // `setSuspended`), and nothing clears that column while leaving a row
        // parked, so a parked row always names a conversation. It is kept so
        // this branch states on its own that it takes a RUNNING row, rather
        // than depending on the branch below it to have claimed the others.
        if !terminal.isParked, terminal.claudeSessionID == nil {
            switch await operations.moveRunningShell(terminal) {
            case .moved:
                logger.info("transport migration: running terminal \(terminalID, privacy: .public) was restarted as a shell on the pty holder")
                return .migrated
            case .lostTheRace:
                return .skipped(reason: Self.raceSkip)
            case .busy(let reason):
                // A skip, not a refusal: the person stops what is running in
                // the pane and runs the migration again.
                logger.debug("transport migration: skipping \(terminalID, privacy: .public) — \(reason, privacy: .public)")
                return .skipped(reason: reason)
            case .refused(let reason):
                return .refused(reason: reason)
            }
        }

        // A parked session is only rewritten. Nothing is running, so there is
        // nothing to park and nothing to respawn; its next ordinary wake lands
        // on the holder.
        if terminal.isParked {
            // One parked row must not be rewritten: an exit-stamped one whose
            // pane the person is using. The rewrite blanks the coordinates,
            // after which the reconcile pass kills that window as untracked
            // and takes whatever they started in it with it.
            if let refusal = await operations.paneBusyRefusal(terminal) {
                return .skipped(reason: refusal)
            }
            switch await rewriteToHolder(terminal) {
            case .written:
                break
            case .lostTheRace:
                return .skipped(reason: Self.raceSkip)
            case .failed(let reason):
                return .refused(reason: reason)
            }
            await operations.retireWindow(terminal)
            logger.info("transport migration: parked terminal \(terminalID, privacy: .public) now reads holder-backed; nothing was spawned")
            return .migrated
        }

        switch await operations.park(terminalID) {
        case .ok:
            break
        case .alreadyHibernated:
            return .skipped(reason: Self.parkInFlightSkip)
        case .notFound:
            return .skipped(reason: Self.notFoundSkip)
        case .notEligible(let reason):
            // The park's own rails, surfaced verbatim. A migration discards
            // typed-but-unsent input, so a rail that refuses is protecting the
            // session and its reason is the one a person should read.
            logger.debug("transport migration: skipping \(terminalID, privacy: .public) — the park refused: \(reason, privacy: .public)")
            return .skipped(reason: reason)
        }

        // The snapshot has to be taken AFTER the park: the park wrote the
        // row's park columns and rotated its incarnation, and
        // `setParkedTransport` additionally requires the row to read parked.
        //
        // A read that fails here gets its own reason rather than the
        // not-found one, because the park above succeeded: this session's
        // program has already been stopped, and a line saying the session was
        // not found would describe a session whose agent was killed a moment
        // ago as one nothing happened to.
        guard let parked = try? await db.terminals.get(id: terminalID) else {
            logger.error("transport migration: terminal \(terminalID, privacy: .public) was parked but could not be read back; it stays on tmux")
            return .skipped(reason: Self.unreadableAfterParkSkip)
        }
        switch await rewriteToHolder(parked) {
        case .written:
            break
        case .lostTheRace:
            return .skipped(reason: Self.raceSkip)
        case .failed(let reason):
            return .refused(reason: reason)
        }
        // The window the park kept, retired now that the row no longer names
        // it. `parked` still carries the pre-rewrite coordinates.
        await operations.retireWindow(parked)

        let woken = await operations.wake(terminalID)
        guard let failure = Self.wakeFailure(woken) else {
            logger.info("transport migration: terminal \(terminalID, privacy: .public) moved to the pty holder and resumed")
            return .migrated
        }
        // Nothing is unwound, and this is not a refusal: the row IS on the
        // holder, which the ordinary wake path already handles, so the only
        // cost is that the session comes back there when next woken rather
        // than now. The handler publishes the rewritten row for this outcome
        // too — a client still caching `tmux` and the retired coordinate would
        // otherwise attach to a window this migration killed.
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
    /// during which every mounted pane is attached to a window the migration
    /// has already killed.
    ///
    /// **Every row, including the ones already on the holder.** A run's
    /// product is its report, and a session absent from it is indistinguishable
    /// from one the run never considered. A holder row costs nothing to
    /// report: `migrate` answers it from the row alone, with no park, no wake
    /// and no write.
    ///
    /// The caller moves them **sequentially**, deliberately: every migration
    /// of a running session is a respawn, and a machine with a large fleet must
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
        case .respawnFailed(let reason):
            return reason
        case .inFlight:
            return "another wake for this session was already running; it resumes on the pty holder"
        case .notHibernated:
            return "this session moved to the pty holder, but TBD no longer saw it as paused and did not resume it; focus the tab to start it there"
        case .sessionGone:
            return "this session moved to the pty holder, but the paused session could not be found to resume; focus the tab to start it there"
        case .paneUnreadable(_, let server):
            return "this session moved to the pty holder, but TBD could not reach its tmux server (\(server)) to check it, so it was not resumed; focus the tab to start it there"
        case .notFound:
            return "this session moved to the pty holder, but its row could not be read back, so nothing was resumed"
        case .noSessionID:
            return "this session moved to the pty holder, but it names no conversation to resume; focus the tab to start a session there"
        case .worktreeMissing(let path):
            return "this session moved to the pty holder, but its worktree directory is missing (\(path)), so nothing was resumed"
        case .profileMissing(let profileID):
            return "this session moved to the pty holder, but its account could not be resolved (profile \(profileID.uuidString)), so it was not resumed"
        case .paneBusy(let pid):
            return "this session moved to the pty holder, but another process (pid \(pid)) still holds its terminal, so it was not resumed"
        }
    }
}
