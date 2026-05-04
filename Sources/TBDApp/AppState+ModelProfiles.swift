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
        } catch {
            logger.error("Failed to list model profiles: \(error, privacy: .public)")
            handleConnectionError(error)
        }
    }

    /// Add a new model profile. Returns the daemon's warning string (if any).
    /// On error sets `alertMessage` and returns nil. The raw token bytes are
    /// not included in any log or alert.
    @discardableResult
    func addModelProfile(name: String, token: String, baseURL: String? = nil, model: String? = nil) async -> String? {
        do {
            let result = try await daemonClient.addModelProfile(name: name, token: token, baseURL: baseURL, model: model)
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
    func updateModelProfileEndpoint(id: UUID, baseURL: String?, model: String?) async {
        do {
            try await daemonClient.updateModelProfileEndpoint(id: id, baseURL: baseURL, model: model)
            await loadModelProfiles()
        } catch {
            logger.error("Failed to update model profile endpoint: \(error, privacy: .public)")
            showAlert("Failed to update endpoint: \(error.localizedDescription)", isError: true)
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

    /// Swap the model profile associated with a running terminal.
    /// The daemon forks a new tmux tab; this method adds the new terminal and tab to local state
    /// and selects it so the UI switches immediately.
    func swapTerminalProfile(terminalID: UUID, newProfileID: UUID?) async {
        do {
            let size = mainAreaTerminalSize()
            let newTerminal = try await daemonClient.swapTerminalProfile(terminalID: terminalID, newProfileID: newProfileID, cols: size.cols, rows: size.rows)
            let worktreeID = newTerminal.worktreeID
            terminals[worktreeID, default: []].append(newTerminal)
            let newTab = Tab(id: newTerminal.id, content: .terminal(terminalID: newTerminal.id))
            tabs[worktreeID, default: []].append(newTab)
            activeTabIndices[worktreeID] = (tabs[worktreeID]?.count ?? 1) - 1
        } catch {
            logger.error("Failed to swap profile on terminal: \(error, privacy: .public)")
            showAlert("Failed to swap profile: \(error.localizedDescription)", isError: true)
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
}
