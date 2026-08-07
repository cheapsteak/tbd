import Foundation
import TBDShared

extension RPCRouter {
    func handleConfigGet() async throws -> RPCResponse {
        let config = try await db.config.get()
        return try RPCResponse(result: config)
    }

    func handleConfigSetAutoArchiveDefault(_ paramsData: Data) async throws -> RPCResponse {
        let params = try decoder.decode(ConfigSetAutoArchiveDefaultParams.self, from: paramsData)
        try await db.config.setAutoArchiveOnMergeDefault(params.enabled)
        // Reuse the existing config-change channel so the app reloads Config.
        subscriptions.broadcast(delta: .modelProfilesChanged)
        return .ok()
    }

    func handleConfigSetAutoHibernateDefault(_ paramsData: Data) async throws -> RPCResponse {
        let params = try decoder.decode(ConfigSetAutoHibernateDefaultParams.self, from: paramsData)
        try await db.config.setAutoHibernateOnMergeDefault(params.enabled)
        // Reuse the existing config-change channel so the app reloads Config.
        subscriptions.broadcast(delta: .modelProfilesChanged)
        return .ok()
    }

    /// Persist the session-limit auto-resume gate. Turning it OFF cancels only
    /// the session-limit pending resumes (`.limitOnly` scope) — the transient
    /// API-error toggle owns its own rows (spec: each toggle cancels only its
    /// own scope) — and wakes the scheduler so its in-flight sleep re-evaluates.
    func handleConfigSetAutoResumeOnLimitReset(_ paramsData: Data) async throws -> RPCResponse {
        let params = try decoder.decode(ConfigSetAutoResumeOnLimitResetParams.self, from: paramsData)
        if !params.enabled {
            // Cancel before persisting the off-state so a cancel failure can never
            // leave the gate off with live pending rows, violating the feature invariant.
            _ = try await db.scheduledResumes.cancelAllPending(scope: .limitOnly)
        }
        try await db.config.setAutoResumeOnLimitReset(params.enabled)
        await limitResumeScheduler?.wake()
        // Reuse the existing config-change channel so the app reloads Config.
        subscriptions.broadcast(delta: .modelProfilesChanged)
        return .ok()
    }

    /// Persist the transient-API-error auto-continue gate. Turning it OFF
    /// cancels only the `api_error`-scoped pending resumes (`.apiErrorOnly`) —
    /// session-limit rows are left to their own toggle (spec: each toggle
    /// cancels only its own scope) — and wakes the scheduler.
    func handleConfigSetAutoResumeOnApiError(_ paramsData: Data) async throws -> RPCResponse {
        let params = try decoder.decode(ConfigSetAutoResumeOnApiErrorParams.self, from: paramsData)
        if !params.enabled {
            // Cancel before persisting the off-state so a cancel failure can never
            // leave the gate off with live pending rows, violating the feature invariant.
            _ = try await db.scheduledResumes.cancelAllPending(scope: .apiErrorOnly)
        }
        try await db.config.setAutoResumeOnApiError(params.enabled)
        await limitResumeScheduler?.wake()
        // Reuse the existing config-change channel so the app reloads Config.
        subscriptions.broadcast(delta: .modelProfilesChanged)
        return .ok()
    }

    func handleConfigSetScratchInstructions(_ paramsData: Data) async throws -> RPCResponse {
        let params = try decoder.decode(ConfigSetScratchInstructionsParams.self, from: paramsData)
        try await db.config.setScratchInstructions(params.instructions)
        // No broadcast: nothing in the app consumes a delta for this field —
        // the editor sheet fetches Config fresh on open, and the daemon reads
        // config from the DB at spawn time.
        return .ok()
    }

    func handleConfigSetScratchRenamePrompt(_ paramsData: Data) async throws -> RPCResponse {
        let params = try decoder.decode(ConfigSetScratchRenamePromptParams.self, from: paramsData)
        try await db.config.setScratchRenamePrompt(params.renamePrompt)
        // No broadcast: nothing in the app consumes a delta for this field —
        // the editor sheet fetches Config fresh on open, and the daemon reads
        // config from the DB at spawn time.
        return .ok()
    }

    func handleConfigSetScratchProfileOverride(_ paramsData: Data) async throws -> RPCResponse {
        let params = try decoder.decode(ConfigSetScratchProfileOverrideParams.self, from: paramsData)
        try await db.config.setScratchProfileOverride(params.profileID)
        // No broadcast: nothing in the app consumes a delta for this field —
        // the picker fetches Config fresh on open, and the daemon reads
        // config from the DB at spawn time.
        return .ok()
    }

    /// Persist the tmux control-mode opt-in (M5). The attach gate reads the
    /// flag per decision (`env || flag`), so this applies to newly created
    /// panes immediately — existing attached panes are not torn down.
    func handleConfigSetControlMode(_ paramsData: Data) async throws -> RPCResponse {
        let params = try decoder.decode(ConfigSetControlModeParams.self, from: paramsData)
        try await db.config.setControlModeEnabled(params.enabled)
        // Reuse the existing config-change channel so the app reloads Config.
        subscriptions.broadcast(delta: .modelProfilesChanged)
        return .ok()
    }

    /// Persist the pending-input veto for auto-hibernate (machine-interface
    /// guard that prevents hibernation of sessions with typed-but-unsent input).
    /// The hibernation sweep re-reads the flag per cycle, so this applies on
    /// the next sweep immediately — existing hibernated sessions are unaffected.
    func handleConfigSetHibernateInputVeto(_ paramsData: Data) async throws -> RPCResponse {
        let params = try decoder.decode(ConfigSetHibernateInputVetoParams.self, from: paramsData)
        try await db.config.setHibernateInputVeto(enabled: params.enabled)
        // Broadcast so the app reloads daemon capabilities.
        subscriptions.broadcast(delta: .modelProfilesChanged)
        return .ok()
    }

    /// Persist the delivery-acknowledgement soak flag (design §12). This is how
    /// an operator enables the flag for its soak — **and enabling it means
    /// restarting the daemon afterwards**, because the observation machinery is
    /// wired once at startup while this column is read per `--verify` call.
    /// Until the restart, `--verify` is refused with a message saying so.
    /// Turning it off makes `--verify` a refusal again on the next send.
    func handleConfigSetDeliveryVerification(_ paramsData: Data) async throws -> RPCResponse {
        let params = try decoder.decode(ConfigSetDeliveryVerificationParams.self, from: paramsData)
        try await db.config.setDeliveryVerification(enabled: params.enabled)
        // Broadcast so the app reloads daemon capabilities.
        subscriptions.broadcast(delta: .modelProfilesChanged)
        return .ok()
    }

    /// Persist the auto-close-setup-tab soak flag. Read fresh at spawn time,
    /// so it applies to the next worktree creation immediately — already-open
    /// setup tabs are unaffected.
    func handleConfigSetAutoCloseSetup(_ paramsData: Data) async throws -> RPCResponse {
        let params = try decoder.decode(ConfigSetAutoCloseSetupParams.self, from: paramsData)
        try await db.config.setAutoCloseSetup(enabled: params.enabled)
        // Broadcast so the app reloads daemon capabilities.
        subscriptions.broadcast(delta: .modelProfilesChanged)
        return .ok()
    }

    /// Persist the worktree auto-trust switch (default ON). Every Claude spawn
    /// and wake re-reads it, so this applies to the next one immediately.
    /// Turning it off never un-trusts a path that was already seeded — it only
    /// stops TBD from seeding new non-scratch worktrees.
    func handleConfigSetAutoTrustWorktrees(_ paramsData: Data) async throws -> RPCResponse {
        let params = try decoder.decode(ConfigSetAutoTrustWorktreesParams.self, from: paramsData)
        try await db.config.setAutoTrustWorktrees(enabled: params.enabled)
        // Broadcast so the app reloads daemon capabilities.
        subscriptions.broadcast(delta: .modelProfilesChanged)
        return .ok()
    }

    /// Persist the orphan-GC master switch. Turning it off does not cancel or
    /// undo any in-progress sweep — `OrphanGC.sweep` re-reads the flag itself
    /// on its next pass — this just flips the persisted gate.
    func handleConfigSetGCEnabled(_ paramsData: Data) async throws -> RPCResponse {
        let params = try decoder.decode(ConfigSetGCEnabledParams.self, from: paramsData)
        try await db.config.setGCEnabled(params.enabled)
        // Reuse the existing config-change channel so the app reloads Config.
        subscriptions.broadcast(delta: .modelProfilesChanged)
        return .ok()
    }

    /// Persist the remote-backends master switch. Takes effect for polling
    /// on the NEXT daemon start — the manager is constructed at boot only
    /// when the flag was already on (see `Daemon.swift`), so flipping this
    /// on alone does not start polling until a restart. `remote.*` RPC
    /// verbs re-check the flag on every call, so disabling it cuts off
    /// access immediately even without a restart.
    func handleConfigSetRemoteBackends(_ paramsData: Data) async throws -> RPCResponse {
        let params = try decoder.decode(ConfigSetRemoteBackendsParams.self, from: paramsData)
        try await db.config.setRemoteBackendsEnabled(params.enabled)
        // Reuse the existing config-change channel so the app reloads Config.
        subscriptions.broadcast(delta: .modelProfilesChanged)
        return .ok()
    }
}
