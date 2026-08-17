import Foundation
import TBDShared

extension RPCRouter {
    private func leaseSnapshot(_ lease: WatchDeskLease, now: Date = Date()) -> WatchDeskLeaseSnapshot {
        let valid = lease.isValid(at: now)
        return WatchDeskLeaseSnapshot(
            worktreeID: lease.worktreeID, terminalID: lease.terminalID,
            generation: lease.generation,
            acquiredAt: lease.acquiredAt, renewedAt: lease.renewedAt,
            expiresAt: lease.expiresAt, valid: valid,
            // A tombstoned or expired row still names its last holder, so the
            // reported role has to follow validity rather than the row's mere
            // existence. Only an unexpired holder is the judge.
            role: valid ? .judge : .readOnlyCoordinator)
    }

    /// `nightwatch.setMode`.
    ///
    /// **The single choke point for the coexistence gate**, which is why the
    /// refusal lives here rather than in the CLI or in `DaywatchRunner`: this is
    /// the one place ahead of both the DB write and `runner.apply`, so a mode
    /// that is refused here neither persists nor starts a loop.
    ///
    /// Anything but `.off` is refused while any project is under fleet
    /// supervision — the two paths watch the same fleet and are mutually
    /// exclusive until Nightwatch is retired. **`.off` is never refused**, in
    /// this direction or the other: an operator must always be able to stop
    /// either path.
    ///
    /// **The gate is check-then-act, and nothing serializes it against its twin
    /// in `handleSuperviseSetProjectMark`.** The two facts live in separate
    /// stores — the marks in `SupervisionStore`, the mode in a DB config row —
    /// and each handler reads the other's store before writing its own.
    /// `RPCRouter` is a plain class, not an actor, so two calls in flight at the
    /// same instant can both pass their precondition before either write lands,
    /// and the fleet ends up under both paths at once: precisely the state these
    /// two gates exist to prevent, and one no later read repairs by itself — an
    /// operator turns one path off. The window is narrow, because reaching it
    /// takes two operator gestures in the same instant, one per path. Closing it
    /// needs a lock shared across both handlers, which is a design decision
    /// about where supervision's writes serialize rather than a fix, and it is
    /// deliberately not made here.
    func handleSetNightwatchMode(_ data: Data) async throws -> RPCResponse {
        let params = try decoder.decode(NightwatchSetModeParams.self, from: data)
        if params.mode != .off, let supervision {
            // A store that cannot answer is not evidence that nothing is
            // supervised, so a throw here propagates rather than being read as
            // "clear to start". Failing toward refusal is the safe direction:
            // the remedy is one readable error, and `off` still works.
            let marked = try await supervision.markedProjects()
            guard marked.isEmpty else {
                throw SupervisionNightwatchConflict.nightwatchOnWhileProjectsSupervised(
                    projects: marked.sorted())
            }
        }
        try await db.config.setNightwatchMode(params.mode)
        // Apply the mode to the runner (start/stop the loop).
        if let runner = daywatchRunner {
            await runner.apply(mode: params.mode)
        }
        // Reuse the existing config-change channel so the app reloads Config.
        subscriptions.broadcast(delta: .modelProfilesChanged)
        return .ok()
    }

    func handleNightwatchLeaseStatus(_ data: Data) async throws -> RPCResponse {
        let params = try decoder.decode(NightwatchLeaseStatusParams.self, from: data)
        let lease = try await db.watchDeskLeases.status(worktreeID: params.worktreeID)
        return try RPCResponse(result: NightwatchLeaseStatusResult(
            held: lease?.isValid(at: Date()) == true,
            lease: lease.map { leaseSnapshot($0) }))
    }

    func handleNightwatchLeaseAcquire(_ data: Data) async throws -> RPCResponse {
        let params = try decoder.decode(NightwatchLeaseAcquireParams.self, from: data)
        let lease = try await db.watchDeskLeases.acquire(
            worktreeID: params.worktreeID, terminalID: params.terminalID)
        let credential = WatchDeskLeaseCredential(
            worktreeID: lease.worktreeID, terminalID: lease.terminalID,
            token: lease.token, generation: lease.generation)
        let credentialFile: String
        do {
            credentialFile = try WatchDeskLeaseCredentialFile.ensure(credential)
        } catch {
            // Never leave an authoritative row whose owner received no capability.
            try? await db.watchDeskLeases.revoke(worktreeID: params.worktreeID)
            throw error
        }
        subscriptions.broadcast(delta: .watchDeskRolesChanged(
            WorktreeIDDelta(worktreeID: params.worktreeID)))
        return try RPCResponse(result: NightwatchLeaseAcquisitionResult(
            lease: leaseSnapshot(lease), credentialFile: credentialFile))
    }

    func handleNightwatchLeaseValidate(_ data: Data) async throws -> RPCResponse {
        let params = try decoder.decode(NightwatchLeaseCredentialsParams.self, from: data)
        let lease = try await db.watchDeskLeases.validate(
            worktreeID: params.worktreeID, terminalID: params.terminalID,
            token: params.token, generation: params.generation)
        return try RPCResponse(result: leaseSnapshot(lease))
    }

    func handleNightwatchLeaseRenew(_ data: Data) async throws -> RPCResponse {
        let params = try decoder.decode(NightwatchLeaseCredentialsParams.self, from: data)
        let lease = try await db.watchDeskLeases.renew(
            worktreeID: params.worktreeID, terminalID: params.terminalID,
            token: params.token, generation: params.generation)
        return try RPCResponse(result: leaseSnapshot(lease))
    }

    func handleNightwatchLeaseTransfer(_ data: Data) async throws -> RPCResponse {
        let params = try decoder.decode(NightwatchLeaseTransferParams.self, from: data)
        // Authenticate the predecessor before touching any successor capability
        // path. The store validates again inside the transfer transaction.
        _ = try await db.watchDeskLeases.validate(
            worktreeID: params.worktreeID, terminalID: params.fromTerminalID,
            token: params.token, generation: params.generation)
        let replacementToken = UUID()
        let successorCredential = WatchDeskLeaseCredential(
            worktreeID: params.worktreeID, terminalID: params.toTerminalID,
            token: replacementToken, generation: params.generation + 1)
        // Prepare the successor capability first. If transfer fails it is inert
        // and removed; if the RPC response/delivery fails after commit, the
        // successor can still recover from its already-present file.
        let credentialFile = try WatchDeskLeaseCredentialFile.write(successorCredential)
        let lease: WatchDeskLease
        do {
            lease = try await db.watchDeskLeases.transfer(
                worktreeID: params.worktreeID, fromTerminalID: params.fromTerminalID,
                toTerminalID: params.toTerminalID, token: params.token,
                generation: params.generation, replacementToken: replacementToken)
        } catch {
            // Remove only this attempt's inert capability. A concurrent winning
            // transfer to the same terminal may already have written its own,
            // differently named credential.
            WatchDeskLeaseCredentialFile.remove(path: credentialFile)
            throw error
        }
        WatchDeskLeaseCredentialFile.remove(
            terminalID: params.toTerminalID, except: credentialFile)
        WatchDeskLeaseCredentialFile.remove(terminalID: params.fromTerminalID)
        subscriptions.broadcast(delta: .watchDeskRolesChanged(
            WorktreeIDDelta(worktreeID: params.worktreeID)))
        return try RPCResponse(result: NightwatchLeaseAcquisitionResult(
            lease: leaseSnapshot(lease), credentialFile: credentialFile))
    }

    func handleNightwatchLeaseRelease(_ data: Data) async throws -> RPCResponse {
        let params = try decoder.decode(NightwatchLeaseCredentialsParams.self, from: data)
        try await db.watchDeskLeases.release(
            worktreeID: params.worktreeID, terminalID: params.terminalID,
            token: params.token, generation: params.generation)
        WatchDeskLeaseCredentialFile.remove(terminalID: params.terminalID)
        subscriptions.broadcast(delta: .watchDeskRolesChanged(
            WorktreeIDDelta(worktreeID: params.worktreeID)))
        return .ok()
    }
}
