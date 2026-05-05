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
    public let secret: String
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
    /// Returns nil if the row is missing OR the keychain secret is missing/empty.
    public func loadByID(_ id: UUID) async throws -> ResolvedModelProfile? {
        try await loadResolved(id: id)
    }

    private func loadResolved(id: UUID) async throws -> ResolvedModelProfile? {
        guard let row = try await profiles.get(id: id) else { return nil }
        guard let secret = try keychain(id.uuidString), !secret.isEmpty else { return nil }
        try await profiles.touchLastUsed(id: row.id)
        return ResolvedModelProfile(
            profileID: row.id,
            name: row.name,
            kind: row.kind,
            baseURL: row.baseURL,
            model: row.model,
            secret: secret
        )
    }

    public func resolve(repoID: UUID?) async throws -> ResolvedModelProfile? {
        // Step 1: per-repo override.
        if let repoID, let repo = try await repos.get(id: repoID),
           let overrideID = repo.profileOverrideID {
            if let resolved = try await loadResolved(id: overrideID) {
                return resolved
            }
            logger.warning("profile override \(overrideID, privacy: .public) for repo \(repoID, privacy: .public) is missing; falling back to global default")
        }

        // Step 2: global default.
        if let defaultID = try await config.get().defaultProfileID {
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
