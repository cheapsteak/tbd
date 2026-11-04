import Foundation
import GRDB
import Testing

@testable import TBDDaemonLib
@testable import TBDShared

/// Schema and resolution guards for `config.transcript_streaming_enabled`,
/// which ships on.
///
/// The column is added with **no SQL default**, so "never chose" (NULL) stays
/// distinguishable from "explicitly off". If someone adds a `DEFAULT` clause to
/// its migration, `nullBeforeAnyGesture` and
/// `rowWrittenBeforeTheMigrationStillReadsNull` go red — that is their only
/// job.
@Suite("TranscriptStreamingConfigFlag")
struct TranscriptStreamingConfigFlagTests {

    /// The last migration identifier that predates the column. Migrating only
    /// this far reproduces the schema a real pre-flag daemon ran on.
    private static let lastIdentifierBeforeTheFlag = "20260905220000_terminal_holder_child_started_at"

    private func fetchConfigRecord(_ db: TBDDatabase) async throws -> ConfigRecord? {
        try await db.writerForTests.read { conn in
            try ConfigRecord.fetchOne(conn, key: ConfigStore.singletonID)
        }
    }

    // MARK: - Storage: the column is genuinely NULL until somebody chooses

    /// **The load-bearing test.** The `config` singleton row is inserted by v1,
    /// so every install has a row that predates this column. After the
    /// migrations that row must read NULL, not `0`.
    @Test func nullBeforeAnyGesture() async throws {
        let db = try TBDDatabase(inMemory: true)
        let record = try #require(try await fetchConfigRecord(db))
        #expect(
            record.transcript_streaming_enabled == nil,
            """
            config.transcript_streaming_enabled must be NULL until the toggle \
            is touched — read back \
            \(String(describing: record.transcript_streaming_enabled)). A \
            non-nil value here means the migration grew a DEFAULT clause; \
            remove it.
            """)
    }

    @Test func rowWrittenBeforeTheMigrationStillReadsNull() throws {
        let queue = try DatabaseQueue()
        let migrator = TBDDatabase.buildMigratorForTests()
        try migrator.migrate(queue, upTo: Self.lastIdentifierBeforeTheFlag)

        try queue.write { db in
            try db.execute(
                sql: "UPDATE config SET queued_prompt_enabled = 1 WHERE id = ?",
                arguments: [ConfigStore.singletonID])
        }

        try migrator.migrate(queue)

        try queue.read { db in
            let row = try #require(try Row.fetchOne(
                db, sql: "SELECT * FROM config WHERE id = ?",
                arguments: [ConfigStore.singletonID]))
            let raw: DatabaseValue = row["transcript_streaming_enabled"]
            #expect(
                raw.isNull,
                "transcript_streaming_enabled on a config row written before the migration must read NULL, not \(raw)")
            #expect(row["queued_prompt_enabled"] == true)
        }
    }

    // MARK: - Resolution: the three states are distinguishable

    /// NULL follows `Config.transcriptStreamingDefault` wherever it goes; an
    /// explicit `false` does not. That property is what makes graduation a
    /// one-line constant change with no forcing `UPDATE` migration.
    @Test func explicitFalseSurvivesADefaultFlipWhileNullFollowsIt() async throws {
        let db = try TBDDatabase(inMemory: true)

        let untouched = try #require(try await fetchConfigRecord(db))
        #expect(untouched.transcript_streaming_enabled == nil)
        #expect(
            untouched.toModel(transcriptStreamingDefault: false)
                .transcriptStreamingEnabled == false)
        #expect(
            untouched.toModel(transcriptStreamingDefault: true).transcriptStreamingEnabled,
            "a never-chosen row must pick up a changed shipped default")

        try await db.config.setTranscriptStreamingEnabled(false)
        let explicitlyOff = try #require(try await fetchConfigRecord(db))
        #expect(explicitlyOff.transcript_streaming_enabled == false)
        #expect(
            explicitlyOff.toModel(transcriptStreamingDefault: true)
                .transcriptStreamingEnabled == false,
            "an explicit opt-out must be honored forever, whatever the default becomes")
        #expect(try await db.config.get().transcriptStreamingEnabled == false)
    }

    @Test func explicitTrueSticks() async throws {
        let db = try TBDDatabase(inMemory: true)
        try await db.config.setTranscriptStreamingEnabled(true)
        let on = try #require(try await fetchConfigRecord(db))
        #expect(on.transcript_streaming_enabled == true)
        #expect(on.toModel(transcriptStreamingDefault: false).transcriptStreamingEnabled)
        #expect(try await db.config.get().transcriptStreamingEnabled)
    }

    /// Isolates the RESOLUTION guard from the STORAGE guard by constructing a
    /// `ConfigRecord` directly — no database, no migration.
    @Test func toModelResolvesNullThroughTheInjectedDefault() {
        let record = ConfigRecord(id: "unstored", transcript_streaming_enabled: nil)
        #expect(
            record.toModel(transcriptStreamingDefault: false)
                .transcriptStreamingEnabled == false)
        #expect(
            record.toModel(transcriptStreamingDefault: true).transcriptStreamingEnabled,
            "a NULL record must pick up whatever default is injected, not a hardcoded false")
    }

    // MARK: - The shipped default, and the wire

    /// Streaming ships on: a row nobody chose for reads on.
    @Test func shippedDefaultIsOn() async throws {
        #expect(Config.transcriptStreamingDefault == true)
        let db = try TBDDatabase(inMemory: true)
        #expect(try await db.config.get().transcriptStreamingEnabled == true)
    }

    @Test func configJSONWithoutTheKeyFollowsTheShippedDefault() throws {
        let json = #"{"primaryAgentPreference":"claude"}"#
        let config = try JSONDecoder().decode(Config.self, from: Data(json.utf8))
        #expect(config.transcriptStreamingEnabled == Config.transcriptStreamingDefault)
    }

    /// Off is the value that differs from the shipped default, so it is the
    /// one whose round trip says anything.
    @Test func configJSONRoundTripsAnExplicitChoice() throws {
        var config = Config()
        config.transcriptStreamingEnabled = false
        let decoded = try JSONDecoder().decode(
            Config.self, from: JSONEncoder().encode(config))
        #expect(decoded.transcriptStreamingEnabled == false)
    }
}
