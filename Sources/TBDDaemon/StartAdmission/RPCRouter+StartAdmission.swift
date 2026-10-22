import Foundation
import TBDShared
import os

private let logger = Logger(subsystem: "com.tbd.daemon", category: "start-admission")

extension RPCRouter {

    /// Which agent a wake of this row would start, or nil when the wake starts
    /// no agent and so is not checked.
    ///
    /// Only a parked row can start anything: a wake of a live one is answered
    /// as a no-op and must stay that way. Of the parked rows, the wake path
    /// resumes a Claude session when the tab is Claude's by kind (a nil kind
    /// counts, as `Terminal.claudeResumeDecision` reads it) and has a session
    /// to resume; a Codex tab is checked by its kind.
    static func startAdmissionAgent(forWaking terminal: Terminal) -> StartAdmissionAgent? {
        guard terminal.isParked else { return nil }
        if terminal.isCodexTerminal { return .codex }
        if case .resume = terminal.claudeResumeDecision { return .claude }
        return nil
    }

    /// Which agent a transport migration of this row would start again, or nil
    /// when the move starts no agent and so is not checked.
    ///
    /// Only a running Claude session with a conversation is relaunched: it is
    /// parked and woken on the holder. A parked row is only rewritten, a
    /// running shell restarts as a shell, and the rows the migrator skips
    /// (Codex tabs among them) start nothing.
    static func startAdmissionAgent(forMigrating terminal: Terminal) -> StartAdmissionAgent? {
        guard TransportMigrationEligibility.decide(terminal) == .eligible,
              !terminal.isParked,
              terminal.claudeResumeDecision.resumableSessionID != nil else { return nil }
        return .claude
    }

    /// The start-admission gate for a create-kind start. Call right after
    /// `beginActuation` and before the first step that changes anything.
    ///
    /// Returns nil to proceed: the actor is not checked, the flag is off, or
    /// the command admitted. Returns the failure to hand back when the start is
    /// held, after closing the actuation row as `refused(.held)` with the
    /// command's reason.
    ///
    /// `earlierHold` is the reason a previous start in the same call was held
    /// for. A call that starts several agents asks before each one until the
    /// first hold, then holds the rest with that reason without running the
    /// command again, so a slow command delays the call once and not once per
    /// agent.
    func holdStartIfDenied(
        _ actuationID: String,
        actor: ActuationActor?,
        kind: StartAdmissionKind = .create,
        agent: StartAdmissionAgent,
        worktreeID: UUID,
        terminalID: UUID? = nil,
        earlierHold: String? = nil
    ) async -> RPCResponse? {
        guard StartAdmissionActorRule.isChecked(actor) else { return nil }
        let verdict = await admissionVerdict(
            earlierHold: earlierHold,
            StartAdmissionRequest(
                kind: kind, agent: agent, actorKind: (actor ?? .anonymous).kind,
                worktreeID: worktreeID, terminalID: terminalID))
        guard case .hold(let reason)? = verdict else { return nil }
        await finishActuation(actuationID, .refused(.held), error: reason)
        return Self.heldResponse(reason)
    }

    /// The start-admission gate for a wake. Call right after `beginActuation`.
    ///
    /// A terminal that is missing, not parked, or not an agent tab is not
    /// checked, so the wake path answers it exactly as it did before. A held
    /// wake records the reason and the time on the row and publishes the row,
    /// so the parked pane can say why it is still asleep. If the row was woken or
    /// re-parked while the command ran, nothing is written. `earlierHold` is as
    /// for `holdStartIfDenied`.
    func holdWakeIfDenied(
        _ actuationID: String, actor: ActuationActor?, terminalID: UUID,
        earlierHold: String? = nil
    ) async -> RPCResponse? {
        guard StartAdmissionActorRule.isChecked(actor) else { return nil }
        guard let terminal = (try? await db.terminals.get(id: terminalID)) ?? nil,
              let agent = Self.startAdmissionAgent(forWaking: terminal) else { return nil }
        let verdict = await admissionVerdict(
            earlierHold: earlierHold,
            StartAdmissionRequest(
                kind: .wake, agent: agent, actorKind: (actor ?? .anonymous).kind,
                worktreeID: terminal.worktreeID, terminalID: terminalID))
        guard case .hold(let reason)? = verdict else { return nil }
        await finishActuation(actuationID, .refused(.held), error: reason)
        do {
            let wrote = try await db.terminals.setStartHeld(
                id: terminalID, reason: reason,
                expectedIncarnationID: terminal.sessionIncarnationID, at: now())
            if wrote, let held = try await db.terminals.get(id: terminalID) {
                subscriptions.broadcast(delta: .terminalReplaced(held))
            }
        } catch {
            logger.error("could not record a held wake on terminal \(terminalID, privacy: .public): \(error.localizedDescription, privacy: .public)")
        }
        return Self.heldResponse(reason)
    }

    static func heldResponse(_ reason: String, leftovers: [String] = []) -> RPCResponse {
        let message = leftovers.isEmpty
            ? reason
            : "\(reason) (the start was held, but cleanup failed; remove by hand: \(leftovers.joined(separator: "; ")))"
        return RPCResponse(error: message, code: RPCErrorCode.startHeld.rawValue)
    }

    /// The answer for one checked start, or nil when the flag is off. An
    /// earlier hold in the same call is the answer without asking: that call
    /// already read the flag as on.
    private func admissionVerdict(
        earlierHold: String?, _ request: StartAdmissionRequest
    ) async -> StartAdmissionVerdict? {
        if let earlierHold { return .hold(reason: earlierHold) }
        guard await startAdmissionEnabled() else { return nil }
        return await startAdmission.evaluate(request)
    }

    /// The flag, read on every start so a change takes effect at the next one.
    /// A config that cannot be read reads as nobody having chosen.
    private func startAdmissionEnabled() async -> Bool {
        guard let config = try? await db.config.get() else { return Config.startAdmissionDefault }
        return config.startAdmissionEnabled
    }
}
