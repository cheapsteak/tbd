import DaemonTestSupport
import Foundation
import GRDB
import TBDShared
import Testing
@testable import TBDDaemonLib

/// The tmux control-mode opt-in's column, `config.control_mode_enabled`, is
/// retired at schema epoch 9: control mode is gone, nothing reads or writes the
/// column, and `RetiredColumnReconciler` drops it once the kept rollback bundle
/// no longer uses it. See "Retiring a column" in
/// `Sources/TBDDaemon/Database/CLAUDE.md`.
@Suite struct ControlModeColumnRetirementTests {

    @Test func theColumnIsRetiredAtEpochNine() throws {
        #expect(SchemaEpoch.current >= 9)
        let retired = RetiredColumn(table: "config", column: "control_mode_enabled", epoch: 9)
        let index = try #require(RetiredColumns.all.firstIndex(of: retired))
        // Appended, never inserted: nothing before it was retired later.
        let earlierEntriesAreNoLater = RetiredColumns.all[..<index].allSatisfy { $0.epoch <= retired.epoch }
        #expect(earlierEntriesAreNoLater, "a retirement is appended, never inserted")
        let everyEpochIsReached = RetiredColumns.all.allSatisfy { $0.epoch <= SchemaEpoch.current }
        #expect(everyEpochIsReached, "an entry names an epoch this tree has not reached")
    }

    /// Dropped once the kept bundle was built from a tree that had retired the
    /// column (epoch 9), and kept while the bundle still reads it.
    @Test func theColumnDropsAtEpochNineAndHoldsBelow() {
        let entry = RetiredColumn(table: "config", column: "control_mode_enabled", epoch: 9)
        #expect(RetiredColumnReconciler.decision(
            for: entry, keptBundle: KeptBundle(path: "/kept/TBD.app", schemaEpoch: 9)) == .drop)
        #expect(RetiredColumnReconciler.decision(
            for: entry, keptBundle: KeptBundle(path: "/kept/TBD.app", schemaEpoch: 8)) == .hold)
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
        #expect(!labels.contains("control_mode_enabled"))
    }

    /// The shared model loses the field the column fed. `composerDraftEnabled`
    /// is the control.
    @Test func theSharedModelNoLongerCarriesTheSetting() {
        let labels = Mirror(reflecting: Config()).children.compactMap(\.label)
        #expect(labels.contains("composerDraftEnabled"))
        #expect(!labels.contains("controlModeEnabled"))
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
            method: "config.setControlMode", params: #"{"enabled":true}"#))
        #expect(!response.success)
        #expect(response.error == "Unknown method: config.setControlMode")
    }

    /// The config row is written through the record and the store, and read
    /// back, against a schema the column has been dropped from.
    @Test func theConfigRowRoundTripsWithoutTheColumn() async throws {
        let db = try TBDDatabase(inMemory: true)
        let record = try await db.writerForTests.write { conn -> ConfigRecord? in
            try conn.execute(sql: "ALTER TABLE config DROP COLUMN control_mode_enabled")
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

    /// A daemon built before the retirement still sends `controlModeEnabled`
    /// in every `Config`. A newer client ignores the key rather than failing
    /// the decode.
    @Test func aConfigThatStillCarriesTheSettingDecodes() throws {
        let data = try JSONEncoder().encode(Config())
        var object = try #require(
            try JSONSerialization.jsonObject(with: data) as? [String: Any])
        object["controlModeEnabled"] = true
        let withSetting = try JSONSerialization.data(withJSONObject: object)

        let expected = try JSONDecoder().decode(Config.self, from: data)
        #expect(try JSONDecoder().decode(Config.self, from: withSetting) == expected)
    }

    /// A daemon built before control mode was removed still sends its three
    /// capability fields. A newer client ignores them; `holderClaimReconcileEnabled`
    /// shows the rest of the reply still decodes.
    @Test func aCapabilitiesReplyThatStillCarriesControlModeDecodes() throws {
        let json = #"""
            {"controlModeEnabled":true,"tmuxVersion":"3.6a","controlModeSupported":true,
             "holderClaimReconcileEnabled":true}
            """#
        let decoded = try JSONDecoder().decode(DaemonCapabilitiesResult.self, from: Data(json.utf8))
        #expect(decoded.holderClaimReconcileEnabled)
    }
}
