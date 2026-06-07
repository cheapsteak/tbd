import Foundation
import os
import TBDShared

private let logger = Logger(subsystem: "com.tbd.daemon", category: "modelProfileHandlers")

/// Normalize a user-supplied fallback model list: trim each id, drop blanks,
/// cap at 3 (Claude Code's documented maximum), and collapse an empty result
/// to nil so the column stores NULL. Order is preserved.
func normalizeFallbackModels(_ raw: [String]?) -> [String]? {
    guard let raw else { return nil }
    let cleaned = raw
        .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        .filter { !$0.isEmpty }
        .prefix(3)
    return cleaned.isEmpty ? nil : Array(cleaned)
}

extension RPCRouter {

    // MARK: - List

    func handleModelProfileList() async throws -> RPCResponse {
        let profiles = try await db.modelProfiles.list()
        let usageByID = try await db.modelProfileUsage.fetchAll()
        let result = profiles.map { profile in
            ModelProfileWithUsage(profile: profile, usage: usageByID[profile.id])
        }
        let config = try await db.config.get()
        return try RPCResponse(result: ModelProfileListResult(
            profiles: result,
            defaultID: config.defaultProfileID,
            primaryAgentPreference: config.primaryAgentPreference
        ))
    }

    // MARK: - Add

    func handleModelProfileAdd(_ paramsData: Data) async throws -> RPCResponse {
        let params = try decoder.decode(ModelProfileAddParams.self, from: paramsData)
        let name = params.name.trimmingCharacters(in: .whitespacesAndNewlines)
        let fallbackModels = normalizeFallbackModels(params.fallbackModels)

        guard !name.isEmpty else {
            return RPCResponse(error: "Name cannot be empty")
        }

        if try await db.modelProfiles.getByName(name) != nil {
            return RPCResponse(error: "A profile named '\(name)' already exists")
        }

        // ─── Bedrock branch ───────────────────────────────────────────────────
        if params.kind == .bedrock {
            let region = (params.awsRegion ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            let model = (params.model ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            let awsProfileRaw = (params.awsProfile ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            let awsProfile: String? = awsProfileRaw.isEmpty ? nil : awsProfileRaw

            guard !region.isEmpty else {
                return RPCResponse(error: "AWS region is required for bedrock profiles")
            }
            guard !model.isEmpty else {
                return RPCResponse(error: "Bedrock model id is required")
            }

            let row = try await db.modelProfiles.create(
                name: name,
                kind: .bedrock,
                baseURL: nil,
                model: model,
                awsRegion: region,
                awsProfile: awsProfile,
                fallbackModels: fallbackModels
            )
            subscriptions.broadcast(delta: .modelProfilesChanged)
            return try RPCResponse(result: ModelProfileAddResult(profile: row, warning: nil))
        }

        // ─── Claude-direct / proxy branch ─────────────────────────────────────
        let trimmed = (params.token ?? "").trimmingCharacters(in: .whitespacesAndNewlines)

        // If no token is provided, treat as OAuth (no token required for OAuth).
        // OAuth profiles do not use baseURL (they are Claude-direct).
        if trimmed.isEmpty {
            guard params.baseURL == nil else {
                return RPCResponse(error: "Token cannot be empty")
            }
            let profileRow = try await db.modelProfiles.create(
                name: name,
                kind: .oauth,
                baseURL: nil,
                model: params.model,
                fallbackModels: fallbackModels
            )
            subscriptions.broadcast(delta: .modelProfilesChanged)
            return try RPCResponse(result: ModelProfileAddResult(profile: profileRow, warning: nil))
        }

        // Secrets pass through tmux's `-e KEY=VALUE` argv (no shell), so most
        // printables are safe. Reject only chars that would break a single-line
        // tmux arg: newlines, carriage returns, NULL bytes.
        if trimmed.contains(where: { $0 == "\n" || $0 == "\r" || $0 == "\0" }) {
            return RPCResponse(error: "Token contains invalid characters (newlines or NULL bytes are not allowed)")
        }

        // Infer credential kind. Claude-direct profiles can be OAuth (sk-ant-oat01-)
        // or API key (sk-ant-api03-); proxy profiles (baseURL set) accept any
        // non-empty string (the proxy decides what's valid).
        let kind: CredentialKind
        let isOAuth: Bool
        if params.baseURL != nil {
            // Proxy profile — credential is whatever the proxy expects. Treat
            // the secret as an API-key-shaped credential so it gets injected
            // via ANTHROPIC_API_KEY.
            kind = .apiKey
            isOAuth = false
        } else if trimmed.hasPrefix("sk-ant-oat01-") {
            // OAuth token (no longer stored in keychain per Phase 3)
            kind = .oauth
            isOAuth = true
        } else if trimmed.hasPrefix("sk-ant-api03-") {
            kind = .apiKey
            isOAuth = false
        } else {
            return RPCResponse(error: "Token must start with sk-ant-oat01- or sk-ant-api03-")
        }

        // Create DB row first so we have the canonical UUID; the keychain entry
        // is keyed by that UUID. If the keychain write fails we roll back the row.
        let profileRow = try await db.modelProfiles.create(
            name: name,
            kind: kind,
            baseURL: params.baseURL,
            model: params.model,
            fallbackModels: fallbackModels
        )

        // Only store keychain for API key profiles; OAuth profiles don't store secrets.
        var warning: String? = nil
        if !isOAuth {
            do {
                try ModelProfileKeychain.store(id: profileRow.id.uuidString, token: trimmed)
            } catch {
                try? await db.modelProfiles.delete(id: profileRow.id)
                return RPCResponse(error: "Failed to store secret in keychain")
            }
        } else {
            // OAuth profile was created with a token supplied, but OAuth profiles
            // don't store secrets. Warn the user that the token was discarded.
            warning = "OAuth profiles authenticate per-session via /login. The supplied token was not stored."
        }

        subscriptions.broadcast(delta: .modelProfilesChanged)
        return try RPCResponse(result: ModelProfileAddResult(profile: profileRow, warning: warning))
    }

    // MARK: - Delete

    func handleModelProfileDelete(_ paramsData: Data) async throws -> RPCResponse {
        let params = try decoder.decode(ModelProfileDeleteParams.self, from: paramsData)
        guard let profile = try await db.modelProfiles.get(id: params.id) else {
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
        // Only API-key profiles store a Keychain entry; OAuth and Bedrock profiles do not.
        if profile.kind == .apiKey {
            do {
                try ModelProfileKeychain.delete(id: params.id.uuidString)
            } catch {
                logger.warning("Failed to delete secret file for \(params.id, privacy: .public): \(error.localizedDescription, privacy: .public)")
            }
        }

        // Remove the per-profile config directory. Non-bedrock profiles have an
        // isolated config dir at ~/tbd/profiles/<uuid>/; bedrock profiles do not.
        if profile.kind != .bedrock {
            do {
                let profileDir = self.configDirManager.profileDirectory(forProfileID: params.id)
                try FileManager.default.removeItem(at: profileDir)
            } catch {
                logger.warning("Failed to delete config directory for \(params.id, privacy: .public): \(error.localizedDescription, privacy: .public)")
            }
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
        guard let profile = try await db.modelProfiles.get(id: params.id) else {
            return RPCResponse(error: "Profile not found")
        }
        guard profile.kind != .bedrock else {
            return RPCResponse(error: "Cannot update endpoint on a bedrock profile")
        }
        try await db.modelProfiles.updateEndpoint(
            id: params.id,
            baseURL: params.baseURL,
            model: params.model,
            fallbackModels: normalizeFallbackModels(params.fallbackModels)
        )
        subscriptions.broadcast(delta: .modelProfilesChanged)
        return .ok()
    }

    // MARK: - Update Bedrock

    func handleModelProfileUpdateBedrock(_ paramsData: Data) async throws -> RPCResponse {
        let params = try decoder.decode(ModelProfileUpdateBedrockParams.self, from: paramsData)

        guard let profile = try await db.modelProfiles.get(id: params.id) else {
            return RPCResponse(error: "Profile not found")
        }
        guard profile.kind == .bedrock else {
            return RPCResponse(error: "Can only update bedrock fields on a bedrock profile")
        }

        let region = params.awsRegion.trimmingCharacters(in: .whitespacesAndNewlines)
        let model = params.model.trimmingCharacters(in: .whitespacesAndNewlines)
        let awsProfileRaw = (params.awsProfile ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let awsProfile: String? = awsProfileRaw.isEmpty ? nil : awsProfileRaw

        guard !region.isEmpty else {
            return RPCResponse(error: "AWS region is required for bedrock profiles")
        }
        guard !model.isEmpty else {
            return RPCResponse(error: "Bedrock model id is required")
        }

        try await db.modelProfiles.updateBedrock(
            id: params.id,
            awsRegion: region,
            awsProfile: awsProfile,
            model: model,
            fallbackModels: normalizeFallbackModels(params.fallbackModels)
        )
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

    func handleModelProfileSetPrimaryAgentPreference(_ paramsData: Data) async throws -> RPCResponse {
        let params = try decoder.decode(ModelProfileSetAgentPreferenceParams.self, from: paramsData)
        try await db.config.setPrimaryAgentPreference(params.preference)
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

        // Proxy, bedrock, and oauth profiles can't be polled against the Claude API usage endpoint.
        // OAuth profiles authenticate per-session and don't store a TBD-side secret.
        // Proxy and bedrock profiles are not supported by the Claude API usage endpoint.
        if profile.baseURL != nil || profile.kind == .bedrock || profile.kind == .oauth {
            return RPCResponse(error: "Usage tracking is not available for \(profile.kind == .oauth ? "OAuth" : profile.baseURL != nil ? "proxy" : "bedrock") profiles")
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
