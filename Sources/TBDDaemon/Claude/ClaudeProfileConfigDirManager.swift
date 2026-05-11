import Foundation
import os
import TBDShared

private let logger = Logger(subsystem: "com.tbd.daemon", category: "claudeProfileConfigDir")

/// Manages per-profile isolated `ANTHROPIC_CONFIG_DIR` directories under
/// `~/tbd/profiles/<profile-id>/claude/`. Used only for proxy profiles
/// (`baseURL` non-nil) so Claude Code's auth-conflict check doesn't see the
/// user's claude.ai OAuth in `~/.claude/.credentials.json` while we're also
/// passing `ANTHROPIC_API_KEY`.
///
/// On dir creation we pre-populate `.claude.json` with:
///   - `customApiKeyResponses.approved`: the last 20 chars of the profile's
///     API key (matches Claude Code's own storage format) so the user isn't
///     prompted to approve the key on first invocation.
///   - `hasCompletedOnboarding: true` so the spawn doesn't drop into the
///     onboarding flow inside an empty config dir.
///
/// Direct-Claude profiles (baseURL == nil) do NOT use this — they keep
/// reading `~/.claude` so the user's OAuth login flows through normally.
struct ClaudeProfileConfigDirManager: Sendable {
    let baseDirectory: URL

    init(
        baseDirectory: URL = TBDConstants.configDir.appendingPathComponent("profiles", isDirectory: true)
    ) {
        self.baseDirectory = baseDirectory
    }

    func configDirectory(forProfileID profileID: UUID) -> URL {
        baseDirectory
            .appendingPathComponent(profileID.uuidString.lowercased(), isDirectory: true)
            .appendingPathComponent("claude", isDirectory: true)
    }

    /// Ensure the per-profile claude config dir exists, and that `.claude.json`
    /// contains a pre-approval for the supplied API key (last-20-char form).
    ///
    /// If the dir already exists but `.claude.json` is missing or doesn't yet
    /// include the approval for this key, the file is rewritten with the
    /// correct content. Existing approvals for other keys are preserved.
    @discardableResult
    func ensureDir(forProfileID profileID: UUID, apiKey: String) throws -> URL {
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

    /// Claude Code stores approved keys as the last 20 chars of the key
    /// (confirmed by inspecting `~/.claude.json#customApiKeyResponses.approved`).
    /// For keys shorter than 20 chars (unusual but possible in tests), use the
    /// full string — matches Claude Code's `.suffix(20)` behavior.
    static func approvalToken(forAPIKey apiKey: String) -> String {
        String(apiKey.suffix(20))
    }
}

extension ClaudeProfileConfigDirManager {
    /// Convenience: ensure the per-profile claude config dir for a resolved
    /// profile and return its path — but ONLY for proxy profiles (baseURL
    /// non-nil) using an API key. Returns nil for direct-Claude profiles or
    /// OAuth-secret profiles, signalling the caller to NOT inject
    /// `ANTHROPIC_CONFIG_DIR`. Filesystem errors are logged and swallowed —
    /// failing to write the pre-approval shouldn't break terminal spawn.
    static func resolveConfigDir(for profile: ResolvedModelProfile?) -> String? {
        guard let profile, profile.baseURL != nil, profile.kind == .apiKey else { return nil }
        do {
            let url = try ClaudeProfileConfigDirManager()
                .ensureDir(forProfileID: profile.profileID, apiKey: profile.secret)
            return url.path
        } catch {
            logger.warning("failed to ensure claude config dir for profile \(profile.profileID, privacy: .public): \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }
}
