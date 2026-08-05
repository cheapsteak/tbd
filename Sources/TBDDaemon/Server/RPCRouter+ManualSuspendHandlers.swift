import Foundation
import TBDShared

/// Backward-compat shims for the retired Suspend/Resume RPCs.
///
/// The Suspend feature merged into Hibernation (one unified "park" state). We
/// KEEP these RPC methods alive so old CLI/app builds that still call
/// `terminal.suspend` / `terminal.resume` / `worktree.suspend` /
/// `worktree.resume` keep working — but they now route to the unified
/// `HibernationCoordinator`:
///   - `terminal.suspend`  → `manualHibernate`
///   - `terminal.resume`   → `wake`
///   - `worktree.suspend`  → hibernate every eligible Claude terminal
///   - `worktree.resume`   → wake every parked Claude terminal
extension RPCRouter {

    func handleTerminalSuspend(
        _ paramsData: Data, actor: ActuationActor? = nil
    ) async throws -> RPCResponse {
        let params = try decoder.decode(TerminalSuspendParams.self, from: paramsData)
        let actuationID = try await beginActuation(
            .terminalSuspend, actor: actor,
            target: await resolvedTerminalTarget(params.terminalID))
        // Parking (formerly suspend) routes to the unified HibernationCoordinator.
        // Cancel any pending auto-resume up-front and unconditionally (spec
        // §Cancellation, preserving #341's shim behavior): the intent to park
        // means "don't send an unattended resume", even if the actual park is
        // then refused (session-less, running, etc.). performHibernate also
        // cancels on a successful park; the up-front cancel covers the refused
        // case. Wake the scheduler so it re-reads pending rows.
        if (try? await db.scheduledResumes.cancelPending(terminalID: params.terminalID)) == true {
            await limitResumeScheduler?.wake()
        }
        let result = await hibernationCoordinator.manualHibernate(terminalID: params.terminalID)
        await finishActuation(
            actuationID, ActuationResult.classify(result),
            error: ActuationResult.detail(result))
        switch result {
        case .ok, .alreadyHibernated:
            return .ok()
        case .notEligible(let reason):
            return RPCResponse(error: reason)
        case .notFound:
            return RPCResponse(error: "Terminal not found")
        }
    }

    func handleTerminalResume(
        _ paramsData: Data, actor: ActuationActor? = nil
    ) async throws -> RPCResponse {
        let params = try decoder.decode(TerminalResumeParams.self, from: paramsData)
        let actuationID = try await beginActuation(
            .terminalResume, actor: actor,
            target: await resolvedTerminalTarget(params.terminalID))
        let result = await hibernationCoordinator.wake(terminalID: params.terminalID)
        await finishActuation(
            actuationID, ActuationResult.classify(result),
            error: ActuationResult.detail(result))
        switch result {
        case .ok, .notHibernated, .inFlight:
            // notHibernated / inFlight are benign no-ops for an idempotent wake.
            return .ok()
        case .notFound:
            return RPCResponse(error: "Terminal not found")
        case .noSessionID:
            return RPCResponse(error: "No session ID to resume")
        case .respawnFailed(let reason):
            // The terminal row exists — the tmux respawn/recreate failed.
            // Surface the real failure, never "Terminal not found".
            return RPCResponse(error: reason)
        case .worktreeMissing(let path):
            return RPCResponse(error: "Worktree directory missing on disk: \(path). Restore the directory (or relocate the repo), then retry — the session stays parked and resumable.")
        case .profileMissing(let profileID):
            return RPCResponse(
                error: "This session was pinned to an account profile (\(profileID.uuidString)) that no longer exists. It stays parked and resumable — wake it on your default account, or restore the profile and retry.",
                code: RPCErrorCode.profileMissing.rawValue)
        }
    }

    func handleWorktreeSuspend(
        _ paramsData: Data, actor: ActuationActor? = nil
    ) async throws -> RPCResponse {
        let params = try decoder.decode(WorktreeSuspendParams.self, from: paramsData)
        guard let terminals = try? await db.terminals.list(worktreeID: params.worktreeID) else {
            return RPCResponse(error: "Worktree not found")
        }

        // Parking cancels any pending auto-resume (spec §Cancellation). Each
        // manualHibernate also cancels its own row, but cancel up-front so a
        // terminal that's ineligible to park (and thus skipped below) still has
        // its stale pending resume cleared, then wake the scheduler once.
        for terminal in terminals where terminal.pendingResumeAt != nil {
            _ = try? await db.scheduledResumes.cancelPending(terminalID: terminal.id)
        }
        await limitResumeScheduler?.wake()

        let eligible = terminals.filter { $0.isManuallyHibernatable }

        // Fire in background — RPC returns immediately so the app can show
        // the parking overlay while the daemon does its work.
        //
        // One row per terminal, written at THAT terminal's own act moment
        // rather than one row for the fan-out: the record's unit is an
        // actuation on a session. A terminal whose request row cannot be
        // persisted is skipped (fail-closed) — the RPC already returned, so
        // there is nothing left to refuse but the act itself.
        let worktreeID = params.worktreeID
        Task { [hibernationCoordinator, actuationLog] in
            for terminal in eligible {
                var row = ActuationRow(actor: actor ?? .anonymous, kind: ActuationSurface.worktreeSuspend.kind)
                row.method = ActuationSurface.worktreeSuspend.method
                row.target = .local(worktree: worktreeID, terminal: terminal.id)
                guard let actuationID = try? await actuationLog.appendRequest(row) else { continue }
                let result = await hibernationCoordinator.manualHibernate(terminalID: terminal.id)
                await actuationLog.appendOutcome(
                    confirms: actuationID,
                    result: ActuationResult.classify(result),
                    error: ActuationResult.detail(result))
            }
        }

        return .ok()
    }

    func handleWorktreeResume(
        _ paramsData: Data, actor: ActuationActor? = nil
    ) async throws -> RPCResponse {
        let params = try decoder.decode(WorktreeResumeParams.self, from: paramsData)
        guard let terminals = try? await db.terminals.list(worktreeID: params.worktreeID) else {
            return RPCResponse(error: "Worktree not found")
        }

        // Wake every parked terminal (authoritative or legacy). The coordinator
        // is an actor so calls serialize anyway.
        // One row per terminal, at each terminal's own act moment (see the
        // note in `handleWorktreeSuspend`). This fan-out runs inline, so an
        // unwritable record fails the RPC — but only the terminals whose rows
        // had not been written yet are spared: the wakes already performed
        // stand, each with its own request and outcome row, and the error the
        // caller sees names a fan-out that stopped partway.
        let parked = terminals.filter { $0.isParked && $0.isClaudeResumable }
        for terminal in parked {
            let actuationID = try await beginActuation(
                .worktreeResume, actor: actor,
                target: .local(worktree: params.worktreeID, terminal: terminal.id))
            let result = await hibernationCoordinator.wake(terminalID: terminal.id)
            await finishActuation(
                actuationID, ActuationResult.classify(result),
                error: ActuationResult.detail(result))
        }

        return .ok()
    }
}
