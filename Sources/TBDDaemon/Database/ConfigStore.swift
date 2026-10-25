import Foundation
import GRDB
import os
import TBDShared

private let configLogger = Logger(subsystem: "com.tbd.daemon", category: "config")

/// The `config` table's singleton row.
///
/// Five columns exist in the table and are deliberately absent here —
/// `gc_holder_rendezvous_enabled`, `gc_rowless_holders_enabled`,
/// `reap_holder_children_enabled`, `holder_row_reconcile_enabled` and
/// `holder_hibernation_enabled`. Holder-ness is a transport property, not a
/// separate opt-in: each of those legs now derives from the subsystem flag it
/// belongs to (`gc_enabled`, `auto_hibernate_enabled`) or runs unconditionally,
/// so nothing reads the columns.
///
/// `transcript_composer_enabled` and `remote_transcript_enabled` are absent
/// for a different reason: the transcript composer and the remote session
/// transcript have no gate. The composer's UI, the `terminal.completions`
/// probe, attachment writes and the attachments GC leg run unconditionally, as
/// do `remote.transcriptSync`, the remote transcript pane and the remote
/// composer, so nothing reads either column.
///
/// `model_proxy_enabled` and `model_proxy_port` are unused; nothing reads them.
///
/// Every one of these columns stays in the schema because a landed migration is
/// never edited and GRDB ignores columns a record does not name.
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
    var auto_hibernate_enabled: Bool?
    var hibernate_idle_minutes: Int?
    var control_mode_enabled: Bool?
    var auto_resume_on_api_error: Bool?
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
    /// Queued prompt on worktree creation (design 2026-08-10). **Genuinely
    /// tri-state**: the `v70_config_queued_prompt` column carries no SQL
    /// default, so `nil` here means "never chose" rather than "off". Resolve it
    /// through `Config.queuedPromptDefault`, never through `?? false`.
    var queued_prompt_enabled: Bool?
    /// Whether ordinary new worktrees start with an empty Notes tab.
    /// **Genuinely tri-state**: the backing migration carries no SQL default,
    /// so `nil` means "never chose" and resolves through
    /// `Config.autoCreateNotesDefault`.
    var auto_create_notes_enabled: Bool?
    /// Gate for the profile-dir collector
    /// (design 2026-08-15). **Genuinely tri-state**, same shape as
    /// `queued_prompt_enabled`: the `v78_config_gc_profile_dirs` column carries
    /// no SQL default, so `nil` here means "never chose" rather than "off".
    /// Resolve it through `Config.gcProfileDirsEnabledDefault`, never through
    /// `?? false`.
    var gc_profile_dirs_enabled: Bool?
    /// The Claude cloud sessions gate (design 2026-08-15 §7). **Genuinely
    /// tri-state**, same shape as `queued_prompt_enabled`: the
    /// `v81_config_claude_cloud` column carries no SQL default, so `nil` here
    /// means "never chose" rather than "off". Resolve it through
    /// `Config.claudeCloudEnabledDefault`, never through `?? false`.
    var claude_cloud_enabled: Bool?
    /// Gate for the orphaned-process collector
    /// (design 2026-08-18). **Genuinely tri-state**, same shape as
    /// `gc_profile_dirs_enabled`: the `v83_config_gc_orphan_processes` column
    /// carries no SQL default, so `nil` here means "never chose" rather than
    /// "off". Resolve it through `Config.gcOrphanProcessesEnabledDefault`,
    /// never through `?? false`.
    var gc_orphan_processes_enabled: Bool?
    /// Gate for the hang-stack reclaimer
    /// (design 2026-08-29). **Genuinely tri-state**, same shape as
    /// `gc_orphan_processes_enabled`: the
    /// `20260830021944_config_gc_hang_stacks` column carries no SQL default, so
    /// `nil` here means "never chose" rather than "off". Resolve it through
    /// `Config.gcHangStacksEnabledDefault`, never through `?? false`.
    var gc_hang_stacks_enabled: Bool?
    // `remote_peer_messaging_enabled` stays in the table (migration
    // `20260830003851_config_remote_peer_messaging`) but is read by nothing:
    // peer messaging is switched per repository in its `tbd.toml` instead.
    /// The pty-holder transport gate. **Genuinely tri-state**, same shape as
    /// `gc_hang_stacks_enabled`: the
    /// `20260831055718_config_pty_holder` migration carries no SQL default, so
    /// `nil` here means "never chose" rather than "off". Resolve it through
    /// `Config.ptyHolderDefault`, never through `?? false`.
    var pty_holder_enabled: Bool?
    /// Gate for `remote.delete`, the verb that destroys a provider-hosted agent
    /// session. **Genuinely tri-state**, same shape as `pty_holder_enabled`:
    /// the
    /// `20260902130000_config_remote_delete` migration carries no SQL default,
    /// so `nil` here means "never chose" rather than "off". Resolve it through
    /// `Config.remoteDeleteEnabledDefault`, never through `?? false`.
    var remote_delete_enabled: Bool?
    /// Gate for the orphan-GC leg that reclaims retained transcripts nobody
    /// references. **Genuinely tri-state**, same shape as
    /// `remote_delete_enabled`: the
    /// `20260902140000_config_gc_retained_transcripts` migration carries no SQL
    /// default, so `nil` here means "never chose" rather than "off". Resolve it
    /// through `Config.gcRetainedTranscriptsEnabledDefault`, never through
    /// `?? false`.
    var gc_retained_transcripts_enabled: Bool?
    /// Gate for the transcript's provisional assistant row. **Genuinely
    /// tri-state**, same shape as `gc_retained_transcripts_enabled`: the
    /// `20260907215725_config_transcript_streaming` migration carries no SQL
    /// default, so `nil` here means "never chose" rather than "off". Resolve it
    /// through `Config.transcriptStreamingDefault`, never through `?? false`.
    var transcript_streaming_enabled: Bool?
    /// Gate for profile balancing across multiple Claude accounts. When enabled,
    /// new sessions land on the eligible profile with the most room, adjusted for
    /// live session count (design 2026-09-05 §6). **Genuinely tri-state**, same
    /// shape as `gc_retained_transcripts_enabled`: the
    /// `20260905080315_config_profile_balancing` migration carries no SQL
    /// default, so `nil` here means "never chose" rather than "off". Resolve it
    /// through `Config.profileBalancingEnabledDefault`, never through
    /// `?? false`.
    var profile_balancing_enabled: Bool?
    /// Balancing's usage ceiling, in percent (design 2026-09-05 §5). NULL
    /// means never set; `ProfilePoolPolicy.resolved` supplies the shipped 85.
    var profile_balancing_usage_ceiling_percent: Int?
    /// Balancing's maximum reading age, in seconds. NULL means never set,
    /// which keeps each credential kind's own cadence-relative window.
    var profile_balancing_max_reading_age_seconds: Int?
    /// Schedule-based PR polling gate. **Genuinely tri-state**: the
    /// `20261002143454_config_pr_poll_schedule` migration carries no SQL default, so
    /// `nil` means "never chose". Resolve it through
    /// `Config.prPollScheduleDefault`, never through `?? false`.
    var pr_poll_schedule_enabled: Bool?
    /// Program Status Protocol (OSC 7501) gate. **Genuinely tri-state**: the
    /// `20261010043448_config_program_status` migration carries no SQL default,
    /// so `nil` means "never chose". Resolve it through
    /// `Config.programStatusEnabledDefault`, never through `?? false`.
    var program_status_enabled: Bool?
    /// Answering question and permission prompts from the transcript.
    /// **Genuinely tri-state**: the
    /// `20261010025458_config_transcript_prompt_answer` migration carries no SQL
    /// default, so `nil` means "never chose". Resolve it through
    /// `Config.transcriptPromptAnswerDefault`, never through `?? false`.
    var transcript_prompt_answer_enabled: Bool?
    /// Composer draft save-and-restore through the session mod. **Genuinely
    /// tri-state**: the `config_composer_draft` migration carries no SQL
    /// default, so `nil` means "never chose". Resolve it through
    /// `Config.composerDraftDefault`, never through `?? false`.
    var composer_draft_enabled: Bool?
    /// Tri-state: the `config_agent_background` migration carries no SQL default,
    /// so `nil` means "never chose". Resolve it through
    /// `Config.agentBackgroundDefault`, never through `?? false`.
    var agent_background_enabled: Bool?
    /// Tri-state: the `config_start_admission` migration carries no SQL default,
    /// so `nil` means "never chose". Resolve it through
    /// `Config.startAdmissionDefault`, never through `?? false`.
    var start_admission_enabled: Bool?
    /// Session usage recorded through the session mod. **Genuinely
    /// tri-state**: the `config_session_mod_usage` migration carries no SQL
    /// default, so `nil` means "never chose". Resolve it through
    /// `Config.sessionModUsageDefault`, never through `?? false`.
    var session_mod_usage_enabled: Bool?
    /// Live remote transcript sync gate: tail-first loading, earlier-history
    /// loading and hint-driven background sync. **Genuinely tri-state**: the
    /// `20261008230000_config_remote_transcript_live_sync` migration carries
    /// no SQL default, so `nil` means "never chose". Resolve it through
    /// `Config.remoteTranscriptLiveSyncEnabledDefault`, never through
    /// `?? false`.
    var remote_transcript_live_sync_enabled: Bool?
    /// Clone-backed worktree checkout gate. **Genuinely tri-state**: the
    /// `20261009180000_config_clone_checkout` migration carries no SQL default,
    /// so `nil` means "never chose". Resolve it through
    /// `Config.cloneCheckoutDefault`, never through `?? false`.
    var clone_checkout_enabled: Bool?
    /// The update mode: 'off', 'check' or 'auto'
    /// (design 2026-09-04 §6). **Genuinely tri-state**, same shape as
    /// `gc_retained_transcripts_enabled`: the
    /// `20260904172536_config_update_mode` migration carries no SQL default, so
    /// `nil` here means "never chose" rather than "off". Resolve it through
    /// `Config.updateModeDefault`, never through `?? .off`. An unrecognised
    /// string resolves the same way — a value this build does not know is not a
    /// mode it can honor.
    var update_mode: String?
    /// This installation's holder owner token, minted once by the first daemon
    /// that needs one and read forever after. **Not a flag**: NULL means "not
    /// yet minted", and the mint is the conditional UPDATE in
    /// `ensureHolderOwnerToken` rather than a resolved default — there is no
    /// value the shipped code could default this to that would not make every
    /// checkout on a machine claim every other checkout's holders.
    var holder_owner_token: String?
    /// JSON-encoded `[String: String]` remote create-param defaults (machine
    /// scope), keyed by the provider's own field names. Nil/absent means no
    /// opinion at this level — every field falls through to its
    /// provider-declared `default`.
    var remote_create_defaults: String?

    /// - Parameter queuedPromptDefault: the shipped default a NULL
    ///   `queued_prompt_enabled` resolves to. Defaulted to the real constant;
    ///   the parameter exists so tests can prove that NULL *follows* a changed
    ///   default while an explicit `false` does not.
    /// - Parameter autoCreateNotesDefault: same shape, for
    ///   `auto_create_notes_enabled` — the parameter proves that an untouched
    ///   preference follows the shipped default while explicit choices stick.
    /// - Parameter gcProfileDirsDefault: same shape again, for
    ///   `gc_profile_dirs_enabled` — the profile-dir collector's own soak gate.
    /// - Parameter claudeCloudEnabledDefault: same shape again, for the Claude
    ///   cloud gate — the parameter exists so tests can prove NULL follows a
    ///   changed default while an explicit `false` does not.
    /// - Parameter gcOrphanProcessesDefault: same shape once more, for
    ///   `gc_orphan_processes_enabled` — the orphaned-process collector's soak
    ///   gate.
    /// - Parameter gcHangStacksDefault: same shape once more, for
    ///   `gc_hang_stacks_enabled` — the hang-stack reclaimer's soak gate,
    ///   which also governs the app-side write-time cap.
    /// - Parameter ptyHolderDefault: same shape once more, for
    ///   `pty_holder_enabled` — the pty-holder transport's soak gate.
    /// - Parameter remoteDeleteDefault: and the last of them, for
    ///   `remote_delete_enabled` — the gate on destroying a provider-hosted
    ///   session, whose soak is the one that matters most, because what it
    ///   permits cannot be undone from this machine.
    /// - Parameter gcRetainedTranscriptsDefault: and truly the last, for
    ///   `gc_retained_transcripts_enabled` — the retained-transcript GC leg's
    ///   soak gate.
    /// - Parameter transcriptStreamingDefault: and its companion, for
    ///   `transcript_streaming_enabled` — the gate on the transcript's
    ///   provisional assistant rows, which the session mod's
    ///   `transcript-stream` feature feeds.
    /// - Parameter updateModeDefault: and truly, finally the last, for
    ///   `update_mode` — the only one of these that is not a Bool, so the
    ///   parameter proves both properties at once: a NULL row follows a changed
    ///   shipped default, and a string this build does not recognise resolves
    ///   the same way rather than to a hardcoded `.off`.
    /// - Parameter profileBalancingDefault: same shape again, for
    ///   `profile_balancing_enabled` — the launch policy's soak gate.
    /// - Parameter prPollScheduleDefault: same shape again, for
    ///   `pr_poll_schedule_enabled`.
    /// - Parameter transcriptPromptAnswerDefault: same shape again, for
    ///   `transcript_prompt_answer_enabled`.
    /// - Parameter composerDraftDefault: same shape again, for
    ///   `composer_draft_enabled`.
    /// - Parameter startAdmissionDefault: same shape again, for
    ///   `start_admission_enabled`.
    /// - Parameter agentBackgroundDefault: same shape again, for
    ///   `agent_background_enabled`.
    /// - Parameter sessionModUsageDefault: same shape again, for
    ///   `session_mod_usage_enabled`.
    /// - Parameter remoteTranscriptLiveSyncDefault: same shape again, for
    ///   `remote_transcript_live_sync_enabled` — the live remote transcript
    ///   sync's soak gate.
    /// - Parameter programStatusDefault: same shape again, for
    ///   `program_status_enabled` — the Program Status Protocol's soak gate.
    /// - Parameter cloneCheckoutDefault: same shape again, for
    ///   `clone_checkout_enabled` — the clone-backed worktree checkout's soak
    ///   gate.
    /// - Parameter worktreeParksOnMerge: whether a worktree that is not
    ///   archived overrides park-on-merge to true. It lives in the `worktree`
    ///   table, so `ConfigStore.get()` reads it with one query beside this row;
    ///   it is one of the ways automatic parking turns the composer-draft
    ///   feature on.
    func toModel(
        queuedPromptDefault: Bool = Config.queuedPromptDefault,
        autoCreateNotesDefault: Bool = Config.autoCreateNotesDefault,
        gcProfileDirsDefault: Bool = Config.gcProfileDirsEnabledDefault,
        claudeCloudEnabledDefault: Bool = Config.claudeCloudEnabledDefault,
        gcOrphanProcessesDefault: Bool = Config.gcOrphanProcessesEnabledDefault,
        gcHangStacksDefault: Bool = Config.gcHangStacksEnabledDefault,
        ptyHolderDefault: Bool = Config.ptyHolderDefault,
        remoteDeleteDefault: Bool = Config.remoteDeleteEnabledDefault,
        gcRetainedTranscriptsDefault: Bool = Config.gcRetainedTranscriptsEnabledDefault,
        transcriptStreamingDefault: Bool = Config.transcriptStreamingDefault,
        updateModeDefault: UpdateMode = Config.updateModeDefault,
        profileBalancingDefault: Bool = Config.profileBalancingEnabledDefault,
        prPollScheduleDefault: Bool = Config.prPollScheduleDefault,
        transcriptPromptAnswerDefault: Bool = Config.transcriptPromptAnswerDefault,
        composerDraftDefault: Bool = Config.composerDraftDefault,
        agentBackgroundDefault: Bool = Config.agentBackgroundDefault,
        startAdmissionDefault: Bool = Config.startAdmissionDefault,
        sessionModUsageDefault: Bool = Config.sessionModUsageDefault,
        remoteTranscriptLiveSyncDefault: Bool = Config.remoteTranscriptLiveSyncEnabledDefault,
        programStatusDefault: Bool = Config.programStatusEnabledDefault,
        cloneCheckoutDefault: Bool = Config.cloneCheckoutDefault,
        worktreeParksOnMerge: Bool = false
    ) -> Config {
        // Assembled in two steps rather than one literal, and deliberately so:
        // this initializer call reached the Swift type-checker's expression
        // budget ("unable to type-check this expression in reasonable time")
        // with every field passed inline. The resolutions below are the same
        // `?? default` shape as every argument above; only where they are
        // written changed.
        var config = Config(
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
            autoCloseSetupEnabled: auto_close_setup_enabled ?? false,
            autoTrustWorktrees: auto_trust_worktrees ?? true,
            gcEnabled: gc_enabled ?? true,
            gcGraceSeconds: gc_grace_seconds ?? Config.defaultGCGraceSeconds,
            gcSnapshotRetentionDays: gc_snapshot_retention_days ?? Config.defaultGCSnapshotRetentionDays,
            panelSurfaceEnabled: daemon_panel_surface_enabled ?? false,
            agentPanelControlEnabled: agent_panel_control_enabled ?? false,
            remoteBackendsEnabled: remote_backends_enabled ?? false,
            deliveryVerificationEnabled: delivery_verification_enabled ?? false,
            // NOT `?? false`. The column has no SQL default, so NULL really
            // means "never chose" and must resolve to the shipped default —
            // that is the whole point of v70_config_queued_prompt.
            queuedPromptEnabled: queued_prompt_enabled ?? queuedPromptDefault,
            autoCreateNotesEnabled: auto_create_notes_enabled ?? autoCreateNotesDefault,
            // Same reasoning, for the profile-dir collector's gate — NOT
            // `?? false`.
            gcProfileDirsEnabled: gc_profile_dirs_enabled ?? gcProfileDirsDefault,
            // Same reasoning again, for the Claude cloud gate — NOT `?? false`.
            claudeCloudEnabled: claude_cloud_enabled ?? claudeCloudEnabledDefault,
            // And once more, for the orphaned-process collector's gate —
            // NOT `?? false`.
            gcOrphanProcessesEnabled: gc_orphan_processes_enabled ?? gcOrphanProcessesDefault,
            // And once more, for the hang-stack reclaimer's gate —
            // NOT `?? false`.
            gcHangStacksEnabled: gc_hang_stacks_enabled ?? gcHangStacksDefault,
            // And once more, for the pty-holder transport's gate — NOT `?? false`.
            ptyHolderEnabled: pty_holder_enabled ?? ptyHolderDefault,
            // And truly the last of them, for the remote-delete gate —
            // NOT `?? false`.
            remoteDeleteEnabled: remote_delete_enabled ?? remoteDeleteDefault,
            // And truly the last of them, for the retained-transcript GC leg's
            // gate — NOT `?? false`.
            gcRetainedTranscriptsEnabled:
                gc_retained_transcripts_enabled ?? gcRetainedTranscriptsDefault,
            // Same reasoning once more, for the update mode — NOT `?? .off`.
            // The `flatMap` covers the second way a value can be absent: a
            // string no `UpdateMode` case matches is as unusable as NULL, so it
            // resolves to the shipped default rather than silently arming a
            // mode this build cannot run.
            updateMode: update_mode.flatMap(UpdateMode.init(rawValue:)) ?? updateModeDefault,
            // Profile balancing gate — NOT `?? false`.
            profileBalancingEnabled: profile_balancing_enabled ?? profileBalancingDefault,
            // PR poll schedule gate — NOT `?? false`.
            prPollScheduleEnabled: pr_poll_schedule_enabled ?? prPollScheduleDefault,
            remoteCreateDefaults: EnvOverridesCoding.decode(remote_create_defaults),
            // Passed straight through, NULL included: "not yet minted" is a
            // real state and has no default to resolve to.
            holderOwnerToken: holder_owner_token
        )
        // Clone-backed checkout gate — NOT `?? false`.
        config.cloneCheckoutEnabled = clone_checkout_enabled ?? cloneCheckoutDefault
        // And the provisional transcript rows' gate — NOT `?? false`.
        config.transcriptStreamingEnabled =
            transcript_streaming_enabled ?? transcriptStreamingDefault
        // Passed straight through as well: `Config.profileBalancingPolicy`
        // resolves NULL, and a hand-edited out-of-range value, to the shipped
        // thresholds in one place.
        config.profileBalancingUsageCeilingPercent = profile_balancing_usage_ceiling_percent
        config.profileBalancingMaxReadingAgeSeconds = profile_balancing_max_reading_age_seconds
        // Transcript prompt-answer gate — NOT `?? false`.
        config.transcriptPromptAnswerEnabled =
            transcript_prompt_answer_enabled ?? transcriptPromptAnswerDefault
        // Composer draft gate — NOT `?? false` — held on by automatic parking.
        // A park's only guard for an unsent draft is the session mod, so every
        // way TBD parks without a gesture turns the feature on: the idle
        // sweep, the global park-on-merge default, and a worktree's own
        // park-on-merge override. The stored column is left as the person set
        // it, so an explicit off holds again once automatic parking is off.
        // Assigned after construction, like the fields around it, to keep the
        // initializer call inside the type-checker's budget.
        let automaticParking = (auto_hibernate_enabled ?? false)
            || (auto_hibernate_on_merge_default ?? false)
            || worktreeParksOnMerge
        config.composerDraftRequiredByAutoPark = automaticParking
        config.composerDraftEnabled =
            (composer_draft_enabled ?? composerDraftDefault) || automaticParking
        config.agentBackgroundEnabled = agent_background_enabled ?? agentBackgroundDefault
        config.startAdmissionEnabled = start_admission_enabled ?? startAdmissionDefault
        // Session usage gate — NOT `?? false`.
        config.sessionModUsageEnabled = session_mod_usage_enabled ?? sessionModUsageDefault
        // Live remote transcript sync gate — NOT `?? false`.
        config.remoteTranscriptLiveSyncEnabled =
            remote_transcript_live_sync_enabled ?? remoteTranscriptLiveSyncDefault
        // Program Status Protocol gate — NOT `?? false`. Assigned after
        // construction, like the fields around it, to keep the initializer
        // call inside the type-checker's budget.
        config.programStatusEnabled = program_status_enabled ?? programStatusDefault
        return config
    }
}

/// Failures the singleton `config` row can produce that GRDB has no error for.
public enum ConfigStoreError: LocalizedError, Equatable {
    /// The conditional mint ran and the row still holds no usable token — the
    /// singleton row is missing, or something wrote an empty value over it.
    case holderOwnerTokenUnavailable

    public var errorDescription: String? {
        switch self {
        case .holderOwnerTokenUnavailable:
            return "the config row holds no holder owner token and one could not be minted"
        }
    }
}

public struct ConfigStore: Sendable {
    static let singletonID = "singleton"
    let writer: any DatabaseWriter

    init(writer: any DatabaseWriter) {
        self.writer = writer
    }

    /// The resolved config. Every reader goes through here, so all of them
    /// agree on the effective composer-draft value, which also depends on the
    /// worktrees' park-on-merge overrides (`ConfigRecord.toModel`).
    public func get() async throws -> Config {
        try await writer.read { db in
            guard let record = try ConfigRecord.fetchOne(db, key: Self.singletonID) else {
                return Config()
            }
            // An unreadable worktree table must not fail the config read:
            // every subsystem opens on this read, and most never touch a
            // worktree row. Resolving without the overrides is safe. Merge-park
            // reads the worktree row before it parks and a spawn reads it
            // before it starts, so while the table is unreadable neither can
            // run, and nothing an override holds the mod on for can happen.
            let worktreeParksOnMerge: Bool
            do {
                worktreeParksOnMerge = try Self.anyWorktreeParksOnMerge(db)
            } catch {
                configLogger.error(
                    "Worktree park-on-merge overrides unreadable, resolving the composer draft without them: \(String(describing: error), privacy: .public)"
                )
                worktreeParksOnMerge = false
            }
            return record.toModel(worktreeParksOnMerge: worktreeParksOnMerge)
        }
    }

    /// Whether a worktree that is not archived overrides park-on-merge to
    /// true. An archived worktree's override parks nothing: merge-park acts
    /// only on active worktrees, and a revive disarms the override.
    static func anyWorktreeParksOnMerge(_ db: GRDB.Database) throws -> Bool {
        try Bool.fetchOne(
            db,
            sql: """
                SELECT EXISTS(
                    SELECT 1 FROM worktree
                    WHERE autoHibernateOnMerge = 1 AND status != ?)
                """,
            arguments: [WorktreeStatus.archived.rawValue]) ?? false
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

    /// Persist the machine-wide remote create-param defaults. An empty map
    /// clears the column, which is the "no opinion" state every field falls
    /// through from to its provider-declared `default`.
    public func setRemoteCreateDefaults(_ defaults: [String: String]) async throws {
        let json = EnvOverridesCoding.encode(defaults)
        try await writer.write { db in
            try db.execute(
                sql: "UPDATE config SET remote_create_defaults = ? WHERE id = ?",
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

    /// Persist the queued-prompt opt-in (default OFF, soaking).
    ///
    /// Writing either value is an explicit gesture that leaves the column
    /// non-NULL forever after — including `false`, which is the point: an
    /// operator who turns the feature off keeps it off when the shipped default
    /// graduates to ON. Read fresh at spawn time and on every
    /// `worktree.setPendingPrompt`, so no daemon restart is required.
    public func setQueuedPrompt(_ enabled: Bool) async throws {
        try await writer.write { db in
            try db.execute(
                sql: "UPDATE config SET queued_prompt_enabled = ? WHERE id = ?",
                arguments: [enabled, Self.singletonID]
            )
        }
    }

    /// Persist whether ordinary new worktrees start with an empty Notes tab.
    /// Writing either value records an explicit choice, distinct from NULL.
    public func setAutoCreateNotes(_ enabled: Bool) async throws {
        try await writer.write { db in
            try db.execute(
                sql: "UPDATE config SET auto_create_notes_enabled = ? WHERE id = ?",
                arguments: [enabled, Self.singletonID]
            )
        }
    }

    /// Persist the Claude cloud sessions gate (design 2026-08-15 §7). Off is the
    /// shipped default. Writing either value is an explicit gesture that leaves
    /// the column non-NULL forever after — including `false`, which is the
    /// point: somebody who turned a scheduled network call off stays off when
    /// the shipped default eventually graduates.
    ///
    /// The daemon builds its provider manager and registers the built-in
    /// provider only at boot, so flipping this on does not start anything until
    /// a restart — `DaemonCapabilitiesResult.claudeCloudLive` is what tells the
    /// user which of the two states they are in.
    public func setClaudeCloud(_ enabled: Bool) async throws {
        try await writer.write { db in
            try db.execute(
                sql: "UPDATE config SET claude_cloud_enabled = ? WHERE id = ?",
                arguments: [enabled, Self.singletonID])
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

    /// Persist the profile-dir collector gate (default OFF, soaking) — read on
    /// top of the GC master switch, so both must be on for the phase to run.
    /// The column is written on every call, because writing either value is
    /// the explicit gesture that lifts it out of NULL forever after.
    public func setGCProfileDirsEnabled(_ enabled: Bool) async throws {
        try await writer.write { db in
            try db.execute(
                sql: "UPDATE config SET gc_profile_dirs_enabled = ? WHERE id = ?",
                arguments: [enabled, Self.singletonID]
            )
        }
    }

    /// Persist the orphaned-process collector gate (default OFF, soaking) —
    /// read on top of the GC master switch, so both must be on for the phase to
    /// run. The column is written on every call, because writing either value
    /// is the explicit gesture that lifts it out of NULL forever after.
    public func setGCOrphanProcessesEnabled(_ enabled: Bool) async throws {
        try await writer.write { db in
            try db.execute(
                sql: "UPDATE config SET gc_orphan_processes_enabled = ? WHERE id = ?",
                arguments: [enabled, Self.singletonID]
            )
        }
    }

    /// Persist the hang-stack reclaimer gate (default OFF, soaking) — read on
    /// top of the GC master switch, so both must be on for the phase to run.
    /// The same flag is mirrored into the app's write-time cap, so this one
    /// call governs both halves of the policy. The column is written on every
    /// call, because writing either value is the explicit gesture that lifts it
    /// out of NULL forever after.
    public func setGCHangStacksEnabled(_ enabled: Bool) async throws {
        try await writer.write { db in
            try db.execute(
                sql: "UPDATE config SET gc_hang_stacks_enabled = ? WHERE id = ?",
                arguments: [enabled, Self.singletonID]
            )
        }
    }

    /// Persist the pty-holder transport gate (default ON). It gates
    /// which transport a session is *spawned* onto; a session records its
    /// transport at creation and keeps it for life, so flipping this never
    /// migrates a running session. The column is written on every call, because
    /// writing either value is the explicit gesture that lifts it out of NULL
    /// forever after.
    public func setPtyHolderEnabled(_ enabled: Bool) async throws {
        try await writer.write { db in
            try db.execute(
                sql: "UPDATE config SET pty_holder_enabled = ? WHERE id = ?",
                arguments: [enabled, Self.singletonID]
            )
        }
    }

    /// Persist the remote-delete gate (default OFF, soaking) — the single
    /// opt-in for destroying a provider-hosted agent session. The column is
    /// written on every call, because writing either value is the explicit
    /// gesture that lifts it out of NULL forever after.
    public func setRemoteDeleteEnabled(_ enabled: Bool) async throws {
        try await writer.write { db in
            try db.execute(
                sql: "UPDATE config SET remote_delete_enabled = ? WHERE id = ?",
                arguments: [enabled, Self.singletonID]
            )
        }
    }

    /// Persist the retained-transcript GC leg's gate (default OFF, soaking) —
    /// read on top of the GC master switch, so both must be on for the leg to
    /// run. Separate from `setRemoteDeleteEnabled` on purpose: that gate
    /// destroys a session on a provider, this one reclaims TBD's own local
    /// residue, and opting into either must never opt into the other. The
    /// column is written on every call, because writing either value is the
    /// explicit gesture that lifts it out of NULL forever after.
    public func setGCRetainedTranscriptsEnabled(_ enabled: Bool) async throws {
        try await writer.write { db in
            try db.execute(
                sql: "UPDATE config SET gc_retained_transcripts_enabled = ? WHERE id = ?",
                arguments: [enabled, Self.singletonID]
            )
        }
    }

    /// Persist the profile balancing gate (default OFF, soaking) — the launch
    /// policy that spreads new sessions across the profiles with the most room
    /// (design 2026-09-05 §6). The column is written on every call, because
    /// writing either value is the explicit gesture that lifts it out of NULL
    /// forever after.
    public func setProfileBalancingEnabled(_ enabled: Bool) async throws {
        try await writer.write { db in
            try db.execute(
                sql: "UPDATE config SET profile_balancing_enabled = ? WHERE id = ?",
                arguments: [enabled, Self.singletonID]
            )
        }
    }

    /// Persist balancing's usage ceiling, in percent; nil returns the column to
    /// NULL, which follows the shipped default. The RPC handler validates the
    /// range before calling.
    public func setProfileBalancingUsageCeilingPercent(_ percent: Int?) async throws {
        try await writer.write { db in
            try db.execute(
                sql: "UPDATE config SET profile_balancing_usage_ceiling_percent = ? WHERE id = ?",
                arguments: [percent, Self.singletonID]
            )
        }
    }

    /// Persist balancing's maximum reading age, in seconds; nil returns the
    /// column to NULL, which keeps each credential kind's own window. The RPC
    /// handler validates the range before calling.
    public func setProfileBalancingMaxReadingAgeSeconds(_ seconds: Int?) async throws {
        try await writer.write { db in
            try db.execute(
                sql: "UPDATE config SET profile_balancing_max_reading_age_seconds = ? WHERE id = ?",
                arguments: [seconds, Self.singletonID]
            )
        }
    }

    /// Persist the clone-backed worktree checkout gate. Written on every call,
    /// so either value is the explicit gesture that lifts the column out of
    /// NULL. Read on every create, so it needs no live switch.
    public func setCloneCheckoutEnabled(_ enabled: Bool) async throws {
        try await writer.write { db in
            try db.execute(
                sql: "UPDATE config SET clone_checkout_enabled = ? WHERE id = ?",
                arguments: [enabled, Self.singletonID]
            )
        }
    }

    /// Persist the schedule-based PR polling gate. Written on every call, so
    /// either value is the explicit gesture that lifts the column out of NULL.
    public func setPRPollScheduleEnabled(_ enabled: Bool) async throws {
        try await writer.write { db in
            try db.execute(
                sql: "UPDATE config SET pr_poll_schedule_enabled = ? WHERE id = ?",
                arguments: [enabled, Self.singletonID]
            )
        }
    }

    /// Persist the Program Status Protocol (OSC 7501) gate. Written on every
    /// call, so either value is the explicit gesture that lifts the column out
    /// of NULL.
    public func setProgramStatusEnabled(_ enabled: Bool) async throws {
        try await writer.write { db in
            try db.execute(
                sql: "UPDATE config SET program_status_enabled = ? WHERE id = ?",
                arguments: [enabled, Self.singletonID]
            )
        }
    }

    /// Persist the transcript prompt-answer gate. Written on every call, so either
    /// value is the explicit gesture that lifts the column out of NULL.
    public func setTranscriptPromptAnswerEnabled(_ enabled: Bool) async throws {
        try await writer.write { db in
            try db.execute(
                sql: "UPDATE config SET transcript_prompt_answer_enabled = ? WHERE id = ?",
                arguments: [enabled, Self.singletonID]
            )
        }
    }

    /// Persist the composer draft gate. Written on every call, so either value
    /// is the explicit gesture that lifts the column out of NULL.
    public func setComposerDraftEnabled(_ enabled: Bool) async throws {
        try await writer.write { db in
            try db.execute(
                sql: "UPDATE config SET composer_draft_enabled = ? WHERE id = ?",
                arguments: [enabled, Self.singletonID]
            )
        }
    }

    /// Persist the the start admission gate flag. Written on every call, so either value
    /// is the explicit gesture that lifts the column out of NULL.
    public func setStartAdmissionEnabled(_ enabled: Bool) async throws {
        try await writer.write { db in
            try db.execute(
                sql: "UPDATE config SET start_admission_enabled = ? WHERE id = ?",
                arguments: [enabled, Self.singletonID]
            )
        }
    }

    /// Persist the the agent background priority command flag. Written on every call, so either value
    /// is the explicit gesture that lifts the column out of NULL.
    public func setAgentBackgroundEnabled(_ enabled: Bool) async throws {
        try await writer.write { db in
            try db.execute(
                sql: "UPDATE config SET agent_background_enabled = ? WHERE id = ?",
                arguments: [enabled, Self.singletonID]
            )
        }
    }

    /// Persist the session usage gate. Written on every call, so either value
    /// is the explicit gesture that lifts the column out of NULL.
    public func setSessionModUsageEnabled(_ enabled: Bool) async throws {
        try await writer.write { db in
            try db.execute(
                sql: "UPDATE config SET session_mod_usage_enabled = ? WHERE id = ?",
                arguments: [enabled, Self.singletonID]
            )
        }
    }

    /// Persist the live remote transcript sync gate (default OFF while it
    /// soaks). Written on every call, so either value is the explicit gesture
    /// that lifts the column out of NULL. Read fresh at every decision, so a
    /// change applies on the next sync without a restart.
    public func setRemoteTranscriptLiveSyncEnabled(_ enabled: Bool) async throws {
        try await writer.write { db in
            try db.execute(
                sql: "UPDATE config SET remote_transcript_live_sync_enabled = ? WHERE id = ?",
                arguments: [enabled, Self.singletonID]
            )
        }
    }

    /// Persist the update mode (default `.off`) — whether the daemon checks for
    /// a newer `main`, and whether it may install one.
    ///
    /// **Takes effect at the next checker tick**, which is at most an hour
    /// away and needs no daemon restart: `UpdateChecker` reads this column
    /// fresh on every tick rather than caching it at boot. The column is
    /// written on every call, because writing any value is the explicit gesture
    /// that lifts it out of NULL forever after.
    public func setUpdateMode(_ mode: UpdateMode) async throws {
        try await writer.write { db in
            try db.execute(
                sql: "UPDATE config SET update_mode = ? WHERE id = ?",
                arguments: [mode.rawValue, Self.singletonID]
            )
        }
    }

    /// Return this installation's holder owner token, minting `candidate` only
    /// if none has been minted yet.
    ///
    /// **The conditional write is the whole point.** Two daemons starting at
    /// once on one `TBD_HOME` must agree on one token or each would disown the
    /// other's holders, so the decision is made by SQLite rather than by the
    /// caller: `WHERE holder_owner_token IS NULL` means the second writer's
    /// UPDATE matches no row, and the read-back inside the same transaction
    /// returns whichever token actually landed. This is the SQL equivalent of
    /// the `O_EXCL` open the file-backed store used before the token moved into
    /// the `config` row.
    ///
    /// The empty string is treated as unminted: a hand-edited row or a
    /// half-written value must not become an identity every holder is compared
    /// against.
    ///
    /// - Returns: the token now stored, which may not be `candidate`.
    /// - Throws: if the row cannot be written or read — including the case
    ///   where no singleton row exists at all, which no migrated database has.
    public func ensureHolderOwnerToken(minting candidate: String) async throws -> String {
        try await writer.write { db in
            try db.execute(
                sql: """
                    UPDATE config SET holder_owner_token = ?
                     WHERE id = ? AND (holder_owner_token IS NULL OR holder_owner_token = '')
                    """,
                arguments: [candidate, Self.singletonID]
            )
            let stored = try String.fetchOne(
                db,
                sql: "SELECT holder_owner_token FROM config WHERE id = ?",
                arguments: [Self.singletonID]
            )
            guard let stored, !stored.isEmpty else {
                throw ConfigStoreError.holderOwnerTokenUnavailable
            }
            return stored
        }
    }

    /// Persist the transcript-streaming gate (default OFF, soaking) — whether
    /// sessions spawn with the session mod's `transcript-stream` feature, and
    /// the transcript shows the provisional rows it feeds.
    ///
    /// Applies to sessions started after the change: the feature list is fixed
    /// in a session's environment at spawn.
    public func setTranscriptStreamingEnabled(_ enabled: Bool) async throws {
        try await writer.write { db in
            try db.execute(
                sql: "UPDATE config SET transcript_streaming_enabled = ? WHERE id = ?",
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
