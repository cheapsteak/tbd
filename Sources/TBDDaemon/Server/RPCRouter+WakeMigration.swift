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
    static func isPersonStarted(_ actor: ActuationActor?) -> Bool {
        (actor ?? .anonymous).kind != ActuationActor.Kind.daemon
    }

    /// The refusal when the row changed while it was being moved, and the
    /// change did not leave it on the pty holder. The migrator wrote nothing,
    /// so the row is as the other writer left it.
    static let raceRefusal =
        "This session changed while TBD was moving it to the pty holder, so this wake "
        + "changed nothing and woke nothing. Wake it again to try once more."
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
    /// meets the coordinator's own refusal. Returns the refusal to hand back
    /// when the row could not be moved, after closing the actuation row with
    /// it. The row is then exactly as the migrator found it.
    ///
    /// The move is `TerminalTransportMigrator.migrate`, the one
    /// `terminal.migrateTransport` makes: a row whose park is still in flight
    /// is refused while its tmux server may run, and the rewrite is a
    /// compare-and-set that spawns nothing.
    func moveParkedTmuxRowBeforeWake(
        _ actuationID: String, actor: ActuationActor?, terminalID: UUID
    ) async -> RPCResponse? {
        guard TransportMigrationOnWake.isPersonStarted(actor),
              let terminal = (try? await db.terminals.get(id: terminalID)) ?? nil,
              terminal.isParked, terminal.transport != .holder else { return nil }
        let actorKind = (actor ?? .anonymous).kind

        let outcome = await makeTransportMigrator().migrate(terminalID: terminalID)
        switch outcome {
        case .migrated, .movedNotResumed, .alreadyHolder:
            await publishIfMovedToHolder(terminalID: terminalID, outcome: outcome)
            logger.notice("wake: moved parked terminal \(terminalID, privacy: .public) from the tmux transport to the pty holder before waking it, at a \(actorKind, privacy: .public) request")
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
}
