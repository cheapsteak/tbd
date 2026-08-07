import Foundation
import TBDShared

extension RPCRouter {

    /// Append the request row for an RPC-initiated actuation.
    ///
    /// Call this in the handler **after params decode and after the target is
    /// resolved, but before the first mutating step** — never from a blanket
    /// `handle(_:)` wrapper. Three reasons: the row must carry the resolved
    /// target and the verbatim payload, which exist only after decode; a
    /// wrapper would also row malformed requests that were never about to be
    /// dispatched; and the daemon-internal rails bypass the router anyway, so a
    /// wrapper buys no completeness.
    ///
    /// Throws when the record is unwritable even after one reopen-retry. The
    /// actuation must then NOT proceed — let the error propagate so the caller
    /// sees the self-explaining message.
    func beginActuation(
        _ surface: ActuationSurface,
        actor: ActuationActor?,
        target: ActuationTarget,
        message: String? = nil,
        submit: Bool? = nil,
        verify: Bool? = nil,
        prompt: String? = nil,
        agent: String? = nil,
        profile: String? = nil
    ) async throws -> String {
        var row = ActuationRow(actor: actor ?? .anonymous, kind: surface.kind)
        row.method = surface.method
        row.target = target
        row.message = message
        row.submit = submit
        row.verify = verify
        row.prompt = prompt
        row.agent = agent
        row.profile = profile
        return try await actuationLog.appendRequest(row)
    }

    /// Append the request row for a surface's alternate branch — the same door,
    /// a different act (see `ActuationBranch`). Same placement and the same
    /// fail-closed contract as the surface overload above.
    func beginActuation(
        _ branch: ActuationBranch,
        actor: ActuationActor?,
        target: ActuationTarget
    ) async throws -> String {
        var row = ActuationRow(actor: actor ?? .anonymous, kind: branch.kind)
        row.method = branch.surface.method
        row.target = target
        return try await actuationLog.appendRequest(row)
    }

    /// Target for a surface whose params name only the terminal. Resolves the
    /// owning worktree so the row carries full coordinates; a terminal whose
    /// row has already vanished still gets a row naming what was asked for,
    /// with `worktree` absent.
    func resolvedTerminalTarget(_ terminalID: UUID) async -> ActuationTarget {
        let terminal = (try? await db.terminals.get(id: terminalID)) ?? nil
        return ActuationTarget(
            worktree: terminal?.worktreeID.uuidString, terminal: terminalID.uuidString)
    }

    /// Run one acting step of a wired handler, recording a throw as
    /// `transport-failed` before it propagates.
    ///
    /// The error is rethrown **unchanged**: the RPC's error surface must stay
    /// byte-identical, and the router's blanket catch keeps formatting it. What
    /// this adds is the outcome row that catch cannot write — without it a
    /// throw leaves the request row unconfirmed, and the record cannot tell
    /// "the act failed" from "the outcome was lost".
    func actuating<T>(_ id: String, _ step: () async throws -> T) async throws -> T {
        do {
            return try await step()
        } catch {
            await finishActuation(id, .transportFailed, error: "\(error)")
            throw error
        }
    }

    /// Append the synchronous outcome row for a request. Never fails the call:
    /// the act already ran, so a lost outcome row leaves the request
    /// unconfirmed rather than retroactively refused.
    func finishActuation(
        _ id: String, _ result: ActuationOutcome, error: String? = nil
    ) async {
        await actuationLog.appendOutcome(confirms: id, result: result, error: error)
    }

    /// Convenience for handlers whose only post-row failure mode is the daemon
    /// declining before it touches the transport. A successful response is
    /// `dispatched`; anything else is a refusal for the reason the caller names
    /// here — the handler knows what its own failure response means, and the
    /// record must not have to read it back out of the error text. Handlers
    /// that CAN fail inside the transport classify explicitly instead.
    func finishActuation(
        _ id: String, response: RPCResponse, refusedAs reason: RefusedReason
    ) async {
        if response.success {
            await finishActuation(id, .dispatched)
        } else {
            await finishActuation(id, .refused(reason), error: response.error)
        }
    }
}
