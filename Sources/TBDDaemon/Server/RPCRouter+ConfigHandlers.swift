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

    /// Persist the queued-prompt soak flag (design 2026-08-10). Read fresh at
    /// spawn time and on every `worktree.setPendingPrompt`, so it applies to
    /// the next worktree creation immediately — no daemon restart.
    ///
    /// Either value is an explicit gesture that takes the backing column out of
    /// its NULL "never chose" state for good, which is deliberate: an operator
    /// who turns the feature off stays off when the shipped default graduates.
    func handleConfigSetQueuedPrompt(_ paramsData: Data) async throws -> RPCResponse {
        let params = try decoder.decode(ConfigSetQueuedPromptParams.self, from: paramsData)
        try await db.config.setQueuedPrompt(params.enabled)
        // Broadcast so the app reloads daemon capabilities.
        subscriptions.broadcast(delta: .modelProfilesChanged)
        return .ok()
    }

    /// Persist whether ordinary new worktrees start with an empty Notes tab.
    /// The create lifecycle snapshots this setting per creation, so the change
    /// applies to the next worktree without a daemon restart.
    func handleConfigSetAutoCreateNotes(_ paramsData: Data) async throws -> RPCResponse {
        let params = try decoder.decode(ConfigSetAutoCreateNotesParams.self, from: paramsData)
        try await db.config.setAutoCreateNotes(params.enabled)
        subscriptions.broadcast(delta: .modelProfilesChanged)
        return .ok()
    }

    /// Persist the Claude cloud sessions gate (design 2026-08-15 §7).
    ///
    /// The daemon builds its provider manager, and registers the built-in
    /// provider into it, only at boot — so unlike the queued-prompt flag this
    /// one does NOT take effect on the next gesture.
    /// `DaemonCapabilitiesResult.claudeCloudLive` is what tells the user
    /// whether a restart is still owed.
    func handleConfigSetClaudeCloud(_ paramsData: Data) async throws -> RPCResponse {
        let params = try decoder.decode(ConfigSetClaudeCloudParams.self, from: paramsData)
        try await db.config.setClaudeCloud(params.enabled)
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

    /// Persist the profile-dir collector gate — the default-off soak switch for
    /// reclaiming orphaned `~/tbd/profiles/<uuid>/` directories, read on top of
    /// the GC master switch. Like that master switch, flipping it off does not
    /// cancel an in-progress sweep: `OrphanGC.sweep` re-reads the flag on its
    /// next pass.
    func handleConfigSetGCProfileDirsEnabled(_ paramsData: Data) async throws -> RPCResponse {
        let params = try decoder.decode(ConfigSetGCProfileDirsEnabledParams.self, from: paramsData)
        try await db.config.setGCProfileDirsEnabled(params.enabled)
        // Reuse the existing config-change channel so the app reloads Config.
        subscriptions.broadcast(delta: .modelProfilesChanged)
        return .ok()
    }

    /// Persist the holder rendezvous sweep gate — the default-off soak switch
    /// for unlinking the socket, lock and log a dead holder left behind, read
    /// on top of the GC master switch. Like that master switch, flipping it off
    /// does not cancel an in-progress sweep: `OrphanGC.sweep` re-reads the flag
    /// on its next pass.
    func handleConfigSetGCHolderRendezvousEnabled(_ paramsData: Data) async throws -> RPCResponse {
        let params = try decoder.decode(
            ConfigSetGCHolderRendezvousEnabledParams.self, from: paramsData)
        try await db.config.setGCHolderRendezvousEnabled(params.enabled)
        // Reuse the existing config-change channel so the app reloads Config.
        subscriptions.broadcast(delta: .modelProfilesChanged)
        return .ok()
    }

    /// Persist the row-less holder sweep gate — the default-off soak switch for
    /// killing a pty holder this installation owns which no session row claims,
    /// read on top of the GC master switch. Deliberately a different verb from
    /// the rendezvous gate above: enabling file cleanup must never enable a
    /// process killer. Like the master switch, flipping it off does not cancel
    /// an in-progress sweep: `OrphanGC.sweep` re-reads the flag on its next
    /// pass.
    func handleConfigSetGCRowlessHoldersEnabled(_ paramsData: Data) async throws -> RPCResponse {
        let params = try decoder.decode(
            ConfigSetGCRowlessHoldersEnabledParams.self, from: paramsData)
        try await db.config.setGCRowlessHoldersEnabled(params.enabled)
    /// Persist the `AgentReaper` holder leg's gate — the default-off soak
    /// switch for killing the surviving job of a dead pty holder.
    ///
    /// This is how the soak is turned on. Flipping it off does not cancel an
    /// in-progress sweep: the reaper task re-reads the flag on its next pass,
    /// the same contract the GC gates keep.
    func handleConfigSetReapHolderChildrenEnabled(_ paramsData: Data) async throws -> RPCResponse {
        let params = try decoder.decode(
            ConfigSetReapHolderChildrenEnabledParams.self, from: paramsData)
        try await db.config.setReapHolderChildrenEnabled(params.enabled)
        // Reuse the existing config-change channel so the app reloads Config.
        subscriptions.broadcast(delta: .modelProfilesChanged)
        return .ok()
    }

    /// Persist the orphaned-process collector gate — the default-off soak
    /// switch for reclaiming processes that outlived the worktree they were
    /// rooted in, read on top of the GC master switch.
    ///
    /// This is how the soak is turned on. Its sibling gates all have an RPC,
    /// and this one is the phase that signals processes, so leaving it
    /// reachable only by hand-editing `~/tbd/state.db` would have made the one
    /// irreversible phase the one with no supported way to enable it — against
    /// a database the project's own rules say not to go behind.
    ///
    /// Like the master switch, flipping it off does not cancel an in-progress
    /// sweep: `OrphanGC.sweep` re-reads the flag on its next pass.
    func handleConfigSetGCOrphanProcessesEnabled(_ paramsData: Data) async throws -> RPCResponse {
        let params = try decoder.decode(
            ConfigSetGCOrphanProcessesEnabledParams.self, from: paramsData)
        try await db.config.setGCOrphanProcessesEnabled(params.enabled)
        // Reuse the existing config-change channel so the app reloads Config.
        subscriptions.broadcast(delta: .modelProfilesChanged)
        return .ok()
    }

    /// Persist the fleet supervision brake (design 2026-07-26 §3, §7) — the
    /// fleet-wide on/off switch for supervision. Shipped OFF; nothing in the
    /// daemon reads this column to gate an actuation yet, because the acting
    /// half of supervision (the sweep, deliveries, actuation preconditions)
    /// lands in later slices. What the column already does is decide what
    /// `supervise.status` reports and what the heartbeat publishes.
    ///
    /// The change is recorded in the supervision ledger, and **the line carries
    /// no project and no mode**: the brake is one bit over the whole fleet, so
    /// naming a project on its line would be a lie. That holds by construction
    /// — the factories behind `applyBrakeChange` take no project.
    ///
    /// The column is written on every call, because writing either value is the
    /// explicit gesture that lifts it out of NULL forever after. The *ledger*
    /// line is written only when the resolved brake actually moved: sending
    /// `false` while the brake already stands engaged is a gesture on the
    /// column but no change to what the brake means, and a gesture that changes
    /// nothing is not a decision.
    func handleConfigSetSupervisionEnabled(_ paramsData: Data) async throws -> RPCResponse {
        let params = try decoder.decode(ConfigSetSupervisionEnabledParams.self, from: paramsData)
        // One serialized region per transition: the store holds a gate across
        // the commit *and* the line it justifies, so two overlapping toggles
        // cannot commit in one order and reach the record in the other. The
        // transaction inside `commit` makes the column atomic; the gate is what
        // keeps the record's order from contradicting it.
        let commit: @Sendable () async throws -> Bool = { [db] in
            try await db.config.setSupervisionEnabled(enabled: params.enabled)
        }
        if let supervision {
            // The transition's ordering token travels with the edge, so the
            // heartbeat can discard a toggle that lost its race in the gate.
            // Notifying from out here rather than from inside the gate is
            // deliberate: publishing performs a file write, and every brake
            // gesture would otherwise pay for it inside the serialized region.
            let transition = try await supervision.applyBrakeChange(
                released: params.enabled, commit: commit)
            await supervisionHeartbeat?.applyBrake(
                released: params.enabled, sequence: transition.sequence)
        } else {
            // Nothing to keep in step with, so the column moves on its own. The
            // brake is a daemon-wide switch and must not depend on supervision
            // being wired — see `brakeWorksWithoutAStore`.
            _ = try await commit()
        }
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

    /// Persist the remote peer-messaging gate — the default-off soak switch for
    /// shadow peers and the provider `messages` stream. This is how the soak is
    /// turned on: the flag is the feature's only opt-in, and leaving it
    /// reachable only by hand-editing `~/tbd/state.db` would put the sole way
    /// to enable it behind a database the project's own rules say not to go
    /// into.
    ///
    /// **It does not take effect until the daemon restarts.** The gate is read
    /// where a provider's streams are armed (`RemoteProviderManager`), so
    /// flipping it on builds no bridge for a provider whose loops are already
    /// running, and flipping it off leaves a running bridge up. `tbd peer list`
    /// and `peer.status` are what say whether a restart is still owed.
    ///
    /// The column is written on every call, because writing either value is the
    /// explicit gesture that lifts it out of NULL forever after.
    func handleConfigSetRemotePeerMessagingEnabled(
        _ paramsData: Data
    ) async throws -> RPCResponse {
        let params = try decoder.decode(
            ConfigSetPeerMessagingEnabledParams.self, from: paramsData)
        try await db.config.setRemotePeerMessagingEnabled(params.enabled)
        // Reuse the existing config-change channel so the app reloads Config.
        subscriptions.broadcast(delta: .modelProfilesChanged)
        return .ok()
    }

    /// Persist the pty-holder transport gate — the default-off soak switch for
    /// spawning sessions onto a holder process rather than into a tmux window.
    /// This is how the soak is turned on: the flag is the feature's only opt-in,
    /// and leaving it reachable only by hand-editing `~/tbd/state.db` would put
    /// the sole way to enable it behind a database the project's own rules say
    /// not to go into.
    ///
    /// **It applies to sessions created after the call, and to no others.** A
    /// session records its transport at creation and keeps it for life, so
    /// flipping this on never moves a running tmux session onto a holder, and
    /// flipping it off never takes a live holder session away.
    ///
    /// The column is written on every call, because writing either value is the
    /// explicit gesture that lifts it out of NULL forever after.
    func handleConfigSetPtyHolderEnabled(_ paramsData: Data) async throws -> RPCResponse {
        let params = try decoder.decode(
            ConfigSetPtyHolderEnabledParams.self, from: paramsData)
        try await db.config.setPtyHolderEnabled(params.enabled)
        // Reuse the existing config-change channel so the app reloads Config.
        subscriptions.broadcast(delta: .modelProfilesChanged)
        return .ok()
    }
}
