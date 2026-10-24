import Foundation
import GRDB
import TBDShared
import Testing
@testable import TBDDaemonLib

/// The keystroke veto's column, `config.hibernate_input_veto_enabled`, is
/// retired at schema epoch 2: nothing reads or writes it, and
/// `RetiredColumnReconciler` drops it once the kept rollback bundle no longer
/// uses it. See "Retiring a column" in `Sources/TBDDaemon/Database/CLAUDE.md`.
@Suite struct KeystrokeVetoRetirementTests {

    @Test func theVetoColumnIsRetiredAtEpochTwo() {
        #expect(SchemaEpoch.current == 2)
        let retired = RetiredColumn(
            table: "config", column: "hibernate_input_veto_enabled", epoch: 2)
        #expect(RetiredColumns.all.contains(retired))
        #expect(RetiredColumns.all.last == retired, "a retirement is appended, never inserted")
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
        #expect(!labels.contains("hibernate_input_veto_enabled"))
    }

    /// The config row is written through the record and the store, and read
    /// back, against a schema the column has been dropped from.
    @Test func theConfigRowRoundTripsWithoutTheColumn() async throws {
        let db = try TBDDatabase(inMemory: true)
        let record = try await db.writerForTests.write { conn -> ConfigRecord? in
            try conn.execute(sql: "ALTER TABLE config DROP COLUMN hibernate_input_veto_enabled")
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
}
