import DaemonTestSupport
import Foundation
import GRDB
import TBDShared
import Testing
@testable import TBDDaemonLib

/// The starter-note setting's column, `config.auto_create_notes_enabled`, is
/// retired at schema epoch 7: new worktrees get no starter note, nothing reads
/// or writes the column, and `RetiredColumnReconciler` drops it once the kept
/// rollback bundle no longer uses it. See "Retiring a column" in
/// `Sources/TBDDaemon/Database/CLAUDE.md`.
@Suite struct AutoCreateNotesRetirementTests {

    @Test func theColumnIsRetiredAtEpochSeven() throws {
        #expect(SchemaEpoch.current >= 7)
        let retired = RetiredColumn(table: "config", column: "auto_create_notes_enabled", epoch: 7)
        let index = try #require(RetiredColumns.all.firstIndex(of: retired))
        // Appended, never inserted: nothing before it was retired later.
        let earlierEntriesAreNoLater = RetiredColumns.all[..<index].allSatisfy { $0.epoch <= retired.epoch }
        #expect(earlierEntriesAreNoLater, "a retirement is appended, never inserted")
        let everyEpochIsReached = RetiredColumns.all.allSatisfy { $0.epoch <= SchemaEpoch.current }
        #expect(everyEpochIsReached, "an entry names an epoch this tree has not reached")
    }

    /// Dropped once the kept bundle was built from a tree that had retired the
    /// column (epoch 7), and kept while the bundle still reads it.
    @Test func theColumnDropsAtEpochSevenAndHoldsBelow() {
        let entry = RetiredColumn(table: "config", column: "auto_create_notes_enabled", epoch: 7)
        #expect(RetiredColumnReconciler.decision(
            for: entry, keptBundle: KeptBundle(path: "/kept/TBD.app", schemaEpoch: 7)) == .drop)
        #expect(RetiredColumnReconciler.decision(
            for: entry, keptBundle: KeptBundle(path: "/kept/TBD.app", schemaEpoch: 6)) == .hold)
        #expect(RetiredColumnReconciler.decision(
            for: entry, keptBundle: KeptBundle(path: "/kept/TBD.app", schemaEpoch: nil)) == .hold)
        #expect(RetiredColumnReconciler.decision(for: entry, keptBundle: nil) == .drop)
    }

    /// A GRDB record writes every property it declares, so a record that
    /// still declared the column would fail every write once it is dropped.
    /// `composer_draft_enabled` is the control: the reflection does see the
    /// record's columns.
    @Test func configRecordNoLongerDeclaresTheColumn() {
        let labels = Mirror(reflecting: ConfigRecord(id: "unstored")).children.compactMap(\.label)
        #expect(labels.contains("composer_draft_enabled"))
        #expect(!labels.contains("auto_create_notes_enabled"))
    }

    /// The shared models lose the field the column fed. `gcEnabled` is the
    /// control for the model-profile list.
    @Test func theSharedModelsNoLongerCarryTheSetting() {
        let configLabels = Mirror(reflecting: Config()).children.compactMap(\.label)
        #expect(configLabels.contains("composerDraftEnabled"))
        #expect(!configLabels.contains("autoCreateNotesEnabled"))

        let listLabels = Mirror(reflecting: ModelProfileListResult(profiles: []))
            .children.compactMap(\.label)
        #expect(listLabels.contains("gcEnabled"))
        #expect(!listLabels.contains("autoCreateNotesEnabled"))
    }

    /// The setter is gone from the router: a client built before the
    /// retirement gets an unknown-method error, not a write.
    @Test func theSetterIsAnUnknownMethod() async throws {
        let db = try TBDDatabase(inMemory: true)
        let router = RPCRouter(
            db: db,
            lifecycle: WorktreeLifecycle(
                db: db, git: GitManager(), tmux: TmuxManager(dryRun: true), hooks: HookResolver()),
            tmux: TmuxManager(dryRun: true), startTime: Date(), actuationLog: makeTestActuationLog())
        let response = await router.handle(RPCRequest(
            method: "config.setAutoCreateNotes", params: #"{"enabled":false}"#))
        #expect(!response.success)
        #expect(response.error == "Unknown method: config.setAutoCreateNotes")
    }

    /// The config row is written through the record and the store, and read
    /// back, against a schema the column has been dropped from.
    @Test func theConfigRowRoundTripsWithoutTheColumn() async throws {
        let db = try TBDDatabase(inMemory: true)
        let record = try await db.writerForTests.write { conn -> ConfigRecord? in
            try conn.execute(sql: "ALTER TABLE config DROP COLUMN auto_create_notes_enabled")
            return try ConfigRecord.fetchOne(conn, key: ConfigStore.singletonID)
        }
        let seeded = try #require(record)
        try await db.writerForTests.write { conn in
            _ = try ConfigRecord.deleteOne(conn, key: ConfigStore.singletonID)
            try seeded.insert(conn)
        }
        try await db.config.setQueuedPrompt(true)

        #expect(try await db.config.get().queuedPromptEnabled)
    }

    /// A daemon built before the retirement still sends
    /// `autoCreateNotesEnabled` in every `Config` and model-profile list. A
    /// newer client ignores the key rather than failing the decode.
    @Test func aConfigThatStillCarriesTheSettingDecodes() throws {
        let data = try JSONEncoder().encode(Config())
        var object = try #require(
            try JSONSerialization.jsonObject(with: data) as? [String: Any])
        object["autoCreateNotesEnabled"] = false
        let withSetting = try JSONSerialization.data(withJSONObject: object)

        let expected = try JSONDecoder().decode(Config.self, from: data)
        #expect(try JSONDecoder().decode(Config.self, from: withSetting) == expected)
    }

    @Test func aModelProfileListThatStillCarriesTheSettingDecodes() throws {
        let json = #"{"profiles":[],"gcEnabled":false,"autoCreateNotesEnabled":false}"#
        let decoded = try JSONDecoder().decode(ModelProfileListResult.self, from: Data(json.utf8))
        #expect(decoded.profiles.isEmpty)
        #expect(decoded.gcEnabled == false)
    }
}
