import DaemonTestSupport
import Foundation
import GRDB
import TBDShared
import Testing
@testable import TBDDaemonLib

/// The pty-holder transport gate's column, `config.pty_holder_enabled`, is
/// retired at schema epoch 8: every session opens on the pty holder, nothing
/// reads or writes the column, and `RetiredColumnReconciler` drops it once the
/// kept rollback bundle no longer uses it. See "Retiring a column" in
/// `Sources/TBDDaemon/Database/CLAUDE.md`.
@Suite struct PtyHolderFlagRetirementTests {

    @Test func theColumnIsRetiredAtEpochEight() throws {
        #expect(SchemaEpoch.current >= 8)
        let retired = RetiredColumn(table: "config", column: "pty_holder_enabled", epoch: 8)
        let index = try #require(RetiredColumns.all.firstIndex(of: retired))
        // Appended, never inserted: nothing before it was retired later.
        let earlierEntriesAreNoLater = RetiredColumns.all[..<index].allSatisfy { $0.epoch <= retired.epoch }
        #expect(earlierEntriesAreNoLater, "a retirement is appended, never inserted")
        let everyEpochIsReached = RetiredColumns.all.allSatisfy { $0.epoch <= SchemaEpoch.current }
        #expect(everyEpochIsReached, "an entry names an epoch this tree has not reached")
    }

    /// Dropped once the kept bundle was built from a tree that had retired the
    /// column (epoch 8), and kept while the bundle still reads it.
    @Test func theColumnDropsAtEpochEightAndHoldsBelow() {
        let entry = RetiredColumn(table: "config", column: "pty_holder_enabled", epoch: 8)
        #expect(RetiredColumnReconciler.decision(
            for: entry, keptBundle: KeptBundle(path: "/kept/TBD.app", schemaEpoch: 8)) == .drop)
        #expect(RetiredColumnReconciler.decision(
            for: entry, keptBundle: KeptBundle(path: "/kept/TBD.app", schemaEpoch: 7)) == .hold)
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
        #expect(!labels.contains("pty_holder_enabled"))
    }

    /// The shared models lose the field the column fed. `composerDraftEnabled`
    /// and `ptyHolderSupported` are the controls; the second stays, because
    /// whether this daemon can start a holder at all is still a fact Settings
    /// shows.
    @Test func theSharedModelsNoLongerCarryTheSetting() {
        let configLabels = Mirror(reflecting: Config()).children.compactMap(\.label)
        #expect(configLabels.contains("composerDraftEnabled"))
        #expect(!configLabels.contains("ptyHolderEnabled"))

        let capabilityLabels = Mirror(reflecting: DaemonCapabilitiesResult(controlModeEnabled: false))
            .children.compactMap(\.label)
        #expect(capabilityLabels.contains("ptyHolderSupported"))
        #expect(!capabilityLabels.contains("ptyHolderEnabled"))
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
            method: "config.setPtyHolderEnabled", params: #"{"enabled":false}"#))
        #expect(!response.success)
        #expect(response.error == "Unknown method: config.setPtyHolderEnabled")
    }

    /// The config row is written through the record and the store, and read
    /// back, against a schema the column has been dropped from.
    @Test func theConfigRowRoundTripsWithoutTheColumn() async throws {
        let db = try TBDDatabase(inMemory: true)
        let record = try await db.writerForTests.write { conn -> ConfigRecord? in
            try conn.execute(sql: "ALTER TABLE config DROP COLUMN pty_holder_enabled")
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

    /// A daemon built before the retirement still sends `ptyHolderEnabled` in
    /// every `Config` and in `daemon.capabilities`. A newer client ignores the
    /// key rather than failing the decode.
    @Test func aConfigThatStillCarriesTheSettingDecodes() throws {
        let data = try JSONEncoder().encode(Config())
        var object = try #require(
            try JSONSerialization.jsonObject(with: data) as? [String: Any])
        object["ptyHolderEnabled"] = false
        let withSetting = try JSONSerialization.data(withJSONObject: object)

        let expected = try JSONDecoder().decode(Config.self, from: data)
        #expect(try JSONDecoder().decode(Config.self, from: withSetting) == expected)
    }

    @Test func capabilitiesThatStillCarryTheSettingDecode() throws {
        let json = #"{"controlModeEnabled":false,"ptyHolderEnabled":false,"ptyHolderSupported":true}"#
        let decoded = try JSONDecoder().decode(
            DaemonCapabilitiesResult.self, from: Data(json.utf8))
        #expect(decoded.ptyHolderSupported == true)
    }
}
