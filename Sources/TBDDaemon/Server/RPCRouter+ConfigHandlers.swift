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

    /// Persist the session-limit auto-resume gate. Turning it OFF cancels
    /// every pending scheduled resume (spec §Cancellation) and wakes the
    /// scheduler so its in-flight sleep re-evaluates.
    func handleConfigSetAutoResumeOnLimitReset(_ paramsData: Data) async throws -> RPCResponse {
        let params = try decoder.decode(ConfigSetAutoResumeOnLimitResetParams.self, from: paramsData)
        if !params.enabled {
            // Cancel before persisting the off-state so a cancel failure can never
            // leave the gate off with live pending rows, violating the feature invariant.
            _ = try await db.scheduledResumes.cancelAllPending()
        }
        try await db.config.setAutoResumeOnLimitReset(params.enabled)
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
}
