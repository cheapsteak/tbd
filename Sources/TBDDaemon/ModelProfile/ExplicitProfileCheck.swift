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
    /// What a profile that exists lacks to start a session.
    enum MissingCredential: Equatable, Sendable {
        /// An OAuth profile with no account in its config directory.
        case login
        /// A token profile with no stored token.
        case token
        /// An API-key profile with no stored key.
        case apiKey
    }

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
        guard requireCredentials, let missing = try missingCredential(of: row) else { return nil }
        switch missing {
        case .login:
            return "Model profile '\(row.name)' is not logged in. Run tbd profile login \(row.name), then try again."
        case .token:
            return "Model profile '\(row.name)' has no stored token. Add one in TBD Settings → Model Profiles, then try again."
        case .apiKey:
            return "Model profile '\(row.name)' has no stored API key. Add one in TBD Settings → Model Profiles, then try again."
        }
    }

    /// What `row` lacks to start a session, or nil when it lacks nothing.
    /// These are exactly the credential refusals of
    /// `refusal(for:requireCredentials:)`, read through the same closures, so
    /// a caller that shows a profile as usable agrees with the create that
    /// checks it. A Bedrock profile lacks nothing here, because AWS owns its
    /// credentials. Throws when the stored secret cannot be read.
    func missingCredential(of row: ModelProfile) throws -> MissingCredential? {
        switch row.kind {
        case .oauth:
            return Self.isBlank(loginIdentity(row.id)) ? .login : nil
        case .oauthToken:
            return try Self.isBlank(secret(row.id)) ? .token : nil
        case .apiKey:
            return try Self.isBlank(secret(row.id)) ? .apiKey : nil
        case .bedrock:
            return nil
        }
    }

    private static func isBlank(_ value: String?) -> Bool {
        value?.isEmpty ?? true
    }
}
