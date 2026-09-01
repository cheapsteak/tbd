import Foundation
import Security
import os
import TBDShared

private let logger = Logger(subsystem: "com.tbd.daemon", category: "modelProfileHandlers")

/// Normalize a user-supplied fallback model list: trim each id, drop blanks,
/// cap at 3 (Claude Code's documented maximum), and collapse an empty result
/// to nil so the column stores NULL. Order is preserved.
///
/// Deliberately duplicates the app-side `normalizedFallbackModels` in
/// `Sources/TBDApp/Settings/ModelProfilesSettingsView.swift` — defense-in-depth
/// so the daemon normalizes even payloads from clients that skip the UI helper.
/// Keep the two in sync.
func normalizeFallbackModels(_ raw: [String]?) -> [String]? {
    guard let raw else { return nil }
    let cleaned = raw
        .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        .filter { !$0.isEmpty }
        .prefix(3)
    return cleaned.isEmpty ? nil : Array(cleaned)
}

/// Why a secret cannot be stored, or nil when it can.
///
/// Secrets reach a spawned pane through tmux's `-e KEY=VALUE`, which is parsed
/// as one line, so a newline, carriage return or NULL byte would truncate or
/// corrupt the argument. Everything else printable is the credential issuer's
/// business, not ours.
///
/// The returned message never echoes the secret — no caller may put token bytes
/// in an error string.
func modelProfileSecretRejectionReason(_ secret: String) -> String? {
    secret.contains(where: { $0 == "\n" || $0 == "\r" || $0 == "\0" })
        ? "Token contains invalid characters (newlines or NULL bytes are not allowed)"
        : nil
}

/// Last four characters of a token profile's stored secret, for the app's
/// `Token •••• <tail>` caption — or nil when there is nothing safe to show.
///
/// nil for a missing or unreadable secret, and nil for a secret shorter than
/// four characters: a two-character "tail" would be a larger fraction of the
/// credential than the caption is worth. The whole secret never leaves the
/// daemon, and this value is computed per list call, never persisted.
func modelProfileTokenTail(forProfileID id: UUID) -> String? {
    guard let secret = try? ModelProfileKeychain.load(id: id.uuidString) else { return nil }
    let trimmed = secret.trimmingCharacters(in: .whitespacesAndNewlines)
    guard trimmed.count >= 4 else { return nil }
    return String(trimmed.suffix(4))
}

extension RPCRouter {

    // MARK: - List

    func handleModelProfileList() async throws -> RPCResponse {
        let profiles = try await db.modelProfiles.list()
        let usageByID = try await db.modelProfileUsage.fetchAll()
        let oauthSnapshots = await oauthUsagePoller?.allSnapshots() ?? [:]
        let result = profiles.map { profile -> ModelProfileWithUsage in
            // Bedrock profiles have no isolated config dir; everything else
            // gets one at ~/tbd/profiles/<uuid>/claude. loginIdentity is only
            // meaningful for OAuth profiles (Claude Code writes oauthAccount
            // into the isolated .claude.json after /login). Computed fresh on
            // every list call — this RPC is infrequent, so no caching.
            let configDirPath: String? = profile.kind == .bedrock
                ? nil
                : configDirManager.configDirectory(forProfileID: profile.id).path
            let loginIdentity: String? = profile.kind == .oauth
                ? configDirManager.loginIdentity(forProfileID: profile.id)
                : nil
            // Token profiles have no identity endpoint to ask (a setup token
            // 403s on /api/oauth/profile), so the masked tail is the only way
            // to tell two of them apart. Computed here beside loginIdentity,
            // for the same reason: it is a fact about the credential store,
            // and the app is never handed the token itself.
            let tokenTail: String? = profile.kind == .oauthToken
                ? modelProfileTokenTail(forProfileID: profile.id)
                : nil
            return ModelProfileWithUsage(
                profile: profile,
                usage: usageByID[profile.id],
                loginIdentity: loginIdentity,
                configDirPath: configDirPath,
                usageSnapshot: oauthSnapshots[profile.id],
                tokenTail: tokenTail
            )
        }
        let config = try await db.config.get()
        return try RPCResponse(result: ModelProfileListResult(
            profiles: result,
            defaultID: config.defaultProfileID,
            primaryAgentPreference: config.primaryAgentPreference,
            globalEnvOverrides: config.envOverrides,
            autoArchiveOnMergeDefault: config.autoArchiveOnMergeDefault,
            autoHibernateOnMergeDefault: config.autoHibernateOnMergeDefault,
            nightwatchMode: config.nightwatchMode,
            autoResumeOnLimitReset: config.autoResumeOnLimitReset,
            autoResumeOnApiError: config.autoResumeOnApiError,
            gcEnabled: config.gcEnabled,
            autoCreateNotesEnabled: config.autoCreateNotesEnabled,
            globalRemoteCreateDefaults: config.remoteCreateDefaults
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

        // ─── Claude token branch (explicit kind, never inferred) ──────────────
        // A `sk-ant-oat01-` value is ambiguous on its own: it is also what a
        // user pastes by mistake into a signed-in profile, which the branch
        // below deliberately discards with a warning. Only an explicit
        // `kind: .claudeToken` — the Add sheet's visible auth sub-picker —
        // means "store this and authenticate with it".
        if params.kind == .claudeToken {
            guard params.baseURL == nil else {
                return RPCResponse(error: "Token profiles are Claude-direct and cannot set a base URL")
            }
            let token = (params.token ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !token.isEmpty else {
                return RPCResponse(error: "A setup token is required for token profiles")
            }
            // Deliberately no `sk-ant-oat01-` prefix requirement. The token
            // format belongs to `claude setup-token`, not to TBD, and a
            // rejected credential surfaces as a rejected-token row the user
            // fixes with "Replace token" — a shape check here would only
            // strand people whenever that format moves.
            if let reason = modelProfileSecretRejectionReason(token) {
                return RPCResponse(error: reason)
            }

            let profileRow = try await db.modelProfiles.create(
                name: name,
                kind: .oauthToken,
                baseURL: nil,
                model: params.model,
                fallbackModels: fallbackModels
            )
            do {
                try ModelProfileKeychain.store(id: profileRow.id.uuidString, token: token)
            } catch {
                // Roll the row back: a token profile whose secret was never
                // written cannot authenticate at all, and the row is the only
                // pointer to the config dir it would otherwise grow.
                try? await db.modelProfiles.delete(id: profileRow.id)
                // Generic on purpose — an error string must never carry
                // token bytes.
                return RPCResponse(error: "Failed to store secret in keychain")
            }
            subscriptions.broadcast(delta: .modelProfilesChanged)
            return try RPCResponse(result: ModelProfileAddResult(profile: profileRow, warning: nil))
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

        if let reason = modelProfileSecretRejectionReason(trimmed) {
            return RPCResponse(error: reason)
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

        // NOTE: We deliberately do NOT touch terminal.profile_id here.
        // Running terminals keep the env var that was injected at spawn time;
        // mutating their stored profile id would mislead the UI about what the
        // already-running claude process is actually using.
        //
        // Cleanup order is load-bearing: the `model_profiles` row is the ONLY
        // pointer to `~/tbd/profiles/<uuid>/`, so it is deleted LAST. A daemon
        // killed partway now leaves "row present, directory gone or present" —
        // both benign — instead of a directory nothing will ever reclaim.
        // Individual cleanup failures stay log-only and non-fatal: the user
        // asked for the profile to be gone, and the profile-dir collector
        // reclaims whatever is left behind.
        // API-key and token profiles store a `<uuid>.token` secret file; OAuth
        // and Bedrock profiles do not. Both stored kinds are reclaimed here —
        // a secret outliving its profile is a credential nothing owns.
        if profile.kind == .apiKey || profile.kind == .oauthToken {
            do {
                try ModelProfileKeychain.delete(id: params.id.uuidString)
            } catch {
                logger.warning("Failed to delete secret file for \(params.id, privacy: .public): \(error.localizedDescription, privacy: .public)")
            }
        }

        // Remove the per-profile config directory. Non-bedrock profiles have an
        // isolated config dir at ~/tbd/profiles/<uuid>/; bedrock profiles do not.
        if profile.kind != .bedrock {
            // Also delete the Claude Code OAuth credential item that /login
            // wrote into the login keychain for this profile's isolated config
            // dir ("Claude Code-credentials-<sha256-prefix-of-configDir>").
            // The service name is always suffixed with the path-derived hash of
            // OUR config dir, so this can never touch the user's bare
            // "Claude Code-credentials" item (default ~/.claude). Done for
            // apiKey-kind profiles too — harmless if the item doesn't exist.
            // errSecItemNotFound is success: there was nothing to clean.
            let configDir = self.configDirManager.configDirectory(forProfileID: params.id)
            let status = claudeCredentialsKeychain.deleteCredentials(forConfigDirPath: configDir.path)
            switch status {
            case errSecSuccess:
                logger.info("Deleted Claude Code keychain credentials for profile \(params.id, privacy: .public)")
            case errSecItemNotFound:
                logger.debug("No Claude Code keychain credentials to delete for profile \(params.id, privacy: .public)")
            default:
                logger.warning("Failed to delete Claude Code keychain credentials for profile \(params.id, privacy: .public): OSStatus \(status, privacy: .public)")
            }

            do {
                let profileDir = self.configDirManager.profileDirectory(forProfileID: params.id)
                try FileManager.default.removeItem(at: profileDir)
            } catch {
                logger.warning("Failed to delete config directory for \(params.id, privacy: .public): \(error.localizedDescription, privacy: .public)")
            }
        }

        // Last DB mutation: everything keyed by the row has now been cleaned.
        try await db.modelProfiles.delete(id: params.id)

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

    // MARK: - Update Token

    /// `modelProfile.updateToken` — replace the stored `claude setup-token` on
    /// an `.oauthToken` profile.
    ///
    /// Setup tokens expire, so rotation is the only recovery path for a profile
    /// whose credential aged out or was revoked. It is deliberately an update
    /// rather than delete-and-recreate: the profile keeps its id, its isolated
    /// config dir, its usage history, and every worktree override pointing at
    /// it. The next usage probe re-reads the account behind the new token.
    func handleModelProfileUpdateToken(_ paramsData: Data) async throws -> RPCResponse {
        let params = try decoder.decode(ModelProfileUpdateTokenParams.self, from: paramsData)
        guard let profile = try await db.modelProfiles.get(id: params.id) else {
            return RPCResponse(error: "Profile not found")
        }
        guard profile.kind == .oauthToken else {
            return RPCResponse(error: "Can only replace the token on a token profile")
        }
        let token = params.token.trimmingCharacters(in: .whitespacesAndNewlines)
        // Blank means "the caller sent nothing", not "clear the credential":
        // leaving the stored token alone is expressed by not calling this.
        guard !token.isEmpty else {
            return RPCResponse(error: "Token cannot be empty")
        }
        if let reason = modelProfileSecretRejectionReason(token) {
            return RPCResponse(error: reason)
        }
        do {
            try ModelProfileKeychain.store(id: params.id.uuidString, token: token)
        } catch {
            // Generic on purpose — an error string must never carry token bytes.
            return RPCResponse(error: "Failed to store secret in keychain")
        }
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

    // MARK: - Reorder

    func handleModelProfileReorder(_ paramsData: Data) async throws -> RPCResponse {
        let params = try decoder.decode(ModelProfileReorderParams.self, from: paramsData)
        try await db.modelProfiles.reorder(profileIDs: params.profileIDs)
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

        // This endpoint serves direct api-key profiles only. OAuth profiles
        // authenticate per-session and store no TBD-side secret; proxy and
        // bedrock profiles are not supported by the Claude API usage endpoint;
        // and a token profile's setup token 403s on it — its utilization comes
        // from response headers on a separate probe, not from here.
        // Order preserved from the ternary this replaced, so the wording for
        // every pre-existing input is unchanged; `.oauthToken` is appended.
        let unsupportedLabel: String?
        if profile.kind == .oauth {
            unsupportedLabel = "OAuth"
        } else if profile.kind == .oauthToken {
            unsupportedLabel = "token"
        } else if profile.baseURL != nil {
            unsupportedLabel = "proxy"
        } else if profile.kind == .bedrock {
            unsupportedLabel = "bedrock"
        } else {
            unsupportedLabel = nil
        }
        if let unsupportedLabel {
            return RPCResponse(error: "Usage tracking is not available for \(unsupportedLabel) profiles")
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

    // MARK: - Usage Refresh (refresh-if-stale sweep of the OAuth usage poller)

    /// `modelProfile.usageRefresh` — sweep stale, eligible profiles (all
    /// logged-in OAuth profiles when params.id == nil, else one) and return
    /// the post-sweep snapshots. Profiles with a snapshot fresher than
    /// `OAuthProfileUsagePoller.refreshFreshness` or inside a backoff window
    /// are skipped (cached snapshot returned) — the picker calls this on
    /// every open, and that must never re-hammer a rate-limited endpoint.
    /// The poller broadcasts `.modelProfilesChanged` itself when data changes.
    func handleModelProfileUsageRefresh(_ paramsData: Data) async throws -> RPCResponse {
        let params = try decoder.decode(ModelProfileUsageRefreshParams.self, from: paramsData)
        guard let poller = oauthUsagePoller else {
            return RPCResponse(error: "OAuth usage poller is not running (mock mode or startup)")
        }
        let snapshots = await poller.sweepNow(profileID: params.id)
        let entries = snapshots
            .map { ModelProfileUsageSnapshotEntry(profileID: $0.key, snapshot: $0.value) }
            .sorted { $0.profileID.uuidString < $1.profileID.uuidString }
        return try RPCResponse(result: ModelProfileUsageRefreshResult(snapshots: entries))
    }

    // MARK: - Health Check

    func handleModelProfileHealthCheck(_ paramsData: Data) async throws -> RPCResponse {
        let params = try decoder.decode(ModelProfileHealthCheckParams.self, from: paramsData)
        let result = await ModelProfileHealthProbe.probe(baseURL: params.baseURL)
        return try RPCResponse(result: result)
    }

    // MARK: - Prepare Config Dir

    /// Ensure an OAuth profile's isolated `CLAUDE_CONFIG_DIR` exists and is
    /// seeded, and return its absolute path. Idempotent — safe to call before
    /// every `tbd profile login`. OAuth-only: apiKey dirs need the secret for
    /// pre-approval seeding (that provisioning stays on the spawn path), and
    /// bedrock profiles have no config dir at all.
    func handleModelProfilePrepareConfigDir(_ paramsData: Data) async throws -> RPCResponse {
        let params = try decoder.decode(ModelProfilePrepareConfigDirParams.self, from: paramsData)
        guard let profile = try await db.modelProfiles.get(id: params.id) else {
            return RPCResponse(error: "Profile not found")
        }
        guard profile.kind == .oauth else {
            return RPCResponse(error: "Profile '\(profile.name)' is a \(profile.kind.rawValue) profile — only OAuth profiles use an isolated login config dir")
        }
        let dir = try configDirManager.ensureOAuthDir(forProfileID: profile.id)
        return try RPCResponse(result: ModelProfilePrepareConfigDirResult(configDirPath: dir.path))
    }
}
