import Foundation
import TBDShared
import os

private let logger = Logger(subsystem: "com.tbd.daemon", category: "TransportMigration")

/// What one session's move to the pty holder came to.
///
/// Four cases rather than a `Bool` and an error, because a fleet-wide run's
/// product is its report: a person needs to know what did not move and why,
/// and "already there" is a different answer from "refused" even though
/// neither moved anything.
enum TransportMigrationOutcome: Sendable, Equatable {
    /// The row now reads holder-backed. A running session was parked and
    /// woken on the holder; a parked one was only rewritten.
    case migrated
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
}

/// Moves a session from the tmux transport to the pty holder in place: same
/// row, same tab, same label and pin, same Claude session id and transcript.
///
/// The composition is park, rewrite, wake — three verbs that already exist,
/// and the same shape as the in-place profile swap with a different column
/// rewritten. Nothing is extracted from a running tmux server; the session's
/// program is killed and started again on the holder, which is why this is
/// only ever reached from a gesture.
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
        // Nothing is unwound. The row is parked and recorded as holder-backed,
        // which the ordinary wake path already handles.
        logger.warning("transport migration: terminal \(terminalID, privacy: .public) is recorded on the pty holder but was not resumed: \(failure, privacy: .public)")
        return .refused(reason: failure)
    }

    // MARK: - The fleet

    /// Move every session TBD tracks, one at a time, and report each.
    ///
    /// **Sequential, deliberately.** Every migration of a running session is a
    /// respawn, and a machine with a large fleet must not be asked for many
    /// simultaneous ones.
    ///
    /// **Every row, including the ones already on the holder.** A run's
    /// product is its report, and a session absent from it is indistinguishable
    /// from one the run never considered. A holder row costs nothing to
    /// report: it is answered from the row alone, with no park, no wake and no
    /// write.
    func migrateAll() async -> [(terminalID: UUID, outcome: TransportMigrationOutcome)] {
        guard let terminals = try? await db.terminals.list() else {
            logger.error("transport migration: could not list terminals; migrated nothing")
            return []
        }
        var report: [(terminalID: UUID, outcome: TransportMigrationOutcome)] = []
        report.reserveCapacity(terminals.count)
        for terminal in terminals {
            report.append((
                terminalID: terminal.id,
                outcome: await migrate(terminalID: terminal.id)))
        }
        return report
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
