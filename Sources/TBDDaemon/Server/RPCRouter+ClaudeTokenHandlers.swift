import Foundation
import os
import TBDShared

private let logger = Logger(subsystem: "com.tbd.daemon", category: "claudeTokenHandlers")

extension RPCRouter {

    // MARK: - List

    func handleClaudeTokenList() async throws -> RPCResponse {
        let tokens = try await db.claudeTokens.list()
        var result: [ClaudeTokenWithUsage] = []
        result.reserveCapacity(tokens.count)
        for token in tokens {
            let usage = try await db.claudeTokenUsage.get(tokenID: token.id)
            result.append(ClaudeTokenWithUsage(token: token, usage: usage))
        }
        let config = try await db.config.get()
        return try RPCResponse(result: ClaudeTokenListResult(tokens: result, defaultID: config.defaultClaudeTokenID))
    }

    // MARK: - Add

    func handleClaudeTokenAdd(_ paramsData: Data) async throws -> RPCResponse {
        let params = try decoder.decode(ClaudeTokenAddParams.self, from: paramsData)
        let trimmed = params.token.trimmingCharacters(in: .whitespacesAndNewlines)
        let name = params.name.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !name.isEmpty else {
            return RPCResponse(error: "Name cannot be empty")
        }

        // Tokens are passed through tmux's `-e KEY=VALUE` argv (no shell), so
        // most printables are safe. Reject only chars that would break a
        // single-line tmux arg: newlines, carriage returns, NULL bytes.
        if trimmed.contains(where: { $0 == "\n" || $0 == "\r" || $0 == "\0" }) {
            return RPCResponse(error: "Token contains invalid characters (newlines or NULL bytes are not allowed)")
        }

        let kind: ClaudeTokenKind
        if trimmed.hasPrefix("sk-ant-oat01-") {
            kind = .oauth
        } else if trimmed.hasPrefix("sk-ant-api03-") {
            kind = .apiKey
        } else {
            return RPCResponse(error: "Token must start with sk-ant-oat01- or sk-ant-api03-")
        }

        if try await db.claudeTokens.getByName(name) != nil {
            return RPCResponse(error: "A token named '\(name)' already exists")
        }

        var warning: String? = nil
        var freshUsage: ClaudeUsageResult? = nil
        var freshStatus: String? = nil

        if kind == .oauth {
            let status = await usageFetcher.fetchUsage(token: trimmed)
            switch status {
            case .ok(let usage):
                freshUsage = usage
                freshStatus = "ok"
            case .http401:
                return RPCResponse(error: "Token invalid")
            case .http429:
                warning = "Could not verify token with Anthropic; saved anyway"
                freshStatus = "http_429"
            case .networkError:
                warning = "Could not verify token with Anthropic; saved anyway"
                freshStatus = "network_error"
            case .decodeError:
                warning = "Could not verify token with Anthropic; saved anyway"
                freshStatus = "decode_error"
            }
        }

        // Create DB row first so we have the canonical UUID; the keychain entry
        // is keyed by that UUID. If the keychain write fails we roll back the row.
        let tokenRow = try await db.claudeTokens.create(name: name, kind: kind)
        do {
            try ClaudeTokenKeychain.store(id: tokenRow.id.uuidString, token: trimmed)
        } catch {
            try? await db.claudeTokens.delete(id: tokenRow.id)
            return RPCResponse(error: "Failed to store token in keychain")
        }

        if let usage = freshUsage {
            let usageRow = ClaudeTokenUsage(
                tokenID: tokenRow.id,
                fiveHourPct: usage.fiveHourPct,
                sevenDayPct: usage.sevenDayPct,
                fiveHourResetsAt: usage.fiveHourResetsAt,
                sevenDayResetsAt: usage.sevenDayResetsAt,
                fetchedAt: Date(),
                lastStatus: freshStatus
            )
            try await db.claudeTokenUsage.upsert(usageRow)
        }

        return try RPCResponse(result: ClaudeTokenAddResult(token: tokenRow, warning: warning))
    }

    // MARK: - Delete

    func handleClaudeTokenDelete(_ paramsData: Data) async throws -> RPCResponse {
        let params = try decoder.decode(ClaudeTokenDeleteParams.self, from: paramsData)
        guard try await db.claudeTokens.get(id: params.id) != nil else {
            return RPCResponse(error: "Token not found")
        }

        let config = try await db.config.get()
        if config.defaultClaudeTokenID == params.id {
            try await db.config.setDefaultClaudeTokenID(nil)
        }

        try await db.repos.clearClaudeTokenOverride(matching: params.id)

        try await db.claudeTokenUsage.deleteForToken(id: params.id)
        try await db.claudeTokens.delete(id: params.id)

        // NOTE: We deliberately do NOT touch terminal.claude_token_id here.
        // Running terminals keep the env var that was injected at spawn time;
        // mutating their stored token id would mislead the UI about what the
        // already-running claude process is actually using.
        // DB row deletion is the source of truth — don't fail the RPC if the
        // on-disk token file delete fails (permission, missing, disk error).
        // Log so an orphan file isn't completely silent.
        do {
            try ClaudeTokenKeychain.delete(id: params.id.uuidString)
        } catch {
            logger.warning("Failed to delete token file for \(params.id): \(error.localizedDescription, privacy: .public)")
        }

        return .ok()
    }

    // MARK: - Rename

    func handleClaudeTokenRename(_ paramsData: Data) async throws -> RPCResponse {
        let params = try decoder.decode(ClaudeTokenRenameParams.self, from: paramsData)
        let name = params.name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else {
            return RPCResponse(error: "Name cannot be empty")
        }
        if let existing = try await db.claudeTokens.getByName(name), existing.id != params.id {
            return RPCResponse(error: "A token named '\(name)' already exists")
        }
        try await db.claudeTokens.rename(id: params.id, name: name)
        return .ok()
    }

    // MARK: - Defaults

    func handleClaudeTokenSetGlobalDefault(_ paramsData: Data) async throws -> RPCResponse {
        let params = try decoder.decode(ClaudeTokenSetGlobalDefaultParams.self, from: paramsData)
        try await db.config.setDefaultClaudeTokenID(params.id)
        return .ok()
    }

    func handleClaudeTokenSetRepoOverride(_ paramsData: Data) async throws -> RPCResponse {
        let params = try decoder.decode(ClaudeTokenSetRepoOverrideParams.self, from: paramsData)
        guard try await db.repos.get(id: params.repoID) != nil else {
            return RPCResponse(error: "Repo not found")
        }
        try await db.repos.setClaudeTokenOverride(id: params.repoID, tokenID: params.tokenID)
        return .ok()
    }

    // MARK: - Fetch Usage (60s dedupe)

    func handleClaudeTokenFetchUsage(_ paramsData: Data) async throws -> RPCResponse {
        let params = try decoder.decode(ClaudeTokenFetchUsageParams.self, from: paramsData)
        guard try await db.claudeTokens.get(id: params.id) != nil else {
            return RPCResponse(error: "Token not found")
        }

        if let cached = try await db.claudeTokenUsage.get(tokenID: params.id),
           let fetchedAt = cached.fetchedAt,
           Date().timeIntervalSince(fetchedAt) < 60 {
            return try RPCResponse(result: ClaudeTokenFetchUsageResult(usage: cached))
        }

        let bytes: String?
        do {
            bytes = try ClaudeTokenKeychain.load(id: params.id.uuidString)
        } catch {
            return RPCResponse(error: "Failed to read token: \(error)")
        }
        guard let token = bytes else {
            return RPCResponse(error: "Token missing from keychain")
        }

        let status = await usageFetcher.fetchUsage(token: token)
        switch status {
        case .ok(let usage):
            let row = ClaudeTokenUsage(
                tokenID: params.id,
                fiveHourPct: usage.fiveHourPct,
                sevenDayPct: usage.sevenDayPct,
                fiveHourResetsAt: usage.fiveHourResetsAt,
                sevenDayResetsAt: usage.sevenDayResetsAt,
                fetchedAt: Date(),
                lastStatus: "ok"
            )
            try await db.claudeTokenUsage.upsert(row)
            subscriptions.broadcastClaudeTokenUsage(row)
            return try RPCResponse(result: ClaudeTokenFetchUsageResult(usage: row))
        case .http401:
            return RPCResponse(error: "Token invalid")
        case .http429:
            return RPCResponse(error: "Rate limited; try again later")
        case .networkError(let msg):
            return RPCResponse(error: "Network error: \(msg)")
        case .decodeError(let msg):
            return RPCResponse(error: "Decode error: \(msg)")
        }
    }
}
