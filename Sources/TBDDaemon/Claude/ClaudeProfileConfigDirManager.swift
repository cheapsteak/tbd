import Foundation
import os
import TBDShared

private let logger = Logger(subsystem: "com.tbd.daemon", category: "claudeProfileConfigDir")

/// Manages per-profile isolated `CLAUDE_CONFIG_DIR` directories under
/// `~/tbd/profiles/<profile-id>/claude/`. Serves oauth, direct apiKey, and
/// proxy apiKey profiles with an isolated config directory where they can
/// maintain independent credentials.
///
/// Each profile dir mirrors customization slots from the host's `~/.claude/`
/// directory via symlinks: `projects/`, `plugins/`, `skills/`, `agents/`,
/// `commands/`, `hooks/`, `CLAUDE.md`, and `settings.json`. Per-profile identity
/// (`.claude.json`, Keychain entry keyed on `CLAUDE_CONFIG_DIR` path, and
/// `.credentials.json` as a fallback when Keychain is unavailable) is
/// owned by each profile. The `apiKeyHelper` mode uses the profile's Keychain
/// entry as a bridge; do not store API keys outside the per-profile context.
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
    let hostBaseDirectory: URL

    public init(baseDirectory: URL? = nil, hostBaseDirectory: URL? = nil) {
        // Resolve inside the init to keep the `TBDConstants.configDir` access
        // out of the caller's compilation context — see HookResolver for the
        // Xcode 26.3 unsafeMutableAddressor link-failure rationale.
        self.baseDirectory = baseDirectory
            ?? TBDConstants.configDir.appendingPathComponent("profiles", isDirectory: true)

        // Honor TBD_CLAUDE_HOST_HOME env var (e.g., for test isolation, matching
        // the TBD_HOME pattern used by TBDConstants). Falls back to ~/.claude/
        // in production.
        if let override = hostBaseDirectory {
            self.hostBaseDirectory = override
        } else if let envOverride = ProcessInfo.processInfo.environment["TBD_CLAUDE_HOST_HOME"], !envOverride.isEmpty {
            self.hostBaseDirectory = URL(fileURLWithPath: envOverride, isDirectory: true)
        } else {
            self.hostBaseDirectory = FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(".claude", isDirectory: true)
        }
    }

    public func profileDirectory(forProfileID profileID: UUID) -> URL {
        baseDirectory
            .appendingPathComponent(profileID.uuidString.lowercased(), isDirectory: true)
    }

    public func configDirectory(forProfileID profileID: UUID) -> URL {
        profileDirectory(forProfileID: profileID)
            .appendingPathComponent("claude", isDirectory: true)
    }

    /// Slots that each TBD profile dir mirrors from the host's claude config dir.
    /// Symlinked from <profile>/claude/<slot> to <host-base>/<slot>.
    /// `projects` is special: pre-existing real-dir content is migrated into
    /// the host store before symlinking. Every other slot is left alone if it
    /// already exists as a non-empty real file or directory.
    private static let mirrorSlots: [String] = [
        "projects",
        "plugins",
        "skills",
        "agents",
        "commands",
        "hooks",
        "CLAUDE.md",
        "settings.json",
    ]

    /// Ensure one host-mirror slot is a symlink from the profile dir into the
    /// host base. Best-effort: filesystem errors are logged and swallowed.
    private func ensureMirrorSlot(
        _ name: String,
        in profileClaudeDir: URL,
        migrateContent: Bool
    ) {
        let fm = FileManager.default
        let hostEntry = hostBaseDirectory.appendingPathComponent(name)

        // Skip if the host doesn't have this slot at all.
        guard fm.fileExists(atPath: hostEntry.path) else { return }

        let profileEntry = profileClaudeDir.appendingPathComponent(name)

        // Already a symlink? Check target; if it's right, done. If wrong,
        // leave it and log (don't fight an owner we don't recognize).
        if let dest = try? fm.destinationOfSymbolicLink(atPath: profileEntry.path) {
            let resolved = URL(fileURLWithPath: dest, relativeTo: profileEntry.deletingLastPathComponent())
                .resolvingSymlinksInPath()
            if resolved == hostEntry.resolvingSymlinksInPath() { return }
            logger.warning("mirror slot \(name, privacy: .public) symlink for profile points elsewhere; leaving as-is")
            return
        }

        // Profile has a real entry. Handle per slot policy.
        var isDir: ObjCBool = false
        if fm.fileExists(atPath: profileEntry.path, isDirectory: &isDir) {
            if isDir.boolValue, migrateContent {
                // projects/ special-case: merge content into host store, then
                // remove the profile-side dir and proceed to symlink.
                do {
                    // Ensure host dir exists (created above by fileExists check
                    // succeeding, but be defensive on race / non-dir).
                    try fm.createDirectory(at: hostEntry, withIntermediateDirectories: true)
                    let entries = (try? fm.contentsOfDirectory(at: profileEntry, includingPropertiesForKeys: nil)) ?? []
                    var anySkipped = false
                    for entry in entries {
                        let dest = hostEntry.appendingPathComponent(entry.lastPathComponent)
                        if fm.fileExists(atPath: dest.path) {
                            logger.debug("collision migrating \(entry.lastPathComponent, privacy: .public) into \(name, privacy: .public); skipping")
                            anySkipped = true
                            continue
                        }
                        try fm.moveItem(at: entry, to: dest)
                    }
                    // Only remove profile-side dir if all entries were successfully migrated.
                    // If any were skipped due to collision, preserve the profile dir to avoid
                    // data loss (profile-unique sessions in the skipped dirs are still there).
                    if anySkipped {
                        logger.warning("projects migration incomplete for profile due to collisions; symlink will not be created. profile-side \(name, privacy: .public)/ dir preserved.")
                        return
                    }
                    try fm.removeItem(at: profileEntry)
                } catch {
                    logger.warning("failed migrating \(name, privacy: .public) for profile: \(error.localizedDescription, privacy: .public)")
                    return
                }
            } else if isDir.boolValue {
                // Non-projects directory in profile: replace only if empty.
                let entries = (try? fm.contentsOfDirectory(at: profileEntry, includingPropertiesForKeys: nil)) ?? []
                if entries.isEmpty {
                    try? fm.removeItem(at: profileEntry)
                } else {
                    logger.warning("profile has real \(name, privacy: .public)/ with content; leaving as-is")
                    return
                }
            } else {
                // Real file (e.g. profile-side settings.json or CLAUDE.md).
                // Don't destroy user content; leave alone.
                logger.warning("profile has real \(name, privacy: .public) file; leaving as-is")
                return
            }
        }

        // Create the symlink. Best-effort; on EEXIST race (concurrent winner),
        // verify idempotency before logging a warning.
        do {
            try fm.createSymbolicLink(at: profileEntry, withDestinationURL: hostEntry)
        } catch {
            // If entry now exists and is a symlink to the correct target,
            // treat as idempotent success. Otherwise log and return.
            if let dest = try? fm.destinationOfSymbolicLink(atPath: profileEntry.path) {
                let resolved = URL(fileURLWithPath: dest, relativeTo: profileEntry.deletingLastPathComponent())
                    .resolvingSymlinksInPath()
                if resolved == hostEntry.resolvingSymlinksInPath() { return }
            }
            logger.warning("failed creating mirror symlink for \(name, privacy: .public): \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Ensure every host-mirror slot is symlinked into the profile dir.
    /// Best-effort and per-entry isolated — one failing slot does not block
    /// the others.
    private func ensureHostMirrors(in profileClaudeDir: URL) {
        for slot in Self.mirrorSlots {
            ensureMirrorSlot(slot, in: profileClaudeDir, migrateContent: slot == "projects")
        }
    }

    /// Ensure the per-profile claude config dir exists, and that `.claude.json`
    /// contains a pre-approval for the supplied API key (last-20-char form).
    ///
    /// If the dir already exists but `.claude.json` is missing or doesn't yet
    /// include the approval for this key, the file is rewritten with the
    /// correct content. Existing approvals for other keys are preserved.
    /// All unknown top-level keys in the existing `.claude.json` are preserved.
    @discardableResult
    public func ensureAPIKeyDir(forProfileID profileID: UUID, apiKey: String) throws -> URL {
        let dir = configDirectory(forProfileID: profileID)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        let approvalToken = Self.approvalToken(forAPIKey: apiKey)
        let claudeJSONPath = dir.appendingPathComponent(".claude.json")

        var approved: [String] = []
        var rejected: [String] = []
        var hasOnboarding = true
        var unknownKeys: [String: Any] = [:]

        if let existing = try? Data(contentsOf: claudeJSONPath),
           let parsed = try? JSONSerialization.jsonObject(with: existing) as? [String: Any] {
            if let responses = parsed["customApiKeyResponses"] as? [String: Any] {
                approved = (responses["approved"] as? [String]) ?? []
                rejected = (responses["rejected"] as? [String]) ?? []
            }
            hasOnboarding = (parsed["hasCompletedOnboarding"] as? Bool) ?? true

            // Preserve all unknown top-level keys from the existing file.
            for (key, value) in parsed {
                if key != "customApiKeyResponses" && key != "hasCompletedOnboarding" {
                    unknownKeys[key] = value
                }
            }
        }

        if !approved.contains(approvalToken) {
            approved.append(approvalToken)
        }

        var payload: [String: Any] = unknownKeys
        payload["customApiKeyResponses"] = [
            "approved": approved,
            "rejected": rejected,
        ]
        payload["hasCompletedOnboarding"] = hasOnboarding

        let data = try JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: claudeJSONPath, options: [.atomic])

        ensureHostMirrors(in: dir)

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
    ///
    /// Host mirror slots are always ensured, regardless of whether `.claude.json`
    /// already existed. This is critical for profiles created before mirror support
    /// was added; without this, they would never get their symlinked customizations.
    @discardableResult
    public func ensureOAuthDir(forProfileID profileID: UUID) throws -> URL {
        let dir = configDirectory(forProfileID: profileID)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        let claudeJSONPath = dir.appendingPathComponent(".claude.json")

        // If `.claude.json` already exists, leave it untouched.
        if FileManager.default.fileExists(atPath: claudeJSONPath.path) {
            logger.debug("claude config dir exists at \(dir.path, privacy: .public) for oauth profile \(profileID, privacy: .public); skipping .claude.json")
        } else {
            let payload: [String: Any] = [
                "hasCompletedOnboarding": true,
            ]
            let data = try JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted, .sortedKeys])
            try data.write(to: claudeJSONPath, options: [.atomic])
        }

        // Always ensure host mirrors, even if .claude.json already existed.
        // Profiles created before mirror support was added must get their
        // symlinks set up on subsequent calls.
        ensureHostMirrors(in: dir)

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
