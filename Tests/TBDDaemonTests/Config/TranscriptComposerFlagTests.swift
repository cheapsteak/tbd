import Foundation
import GRDB
import Testing

@testable import TBDDaemonLib
@testable import TBDShared

/// Schema and resolution guards for `config.transcript_composer_enabled`, the
/// gate on the live transcript's message composer, its completions probe, its
/// attachment writes and its GC leg.
///
/// The column is added by `20260905120000_config_transcript_composer` with **no
/// SQL default**, so "never chose" (NULL) stays distinguishable from
/// "explicitly off". If someone adds a `DEFAULT` clause to that migration,
/// `nullBeforeAnyGesture` and `rowWrittenBeforeTheMigrationStillReadsNull` go
/// red — that is their only job.
@Suite("TranscriptComposerFlag")
struct TranscriptComposerFlagTests {

    /// The last migration identifier that predates the column. Migrating only
    /// this far reproduces the schema a real pre-flag daemon ran on.
    private static let lastIdentifierBeforeTheFlag = "20260904172536_config_update_mode"

    private func fetchConfigRecord(_ db: TBDDatabase) async throws -> ConfigRecord? {
        try await db.writerForTests.read { conn in
            try ConfigRecord.fetchOne(conn, key: ConfigStore.singletonID)
        }
    }

    // MARK: - Storage: the column is genuinely NULL until somebody chooses

    /// **The load-bearing test.** The `config` singleton row is inserted by v1,
    /// so every install has a row that predates this column. After the migration
    /// that row must read NULL, not `0`.
    @Test func nullBeforeAnyGesture() async throws {
        let db = try TBDDatabase(inMemory: true)
        let record = try #require(try await fetchConfigRecord(db))
        #expect(
            record.transcript_composer_enabled == nil,
            """
            config.transcript_composer_enabled must be NULL until the toggle is \
            touched — read back \
            \(String(describing: record.transcript_composer_enabled)). A non-nil \
            value here means the migration grew a DEFAULT clause; remove it.
            """)
    }

    @Test func rowWrittenBeforeTheMigrationStillReadsNull() throws {
        let queue = try DatabaseQueue()
        let migrator = TBDDatabase.buildMigratorForTests()
        try migrator.migrate(queue, upTo: Self.lastIdentifierBeforeTheFlag)

        try queue.write { db in
            try db.execute(
                sql: "UPDATE config SET auto_create_notes_enabled = 1 WHERE id = ?",
                arguments: [ConfigStore.singletonID])
        }

        try migrator.migrate(queue)

        try queue.read { db in
            let row = try #require(try Row.fetchOne(
                db, sql: "SELECT * FROM config WHERE id = ?",
                arguments: [ConfigStore.singletonID]))
            let raw: DatabaseValue = row["transcript_composer_enabled"]
            #expect(
                raw.isNull,
                "a config row written before the migration must read NULL, not \(raw)")
            #expect(row["auto_create_notes_enabled"] == true)
        }
    }

    // MARK: - Resolution: the three states are distinguishable

    /// NULL follows `Config.transcriptComposerEnabledDefault` wherever it goes;
    /// an explicit `false` does not. That property is what makes graduation a
    /// one-line constant change with no forcing `UPDATE` migration.
    @Test func explicitFalseSurvivesADefaultFlipWhileNullFollowsIt() async throws {
        let db = try TBDDatabase(inMemory: true)

        let untouched = try #require(try await fetchConfigRecord(db))
        #expect(untouched.transcript_composer_enabled == nil)
        #expect(untouched.toModel(transcriptComposerDefault: false)
            .transcriptComposerEnabled == false)
        #expect(
            untouched.toModel(transcriptComposerDefault: true).transcriptComposerEnabled,
            "a never-chosen row must pick up a changed shipped default")

        try await db.config.setTranscriptComposerEnabled(false)
        let explicitlyOff = try #require(try await fetchConfigRecord(db))
        #expect(explicitlyOff.transcript_composer_enabled == false)
        #expect(
            explicitlyOff.toModel(transcriptComposerDefault: true)
                .transcriptComposerEnabled == false,
            "an explicit opt-out must be honored forever, whatever the default becomes")
    }

    @Test func explicitTrueSticks() async throws {
        let db = try TBDDatabase(inMemory: true)
        try await db.config.setTranscriptComposerEnabled(true)
        let explicit = try #require(try await fetchConfigRecord(db))
        #expect(explicit.transcript_composer_enabled == true)
        #expect(explicit.toModel(transcriptComposerDefault: false).transcriptComposerEnabled)
        #expect(explicit.toModel(transcriptComposerDefault: true).transcriptComposerEnabled)
    }

    /// Isolates the RESOLUTION guard from the STORAGE guard by constructing a
    /// `ConfigRecord` directly — no database, no migration.
    @Test func toModelResolvesNullThroughTheInjectedDefault() {
        let record = ConfigRecord(id: "unstored", transcript_composer_enabled: nil)
        #expect(record.toModel(transcriptComposerDefault: false)
            .transcriptComposerEnabled == false)
        #expect(
            record.toModel(transcriptComposerDefault: true).transcriptComposerEnabled,
            "a NULL record must pick up whatever default is injected, not a hardcoded false")
    }

    // MARK: - The shipped default, and the wire

    @Test func shippedDefaultIsOff() async throws {
        #expect(Config.transcriptComposerEnabledDefault == false)
        let db = try TBDDatabase(inMemory: true)
        #expect(try await db.config.get().transcriptComposerEnabled == false)
    }

    @Test func setterRoundtrips() async throws {
        let db = try TBDDatabase(inMemory: true)
        try await db.config.setTranscriptComposerEnabled(true)
        #expect(try await db.config.get().transcriptComposerEnabled)
        try await db.config.setTranscriptComposerEnabled(false)
        #expect(try await db.config.get().transcriptComposerEnabled == false)
    }

    /// The flag is its own. Turning it on must not turn on anything else.
    @Test func theFlagIsIndependentOfTheOthers() async throws {
        let db = try TBDDatabase(inMemory: true)
        try await db.config.setTranscriptComposerEnabled(true)
        let config = try await db.config.get()
        #expect(config.transcriptComposerEnabled)
        #expect(config.ptyHolderEnabled == Config.ptyHolderDefault)
        #expect(config.gcEnabled == true)
    }

    @Test func configJSONWithoutTheKeyFollowsTheShippedDefault() throws {
        let json = #"{"primaryAgentPreference":"claude"}"#
        let config = try JSONDecoder().decode(Config.self, from: Data(json.utf8))
        #expect(config.transcriptComposerEnabled == Config.transcriptComposerEnabledDefault)
    }

    @Test func configJSONRoundTripsAnExplicitChoice() throws {
        var config = Config()
        config.transcriptComposerEnabled = true
        let decoded = try JSONDecoder().decode(
            Config.self, from: JSONEncoder().encode(config))
        #expect(decoded.transcriptComposerEnabled)
    }
}
