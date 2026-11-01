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

    /// Persist the global park-on-merge default. Park-on-merge is automatic
    /// parking, which holds the composer-draft feature on, so the write
    /// re-syncs the plugin when it changes the features on.
    func handleConfigSetAutoHibernateDefault(_ paramsData: Data) async throws -> RPCResponse {
        let params = try decoder.decode(ConfigSetAutoHibernateDefaultParams.self, from: paramsData)
        try await writeAffectingAutomaticParking {
            try await db.config.setAutoHibernateOnMergeDefault(params.enabled)
        }
        // Reuse the existing config-change channel so the app reloads Config.
        subscriptions.broadcast(delta: .modelProfilesChanged)
        return .ok()
    }

    /// Runs a write that can turn automatic parking on or off — the idle
    /// sweep, the global park-on-merge default, a worktree's park-on-merge
    /// override — and with it the composer-draft feature, which automatic
    /// parking holds on (`ConfigRecord.toModel`). Re-syncs the plugin when the
    /// session-mod features the config turns on differ after the write, and
    /// leaves the plugin alone when they do not. A config that cannot be read
    /// before the write counts as a change.
    ///
    /// - Returns: whether the composer-draft state Settings shows changed: the
    ///   effective value, or whether automatic parking holds it on.
    /// Design: docs/specs/2026-10-24-mod-only-park-guard-design.md.
    @discardableResult
    func writeAffectingAutomaticParking(
        _ write: () async throws -> Void
    ) async throws -> Bool {
        let before = try? await db.config.get()
        try await write()
        let after = try await db.config.get()
        let features = SessionModFeature.enabled(in: after)
        if let sessionModPluginSync,
           before.map({ SessionModFeature.enabled(in: $0) }) != features {
            sessionModPluginSync(features)
        }
        guard let before else { return true }
        return before.composerDraftEnabled != after.composerDraftEnabled
            || before.composerDraftRequiredByAutoPark != after.composerDraftRequiredByAutoPark
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

    /// Persist whether ordinary new worktrees open an empty "Notes" note as a
    /// worktree panel. The create lifecycle snapshots this setting per creation, so the change
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

    /// Persist the retained-transcript GC gate — the default-off soak switch
    /// for the `OrphanGC` leg that unlinks retained transcripts nobody
    /// references and drops receipts whose expiry has passed, read on top of
    /// the GC master switch.
    ///
    /// This is how the soak is turned on. Deliberately a different verb from
    /// the remote-delete gate below: enabling a local reclaimer must never
    /// enable the one verb that destroys a session on a provider. Like the
    /// master switch, flipping it off does not cancel an in-progress sweep:
    /// `OrphanGC.sweep` re-reads the flag on its next pass.
    func handleConfigSetGCRetainedTranscriptsEnabled(_ paramsData: Data) async throws -> RPCResponse {
        let params = try decoder.decode(
            ConfigSetGCRetainedTranscriptsParams.self, from: paramsData)
        try await db.config.setGCRetainedTranscriptsEnabled(params.enabled)
        // Reuse the existing config-change channel so the app reloads Config.
        subscriptions.broadcast(delta: .modelProfilesChanged)
        return .ok()
    }

    /// Persist the remote-delete gate — the default-off soak switch for
    /// `remote.delete`, the verb that destroys a provider-hosted session.
    ///
    /// This is how the soak is turned on. Every other flag in this file gates
    /// something a reconciler could undo; this one gates the single act that
    /// nothing on this machine can reverse, which is exactly why it must have a
    /// supported switch rather than being reachable only by hand-editing the
    /// database. Flipping it off refuses the next delete; it cannot recall one
    /// already made.
    func handleConfigSetRemoteDeleteEnabled(_ paramsData: Data) async throws -> RPCResponse {
        let params = try decoder.decode(
            ConfigSetRemoteDeleteEnabledParams.self, from: paramsData)
        try await db.config.setRemoteDeleteEnabled(params.enabled)
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

    /// Persist the hang-stack reclaimer gate — the default-off soak switch for
    /// bounding `~/Library/Logs/TBD/hang-stacks/` by age and by count, read on
    /// top of the GC master switch.
    ///
    /// The broadcast is load-bearing beyond refreshing the Settings → Cleanup
    /// toggle: the app mirrors the resolved value into `HangStackWriter`'s
    /// write-time cap, so this delta is how the write side of the policy
    /// learns it was turned on without waiting for a relaunch.
    ///
    /// Like the master switch, flipping it off does not cancel an in-progress
    /// sweep: `OrphanGC.sweep` re-reads the flag on its next pass.
    func handleConfigSetGCHangStacksEnabled(_ paramsData: Data) async throws -> RPCResponse {
        let params = try decoder.decode(
            ConfigSetGCHangStacksEnabledParams.self, from: paramsData)
        try await db.config.setGCHangStacksEnabled(params.enabled)
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

    /// Persist the pty-holder transport gate — the switch that decides whether
    /// a session is spawned onto a holder process or into a tmux window. The
    /// flag is the feature's only switch in either direction, and leaving it
    /// reachable only by hand-editing `~/tbd/state.db` would put the sole way
    /// to move off the default behind a database the project's own rules say
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

    /// Persist the transcript-streaming gate — the default-off soak switch for
    /// the session mod's `transcript-stream` feature and the provisional rows
    /// the transcript pane reads from it.
    ///
    /// **It applies to sessions created after the call**: the feature list is
    /// fixed in a session's environment at spawn.
    ///
    /// The `tbd` plugin on disk is brought in line with the new feature set,
    /// as the composer-draft gate does: the session mod is present while any
    /// feature's flag is on.
    /// Design: docs/specs/2026-10-20-transcript-stream-mod-design.md.
    func handleConfigSetTranscriptStreamingEnabled(
        _ paramsData: Data
    ) async throws -> RPCResponse {
        let params = try decoder.decode(
            ConfigSetTranscriptStreamingParams.self, from: paramsData)
        try await db.config.setTranscriptStreamingEnabled(params.enabled)
        // Reuse the existing config-change channel so the app reloads Config.
        subscriptions.broadcast(delta: .modelProfilesChanged)
        if let sessionModPluginSync {
            let config = try await db.config.get()
            sessionModPluginSync(SessionModFeature.enabled(in: config))
        }
        return .ok()
    }

    /// Persist the update mode — the daemon's only policy about updating
    /// itself, and the default-off gate on a feature that rebuilds and replaces
    /// the whole installation.
    ///
    /// **It takes effect on the daemon already running**, with no restart in
    /// any direction. A flip to `check` or `auto` starts the checker's periodic
    /// loop from here, which is what a daemon that booted in the shipped `off`
    /// needs — nothing was spawned at boot then, by design. `UpdateChecker.start()`
    /// is idempotent, so a loop already ticking keeps its own cadence instead
    /// of gaining a second one. A flip to `off` starts nothing and stops
    /// nothing: every tick reads the column fresh, so the next one simply does
    /// no work. `tbd version --check` and the app's "Check for Updates…" work
    /// regardless, since an explicit question is not the thing this flag gates.
    ///
    /// The column is written on every call, because writing any value is the
    /// explicit gesture that lifts it out of NULL forever after.
    func handleConfigSetUpdateMode(_ paramsData: Data) async throws -> RPCResponse {
        let params = try decoder.decode(ConfigSetUpdateModeParams.self, from: paramsData)
        try await db.config.setUpdateMode(params.mode)
        if params.mode.runsChecks {
            await updateChecker?.start()
        }
        // Reuse the existing config-change channel so the app reloads Config.
        subscriptions.broadcast(delta: .modelProfilesChanged)
        return .ok()
    }

    /// Persist the profile balancing gate (default OFF, soaking) — the launch
    /// policy that spreads new sessions across the profiles with the most room
    /// (design 2026-09-05 §6). The column is written on every call, because
    /// writing either value is the explicit gesture that lifts it out of NULL
    /// forever after.
    func handleConfigSetProfileBalancingEnabled(_ paramsData: Data) async throws -> RPCResponse {
        let params = try decoder.decode(
            ConfigSetProfileBalancingEnabledParams.self, from: paramsData)
        try await db.config.setProfileBalancingEnabled(params.enabled)
        // Reuse the existing config-change channel so the app reloads Config.
        subscriptions.broadcast(delta: .modelProfilesChanged)
        return .ok()
    }

    /// Persist balancing's usage ceiling (design 2026-09-05 §5). A value outside
    /// `ProfilePoolPolicy.usageCeilingRange` is refused rather than clamped: a
    /// typo should say so, not quietly become some other threshold. Nil
    /// returns the column to NULL, the shipped default.
    func handleConfigSetProfileBalancingUsageCeiling(_ paramsData: Data) async throws -> RPCResponse {
        let params = try decoder.decode(
            ConfigSetBalancingUsageCeilingParams.self, from: paramsData)
        let range = ProfilePoolPolicy.usageCeilingRange
        if let percent = params.percent, !range.contains(percent) {
            return RPCResponse(
                error: "Usage ceiling must be between \(range.lowerBound) and \(range.upperBound) percent, got \(percent)")
        }
        try await db.config.setProfileBalancingUsageCeilingPercent(params.percent)
        subscriptions.broadcast(delta: .modelProfilesChanged)
        return .ok()
    }

    /// Persist balancing's maximum reading age. Refused outside
    /// `ProfilePoolPolicy.maxReadingAgeRange`, for the same reason as the
    /// ceiling. Nil returns the column to NULL, each kind's own window.
    func handleConfigSetProfileBalancingMaxReadingAge(_ paramsData: Data) async throws -> RPCResponse {
        let params = try decoder.decode(
            ConfigSetBalancingMaxReadingAgeParams.self, from: paramsData)
        let range = ProfilePoolPolicy.maxReadingAgeRange
        if let seconds = params.seconds, !range.contains(seconds) {
            return RPCResponse(
                error: "Maximum reading age must be between \(range.lowerBound) and \(range.upperBound) seconds, got \(seconds)")
        }
        try await db.config.setProfileBalancingMaxReadingAgeSeconds(params.seconds)
        subscriptions.broadcast(delta: .modelProfilesChanged)
        return .ok()
    }

    /// Persist the schedule-based PR polling gate (default OFF, soaking) and
    /// apply it at once: the daemon stops the running PR driver and starts the
    /// other (`PRPollDriverSwitch`). The write happens inside the switch's
    /// serialized section, so two concurrent calls cannot leave the column and
    /// the running driver disagreeing. The switch is inert until the daemon
    /// arms it at start-up, so in mock mode (and in a test's router) this only
    /// writes the column. Design: docs/specs/2026-10-01-pr-polling-schedule-design.md.
    func handleConfigSetPRPollScheduleEnabled(_ paramsData: Data) async throws -> RPCResponse {
        let params = try decoder.decode(
            ConfigSetPRPollScheduleEnabledParams.self, from: paramsData)
        let enabled = params.enabled
        let config = db.config
        try await prPollDriverSwitch.apply(PRPollDriver.kind(enabled: enabled)) {
            try await config.setPRPollScheduleEnabled(enabled)
        }
        // Reuse the existing config-change channel so the app reloads Config.
        subscriptions.broadcast(delta: .modelProfilesChanged)
        return .ok()
    }

    /// Persist the transcript prompt-answer gate (default OFF while it soaks).
    /// Hook changes reach a session on its next start; the answer RPCs read the
    /// column on every call, so they follow the toggle at once.
    func handleConfigSetTranscriptPromptAnswerEnabled(_ paramsData: Data) async throws -> RPCResponse {
        let params = try decoder.decode(ConfigSetPromptAnswerParams.self, from: paramsData)
        try await db.config.setTranscriptPromptAnswerEnabled(params.enabled)
        subscriptions.broadcast(delta: .modelProfilesChanged)
        // Add or remove the session mod's prompt-answer feature in the plugin;
        // the features come from the fresh config, as for the composer draft.
        if let sessionModPluginSync {
            let config = try await db.config.get()
            sessionModPluginSync(SessionModFeature.enabled(in: config))
        }
        return .ok()
    }

    /// Persist the live remote transcript sync gate (default OFF, soaking).
    /// Nothing caches it: every decision reads it fresh, so it applies on the
    /// next sync without a restart. Turning it off also drops background
    /// sync's queue at once, rather than leaving it to the next dequeue's
    /// read of the flag. Design:
    /// docs/specs/2026-09-25-remote-session-transcript-design.md § Gating.
    func handleConfigSetRemoteTranscriptLiveSyncEnabled(_ paramsData: Data) async throws -> RPCResponse {
        let params = try decoder.decode(
            ConfigSetRemoteLiveSyncEnabledParams.self, from: paramsData)
        try await db.config.setRemoteTranscriptLiveSyncEnabled(params.enabled)
        if !params.enabled {
            await remoteTranscriptBackgroundSync?.dropAll()
        }
        // Reuse the existing config-change channel so the app reloads Config.
        subscriptions.broadcast(delta: .modelProfilesChanged)
        return .ok()
    }

    /// Persist the the start admission gate flag (default OFF). Read on every use, so a
    /// change takes effect at the next request.
    func handleConfigSetStartAdmissionEnabled(_ paramsData: Data) async throws -> RPCResponse {
        let params = try decoder.decode(ConfigSetStartAdmissionEnabledParams.self, from: paramsData)
        try await db.config.setStartAdmissionEnabled(params.enabled)
        subscriptions.broadcast(delta: .modelProfilesChanged)
        return .ok()
    }

    /// Persist the holder viewer-claim reconcile gate (default OFF, soaking).
    /// `holder.reconcileClaims` reads it on every sweep, so a change takes
    /// effect at the app's next poll tick. Design:
    /// docs/specs/2026-10-25-holder-claim-reconcile-design.md.
    func handleConfigSetHolderClaimReconcileEnabled(_ paramsData: Data) async throws -> RPCResponse {
        let params = try decoder.decode(
            ConfigSetHolderClaimReconcileParams.self, from: paramsData)
        try await db.config.setHolderClaimReconcileEnabled(params.enabled)
        // Reuse the existing config-change channel so the app reloads Config.
        subscriptions.broadcast(delta: .modelProfilesChanged)
        return .ok()
    }

    /// Persist the the agent background priority command flag (default OFF). Read on every use, so a
    /// change takes effect at the next request. Turning it off also ends a live lease and restores
    /// what it lowered, so the flag is an off switch and not only a gate on `on`.
    func handleConfigSetAgentBackgroundEnabled(_ paramsData: Data) async throws -> RPCResponse {
        let params = try decoder.decode(ConfigSetAgentBackgroundEnabledParams.self, from: paramsData)
        try await db.config.setAgentBackgroundEnabled(params.enabled)
        if !params.enabled { await agentBackground?.off() }
        subscriptions.broadcast(delta: .modelProfilesChanged)
        return .ok()
    }

    /// Persist the composer draft gate (default OFF, soaking). Sessions pick the
    /// feature up when they next start. Automatic parking holds the feature on
    /// whatever this stores, so while it is on, an off written here takes
    /// effect only once automatic parking is off.
    /// Design: docs/specs/2026-10-19-tbd-session-mod-design.md.
    func handleConfigSetComposerDraftEnabled(_ paramsData: Data) async throws -> RPCResponse {
        let params = try decoder.decode(
            ConfigSetComposerDraftEnabledParams.self, from: paramsData)
        try await db.config.setComposerDraftEnabled(params.enabled)
        // Reuse the existing config-change channel so the app reloads Config.
        subscriptions.broadcast(delta: .modelProfilesChanged)
        // Add or remove the session mod in the plugin. The features come from
        // the fresh config rather than this one flag, so the mod stays while
        // any feature's flag is still on.
        if let sessionModPluginSync {
            let config = try await db.config.get()
            sessionModPluginSync(SessionModFeature.enabled(in: config))
        }
        return .ok()
    }

    /// Persist the session usage gate (default OFF, soaking). Sessions pick the
    /// feature up when they next start.
    /// Design: docs/specs/2026-10-20-session-usage-mod-feature-design.md.
    func handleConfigSetSessionModUsageEnabled(_ paramsData: Data) async throws -> RPCResponse {
        let params = try decoder.decode(
            ConfigSetSessionModUsageEnabledParams.self, from: paramsData)
        try await db.config.setSessionModUsageEnabled(params.enabled)
        // Reuse the existing config-change channel so the app reloads Config.
        subscriptions.broadcast(delta: .modelProfilesChanged)
        // Add or remove the session mod in the plugin. The features come from
        // the fresh config rather than this one flag, so the mod stays while
        // any feature's flag is still on.
        if let sessionModPluginSync {
            let config = try await db.config.get()
            sessionModPluginSync(SessionModFeature.enabled(in: config))
        }
        return .ok()
    }

    /// Persist the clone-backed worktree checkout gate (default OFF, soaking).
    /// No live switch: `WorktreeLifecycle` reads the column on every create.
    /// Design: docs/specs/2026-10-09-clone-backed-worktree-checkout-design.md.
    func handleConfigSetCloneCheckoutEnabled(_ paramsData: Data) async throws -> RPCResponse {
        let params = try decoder.decode(
            ConfigSetCloneCheckoutEnabledParams.self, from: paramsData)
        try await db.config.setCloneCheckoutEnabled(params.enabled)
        // Reuse the existing config-change channel so the app reloads Config.
        subscriptions.broadcast(delta: .modelProfilesChanged)
        return .ok()
    }
}
