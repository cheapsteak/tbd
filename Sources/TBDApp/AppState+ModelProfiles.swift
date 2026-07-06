import AppKit
import Foundation
import TBDShared
import os

private let logger = Logger(subsystem: "com.tbd.app", category: "modelProfiles")

extension AppState {
    // MARK: - Model Profile Actions
    //
    // IMPORTANT: never include the raw token string in any logger / alert
    // message. The `addModelProfile` helper accepts the token as a parameter
    // and forwards it directly to the daemon — that is the only place a
    // secret crosses the boundary in the app process.

    /// Refresh the full model profile list and global default ID from the daemon.
    func loadModelProfiles() async {
        do {
            let result = try await daemonClient.listModelProfiles()
            if result.profiles != modelProfiles {
                modelProfiles = result.profiles
            }
            if result.defaultID != defaultProfileID {
                defaultProfileID = result.defaultID
            }
            if result.primaryAgentPreference != primaryAgentPreference {
                primaryAgentPreference = result.primaryAgentPreference
            }
            if result.globalEnvOverrides != globalEnvOverrides {
                globalEnvOverrides = result.globalEnvOverrides
            }
            if result.autoArchiveOnMergeDefault != autoArchiveOnMergeDefault {
                autoArchiveOnMergeDefault = result.autoArchiveOnMergeDefault
            }
            if result.nightwatchMode != nightwatchMode {
                nightwatchMode = result.nightwatchMode
            }
            if result.autoResumeOnLimitReset != autoResumeOnLimitReset {
                autoResumeOnLimitReset = result.autoResumeOnLimitReset
            }
        } catch {
            logger.error("Failed to list model profiles: \(error, privacy: .public)")
            handleConnectionError(error)
        }
    }

    /// Add a new model profile. Returns the daemon's warning string (if any).
    /// On error sets `alertMessage` and returns nil. The raw token bytes are
    /// not included in any log or alert.
    @discardableResult
    func addModelProfile(name: String,
                         kind: ModelProfileAddKind? = nil,
                         token: String? = nil,
                         baseURL: String? = nil,
                         model: String? = nil,
                         awsRegion: String? = nil,
                         awsProfile: String? = nil,
                         fallbackModels: [String]? = nil) async -> String? {
        do {
            let result = try await daemonClient.addModelProfile(
                name: name, kind: kind, token: token,
                baseURL: baseURL, model: model,
                awsRegion: awsRegion, awsProfile: awsProfile,
                fallbackModels: fallbackModels
            )
            await loadModelProfiles()
            return result.warning
        } catch {
            logger.error("Failed to add model profile (name=\(name, privacy: .public)): \(error, privacy: .public)")
            showAlert("Failed to add model profile: \(error.localizedDescription)", isError: true)
            return nil
        }
    }

    /// Delete a model profile by ID.
    func deleteModelProfile(id: UUID) async {
        do {
            try await daemonClient.deleteModelProfile(id: id)
            await loadModelProfiles()
        } catch {
            logger.error("Failed to delete model profile: \(error, privacy: .public)")
            showAlert("Failed to delete model profile: \(error.localizedDescription)", isError: true)
        }
    }

    /// Rename a model profile.
    func renameModelProfile(id: UUID, name: String) async {
        do {
            try await daemonClient.renameModelProfile(id: id, name: name)
            await loadModelProfiles()
        } catch {
            logger.error("Failed to rename model profile: \(error, privacy: .public)")
            showAlert("Failed to rename model profile: \(error.localizedDescription)", isError: true)
        }
    }

    /// Update a model profile's proxy endpoint (baseURL + model). Pass nil to
    /// either field to clear it.
    func updateModelProfileEndpoint(id: UUID, baseURL: String?, model: String?,
                                    fallbackModels: [String]? = nil) async {
        do {
            try await daemonClient.updateModelProfileEndpoint(
                id: id, baseURL: baseURL, model: model, fallbackModels: fallbackModels
            )
            await loadModelProfiles()
        } catch {
            logger.error("Failed to update model profile endpoint: \(error, privacy: .public)")
            showAlert("Failed to update endpoint: \(error.localizedDescription)", isError: true)
        }
    }

    /// Update a bedrock model profile's region, awsProfile, model, and fallback list in-place.
    func updateModelProfileBedrock(id: UUID, awsRegion: String, awsProfile: String?, model: String,
                                   fallbackModels: [String]? = nil) async {
        do {
            try await daemonClient.updateModelProfileBedrock(
                id: id, awsRegion: awsRegion, awsProfile: awsProfile, model: model,
                fallbackModels: fallbackModels
            )
            await loadModelProfiles()
        } catch {
            logger.error("Failed to update bedrock profile: \(error, privacy: .public)")
            showAlert("Failed to update bedrock profile: \(error.localizedDescription)", isError: true)
        }
    }

    /// Probe a proxy base URL via the daemon. Returns a result describing
    /// reachability. Phase 5 fills in the daemon-side handler; until then
    /// callers may receive a "Not yet implemented" error which they should
    /// surface non-blockingly.
    func healthCheckProfile(baseURL: String) async -> ModelProfileHealthCheckResult {
        do {
            return try await daemonClient.healthCheckProfile(baseURL: baseURL)
        } catch {
            logger.warning("Health check failed: \(error, privacy: .public)")
            return ModelProfileHealthCheckResult(
                reachable: false,
                statusCode: nil,
                detail: error.localizedDescription
            )
        }
    }

    /// Set or clear the global default model profile.
    func setDefaultProfile(id: UUID?) async {
        do {
            try await daemonClient.setDefaultProfile(id: id)
            defaultProfileID = id
        } catch {
            logger.error("Failed to set default model profile: \(error, privacy: .public)")
            showAlert("Failed to set default profile: \(error.localizedDescription)", isError: true)
        }
    }

    /// Set the default primary agent used for new worktrees.
    func setPrimaryAgentPreference(_ preference: PrimaryAgentPreference) async {
        do {
            try await daemonClient.setPrimaryAgentPreference(preference)
            primaryAgentPreference = preference
        } catch {
            logger.error("Failed to set primary agent preference: \(error, privacy: .public)")
            showAlert("Failed to set primary agent: \(error.localizedDescription)", isError: true)
        }
    }

    /// Set the global default for auto-archive-on-PR-merge.
    func setAutoArchiveOnMergeDefault(_ enabled: Bool) async {
        do {
            try await daemonClient.setAutoArchiveOnMergeDefault(enabled)
            autoArchiveOnMergeDefault = enabled
        } catch {
            logger.error("Failed to set auto-archive default: \(error, privacy: .public)")
            showAlert("Failed to set default: \(error.localizedDescription)", isError: true)
        }
    }

    /// Set the global session-limit auto-resume gate. Turning it OFF also
    /// cancels all pending scheduled resumes daemon-side.
    func setAutoResumeOnLimitReset(_ enabled: Bool) async {
        do {
            try await daemonClient.setAutoResumeOnLimitReset(enabled)
            autoResumeOnLimitReset = enabled
        } catch {
            logger.error("Failed to set auto-resume gate: \(error, privacy: .public)")
            showAlert("Failed to set auto-resume: \(error.localizedDescription)", isError: true)
        }
    }

    /// Set the global scratch-space system-prompt override. Nil or blank resets to the built-in default.
    func setScratchInstructions(_ instructions: String?) async {
        do {
            try await daemonClient.setScratchInstructions(instructions)
        } catch {
            logger.error("Failed to set scratch instructions: \(error, privacy: .public)")
            handleConnectionError(error)
        }
    }

    /// Set the global scratch-space rename-nudge override. Nil or blank resets to the built-in default.
    func setScratchRenamePrompt(_ value: String?) async {
        do {
            try await daemonClient.setScratchRenamePrompt(value)
        } catch {
            logger.error("Failed to set scratch rename prompt: \(error, privacy: .public)")
            handleConnectionError(error)
        }
    }

    /// Fetch the current global Config (used by the scratch-instructions editor to show the effective text).
    func fetchConfig() async -> Config? {
        do {
            return try await daemonClient.getConfig()
        } catch {
            logger.error("Failed to fetch config: \(error, privacy: .public)")
            handleConnectionError(error)
            return nil
        }
    }

    /// Set or clear a per-repo model profile override.
    func setRepoProfileOverride(repoID: UUID, profileID: UUID?) async {
        do {
            try await daemonClient.setRepoProfileOverride(repoID: repoID, profileID: profileID)
            if let idx = repos.firstIndex(where: { $0.id == repoID }) {
                var repo = repos[idx]
                repo.profileOverrideID = profileID
                repos[idx] = repo
            }
        } catch {
            logger.error("Failed to set repo profile override: \(error, privacy: .public)")
            showAlert("Failed to set repo profile: \(error.localizedDescription)", isError: true)
        }
    }

    /// Set or clear the global model-profile override applied to scratch terminal
    /// spawns. Unlike `setRepoProfileOverride`, there's no `Repo` array entry to
    /// patch afterward — callers refresh their own local `@State` on success.
    func setScratchProfileOverride(_ profileID: UUID?) async {
        do {
            try await daemonClient.setScratchProfileOverride(profileID)
        } catch {
            logger.error("Failed to set scratch profile override: \(error, privacy: .public)")
            showAlert("Failed to set scratch profile override: \(error.localizedDescription)", isError: true)
        }
    }

    // MARK: - Env Overrides

    /// Set or clear the global free-form env overrides.
    func setGlobalEnvOverrides(_ overrides: [String: String]) async {
        do {
            try await daemonClient.setGlobalEnvOverrides(overrides)
            globalEnvOverrides = overrides
        } catch {
            logger.error("Failed to set global env overrides: \(error, privacy: .public)")
            showAlert("Failed to set env overrides: \(error.localizedDescription)", isError: true)
        }
    }

    /// Set or clear a repo's free-form env overrides.
    func setRepoEnvOverrides(repoID: UUID, overrides: [String: String]) async {
        do {
            try await daemonClient.setRepoEnvOverrides(repoID: repoID, overrides: overrides)
            if let idx = repos.firstIndex(where: { $0.id == repoID }) {
                var repo = repos[idx]
                repo.envOverrides = overrides
                repos[idx] = repo
            }
        } catch {
            logger.error("Failed to set repo env overrides: \(error, privacy: .public)")
            showAlert("Failed to set env overrides: \(error.localizedDescription)", isError: true)
        }
    }

    /// Set or clear a model profile's free-form env overrides.
    func setProfileEnvOverrides(profileID: UUID, overrides: [String: String]) async {
        do {
            try await daemonClient.setProfileEnvOverrides(profileID: profileID, overrides: overrides)
            if let idx = modelProfiles.firstIndex(where: { $0.profile.id == profileID }) {
                var profile = modelProfiles[idx].profile
                profile.envOverrides = overrides
                modelProfiles[idx] = ModelProfileWithUsage(profile: profile, usage: modelProfiles[idx].usage)
            }
        } catch {
            logger.error("Failed to set profile env overrides: \(error, privacy: .public)")
            showAlert("Failed to set env overrides: \(error.localizedDescription)", isError: true)
        }
    }

    /// Swap the model profile associated with a running terminal.
    ///
    /// `.inPlace` (default, "Switch account"): the daemon respawns the SAME
    /// tmux window/terminal row under the new profile. The row is updated in
    /// place via the `terminalProfileChanged` delta — no new tab is created, so
    /// this method just fires the RPC and lets the delta reconcile local state.
    ///
    /// `.fork` ("Fork session"): the daemon forks the conversation into a NEW
    /// tab/terminal row; this method appends it to local state and selects it.
    func swapTerminalProfile(
        terminalID: UUID,
        newProfileID: UUID?,
        mode: TerminalSwapMode = .inPlace
    ) async {
        do {
            let size = mainAreaTerminalSize()
            let resultTerminal = try await daemonClient.swapTerminalProfile(
                terminalID: terminalID, newProfileID: newProfileID,
                mode: mode, cols: size.cols, rows: size.rows
            )
            guard mode == .fork else {
                // In-place: same tab/row. The `terminalProfileChanged` +
                // `terminalSessionUpdated` deltas already reconciled the row;
                // nothing to add or re-select here.
                return
            }
            let worktreeID = resultTerminal.worktreeID
            terminals[worktreeID, default: []].append(resultTerminal)
            let newTab = Tab(id: resultTerminal.id, content: .terminal(terminalID: resultTerminal.id))
            tabs[worktreeID, default: []].append(newTab)
            setActiveTab(worktreeID: worktreeID, tabIndex: (tabs[worktreeID]?.count ?? 1) - 1)
        } catch {
            logger.error("Failed to swap profile on terminal: \(error, privacy: .public)")
            showAlert("Failed to swap profile: \(error.localizedDescription)", isError: true)
        }
    }

    /// Open (or focus) a Claude *login session* pinned to `profileID` so the
    /// user can complete `/login` there — the daemon labels the terminal as a
    /// login session, auto-types `/login` once Claude is up, and pushes a
    /// `modelProfilesChanged` delta when the profile's isolated config dir
    /// gains an account, flipping the Settings badge live.
    ///
    /// Duplicate-safe: if a live login session for this profile already
    /// exists, it is focused instead of spawning another; while a spawn RPC
    /// is in flight, repeat clicks are dropped. Returns true when a session
    /// was opened or focused (callers dismiss the Settings surface on true).
    @discardableResult
    func openLoginSession(profileID: UUID) async -> Bool {
        // Focus an existing live login session for this profile, if any —
        // five clicks should mean one session.
        if let existing = Self.existingLoginSessionTerminal(profileID: profileID, terminals: terminals) {
            navigateToActiveWorktree(existing.worktreeID, terminalID: existing.id)
            NSApplication.shared.activate(ignoringOtherApps: true)
            return true
        }

        guard let worktree = selectedWorktree else {
            showAlert("Select a worktree first, then open a login session.", isError: false)
            return false
        }
        guard !loginSessionSpawnsInFlight.contains(profileID) else { return false }
        loginSessionSpawnsInFlight.insert(profileID)
        defer { loginSessionSpawnsInFlight.remove(profileID) }

        guard let terminal = await createClaudeTerminal(
            worktreeID: worktree.id, profileID: profileID, loginSession: true
        ) else {
            // createClaudeTerminal already surfaced the error as an alert.
            return false
        }
        navigateToActiveWorktree(worktree.id, terminalID: terminal.id)
        NSApplication.shared.activate(ignoringOtherApps: true)
        await loadModelProfiles()
        return true
    }

    /// First live (non-suspended) login-session terminal pinned to
    /// `profileID`, across all worktrees. Static + pure for unit testing.
    nonisolated static func existingLoginSessionTerminal(
        profileID: UUID,
        terminals: [UUID: [Terminal]]
    ) -> Terminal? {
        terminals.values
            .flatMap { $0 }
            .first {
                $0.profileID == profileID
                    && $0.label == TerminalLabel.login
                    && $0.suspendedAt == nil
            }
    }

    /// Force an immediate daemon-side OAuth usage sweep and merge the returned
    /// snapshots into local state. The account picker calls this on open —
    /// cached snapshots stay on screen and update in place when fresh data
    /// lands. Failures are logged but never surfaced as a blocking alert
    /// (the picker degrades to cached data).
    func refreshUsageSnapshots(profileID: UUID? = nil) async {
        do {
            let result = try await daemonClient.refreshProfileUsage(id: profileID)
            let merged = Self.mergingUsageSnapshots(into: modelProfiles, entries: result.snapshots)
            if merged != modelProfiles {
                modelProfiles = merged
            }
        } catch {
            logger.warning("Usage snapshot refresh failed: \(error, privacy: .public)")
        }
    }

    /// Merge freshly swept snapshots into the current profile list, preserving
    /// every other field. Profiles without a returned snapshot keep whatever
    /// snapshot they had (the sweep only reports eligible logged-in OAuth
    /// profiles). Static + pure for unit testing.
    nonisolated static func mergingUsageSnapshots(
        into profiles: [ModelProfileWithUsage],
        entries: [ModelProfileUsageSnapshotEntry]
    ) -> [ModelProfileWithUsage] {
        guard !entries.isEmpty else { return profiles }
        let snapshotsByID = Dictionary(entries.map { ($0.profileID, $0.snapshot) },
                                       uniquingKeysWith: { _, last in last })
        return profiles.map { entry in
            guard let snapshot = snapshotsByID[entry.profile.id] else { return entry }
            return ModelProfileWithUsage(
                profile: entry.profile,
                usage: entry.usage,
                loginIdentity: entry.loginIdentity,
                configDirPath: entry.configDirPath,
                usageSnapshot: snapshot
            )
        }
    }

    /// Fetch fresh usage for a single profile and merge it into local state.
    func fetchProfileUsage(id: UUID) async {
        do {
            let usage = try await daemonClient.fetchProfileUsage(id: id)
            if let idx = modelProfiles.firstIndex(where: { $0.profile.id == id }) {
                let existing = modelProfiles[idx]
                modelProfiles[idx] = ModelProfileWithUsage(profile: existing.profile, usage: usage)
            }
        } catch {
            logger.error("Failed to fetch profile usage: \(error, privacy: .public)")
            showAlert("Failed to fetch profile usage: \(error.localizedDescription)", isError: true)
        }
    }

    // MARK: - Nightwatch Mode

    /// Set the nightwatch mode (off, daywatch, or nightwatch).
    func setNightwatchMode(_ mode: NightwatchMode) async {
        do {
            try await daemonClient.setNightwatchMode(mode)
            nightwatchMode = mode
        } catch {
            logger.error("Failed to set nightwatch mode: \(error, privacy: .public)")
            showAlert("Failed to set nightwatch mode: \(error.localizedDescription)", isError: true)
        }
    }
}
