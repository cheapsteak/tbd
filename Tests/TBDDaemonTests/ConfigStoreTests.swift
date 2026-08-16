import Testing
import Foundation
import GRDB
@testable import TBDDaemonLib
@testable import TBDShared

@Suite("ConfigStore")
struct ConfigStoreTests {
    private func fetchConfigRecord(_ db: TBDDatabase) async throws -> ConfigRecord? {
        try await db.writerForTests.read { conn in
            try ConfigRecord.fetchOne(conn, key: ConfigStore.singletonID)
        }
    }

    @Test func defaultsToNil() async throws {
        let db = try TBDDatabase(inMemory: true)
        let cfg = try await db.config.get()
        #expect(cfg.defaultProfileID == nil)
        #expect(cfg.primaryAgentPreference == .claude)
    }

    @Test func setAndGetDefaultClaudeTokenID() async throws {
        let db = try TBDDatabase(inMemory: true)
        let tok = try await db.modelProfiles.create(name: "Personal", kind: .oauth)
        try await db.config.setDefaultProfileID(tok.id)
        let cfg = try await db.config.get()
        #expect(cfg.defaultProfileID == tok.id)
    }

    @Test func clearDefaultClaudeTokenID() async throws {
        let db = try TBDDatabase(inMemory: true)
        let tok = try await db.modelProfiles.create(name: "Personal", kind: .oauth)
        try await db.config.setDefaultProfileID(tok.id)
        try await db.config.setDefaultProfileID(nil)
        let cfg = try await db.config.get()
        #expect(cfg.defaultProfileID == nil)
    }

    @Test func envOverridesDefaultEmpty() async throws {
        let db = try TBDDatabase(inMemory: true)
        let cfg = try await db.config.get()
        #expect(cfg.envSettingOverrides.isEmpty)
    }

    @Test func setAndGetEnvOverrides() async throws {
        let db = try TBDDatabase(inMemory: true)
        try await db.config.setEnvSettingOverrides(["fullscreenRendering": .bool(false)])
        let cfg = try await db.config.get()
        #expect(cfg.envSettingOverrides["fullscreenRendering"] == .bool(false))
    }

    @Test func overwriteEnvOverrides() async throws {
        let db = try TBDDatabase(inMemory: true)
        try await db.config.setEnvSettingOverrides(["fullscreenRendering": .bool(false)])
        try await db.config.setEnvSettingOverrides([:])
        let cfg = try await db.config.get()
        #expect(cfg.envSettingOverrides.isEmpty)
    }

    @Test func setAndGetPrimaryAgentPreference() async throws {
        let db = try TBDDatabase(inMemory: true)
        try await db.config.setPrimaryAgentPreference(.codex)
        let cfg = try await db.config.get()
        #expect(cfg.primaryAgentPreference == .codex)
    }

    @Test func scratchInstructionsDefaultsToNil() async throws {
        let db = try TBDDatabase(inMemory: true)
        let cfg = try await db.config.get()
        #expect(cfg.scratchInstructions == nil)
    }

    @Test func setAndGetScratchInstructions() async throws {
        let db = try TBDDatabase(inMemory: true)
        try await db.config.setScratchInstructions("Always use uv, never pip.")
        let cfg = try await db.config.get()
        #expect(cfg.scratchInstructions == "Always use uv, never pip.")
    }

    @Test func setScratchInstructionsWhitespaceResetsToNil() async throws {
        let db = try TBDDatabase(inMemory: true)
        try await db.config.setScratchInstructions("   \n  ")
        let cfg = try await db.config.get()
        #expect(cfg.scratchInstructions == nil)
    }

    @Test func setScratchInstructionsNilResetsToNil() async throws {
        let db = try TBDDatabase(inMemory: true)
        try await db.config.setScratchInstructions("Always use uv, never pip.")
        try await db.config.setScratchInstructions(nil)
        let cfg = try await db.config.get()
        #expect(cfg.scratchInstructions == nil)
    }

    @Test func scratchRenamePromptDefaultsToNil() async throws {
        let db = try TBDDatabase(inMemory: true)
        let cfg = try await db.config.get()
        #expect(cfg.scratchRenamePrompt == nil)
    }

    @Test func setAndGetScratchRenamePrompt() async throws {
        let db = try TBDDatabase(inMemory: true)
        try await db.config.setScratchRenamePrompt("Rename it once it has a clear purpose.")
        let cfg = try await db.config.get()
        #expect(cfg.scratchRenamePrompt == "Rename it once it has a clear purpose.")
    }

    @Test func setScratchRenamePromptWhitespaceResetsToNil() async throws {
        let db = try TBDDatabase(inMemory: true)
        try await db.config.setScratchRenamePrompt("   \n  ")
        let cfg = try await db.config.get()
        #expect(cfg.scratchRenamePrompt == nil)
    }

    @Test func setScratchRenamePromptNilResetsToNil() async throws {
        let db = try TBDDatabase(inMemory: true)
        try await db.config.setScratchRenamePrompt("Rename it once it has a clear purpose.")
        try await db.config.setScratchRenamePrompt(nil)
        let cfg = try await db.config.get()
        #expect(cfg.scratchRenamePrompt == nil)
    }

    @Test func scratchProfileOverrideIDDefaultsToNil() async throws {
        let db = try TBDDatabase(inMemory: true)
        let cfg = try await db.config.get()
        #expect(cfg.scratchProfileOverrideID == nil)
    }

    @Test func setAndGetScratchProfileOverride() async throws {
        let db = try TBDDatabase(inMemory: true)
        let tok = try await db.modelProfiles.create(name: "Personal", kind: .oauth)
        try await db.config.setScratchProfileOverride(tok.id)
        let cfg = try await db.config.get()
        #expect(cfg.scratchProfileOverrideID == tok.id)
    }

    @Test func clearScratchProfileOverride() async throws {
        let db = try TBDDatabase(inMemory: true)
        let tok = try await db.modelProfiles.create(name: "Personal", kind: .oauth)
        try await db.config.setScratchProfileOverride(tok.id)
        try await db.config.setScratchProfileOverride(nil)
        let cfg = try await db.config.get()
        #expect(cfg.scratchProfileOverrideID == nil)
    }

    @Test func nightwatchModeDefaultsToOff() async throws {
        let db = try TBDDatabase(inMemory: true)
        let cfg = try await db.config.get()
        #expect(cfg.nightwatchMode == .off)
    }

    @Test func setAndGetNightwatchModeOff() async throws {
        let db = try TBDDatabase(inMemory: true)
        try await db.config.setNightwatchMode(.off)
        let cfg = try await db.config.get()
        #expect(cfg.nightwatchMode == .off)
    }

    @Test func setAndGetNightwatchModeDaywatch() async throws {
        let db = try TBDDatabase(inMemory: true)
        try await db.config.setNightwatchMode(.daywatch)
        let cfg = try await db.config.get()
        #expect(cfg.nightwatchMode == .daywatch)
    }

    @Test func setAndGetNightwatchModeNightwatch() async throws {
        let db = try TBDDatabase(inMemory: true)
        try await db.config.setNightwatchMode(.nightwatch)
        let cfg = try await db.config.get()
        #expect(cfg.nightwatchMode == .nightwatch)
    }

    @Test func nightwatchModeTransitions() async throws {
        let db = try TBDDatabase(inMemory: true)
        try await db.config.setNightwatchMode(.nightwatch)
        var cfg = try await db.config.get()
        #expect(cfg.nightwatchMode == .nightwatch)

        try await db.config.setNightwatchMode(.daywatch)
        cfg = try await db.config.get()
        #expect(cfg.nightwatchMode == .daywatch)

        try await db.config.setNightwatchMode(.off)
        cfg = try await db.config.get()
        #expect(cfg.nightwatchMode == .off)
    }

    @Test func hibernateInputVetoDefaultsToFalse() async throws {
        let db = try TBDDatabase(inMemory: true)
        let cfg = try await db.config.get()
        #expect(cfg.hibernateInputVetoEnabled == false)
    }

    @Test func setAndGetHibernateInputVetoEnabled() async throws {
        let db = try TBDDatabase(inMemory: true)
        try await db.config.setHibernateInputVeto(enabled: true)
        let cfg = try await db.config.get()
        #expect(cfg.hibernateInputVetoEnabled == true)
    }

    /// `delivery_verification_enabled` (v69) ships default OFF: the re-check
    /// acts on no user gesture and its retry types into a live session.
    @Test func deliveryVerificationDefaultsToFalse() async throws {
        let db = try TBDDatabase(inMemory: true)
        let cfg = try await db.config.get()
        #expect(cfg.deliveryVerificationEnabled == false)
    }

    @Test func setAndGetDeliveryVerificationEnabled() async throws {
        let db = try TBDDatabase(inMemory: true)
        try await db.config.setDeliveryVerification(enabled: true)
        let cfg = try await db.config.get()
        #expect(cfg.deliveryVerificationEnabled == true)
    }

    @Test func setDeliveryVerificationToFalse() async throws {
        let db = try TBDDatabase(inMemory: true)
        try await db.config.setDeliveryVerification(enabled: true)
        try await db.config.setDeliveryVerification(enabled: false)
        let cfg = try await db.config.get()
        #expect(cfg.deliveryVerificationEnabled == false)
    }

    @Test func setHibernateInputVetoToFalse() async throws {
        let db = try TBDDatabase(inMemory: true)
        try await db.config.setHibernateInputVeto(enabled: true)
        try await db.config.setHibernateInputVeto(enabled: false)
        let cfg = try await db.config.get()
        #expect(cfg.hibernateInputVetoEnabled == false)
    }

    /// `auto_trust_worktrees` (v66) ships default ON, unlike its soak-flag
    /// siblings: the trust answer is known by construction for a TBD-created
    /// worktree, and the dialog stalls the spawn invisibly when it renders.
    @Test func autoTrustWorktreesDefaultsToTrue() async throws {
        let db = try TBDDatabase(inMemory: true)
        let cfg = try await db.config.get()
        #expect(cfg.autoTrustWorktrees == true, "auto_trust_worktrees must default ON")
    }

    @Test func setAutoTrustWorktreesRoundtrips() async throws {
        let db = try TBDDatabase(inMemory: true)
        try await db.config.setAutoTrustWorktrees(enabled: false)
        #expect(try await db.config.get().autoTrustWorktrees == false)
        try await db.config.setAutoTrustWorktrees(enabled: true)
        #expect(try await db.config.get().autoTrustWorktrees == true)
    }

    // MARK: - v78: `gc_profile_dirs_enabled` is genuinely tri-state

    /// **The storage guard.** The `config` singleton row is inserted by v1, so
    /// every install — fresh or years old — has a row that predates v78. After
    /// v78 that row's `gc_profile_dirs_enabled` must read NULL, not `0`: a SQL
    /// default would backfill it and make "never chose" indistinguishable from
    /// a deliberate opt-out, which is what the no-default convention exists to
    /// prevent. If someone adds `defaults:` to
    /// `v78_config_gc_profile_dirs`, this goes red — that is its only job.
    @Test func gcProfileDirsIsNullBeforeAnyGesture() async throws {
        let db = try TBDDatabase(inMemory: true)
        let record = try #require(try await fetchConfigRecord(db))
        #expect(
            record.gc_profile_dirs_enabled == nil,
            """
            config.gc_profile_dirs_enabled must be NULL until the toggle is \
            touched — read back \
            \(String(describing: record.gc_profile_dirs_enabled)). A non-nil \
            value here means v78_config_gc_profile_dirs grew a `defaults:` \
            argument; remove it.
            """
        )
    }

    /// The same guard against a row written by a real pre-v78 daemon: migrate
    /// only through v77, write to the config row, then finish migrating.
    @Test func rowWrittenBeforeV78StillReadsNull() throws {
        let queue = try DatabaseQueue()
        let migrator = TBDDatabase.buildMigratorForTests()
        try migrator.migrate(queue, upTo: "v77_config_supervision_enabled")

        // A pre-v78 daemon touching config: the row exists and has been written
        // to, but knows nothing about the new column.
        try queue.write { db in
            try db.execute(
                sql: "UPDATE config SET gc_enabled = 1 WHERE id = ?",
                arguments: [ConfigStore.singletonID]
            )
        }

        try migrator.migrate(queue)

        try queue.read { db in
            let row = try #require(try Row.fetchOne(
                db, sql: "SELECT * FROM config WHERE id = ?",
                arguments: [ConfigStore.singletonID]))
            let raw: DatabaseValue = row["gc_profile_dirs_enabled"]
            #expect(
                raw.isNull,
                "a config row written before v78 must read NULL, not \(raw)"
            )
            // The pre-existing write survived — v78 is purely additive.
            #expect(row["gc_enabled"] == true)
        }
    }

    /// NULL follows `Config.gcProfileDirsEnabledDefault` wherever it goes; an
    /// explicit `false` does not. That property is what makes graduation a
    /// one-line constant change with no forcing `UPDATE` migration. Exercised
    /// against BOTH possible default values, so it fails if the resolution is
    /// ever wired as `?? false`.
    @Test func gcProfileDirsExplicitFalseSurvivesADefaultFlipWhileNullFollowsIt() async throws {
        let db = try TBDDatabase(inMemory: true)

        let untouched = try #require(try await fetchConfigRecord(db))
        #expect(untouched.gc_profile_dirs_enabled == nil)
        #expect(untouched.toModel(gcProfileDirsDefault: false).gcProfileDirsEnabled == false)
        #expect(
            untouched.toModel(gcProfileDirsDefault: true).gcProfileDirsEnabled == true,
            "a never-chosen row must pick up a changed shipped default"
        )

        try await db.config.setGCProfileDirsEnabled(false)
        let explicitlyOff = try #require(try await fetchConfigRecord(db))
        #expect(explicitlyOff.gc_profile_dirs_enabled == false)
        #expect(explicitlyOff.toModel(gcProfileDirsDefault: false).gcProfileDirsEnabled == false)
        #expect(
            explicitlyOff.toModel(gcProfileDirsDefault: true).gcProfileDirsEnabled == false,
            "an explicit opt-out must be honored forever, whatever the shipped default becomes"
        )
    }

    /// Mirrored for an explicit `true`: an operator who opted into the soak
    /// stays opted in even if the shipped default never moves.
    @Test func gcProfileDirsExplicitTrueSticks() async throws {
        let db = try TBDDatabase(inMemory: true)
        try await db.config.setGCProfileDirsEnabled(true)
        let explicitlyOn = try #require(try await fetchConfigRecord(db))
        #expect(explicitlyOn.gc_profile_dirs_enabled == true)
        #expect(explicitlyOn.toModel(gcProfileDirsDefault: false).gcProfileDirsEnabled == true)
        #expect(explicitlyOn.toModel(gcProfileDirsDefault: true).gcProfileDirsEnabled == true)
    }

    /// Isolates the RESOLUTION guard (`toModel()`'s
    /// `?? gcProfileDirsDefault`) from the STORAGE guard (the migration's
    /// no-SQL-default) by constructing a `ConfigRecord` directly — no database,
    /// no migration. It catches a hardening of `?? gcProfileDirsDefault` into
    /// `?? false` even if the migration guard were broken at the same time.
    @Test func gcProfileDirsToModelResolvesNullThroughTheInjectedDefault() {
        let record = ConfigRecord(id: "unstored", gc_profile_dirs_enabled: nil)
        #expect(record.toModel(gcProfileDirsDefault: false).gcProfileDirsEnabled == false)
        #expect(
            record.toModel(gcProfileDirsDefault: true).gcProfileDirsEnabled == true,
            "a NULL record must pick up whatever default is injected, not a hardcoded false"
        )
    }

    /// The shipped default today: OFF. The collector quarantines directories
    /// holding per-profile credentials, so it soaks behind its own switch.
    /// Graduation edits this constant and nothing else.
    @Test func gcProfileDirsShipsOff() async throws {
        #expect(Config.gcProfileDirsEnabledDefault == false)
        let db = try TBDDatabase(inMemory: true)
        #expect(try await db.config.get().gcProfileDirsEnabled == false)
    }

    @Test func setGCProfileDirsEnabledRoundtrips() async throws {
        let db = try TBDDatabase(inMemory: true)
        try await db.config.setGCProfileDirsEnabled(true)
        #expect(try await db.config.get().gcProfileDirsEnabled == true)
        try await db.config.setGCProfileDirsEnabled(false)
        #expect(try await db.config.get().gcProfileDirsEnabled == false)
    }

    // MARK: - v80: the supervision-desk collector's soak gate
    //
    // The same three-state property as v78, for the same reason: the leg
    // archives a worktree and drops a record, so it ships off and soaks, and
    // graduation must be a one-line constant change that reaches every
    // never-chosen install while preserving every explicit opt-out.

    /// A row written by a real pre-v80 daemon must read NULL, not 0.
    @Test func rowWrittenBeforeV80StillReadsNull() throws {
        let queue = try DatabaseQueue()
        let migrator = TBDDatabase.buildMigratorForTests()
        try migrator.migrate(queue, upTo: "v79_reap_records_quarantine_path")

        try queue.write { db in
            try db.execute(
                sql: "UPDATE config SET gc_enabled = 1 WHERE id = ?",
                arguments: [ConfigStore.singletonID]
            )
        }

        try migrator.migrate(queue)

        try queue.read { db in
            let row = try #require(try Row.fetchOne(
                db, sql: "SELECT * FROM config WHERE id = ?",
                arguments: [ConfigStore.singletonID]))
            let raw: DatabaseValue = row["gc_supervision_desks_enabled"]
            #expect(
                raw.isNull,
                "a config row written before v80 must read NULL, not \(raw)"
            )
            #expect(row["gc_enabled"] == true)
        }
    }

    /// NULL follows the shipped default wherever it goes; an explicit `false`
    /// does not. Exercised against BOTH default values, so it fails if the
    /// resolution is ever wired as `?? false`.
    @Test func gcSupervisionDesksExplicitFalseSurvivesADefaultFlipWhileNullFollowsIt()
        async throws {
        let db = try TBDDatabase(inMemory: true)

        let untouched = try #require(try await fetchConfigRecord(db))
        #expect(untouched.gc_supervision_desks_enabled == nil)
        #expect(
            untouched.toModel(gcSupervisionDesksDefault: false).gcSupervisionDesksEnabled
                == false)
        #expect(
            untouched.toModel(gcSupervisionDesksDefault: true).gcSupervisionDesksEnabled == true,
            "a never-chosen row must pick up a changed shipped default"
        )

        try await db.config.setGCSupervisionDesksEnabled(false)
        let explicitlyOff = try #require(try await fetchConfigRecord(db))
        #expect(explicitlyOff.gc_supervision_desks_enabled == false)
        #expect(
            explicitlyOff.toModel(gcSupervisionDesksDefault: true).gcSupervisionDesksEnabled
                == false,
            "an explicit opt-out must be honored forever, whatever the shipped default becomes"
        )
    }

    /// Isolates the RESOLUTION guard from the STORAGE guard: no database, no
    /// migration, just the record's own `??`.
    @Test func gcSupervisionDesksToModelResolvesNullThroughTheInjectedDefault() {
        let record = ConfigRecord(id: "unstored", gc_supervision_desks_enabled: nil)
        #expect(
            record.toModel(gcSupervisionDesksDefault: false).gcSupervisionDesksEnabled == false)
        #expect(
            record.toModel(gcSupervisionDesksDefault: true).gcSupervisionDesksEnabled == true,
            "a NULL record must pick up whatever default is injected, not a hardcoded false"
        )
    }

    /// The shipped default today: OFF. Graduation edits this constant and
    /// nothing else.
    @Test func gcSupervisionDesksShipsOff() async throws {
        #expect(Config.gcSupervisionDesksEnabledDefault == false)
        let db = try TBDDatabase(inMemory: true)
        #expect(try await db.config.get().gcSupervisionDesksEnabled == false)
    }

    @Test func setGCSupervisionDesksEnabledRoundtrips() async throws {
        let db = try TBDDatabase(inMemory: true)
        try await db.config.setGCSupervisionDesksEnabled(true)
        #expect(try await db.config.get().gcSupervisionDesksEnabled == true)
        try await db.config.setGCSupervisionDesksEnabled(false)
        #expect(try await db.config.get().gcSupervisionDesksEnabled == false)
    }
}
