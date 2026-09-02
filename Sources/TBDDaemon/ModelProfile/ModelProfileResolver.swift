import Foundation
import os
import TBDShared

private let logger = Logger(subsystem: "com.tbd.daemon", category: "modelProfileResolver")

public struct ResolvedModelProfile: Sendable, Equatable {
    public let profileID: UUID
    public let name: String
    public let kind: CredentialKind
    public let baseURL: String?
    public let model: String?
    public let secret: String?
    public let awsRegion: String?
    public let awsProfile: String?
    /// Ordered fallback model ids for the Claude `fallbackModel` setting.
    /// nil/empty = no fallback configured for this profile.
    public let fallbackModels: [String]?
    /// Free-form env overrides carried by this profile (profile scope). Merged
    /// into the spawned session's env under `global < repo < profile` precedence.
    public let envOverrides: [String: String]
}

public struct ModelProfileResolver: Sendable {
    let profiles: ModelProfileStore
    let repos: RepoStore
    let config: ConfigStore
    let keychain: @Sendable (String) throws -> String?

    public init(
        profiles: ModelProfileStore,
        repos: RepoStore,
        config: ConfigStore,
        keychain: @Sendable @escaping (String) throws -> String? = { try ModelProfileKeychain.load(id: $0) }
    ) {
        self.profiles = profiles
        self.repos = repos
        self.config = config
        self.keychain = keychain
    }

    /// Load a profile by explicit ID, bypassing the precedence chain.
    /// Used by per-terminal pinning (resume) and mid-conversation swap.
    /// Returns nil if the row is missing. For .apiKey profiles, also returns
    /// nil if the keychain secret is missing or empty. OAuth and bedrock
    /// profiles carry no TBD-stored secret and always succeed if the row
    /// exists; an .oauthToken profile carries one but still resolves without
    /// it (see `loadResolved`).
    public func loadByID(_ id: UUID) async throws -> ResolvedModelProfile? {
        try await loadResolved(id: id)
    }

    private func loadResolved(id: UUID) async throws -> ResolvedModelProfile? {
        guard let row = try await profiles.get(id: id) else { return nil }

        let secret: String?
        switch row.kind {
        case .apiKey:
            // An api-key profile is nothing but its key: with no secret there
            // is no credential to spawn under at all, so the row resolves to
            // nil and the caller falls through the precedence chain.
            guard let s = try keychain(id.uuidString), !s.isEmpty else { return nil }
            secret = s
        case .oauthToken:
            // A token profile carries a TBD-stored secret like `.apiKey`, but
            // a MISSING one deliberately does NOT fail resolution. The profile
            // still owns an isolated config dir, so spawning without the token
            // yields an unauthenticated pane that asks for a login — visible
            // and recoverable. Falling through the chain instead would
            // silently run the session under some other account.
            let stored = try keychain(id.uuidString)
            if let stored, !stored.isEmpty {
                secret = stored
            } else {
                logger.warning("token profile \(row.id, privacy: .public) has no stored secret; spawning without CLAUDE_CODE_OAUTH_TOKEN")
                secret = nil
            }
        case .oauth, .bedrock:
            secret = nil   // no TBD-stored secret
        }

        try await profiles.touchLastUsed(id: row.id)
        return ResolvedModelProfile(
            profileID: row.id,
            name: row.name,
            kind: row.kind,
            baseURL: row.baseURL,
            model: row.model,
            secret: secret,
            awsRegion: row.awsRegion,
            awsProfile: row.awsProfile,
            fallbackModels: row.fallbackModels,
            envOverrides: row.envOverrides
        )
    }

    /// Resolve the model profile for a spawn.
    ///
    /// `override` is an explicit per-creation profile id (e.g. chosen in the
    /// sidebar `+` profile picker). When non-nil AND it resolves, it wins over
    /// EVERY tier of the precedence chain below. A nil `override` (the default)
    /// preserves the exact pre-existing precedence: repo override → scratch
    /// override → global default → none.
    public func resolve(repoID: UUID?, override overrideID: UUID? = nil) async throws -> ResolvedModelProfile? {
        // Step 0: explicit per-creation override — highest priority. If the
        // row/keychain is missing we log and fall through to the normal chain
        // rather than fail the spawn.
        if let overrideID {
            if let resolved = try await loadResolved(id: overrideID) {
                return resolved
            }
            logger.warning("explicit profile override \(overrideID, privacy: .public) is missing; falling back to precedence chain")
        }

        // Step 1: per-repo override.
        if let repoID, let repo = try await repos.get(id: repoID),
           let overrideID = repo.profileOverrideID {
            if let resolved = try await loadResolved(id: overrideID) {
                return resolved
            }
            logger.warning("profile override \(overrideID, privacy: .public) for repo \(repoID, privacy: .public) is missing; falling back to global default")
        }

        let cfg = try await config.get()

        // Step 1.5: scratch override. `repoID == nil` is the sole signal for a
        // scratch (repo-less) spawn — see resolve(repoID:) call sites. Repo-scoped
        // calls (repoID != nil) never consult scratchProfileOverrideID.
        if repoID == nil, let scratchOverrideID = cfg.scratchProfileOverrideID {
            if let resolved = try await loadResolved(id: scratchOverrideID) {
                return resolved
            }
            logger.warning("scratch profile override \(scratchOverrideID, privacy: .public) is missing; falling back to global default")
        }

        // Step 2: global default.
        if let defaultID = cfg.defaultProfileID {
            if let resolved = try await loadResolved(id: defaultID) {
                return resolved
            }
            logger.warning("global default profile \(defaultID, privacy: .public) is missing; no env will be injected")
            return nil
        }

        // Step 3: nothing applies.
        return nil
    }
}
