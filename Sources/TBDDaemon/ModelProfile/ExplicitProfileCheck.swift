import Foundation
import TBDShared

/// Checks a model profile a caller named explicitly — `worktree.create`'s
/// `profileID`, `terminal.create`'s `overrideProfileID` — before anything of
/// the create exists, so an unusable profile is refused with its fix instead
/// of falling back to another account or opening a tab at Claude's login
/// screen (docs/specs/2026-11-10-create-with-profile-and-model-design.md).
///
/// The reads are closures so this folder stays below `Claude`, which owns the
/// profile config directories the login test reads.
struct ExplicitProfileCheck: Sendable {
    /// The profile's row, or nil when it does not exist.
    let profile: @Sendable (UUID) async throws -> ModelProfile?
    /// The profile's stored secret, for a token or API-key profile.
    let secret: @Sendable (UUID) throws -> String?
    /// The account email in the profile's config directory, which an OAuth
    /// profile has once it has logged in (`tbd profile list` reads the same).
    let loginIdentity: @Sendable (UUID) -> String?

    /// nil when usable; otherwise the refusal message.
    ///
    /// `requireCredentials: false` checks only that the profile exists. A
    /// login session passes it, because its profile is not logged in yet.
    func refusal(for id: UUID, requireCredentials: Bool) async throws -> String? {
        guard let row = try await profile(id) else {
            return "Model profile \(id.uuidString) does not exist. Run tbd profile list to see the profiles."
        }
        guard requireCredentials else { return nil }
        switch row.kind {
        case .oauth:
            guard Self.isBlank(loginIdentity(id)) else { return nil }
            return "Model profile '\(row.name)' is not logged in. Run tbd profile login \(row.name), then try again."
        case .oauthToken:
            guard try Self.isBlank(secret(id)) else { return nil }
            return "Model profile '\(row.name)' has no stored token. Add one in TBD Settings → Model Profiles, then try again."
        case .apiKey:
            guard try Self.isBlank(secret(id)) else { return nil }
            return "Model profile '\(row.name)' has no stored API key. Add one in TBD Settings → Model Profiles, then try again."
        case .bedrock:
            // AWS owns a Bedrock profile's credentials.
            return nil
        }
    }

    private static func isBlank(_ value: String?) -> Bool {
        value?.isEmpty ?? true
    }
}
