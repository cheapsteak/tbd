import Foundation
import GRDB
import os
import TBDShared

private let configLogger = Logger(subsystem: "com.tbd.daemon", category: "config")

struct ConfigRecord: Codable, FetchableRecord, PersistableRecord, Sendable {
    static let databaseTableName = "config"

    var id: String
    var default_profile_id: String?
    var primary_agent_preference: String?
    /// JSON-encoded `[String: ClaudeEnvValue]` overrides map. Nil/absent
    /// means no overrides — every setting falls back to its registry default.
    var claude_env_settings: String?
    /// JSON-encoded `[String: String]` free-form env overrides (global scope).
    var env_overrides: String?
    var auto_archive_on_merge_default: Bool?
    var auto_hibernate_on_merge_default: Bool?
    var auto_resume_on_limit_reset: Bool?
    var scratch_instructions: String?
    var scratch_rename_prompt: String?
    var scratch_profile_override_id: String?
    /// Nightwatch mode: 'off', 'daywatch', or 'nightwatch'. Nil/absent defaults to 'off'.
    var nightwatch_mode: String?
    var auto_hibernate_enabled: Bool?
    var hibernate_idle_minutes: Int?
    var control_mode_enabled: Bool?
    var auto_resume_on_api_error: Bool?
    var hibernate_input_veto_enabled: Bool?
    var auto_close_setup_enabled: Bool?
    /// Pre-accept Claude's folder-trust dialog for the worktrees of registered
    /// repos (TBD-created ones and the repo's own checkout), excluding
    /// fork-PR-head checkouts. Default ON (see the
    /// `v66_config_auto_trust_worktrees` migration).
    var auto_trust_worktrees: Bool?
    var gc_enabled: Bool?
    var gc_grace_seconds: Int?
    var gc_snapshot_retention_days: Int?
    var daemon_panel_surface_enabled: Bool?
    var agent_panel_control_enabled: Bool?
    var remote_backends_enabled: Bool?
    /// Delivery acknowledgement (design §12). Nil/absent means OFF — the
    /// `v69_config_delivery_verification` column default.
    var delivery_verification_enabled: Bool?

    func toModel() -> Config {
        Config(
            defaultProfileID: default_profile_id.flatMap(UUID.init(uuidString:)),
            primaryAgentPreference: primary_agent_preference
                .flatMap(PrimaryAgentPreference.init(rawValue:)) ?? .defaultValue,
            envSettingOverrides: ConfigStore.decodeOverrides(claude_env_settings),
            envOverrides: EnvOverridesCoding.decode(env_overrides),
            autoArchiveOnMergeDefault: auto_archive_on_merge_default ?? false,
            autoHibernateOnMergeDefault: auto_hibernate_on_merge_default ?? false,
            autoResumeOnLimitReset: auto_resume_on_limit_reset ?? false,
            scratchInstructions: scratch_instructions,
            scratchRenamePrompt: scratch_rename_prompt,
            scratchProfileOverrideID: scratch_profile_override_id.flatMap(UUID.init(uuidString:)),
            nightwatchMode: nightwatch_mode
                .flatMap(NightwatchMode.init(rawValue:)) ?? .off,
            autoHibernateEnabled: auto_hibernate_enabled ?? false,
            // Clamped on read (not just on write) so every consumer sees a
            // bounded value regardless of what's actually in the row — a
            // hand-edited DB, a value written by an older/newer daemon
            // build, or any other row that bypassed `setAutoHibernate`.
            hibernateIdleMinutes: min(
                max(
                    hibernate_idle_minutes ?? Config.defaultHibernateIdleMinutes,
                    Config.minHibernateIdleMinutes
                ),
                Config.maxHibernateIdleMinutes
            ),
            controlModeEnabled: control_mode_enabled ?? false,
            autoResumeOnApiError: auto_resume_on_api_error ?? false,
            hibernateInputVetoEnabled: hibernate_input_veto_enabled ?? false,
            autoCloseSetupEnabled: auto_close_setup_enabled ?? false,
            autoTrustWorktrees: auto_trust_worktrees ?? true,
            gcEnabled: gc_enabled ?? true,
            gcGraceSeconds: gc_grace_seconds ?? Config.defaultGCGraceSeconds,
            gcSnapshotRetentionDays: gc_snapshot_retention_days ?? Config.defaultGCSnapshotRetentionDays,
            panelSurfaceEnabled: daemon_panel_surface_enabled ?? false,
            agentPanelControlEnabled: agent_panel_control_enabled ?? false,
            remoteBackendsEnabled: remote_backends_enabled ?? false,
            deliveryVerificationEnabled: delivery_verification_enabled ?? false
        )
    }
}

public struct ConfigStore: Sendable {
    static let singletonID = "singleton"
    let writer: any DatabaseWriter

    init(writer: any DatabaseWriter) {
        self.writer = writer
    }

    public func get() async throws -> Config {
        try await writer.read { db in
            try ConfigRecord.fetchOne(db, key: Self.singletonID)?.toModel() ?? Config()
        }
    }

    /// Decode the `claude_env_settings` JSON column into an overrides map.
    /// Any malformed/absent value decodes to an empty map so a corrupt row
    /// degrades to registry defaults rather than crashing a spawn. A genuinely
    /// corrupt row (JSON present but undecodable) is logged so it's observable
    /// via `log stream` instead of silently resetting the user's settings.
    static func decodeOverrides(_ json: String?) -> [String: ClaudeEnvValue] {
        guard let json, let data = json.data(using: .utf8) else { return [:] }
        do {
            return try JSONDecoder().decode([String: ClaudeEnvValue].self, from: data)
        } catch {
            configLogger.error(
                "Corrupt claude_env_settings row, falling back to defaults: \(String(describing: error), privacy: .public)"
            )
            return [:]
        }
    }

    public func setDefaultProfileID(_ id: UUID?) async throws {
        try await writer.write { db in
            try db.execute(
                sql: "UPDATE config SET default_profile_id = ? WHERE id = ?",
                arguments: [id?.uuidString, Self.singletonID]
            )
        }
    }

    public func setPrimaryAgentPreference(_ preference: PrimaryAgentPreference) async throws {
        try await writer.write { db in
            try db.execute(
                sql: "UPDATE config SET primary_agent_preference = ? WHERE id = ?",
                arguments: [preference.rawValue, Self.singletonID]
            )
        }
    }

    /// Persist the Claude spawn-env setting overrides map. An empty map
    /// clears all overrides; spawns then use every setting's registry default.
    public func setEnvSettingOverrides(_ overrides: [String: ClaudeEnvValue]) async throws {
        let json = String(data: try JSONEncoder().encode(overrides), encoding: .utf8)
        try await writer.write { db in
            try db.execute(
                sql: "UPDATE config SET claude_env_settings = ? WHERE id = ?",
                arguments: [json, Self.singletonID]
            )
        }
    }

    /// Persist the global free-form env overrides. Empty clears the column.
    public func setEnvOverrides(_ overrides: [String: String]) async throws {
        let json = EnvOverridesCoding.encode(overrides)
        try await writer.write { db in
            try db.execute(
                sql: "UPDATE config SET env_overrides = ? WHERE id = ?",
                arguments: [json, Self.singletonID]
            )
        }
    }

    /// Persist the global auto-archive-on-merge default. When true, every
    /// worktree that hasn't overridden `autoArchiveOnMerge` will be archived
    /// when its PR merges.
    public func setAutoArchiveOnMergeDefault(_ enabled: Bool) async throws {
        try await writer.write { db in
            try db.execute(
                sql: "UPDATE config SET auto_archive_on_merge_default = ? WHERE id = ?",
                arguments: [enabled, Self.singletonID]
            )
        }
    }

    /// Persist the global auto-hibernate-on-merge default. When true, every
    /// worktree that hasn't overridden `autoHibernateOnMerge` will have its
    /// Claude sessions hibernated when its PR merges.
    public func setAutoHibernateOnMergeDefault(_ enabled: Bool) async throws {
        try await writer.write { db in
            try db.execute(
                sql: "UPDATE config SET auto_hibernate_on_merge_default = ? WHERE id = ?",
                arguments: [enabled, Self.singletonID]
            )
        }
    }

    /// Persist the session-limit auto-resume gate (default OFF).
    public func setAutoResumeOnLimitReset(_ enabled: Bool) async throws {
        try await writer.write { db in
            try db.execute(
                sql: "UPDATE config SET auto_resume_on_limit_reset = ? WHERE id = ?",
                arguments: [enabled, Self.singletonID]
            )
        }
    }

    /// Persist the transient API-error auto-resume gate (default OFF).
    public func setAutoResumeOnApiError(_ enabled: Bool) async throws {
        try await writer.write { db in
            try db.execute(
                sql: "UPDATE config SET auto_resume_on_api_error = ? WHERE id = ?",
                arguments: [enabled, Self.singletonID]
            )
        }
    }

    /// Persist the global scratch-space system-prompt override. Nil or a
    /// whitespace-only string clears the override, falling back to the
    /// built-in default scratch layer.
    public func setScratchInstructions(_ value: String?) async throws {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines)
        let toStore = (trimmed?.isEmpty ?? true) ? nil : value
        try await writer.write { db in
            try db.execute(
                sql: "UPDATE config SET scratch_instructions = ? WHERE id = ?",
                arguments: [toStore, Self.singletonID]
            )
        }
    }

    /// Persist the global scratch-space rename-nudge override. Nil or a
    /// whitespace-only string clears the override, falling back to the
    /// built-in default rename-nudge layer.
    public func setScratchRenamePrompt(_ value: String?) async throws {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines)
        let toStore = (trimmed?.isEmpty ?? true) ? nil : value
        try await writer.write { db in
            try db.execute(
                sql: "UPDATE config SET scratch_rename_prompt = ? WHERE id = ?",
                arguments: [toStore, Self.singletonID]
            )
        }
    }

    /// Persist the global model-profile override applied to scratch terminal
    /// spawns. Nil clears the override, falling back to the global default
    /// profile.
    public func setScratchProfileOverride(_ id: UUID?) async throws {
        try await writer.write { db in
            try db.execute(
                sql: "UPDATE config SET scratch_profile_override_id = ? WHERE id = ?",
                arguments: [id?.uuidString, Self.singletonID]
            )
        }
    }

    public func setNightwatchMode(_ mode: NightwatchMode) async throws {
        try await writer.write { db in
            try db.execute(
                sql: "UPDATE config SET nightwatch_mode = ? WHERE id = ?",
                arguments: [mode.rawValue, Self.singletonID]
            )
        }
    }

    /// Persist the auto-hibernate master switch + idle-timeout (minutes). The
    /// minutes value is floored at 1 so a zero/negative can't make the idle
    /// timer hibernate everything on the next sweep, and ceilinged at 99 days
    /// so a stale or hand-edited value can't produce an absurd timeout.
    /// `ConfigRecord.toModel()` applies the same clamp on every read, so a
    /// row that bypassed this method — hand-edited SQL, a value written by a
    /// different daemon build — still comes back bounded.
    public func setAutoHibernate(enabled: Bool, idleMinutes: Int) async throws {
        let minutes = min(max(Config.minHibernateIdleMinutes, idleMinutes), Config.maxHibernateIdleMinutes)
        try await writer.write { db in
            try db.execute(
                sql: "UPDATE config SET auto_hibernate_enabled = ?, hibernate_idle_minutes = ? WHERE id = ?",
                arguments: [enabled, minutes, Self.singletonID]
            )
        }
    }

    /// Persist the tmux control-mode opt-in. The attach gate re-reads this
    /// per decision (`env || flag`), so no daemon restart is required —
    /// but only newly created panes pick up the change.
    public func setControlModeEnabled(_ enabled: Bool) async throws {
        try await writer.write { db in
            try db.execute(
                sql: "UPDATE config SET control_mode_enabled = ? WHERE id = ?",
                arguments: [enabled, Self.singletonID]
            )
        }
    }

    /// Persist the pending-input veto for auto-hibernate (machine-interface
    /// guard that prevents hibernation of sessions with typed-but-unsent input).
    /// The hibernation sweep re-reads this per decision, so no daemon restart
    /// is required — changes take effect on the next sweep cycle.
    public func setHibernateInputVeto(enabled: Bool) async throws {
        try await writer.write { db in
            try db.execute(
                sql: "UPDATE config SET hibernate_input_veto_enabled = ? WHERE id = ?",
                arguments: [enabled, Self.singletonID]
            )
        }
    }

    /// Persist the delivery-acknowledgement opt-in (default OFF, soaking).
    ///
    /// **Enabling it takes effect at the next daemon start.** `terminal.send`
    /// re-reads this column per call — but only when the caller armed
    /// `--verify`, so an ordinary send pays nothing — while the observation
    /// machinery it gates is wired once, at startup. In between, `--verify` is
    /// refused with a message naming the restart, rather than dispatched with
    /// nothing armed.
    ///
    /// Turning it off does not cancel observations already armed; it stops new
    /// ones from being armed and makes `--verify` a refusal again — and that
    /// half does apply to the next send.
    public func setDeliveryVerification(enabled: Bool) async throws {
        try await writer.write { db in
            try db.execute(
                sql: "UPDATE config SET delivery_verification_enabled = ? WHERE id = ?",
                arguments: [enabled, Self.singletonID]
            )
        }
    }

    /// Persist the auto-close-setup-tab opt-in (default OFF, soaking). Read
    /// fresh at spawn time, so no daemon restart is required — applies to the
    /// next worktree creation.
    public func setAutoCloseSetup(enabled: Bool) async throws {
        try await writer.write { db in
            try db.execute(
                sql: "UPDATE config SET auto_close_setup_enabled = ? WHERE id = ?",
                arguments: [enabled, Self.singletonID]
            )
        }
    }

    /// Persist the auto-trust opt-out for TBD-created worktrees (default ON).
    /// Read fresh at every spawn/wake, so no daemon restart is required — the
    /// next Claude spawn picks it up. Turning it OFF does not un-trust anything
    /// already seeded; it only stops TBD from seeding new non-scratch paths.
    /// Scratch spaces are seeded unconditionally and are not governed by this.
    public func setAutoTrustWorktrees(enabled: Bool) async throws {
        try await writer.write { db in
            try db.execute(
                sql: "UPDATE config SET auto_trust_worktrees = ? WHERE id = ?",
                arguments: [enabled, Self.singletonID]
            )
        }
    }

    /// Persist the orphan-GC master switch (default ON).
    public func setGCEnabled(_ enabled: Bool) async throws {
        try await writer.write { db in
            try db.execute(
                sql: "UPDATE config SET gc_enabled = ? WHERE id = ?",
                arguments: [enabled, Self.singletonID]
            )
        }
    }

    /// Persist the daemon panel-surface store master switch (spec C Phase 2
    /// §8). Default OFF; the store stays inert until this flips on.
    public func setPanelSurfaceEnabled(_ enabled: Bool) async throws {
        try await writer.write { db in
            try db.execute(
                sql: "UPDATE config SET daemon_panel_surface_enabled = ? WHERE id = ?",
                arguments: [enabled, Self.singletonID]
            )
        }
    }

    /// Persist the agent-originated panel-control gate. Default OFF and
    /// independent of `daemon_panel_surface_enabled` — both must be true for
    /// an agent to mutate panel layout.
    public func setAgentPanelControlEnabled(_ enabled: Bool) async throws {
        try await writer.write { db in
            try db.execute(
                sql: "UPDATE config SET agent_panel_control_enabled = ? WHERE id = ?",
                arguments: [enabled, Self.singletonID]
            )
        }
    }

    /// Persist the remote-agent-backends master switch (spec 2026-07-24).
    /// Default OFF: the feature polls provider executables in the background
    /// and can stop remote sessions, so it is opt-in until it soaks.
    public func setRemoteBackendsEnabled(_ enabled: Bool) async throws {
        try await writer.write { db in
            try db.execute(
                sql: "UPDATE config SET remote_backends_enabled = ? WHERE id = ?",
                arguments: [enabled, Self.singletonID]
            )
        }
    }
}
