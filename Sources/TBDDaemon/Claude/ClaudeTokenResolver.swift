import Foundation
import TBDShared

public struct ResolvedClaudeToken: Sendable, Equatable {
    public let tokenID: UUID
    public let name: String
    public let kind: ClaudeTokenKind
    public let secret: String
}

public struct ClaudeTokenResolver: Sendable {
    let tokens: ClaudeTokenStore
    let repos: RepoStore
    let config: ConfigStore
    let keychain: @Sendable (String) throws -> String?

    public init(
        tokens: ClaudeTokenStore,
        repos: RepoStore,
        config: ConfigStore,
        keychain: @Sendable @escaping (String) throws -> String? = { try ClaudeTokenKeychain.load(id: $0) }
    ) {
        self.tokens = tokens
        self.repos = repos
        self.config = config
        self.keychain = keychain
    }

    private func loadResolved(id: UUID) async throws -> ResolvedClaudeToken? {
        guard let row = try await tokens.get(id: id) else { return nil }
        guard let secret = try keychain(id.uuidString), !secret.isEmpty else { return nil }
        return ResolvedClaudeToken(
            tokenID: row.id,
            name: row.name,
            kind: row.kind,
            secret: secret
        )
    }

    public func resolve(repoID: UUID?) async throws -> ResolvedClaudeToken? {
        // Step 1: repo override
        if let repoID, let repo = try await repos.get(id: repoID),
           let overrideID = repo.claudeTokenOverrideID {
            if let resolved = try await loadResolved(id: overrideID) {
                try await tokens.touchLastUsed(id: resolved.tokenID)
                return resolved
            }
            FileHandle.standardError.write(Data(
                "[ClaudeTokenResolver] warning: claude token override \(overrideID) for repo \(repoID) is missing; falling back to global default\n".utf8
            ))
        }

        // Step 2: global default
        if let defaultID = try await config.get().defaultClaudeTokenID {
            if let resolved = try await loadResolved(id: defaultID) {
                try await tokens.touchLastUsed(id: resolved.tokenID)
                return resolved
            }
            return nil
        }

        // Step 3: nothing applies
        return nil
    }
}
