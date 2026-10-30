import Foundation
import GRDB
import TBDShared
import Testing
@testable import TBDDaemonLib

/// Fleet supervision's brake, `config.supervision_enabled`, is retired at
/// schema epoch 3: nothing reads or writes it, and `RetiredColumnReconciler`
/// drops it once the kept rollback bundle no longer uses it. See "Retiring a
/// column" in `Sources/TBDDaemon/Database/CLAUDE.md`.
@Suite struct SupervisionBrakeRetirementTests {

    @Test func theBrakeColumnIsRetiredAtEpochThree() throws {
        #expect(SchemaEpoch.current >= 3)
        let retired = RetiredColumn(table: "config", column: "supervision_enabled", epoch: 3)
        let index = try #require(RetiredColumns.all.firstIndex(of: retired))
        // Appended, never inserted: nothing before it was retired later.
        #expect(RetiredColumns.all[..<index].allSatisfy { $0.epoch <= retired.epoch },
                "a retirement is appended, never inserted")
        #expect(RetiredColumns.all.allSatisfy { $0.epoch <= SchemaEpoch.current },
                "an entry names an epoch this tree has not reached")
    }

    /// A GRDB record writes every property it declares, so a record that
    /// still declared the column would fail every write once it is dropped.
    /// `composer_draft_enabled` is the control: the reflection does see the
    /// record's columns.
    @Test func configRecordNoLongerDeclaresTheColumn() {
        let labels = Mirror(reflecting: ConfigRecord(id: "unstored")).children.compactMap(\.label)
        #expect(labels.contains("composer_draft_enabled"))
        #expect(!labels.contains("supervision_enabled"))
    }

    /// The config row is written through the record and the store, and read
    /// back, against a schema the column has been dropped from.
    @Test func theConfigRowRoundTripsWithoutTheColumn() async throws {
        let db = try TBDDatabase(inMemory: true)
        let record = try await db.writerForTests.write { conn -> ConfigRecord? in
            try conn.execute(sql: "ALTER TABLE config DROP COLUMN supervision_enabled")
            return try ConfigRecord.fetchOne(conn, key: ConfigStore.singletonID)
        }
        let seeded = try #require(record)
        try await db.writerForTests.write { conn in
            _ = try ConfigRecord.deleteOne(conn, key: ConfigStore.singletonID)
            try seeded.insert(conn)
        }
        try await db.config.setAutoHibernate(enabled: true, idleMinutes: 30)

        let config = try await db.config.get()
        #expect(config.autoHibernateEnabled)
        #expect(config.composerDraftEnabled)
    }

    /// A daemon built before the retirement still sends `supervisionEnabled`
    /// in every `Config`. A newer client ignores the key rather than failing
    /// the decode.
    @Test func aConfigThatStillCarriesTheFlagDecodes() throws {
        let data = try JSONEncoder().encode(Config())
        var object = try #require(
            try JSONSerialization.jsonObject(with: data) as? [String: Any])
        object["supervisionEnabled"] = true
        let withFlag = try JSONSerialization.data(withJSONObject: object)

        let expected = try JSONDecoder().decode(Config.self, from: data)
        #expect(try JSONDecoder().decode(Config.self, from: withFlag) == expected)
    }
}
