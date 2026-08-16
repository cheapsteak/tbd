import Foundation
import os
import TBDShared

private let deliveryLogger = Logger(
    subsystem: "com.tbd.daemon", category: "supervision.brief")

/// The last leg of the brief pipe: hand one surviving briefing to the project's
/// supervisor and answer what became of it
/// (`docs/specs/2026-08-01-fleet-supervision-sweep-program-design.md` §3 step 4).
///
/// **One full attempt, never a retry** — adapter fallback included. The
/// implementation returns an outcome rather than throwing, because every way a
/// delivery can end is already a named value in `SupervisionBriefOutcome` and
/// the submitting program's continuation policy branches on it; a thrown error
/// would collapse `transport-failed` and `no-live-supervisor` into one refusal
/// whose remedies are opposite.
///
/// **This exists as a protocol for two reasons, and neither is decoration.**
/// Briefing delivery itself lands in slice 5, and this is the insertion point it
/// plugs into — the pipe above it is complete and tested today. And it is the
/// only way `SupervisionBriefOutcome.transportFailed` is reachable at all right
/// now: a test injects a deliverer that returns it, which is what keeps that
/// contract value exercised rather than merely declared. Do not delete the seam
/// as unused.
///
/// **No durable external resource is created here** — see the doctrine in the
/// repo's `CLAUDE.md`. A deliverer sends into an existing session; the pipe's
/// pacing and liveness state is in memory and dies with the process, and the
/// only write path is an append to `~/tbd/supervision/ledger.jsonl`, a file
/// created and owned by `SupervisionLedgerWriter` and already covered by its
/// own lifecycle. There is nothing here for a reconciler to reclaim.
public protocol SupervisionBriefingDelivering: Sendable {
    /// Deliver one briefing to `project`'s supervisor, synchronously, once.
    ///
    /// The text is passed through verbatim and is never parsed — the daemon
    /// reads only its byte count, and does that upstream of here.
    func deliver(project: String, text: String) async -> SupervisionBriefOutcome
}

/// The shipped deliverer: it resolves the project's supervisor, finds none
/// standing in the role, and says so.
///
/// **That is an honest answer, not a stub.** Nothing in this build establishes
/// a supervisor session, so there is no session to send into and
/// `no-live-supervisor` is precisely what happened — distinct from
/// `transport-failed`, which would claim an attempt against a session that
/// exists. Briefing *delivery* lands in slice 5, which replaces the body of
/// this type with the real resolve-and-send: the operator's appointed session
/// where a binding stands, otherwise the hosted desk (design §5, §9).
///
/// **This must stay consistent with the readout's `supervisor.live == false`.**
/// The two describe the same absence from opposite ends — the readout says
/// nothing is standing in the role, this says nothing was there to deliver to —
/// and a build where one claims a live supervisor while the other refuses for
/// want of one would be lying on whichever surface a program happened to read.
/// Slice 5 changes both together or neither.
public struct SupervisorBriefingDeliverer: SupervisionBriefingDelivering {
    public init() {}

    public func deliver(project: String, text: String) async -> SupervisionBriefOutcome {
        // Deliberately never looks at `text`: the daemon does not parse a
        // briefing, and the only fact it takes from one is its size, decided
        // before this call.
        deliveryLogger.debug(
            """
            No supervisor stands for project \(project, privacy: .public); \
            briefing not delivered.
            """)
        return .noLiveSupervisor
    }
}
