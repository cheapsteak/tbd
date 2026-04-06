import Foundation
import TBDShared
import os

private let logger = Logger(subsystem: "com.tbd.app", category: "AppState+ClaudeTokens")

extension AppState {
    // MARK: - Claude Token Actions
    //
    // IMPORTANT: never include the raw token string in any logger / alert
    // message. The `addClaudeToken` helper accepts the token as a parameter
    // and forwards it directly to the daemon — that is the only place a
    // secret crosses the boundary in the app process.

    /// Refresh the full Claude token list and global default ID from the daemon.
    func refreshClaudeTokens() async {
        do {
            let result = try await daemonClient.listClaudeTokens()
            if result.tokens != claudeTokens {
                claudeTokens = result.tokens
            }
            if result.defaultID != globalDefaultClaudeTokenID {
                globalDefaultClaudeTokenID = result.defaultID
            }
        } catch {
            logger.error("Failed to list Claude tokens: \(error)")
            handleConnectionError(error)
        }
    }

    /// Add a new Claude token. Returns the daemon's warning string (if any).
    /// On error sets `alertMessage` and returns nil. The raw token bytes are
    /// not included in any log or alert.
    @discardableResult
    func addClaudeToken(name: String, token: String) async -> String? {
        do {
            let result = try await daemonClient.addClaudeToken(name: name, token: token)
            await refreshClaudeTokens()
            return result.warning
        } catch {
            logger.error("Failed to add Claude token (name=\(name)): \(error)")
            showAlert("Failed to add Claude token: \(error.localizedDescription)", isError: true)
            return nil
        }
    }

    /// Delete a Claude token by ID.
    func deleteClaudeToken(id: UUID) async {
        do {
            try await daemonClient.deleteClaudeToken(id: id)
            await refreshClaudeTokens()
        } catch {
            logger.error("Failed to delete Claude token: \(error)")
            showAlert("Failed to delete Claude token: \(error.localizedDescription)", isError: true)
        }
    }

    /// Rename a Claude token.
    func renameClaudeToken(id: UUID, name: String) async {
        do {
            try await daemonClient.renameClaudeToken(id: id, name: name)
            await refreshClaudeTokens()
        } catch {
            logger.error("Failed to rename Claude token: \(error)")
            showAlert("Failed to rename Claude token: \(error.localizedDescription)", isError: true)
        }
    }

    /// Set or clear the global default Claude token.
    func setGlobalDefaultClaudeToken(id: UUID?) async {
        do {
            try await daemonClient.setGlobalDefaultClaudeToken(id: id)
            globalDefaultClaudeTokenID = id
        } catch {
            logger.error("Failed to set global default Claude token: \(error)")
            showAlert("Failed to set default Claude token: \(error.localizedDescription)", isError: true)
        }
    }

    /// Set or clear a per-repo Claude token override.
    func setRepoClaudeTokenOverride(repoID: UUID, tokenID: UUID?) async {
        do {
            try await daemonClient.setRepoClaudeTokenOverride(repoID: repoID, tokenID: tokenID)
            // Optimistically update local repo state
            if let idx = repos.firstIndex(where: { $0.id == repoID }) {
                var repo = repos[idx]
                repo.claudeTokenOverrideID = tokenID
                repos[idx] = repo
            }
        } catch {
            logger.error("Failed to set repo Claude token override: \(error)")
            showAlert("Failed to set repo Claude token: \(error.localizedDescription)", isError: true)
        }
    }

    /// Swap the Claude token associated with a running terminal.
    func swapClaudeTokenOnTerminal(terminalID: UUID, newTokenID: UUID?) async {
        do {
            try await daemonClient.swapClaudeTokenOnTerminal(terminalID: terminalID, newTokenID: newTokenID)
        } catch {
            logger.error("Failed to swap Claude token on terminal: \(error)")
            showAlert("Failed to swap Claude token: \(error.localizedDescription)", isError: true)
        }
    }

    /// Fetch fresh usage for a single Claude token and merge it into local state.
    func fetchClaudeTokenUsage(id: UUID) async {
        do {
            let usage = try await daemonClient.fetchClaudeTokenUsage(id: id)
            if let idx = claudeTokens.firstIndex(where: { $0.token.id == id }) {
                let existing = claudeTokens[idx]
                claudeTokens[idx] = ClaudeTokenWithUsage(token: existing.token, usage: usage)
            }
        } catch {
            logger.error("Failed to fetch Claude token usage: \(error)")
            showAlert("Failed to fetch token usage: \(error.localizedDescription)", isError: true)
        }
    }
}
