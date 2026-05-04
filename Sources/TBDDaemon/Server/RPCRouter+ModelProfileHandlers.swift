import Foundation
import os
import TBDShared

private let logger = Logger(subsystem: "com.tbd.daemon", category: "modelProfileHandlers")

extension RPCRouter {

    // MARK: - List

    func handleModelProfileList() async throws -> RPCResponse {
        let profiles = try await db.modelProfiles.list()
        var result: [ModelProfileWithUsage] = []
        result.reserveCapacity(profiles.count)
        for profile in profiles {
            let usage = try await db.modelProfileUsage.get(profileID: profile.id)
            result.append(ModelProfileWithUsage(profile: profile, usage: usage))
        }
        let config = try await db.config.get()
        return try RPCResponse(result: ModelProfileListResult(profiles: result, defaultID: config.defaultProfileID))
    }

    // MARK: - Add

    func handleModelProfileAdd(_ paramsData: Data) async throws -> RPCResponse {
        let params = try decoder.decode(ModelProfileAddParams.self, from: paramsData)
        let trimmed = params.token.trimmingCharacters(in: .whitespacesAndNewlines)
        let name = params.name.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !name.isEmpty else {
            return RPCResponse(error: "Name cannot be empty")
        }

        // Secrets pass through tmux's `-e KEY=VALUE` argv (no shell), so most
        // printables are safe. Reject only chars that would break a single-line
        // tmux arg: newlines, carriage returns, NULL bytes.
        if trimmed.contains(where: { $0 == "\n" || $0 == "\r" || $0 == "\0" }) {
            return RPCResponse(error: "Token contains invalid characters (newlines or NULL bytes are not allowed)")
        }

        // OAuth/api-key tokens get caught by the prefix check below, but proxy
        // profiles (baseURL set) accept any non-empty string and would happily
        // store an empty token, then inject `ANTHROPIC_API_KEY=` at spawn.
        guard !trimmed.isEmpty else {
            return RPCResponse(error: "Token cannot be empty")
        }

        // Infer credential kind. Claude-direct profiles must look like a Claude
        // OAuth token or API key; proxy profiles (baseURL set) accept any
        // string (the proxy decides what's valid).
        let kind: CredentialKind
        if let _ = params.baseURL {
            // Proxy profile — credential is whatever the proxy expects. Treat
            // the secret as an API-key-shaped credential so it gets injected
            // via ANTHROPIC_API_KEY.
            kind = .apiKey
        } else if trimmed.hasPrefix("sk-ant-oat01-") {
            kind = .oauth
        } else if trimmed.hasPrefix("sk-ant-api03-") {
            kind = .apiKey
        } else {
            return RPCResponse(error: "Token must start with sk-ant-oat01- or sk-ant-api03-")
        }

        if try await db.modelProfiles.getByName(name) != nil {
            return RPCResponse(error: "A profile named '\(name)' already exists")
        }

        var warning: String? = nil
        var freshUsage: ClaudeUsageResult? = nil
        var freshStatus: String? = nil

        // Only verify Claude-direct OAuth tokens against the Anthropic usage
        // endpoint. Proxy profiles route to a user-managed endpoint that may
        // not implement that API.
        if kind == .oauth && params.baseURL == nil {
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
        let profileRow = try await db.modelProfiles.create(
            name: name,
            kind: kind,
            baseURL: params.baseURL,
            model: params.model
        )
        do {
            try ModelProfileKeychain.store(id: profileRow.id.uuidString, token: trimmed)
        } catch {
            try? await db.modelProfiles.delete(id: profileRow.id)
            return RPCResponse(error: "Failed to store secret in keychain")
        }

        if let usage = freshUsage {
            let usageRow = ModelProfileUsage(
                profileID: profileRow.id,
                fiveHourPct: usage.fiveHourPct,
                sevenDayPct: usage.sevenDayPct,
                fiveHourResetsAt: usage.fiveHourResetsAt,
                sevenDayResetsAt: usage.sevenDayResetsAt,
                fetchedAt: Date(),
                lastStatus: freshStatus
            )
            try await db.modelProfileUsage.upsert(usageRow)
        }

        subscriptions.broadcast(delta: .modelProfilesChanged)
        return try RPCResponse(result: ModelProfileAddResult(profile: profileRow, warning: warning))
    }

    // MARK: - Delete

    func handleModelProfileDelete(_ paramsData: Data) async throws -> RPCResponse {
        let params = try decoder.decode(ModelProfileDeleteParams.self, from: paramsData)
        guard try await db.modelProfiles.get(id: params.id) != nil else {
            return RPCResponse(error: "Profile not found")
        }

        let config = try await db.config.get()
        if config.defaultProfileID == params.id {
            try await db.config.setDefaultProfileID(nil)
        }

        try await db.repos.clearProfileOverride(matching: params.id)

        try await db.modelProfileUsage.deleteForProfile(id: params.id)
        try await db.modelProfiles.delete(id: params.id)

        // NOTE: We deliberately do NOT touch terminal.profile_id here.
        // Running terminals keep the env var that was injected at spawn time;
        // mutating their stored profile id would mislead the UI about what the
        // already-running claude process is actually using.
        // DB row deletion is the source of truth — don't fail the RPC if the
        // on-disk secret file delete fails (permission, missing, disk error).
        // Log so an orphan file isn't completely silent.
        do {
            try ModelProfileKeychain.delete(id: params.id.uuidString)
        } catch {
            logger.warning("Failed to delete secret file for \(params.id, privacy: .public): \(error.localizedDescription, privacy: .public)")
        }

        subscriptions.broadcast(delta: .modelProfilesChanged)
        return .ok()
    }

    // MARK: - Rename

    func handleModelProfileRename(_ paramsData: Data) async throws -> RPCResponse {
        let params = try decoder.decode(ModelProfileRenameParams.self, from: paramsData)
        let name = params.name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else {
            return RPCResponse(error: "Name cannot be empty")
        }
        if let existing = try await db.modelProfiles.getByName(name), existing.id != params.id {
            return RPCResponse(error: "A profile named '\(name)' already exists")
        }
        try await db.modelProfiles.rename(id: params.id, name: name)
        subscriptions.broadcast(delta: .modelProfilesChanged)
        return .ok()
    }

    // MARK: - Update Endpoint

    func handleModelProfileUpdateEndpoint(_ paramsData: Data) async throws -> RPCResponse {
        let params = try decoder.decode(ModelProfileUpdateEndpointParams.self, from: paramsData)
        guard try await db.modelProfiles.get(id: params.id) != nil else {
            return RPCResponse(error: "Profile not found")
        }
        try await db.modelProfiles.updateEndpoint(id: params.id, baseURL: params.baseURL, model: params.model)
        subscriptions.broadcast(delta: .modelProfilesChanged)
        return .ok()
    }

    // MARK: - Defaults

    func handleModelProfileSetGlobalDefault(_ paramsData: Data) async throws -> RPCResponse {
        let params = try decoder.decode(ModelProfileSetGlobalDefaultParams.self, from: paramsData)
        try await db.config.setDefaultProfileID(params.id)
        subscriptions.broadcast(delta: .modelProfilesChanged)
        return .ok()
    }

    func handleModelProfileSetRepoOverride(_ paramsData: Data) async throws -> RPCResponse {
        let params = try decoder.decode(ModelProfileSetRepoOverrideParams.self, from: paramsData)
        guard try await db.repos.get(id: params.repoID) != nil else {
            return RPCResponse(error: "Repo not found")
        }
        try await db.repos.setProfileOverride(id: params.repoID, profileID: params.profileID)
        subscriptions.broadcast(delta: .modelProfilesChanged)
        return .ok()
    }

    // MARK: - Fetch Usage (60s dedupe)

    func handleModelProfileFetchUsage(_ paramsData: Data) async throws -> RPCResponse {
        let params = try decoder.decode(ModelProfileFetchUsageParams.self, from: paramsData)
        guard let profile = try await db.modelProfiles.get(id: params.id) else {
            return RPCResponse(error: "Profile not found")
        }

        // Proxy profiles can't be polled against the Claude API usage endpoint.
        if profile.baseURL != nil {
            return RPCResponse(error: "Usage tracking is only available for Claude-direct profiles")
        }

        if let cached = try await db.modelProfileUsage.get(profileID: params.id),
           let fetchedAt = cached.fetchedAt,
           Date().timeIntervalSince(fetchedAt) < 60 {
            return try RPCResponse(result: ModelProfileFetchUsageResult(usage: cached))
        }

        let bytes: String?
        do {
            bytes = try ModelProfileKeychain.load(id: params.id.uuidString)
        } catch {
            return RPCResponse(error: "Failed to read secret: \(error)")
        }
        guard let token = bytes else {
            return RPCResponse(error: "Secret missing from keychain")
        }

        let status = await usageFetcher.fetchUsage(token: token)
        switch status {
        case .ok(let usage):
            let row = ModelProfileUsage(
                profileID: params.id,
                fiveHourPct: usage.fiveHourPct,
                sevenDayPct: usage.sevenDayPct,
                fiveHourResetsAt: usage.fiveHourResetsAt,
                sevenDayResetsAt: usage.sevenDayResetsAt,
                fetchedAt: Date(),
                lastStatus: "ok"
            )
            try await db.modelProfileUsage.upsert(row)
            subscriptions.broadcastModelProfileUsage(row)
            return try RPCResponse(result: ModelProfileFetchUsageResult(usage: row))
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

    // MARK: - Health Check

    func handleModelProfileHealthCheck(_ paramsData: Data) async throws -> RPCResponse {
        let params = try decoder.decode(ModelProfileHealthCheckParams.self, from: paramsData)
        let result = await ModelProfileHealthProbe.probe(baseURL: params.baseURL)
        return try RPCResponse(result: result)
    }
}
