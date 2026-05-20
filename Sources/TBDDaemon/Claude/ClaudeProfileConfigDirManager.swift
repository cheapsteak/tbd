import Foundation
import os
import TBDShared

private let logger = Logger(subsystem: "com.tbd.daemon", category: "claudeProfileConfigDir")

/// Manages per-profile isolated `CLAUDE_CONFIG_DIR` directories under
/// `~/tbd/profiles/<profile-id>/claude/`. Serves oauth, direct apiKey, and
/// proxy apiKey profiles with an isolated config directory where they can
/// maintain independent credentials.
///
/// On dir creation for API-key profiles, `.claude.json` is pre-populated with:
///   - `customApiKeyResponses.approved`: the last 20 chars of the profile's
///     API key (matches Claude Code's own storage format) so the user isn't
///     prompted to approve the key on first invocation.
///   - `hasCompletedOnboarding: true` so the spawn doesn't drop into the
///     onboarding flow inside an empty config dir.
///
/// For OAuth profiles, `.claude.json` is pre-populated with only:
///   - `hasCompletedOnboarding: true` (no `customApiKeyResponses`, since the
///     user will `/login` into this isolated config dir).
public struct ClaudeProfileConfigDirManager: Sendable {
    let baseDirectory: URL

    public init(baseDirectory: URL? = nil) {
        // Resolve inside the init to keep the `TBDConstants.configDir` access
        // out of the caller's compilation context — see HookResolver for the
        // Xcode 26.3 unsafeMutableAddressor link-failure rationale.
        self.baseDirectory = baseDirectory
            ?? TBDConstants.configDir.appendingPathComponent("profiles", isDirectory: true)
    }

    public func profileDirectory(forProfileID profileID: UUID) -> URL {
        baseDirectory
            .appendingPathComponent(profileID.uuidString.lowercased(), isDirectory: true)
    }

    public func configDirectory(forProfileID profileID: UUID) -> URL {
        profileDirectory(forProfileID: profileID)
            .appendingPathComponent("claude", isDirectory: true)
    }

    /// Ensure the per-profile claude config dir exists, and that `.claude.json`
    /// contains a pre-approval for the supplied API key (last-20-char form).
    ///
    /// If the dir already exists but `.claude.json` is missing or doesn't yet
    /// include the approval for this key, the file is rewritten with the
    /// correct content. Existing approvals for other keys are preserved.
    @discardableResult
    public func ensureAPIKeyDir(forProfileID profileID: UUID, apiKey: String) throws -> URL {
        let dir = configDirectory(forProfileID: profileID)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        let approvalToken = Self.approvalToken(forAPIKey: apiKey)
        let claudeJSONPath = dir.appendingPathComponent(".claude.json")

        var approved: [String] = []
        var rejected: [String] = []
        var hasOnboarding = true

        if let existing = try? Data(contentsOf: claudeJSONPath),
           let parsed = try? JSONSerialization.jsonObject(with: existing) as? [String: Any] {
            if let responses = parsed["customApiKeyResponses"] as? [String: Any] {
                approved = (responses["approved"] as? [String]) ?? []
                rejected = (responses["rejected"] as? [String]) ?? []
            }
            hasOnboarding = (parsed["hasCompletedOnboarding"] as? Bool) ?? true
        }

        if !approved.contains(approvalToken) {
            approved.append(approvalToken)
        }

        let payload: [String: Any] = [
            "customApiKeyResponses": [
                "approved": approved,
                "rejected": rejected,
            ],
            "hasCompletedOnboarding": hasOnboarding,
        ]
        let data = try JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: claudeJSONPath, options: [.atomic])

        logger.debug("ensured claude config dir at \(dir.path, privacy: .public) for profile \(profileID, privacy: .public)")
        return dir
    }

    /// Ensure the per-profile claude config dir exists for an OAuth profile,
    /// and write a minimal `.claude.json` with only `hasCompletedOnboarding: true`
    /// if the file does not already exist. If the file already exists, leave it
    /// untouched.
    ///
    /// OAuth profiles do not need a pre-approved API key, so no
    /// `customApiKeyResponses` is written. The user will `/login` once into
    /// this isolated config dir, and the credential persists in the Keychain
    /// entry derived from the `CLAUDE_CONFIG_DIR` path.
    @discardableResult
    public func ensureOAuthDir(forProfileID profileID: UUID) throws -> URL {
        let dir = configDirectory(forProfileID: profileID)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        let claudeJSONPath = dir.appendingPathComponent(".claude.json")

        // If `.claude.json` already exists, leave it untouched.
        if FileManager.default.fileExists(atPath: claudeJSONPath.path) {
            logger.debug("claude config dir exists at \(dir.path, privacy: .public) for oauth profile \(profileID, privacy: .public); skipping .claude.json")
            return dir
        }

        let payload: [String: Any] = [
            "hasCompletedOnboarding": true,
        ]
        let data = try JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: claudeJSONPath, options: [.atomic])

        logger.debug("ensured claude config dir at \(dir.path, privacy: .public) for oauth profile \(profileID, privacy: .public)")
        return dir
    }

    /// Claude Code stores approved keys as the last 20 chars of the key
    /// (confirmed by inspecting `~/.claude.json#customApiKeyResponses.approved`).
    /// For keys shorter than 20 chars (unusual but possible in tests), use the
    /// full string — matches Claude Code's `.suffix(20)` behavior.
    public static func approvalToken(forAPIKey apiKey: String) -> String {
        String(apiKey.suffix(20))
    }
}

extension ClaudeProfileConfigDirManager {
    /// Ensure the per-profile claude config dir for a resolved profile and
    /// return its path. Returns nil for bedrock profiles (which do not
    /// need config-dir isolation), nil profile, and apiKey profiles with
    /// a missing secret.
    ///
    /// For `.oauth` profiles, calls `ensureOAuthDir`.
    /// For `.apiKey` profiles, calls `ensureAPIKeyDir` (needs `profile.secret`;
    /// if the secret is nil, logs a warning and returns nil).
    /// For `.bedrock` profiles, returns nil.
    ///
    /// Filesystem errors are logged and swallowed — failing to write
    /// the config dir shouldn't break terminal spawn.
    static func resolveConfigDir(for profile: ResolvedModelProfile?) -> String? {
        guard let profile else { return nil }

        let manager = ClaudeProfileConfigDirManager()

        switch profile.kind {
        case .oauth:
            do {
                let url = try manager.ensureOAuthDir(forProfileID: profile.profileID)
                return url.path
            } catch {
                logger.warning("failed to ensure oauth config dir for profile \(profile.profileID, privacy: .public): \(error.localizedDescription, privacy: .public)")
                return nil
            }

        case .apiKey:
            guard let apiKey = profile.secret else {
                logger.warning("api-key profile \(profile.profileID, privacy: .public) has no secret; skipping config dir")
                return nil
            }
            do {
                let url = try manager.ensureAPIKeyDir(forProfileID: profile.profileID, apiKey: apiKey)
                return url.path
            } catch {
                logger.warning("failed to ensure api-key config dir for profile \(profile.profileID, privacy: .public): \(error.localizedDescription, privacy: .public)")
                return nil
            }

        case .bedrock:
            // Bedrock doesn't need config-dir isolation.
            return nil
        }
    }
}
