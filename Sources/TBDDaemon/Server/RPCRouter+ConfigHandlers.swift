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
}
