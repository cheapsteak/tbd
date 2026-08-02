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

    func handleSetNightwatchMode(_ data: Data) async throws -> RPCResponse {
        let params = try decoder.decode(NightwatchSetModeParams.self, from: data)
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
