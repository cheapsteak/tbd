import Foundation
import TBDShared
import os

private let logger = Logger(subsystem: "com.tbd.daemon", category: "TransportMigration")

/// Whether a wake of a session parked on the tmux transport moves it to the
/// pty holder first, and what it answers when that move cannot happen.
///
/// See `docs/specs/2026-10-11-holder-transport-migration-design.md`, "Why a
/// gesture rather than a behaviour".
enum TransportMigrationOnWake {

    /// Whether `actor` declares a request from outside the daemon, which
    /// moves a parked tmux row to the pty holder before the wake.
    ///
    /// Moving a session starts a program, and whether to start it now is its
    /// owner's choice, so the daemon never initiates a move. A person's wake is
    /// that choice: they asked for the session to start now, and for a row
    /// whose park is complete the move only rewrites the row before the
    /// ordinary wake. So the two gestures compose. A rail's wake — session
    /// restore, limit resume, a queued prompt, any wake the daemon decides on
    /// its own — moves nothing, and is refused with the reason that names the
    /// move (`HibernationCoordinator.tmuxWakeUnavailableReason`).
    ///
    /// Judged by kind alone: every `daemon` actor is a rail, whatever its rail
    /// name. Every other kind — `app`, `phone`, `session`, `anonymous`, and a
    /// kind a newer client declares — came through the socket from outside the
    /// daemon, and no declared actor reads as anonymous. The actor is
    /// self-declared, so this decides who chose the moment, not who may.
    ///
    /// Because no declared actor reads as a person, a caller inside the daemon
    /// must name its own: the wake and resume handlers take the actor with no
    /// default, and `WakeMigratesParkedTmuxRowTests` pins what every such
    /// caller passes.
    static func isPersonStarted(_ actor: ActuationActor?) -> Bool {
        (actor ?? .anonymous).kind != ActuationActor.Kind.daemon
    }

    /// The refusal when the row changed while it was being moved, and the
    /// change did not leave it on the pty holder. The migrator wrote nothing,
    /// so the row is as the other writer left it.
    static let raceRefusal =
        "This session changed while TBD was moving it to the pty holder, so this wake "
        + "changed nothing and woke nothing. Wake it again to try once more."

    /// The refusal when the row could not be read to tell whether it has to
    /// move to the pty holder before it wakes. Nothing was moved or woken, and
    /// nothing about the row is known, so trying again is the remedy.
    static func unreadableRefusal(_ error: String) -> String {
        "TBD could not read this session to tell whether it has to move to the pty holder "
            + "before it wakes (\(error)), so this wake changed nothing and woke nothing. "
            + "Try again."
    }
}

extension RPCRouter {

    /// Before a person's wake of a row parked on the tmux transport, move the
    /// row to the pty holder, so the ordinary wake that follows starts it
    /// there with the caller's own parameters.
    ///
    /// Call after `beginActuation` and the start-admission hold, and before
    /// `hibernationCoordinator.wake`: a hold leaves the row on tmux untouched,
    /// and the wake then reads the moved row.
    ///
    /// Returns nil to let the wake proceed: the actor is a rail
    /// (`TransportMigrationOnWake.isPersonStarted`), the row is missing, not
    /// parked or already on the holder, or the move landed. The wake answers
    /// each of those as it always does; a rail's wake of a parked tmux row
    /// meets the coordinator's own refusal. A row closed while the move ran is
    /// missing too, and the wake answers it so.
    ///
    /// Returns the refusal to hand back, after closing the actuation row with
    /// it, when the row is not moved: it could not be read, no wake could
    /// resume it, or the move could not happen. The row is then exactly as the
    /// migrator found it.
    ///
    /// A row with no resume plan is not moved at all. The wake after the move
    /// would refuse it (`HibernationCoordinator.wakeResultWithoutResumePlan`),
    /// so moving it would change a row this wake then leaves asleep. It is the
    /// test start admission asks (`startAdmissionAgent(forWaking:)`).
    ///
    /// The move is `TerminalTransportMigrator.migrate`, the one
    /// `terminal.migrateTransport` makes: a row whose park is still in flight
    /// is refused while its tmux server may run, and the rewrite is a
    /// compare-and-set that spawns nothing.
    func moveParkedTmuxRowBeforeWake(
        _ actuationID: String, actor: ActuationActor?, terminalID: UUID
    ) async -> RPCResponse? {
        guard TransportMigrationOnWake.isPersonStarted(actor) else { return nil }
        // A read that fails is not a row that is absent or awake. Read as
        // either, it would hand the wake a row still on tmux, whose backstop
        // tells a person who has just woken it to wake it.
        let terminal: TBDShared.Terminal
        do {
            guard let row = try await db.terminals.get(id: terminalID) else { return nil }
            terminal = row
        } catch {
            return await refuseUnreadableWake(actuationID, terminalID: terminalID, error: error)
        }
        guard terminal.isParked, terminal.transport != .holder else { return nil }
        guard terminal.recoveryResumePlan != nil else {
            return await refuseUnresumableWake(actuationID, terminal)
        }
        let actorKind = (actor ?? .anonymous).kind

        let outcome = await makeTransportMigrator().migrate(terminalID: terminalID)
        switch outcome {
        case .migrated, .movedNotResumed:
            await publishIfMovedToHolder(terminalID: terminalID, outcome: outcome)
            logger.notice("wake: moved parked terminal \(terminalID, privacy: .public) from the tmux transport to the pty holder before waking it, at a \(actorKind, privacy: .public) request")
            return nil
        case .alreadyHolder:
            // Moved by another request between this read and the move's own —
            // a concurrent wake, or a migration. This wake moved nothing, and
            // wakes the row where it now is.
            logger.info("wake: terminal \(terminalID, privacy: .public) was already on the pty holder when the move read it; waking it there without moving it")
            return nil
        case .skipped(let reason) where reason == TerminalTransportMigrator.notFoundSkip:
            // Gone between the two reads. The wake answers a missing row as
            // it answers any other.
            return nil
        case .skipped(let reason) where reason == TerminalTransportMigrator.raceSkip:
            // A concurrent gesture may have moved it first — two focus-wakes,
            // or a migration — and then this wake has nothing left to move.
            if let row = (try? await db.terminals.get(id: terminalID)) ?? nil,
               row.transport == .holder {
                logger.info("wake: terminal \(terminalID, privacy: .public) was moved to the pty holder by a concurrent request; waking it there")
                return nil
            }
            return await refuseWakeMigration(
                actuationID, terminalID: terminalID,
                outcome: .skipped(reason: TransportMigrationOnWake.raceRefusal))
        case .skipped, .refused:
            // A tab closed while the move ran fails the rewrite, which finds
            // no row to write. That is a missing row, and the wake answers it
            // as one, not as a move that could not be recorded.
            if await terminalRowIsGone(terminalID) {
                logger.info("wake: terminal \(terminalID, privacy: .public) was closed while it was being moved to the pty holder")
                return nil
            }
            return await refuseWakeMigration(actuationID, terminalID: terminalID, outcome: outcome)
        }
    }

    /// Close the actuation with a move that did not happen, and answer the
    /// wake with its reason and `terminalOnTmux`, as every other refusal of a
    /// tmux row is answered.
    private func refuseWakeMigration(
        _ actuationID: String, terminalID: UUID, outcome: TransportMigrationOutcome
    ) async -> RPCResponse {
        let reason = ActuationOutcome.detail(outcome) ?? TransportMigrationOnWake.raceRefusal
        logger.notice("wake: terminal \(terminalID, privacy: .public) is parked on the tmux transport and could not be moved to the pty holder; refusing the wake and leaving it parked: \(reason, privacy: .public)")
        await finishActuation(actuationID, ActuationOutcome.classify(outcome), error: reason)
        return RPCResponse(error: reason, code: RPCErrorCode.terminalOnTmux.rawValue)
    }

    /// Refuse a person's wake of a parked tmux row that no wake can resume,
    /// leaving the row on tmux as it is.
    ///
    /// A row the migration would skip for having nothing to resume — a hook
    /// tab, a Codex tab with no thread, a Claude tab whose session never began
    /// — is answered with that skip's reason, which says what to do instead.
    /// Any other, such as a parked shell, is answered as its wake would answer
    /// it on the pty holder, where it is refused the same way.
    private func refuseUnresumableWake(
        _ actuationID: String, _ terminal: TBDShared.Terminal
    ) async -> RPCResponse {
        if let skip = TransportMigrationEligibility.nothingToResumeSkip(terminal) {
            return await refuseWakeMigration(
                actuationID, terminalID: terminal.id, outcome: .skipped(reason: skip))
        }
        let result = HibernationCoordinator.wakeResultWithoutResumePlan(terminal)
        let reason: String
        if case .notAClaudeTab(let kind) = result {
            reason = ClaudeResumeDecision.notAClaudeTabReason(kind)
        } else {
            reason = "No session ID to resume"
        }
        logger.notice("wake: terminal \(terminal.id, privacy: .public) is parked on the tmux transport with nothing a wake can resume; refusing the wake and leaving it where it is: \(reason, privacy: .public)")
        await finishActuation(actuationID, ActuationOutcome.classify(result), error: reason)
        return RPCResponse(error: reason)
    }

    /// Close the actuation with a read of the row that failed, and answer the
    /// wake with it.
    ///
    /// Recorded as a transport failure, as a read that throws after the
    /// request row is everywhere else (`actuating`), and as the wake records
    /// its own failed read of the resume gate: nothing was declined, the
    /// daemon could not find out. No code, because trying again is the
    /// remedy.
    private func refuseUnreadableWake(
        _ actuationID: String, terminalID: UUID, error: any Error
    ) async -> RPCResponse {
        let reason = TransportMigrationOnWake.unreadableRefusal("\(error)")
        logger.error("wake: could not read terminal \(terminalID, privacy: .public) to tell whether it has to move to the pty holder; refusing the wake: \(reason, privacy: .public)")
        await finishActuation(actuationID, .transportFailed, error: reason)
        return RPCResponse(error: reason)
    }

    /// Whether the row is positively gone: a read that succeeded and found
    /// nothing. A read that fails says nothing about the row.
    private func terminalRowIsGone(_ terminalID: UUID) async -> Bool {
        do {
            return try await db.terminals.get(id: terminalID) == nil
        } catch {
            return false
        }
    }
}
