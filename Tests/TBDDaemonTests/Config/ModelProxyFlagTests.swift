import Foundation
import GRDB
import Testing

@testable import TBDDaemonLib
@testable import TBDShared

/// Schema, resolution and coupling guards for the model proxy's two flags and
/// its port column
/// (`docs/specs/2026-09-05-transcript-streaming-model-proxy-design.md`,
/// "Flags and migrations" and "Port").
///
/// `config.model_proxy_enabled` and `config.transcript_streaming_enabled` are
/// added with **no SQL default**, so "never chose" (NULL) stays
/// distinguishable from "explicitly off". If someone adds a `DEFAULT` clause to
/// either migration, `nullBeforeAnyGesture` and
/// `rowWrittenBeforeTheMigrationStillReadsNull` go red — that is their only
/// job.
///
/// The two flags are coupled in one direction each by the setters, and their
/// conjunction is what any reader acts on; both properties are pinned below,
/// the conjunction against a row no setter can produce.
@Suite("ModelProxyFlag")
struct ModelProxyFlagTests {

    /// The last migration identifier that predates the columns. Migrating only
    /// this far reproduces the schema a real pre-flag daemon ran on. Any
    /// identifier that predates the four columns would do — this one is just
    /// whatever landed last before them.
    private static let lastIdentifierBeforeTheFlags = "20260905220000_terminal_holder_child_started_at"

    private func fetchConfigRecord(_ db: TBDDatabase) async throws -> ConfigRecord? {
        try await db.writerForTests.read { conn in
            try ConfigRecord.fetchOne(conn, key: ConfigStore.singletonID)
        }
    }

    // MARK: - Storage: the columns are genuinely NULL until somebody chooses

    /// **The load-bearing test.** The `config` singleton row is inserted by v1,
    /// so every install has a row that predates these columns. After the
    /// migrations that row must read NULL for all three, not `0`.
    @Test func nullBeforeAnyGesture() async throws {
        let db = try TBDDatabase(inMemory: true)
        let record = try #require(try await fetchConfigRecord(db))
        #expect(
            record.model_proxy_enabled == nil,
            """
            config.model_proxy_enabled must be NULL until the toggle is touched \
            — read back \(String(describing: record.model_proxy_enabled)). A \
            non-nil value here means the migration grew a DEFAULT clause; \
            remove it.
            """)
        #expect(
            record.transcript_streaming_enabled == nil,
            """
            config.transcript_streaming_enabled must be NULL until the toggle \
            is touched — read back \
            \(String(describing: record.transcript_streaming_enabled)).
            """)
        #expect(
            record.model_proxy_port == nil,
            """
            config.model_proxy_port must be NULL until a port is minted — read \
            back \(String(describing: record.model_proxy_port)). Zero is the ask \
            the proxy is spawned with, never a stored answer.
            """)
    }

    @Test func rowWrittenBeforeTheMigrationStillReadsNull() throws {
        let queue = try DatabaseQueue()
        let migrator = TBDDatabase.buildMigratorForTests()
        try migrator.migrate(queue, upTo: Self.lastIdentifierBeforeTheFlags)

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
            for column in [
                "model_proxy_enabled", "transcript_streaming_enabled", "model_proxy_port",
            ] {
                let raw: DatabaseValue = row[column]
                #expect(
                    raw.isNull,
                    "\(column) on a config row written before the migration must read NULL, not \(raw)")
            }
            #expect(row["auto_create_notes_enabled"] == true)
        }
    }

    /// The terminal column ships in the same commit as the config ones and is
    /// nullable for the same reason: a session either got a stream file at
    /// spawn or never will.
    @Test func terminalStreamPathColumnExistsAndIsNullable() throws {
        let queue = try DatabaseQueue()
        try TBDDatabase.buildMigratorForTests().migrate(queue)
        try queue.read { db in
            #expect(try db.columns(in: "terminal").map(\.name)
                .contains("transcript_stream_path"))
            let info = try #require(try Row.fetchAll(db, sql: "PRAGMA table_info(terminal)")
                .first { $0["name"] == "transcript_stream_path" })
            #expect(info["notnull"] == 0, "the column must be nullable")
            let defaultValue: DatabaseValue = info["dflt_value"]
            #expect(defaultValue.isNull, "the column must carry no SQL DEFAULT, read \(defaultValue)")
        }
    }

    // MARK: - Resolution: the three states are distinguishable

    /// NULL follows `Config.modelProxyDefault` wherever it goes; an explicit
    /// `false` does not. That property is what makes graduation a one-line
    /// constant change with no forcing `UPDATE` migration.
    @Test func explicitFalseSurvivesADefaultFlipWhileNullFollowsIt() async throws {
        let db = try TBDDatabase(inMemory: true)

        let untouched = try #require(try await fetchConfigRecord(db))
        #expect(untouched.model_proxy_enabled == nil)
        #expect(untouched.toModel(modelProxyDefault: false).modelProxyEnabled == false)
        #expect(
            untouched.toModel(modelProxyDefault: true).modelProxyEnabled,
            "a never-chosen row must pick up a changed shipped default")

        try await db.config.setModelProxyEnabled(false)
        let explicitlyOff = try #require(try await fetchConfigRecord(db))
        #expect(explicitlyOff.model_proxy_enabled == false)
        #expect(
            explicitlyOff.toModel(modelProxyDefault: true).modelProxyEnabled == false,
            "an explicit opt-out must be honored forever, whatever the default becomes")
    }

    @Test func streamingExplicitFalseSurvivesADefaultFlipWhileNullFollowsIt() async throws {
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
    }

    /// Isolates the RESOLUTION guard from the STORAGE guard by constructing a
    /// `ConfigRecord` directly — no database, no migration.
    @Test func toModelResolvesNullThroughTheInjectedDefaults() {
        let record = ConfigRecord(
            id: "unstored", model_proxy_enabled: nil, transcript_streaming_enabled: nil)
        #expect(record.toModel(modelProxyDefault: false).modelProxyEnabled == false)
        #expect(
            record.toModel(modelProxyDefault: true).modelProxyEnabled,
            "a NULL record must pick up whatever default is injected, not a hardcoded false")
        #expect(
            record.toModel(transcriptStreamingDefault: false)
                .transcriptStreamingEnabled == false)
        #expect(record.toModel(transcriptStreamingDefault: true).transcriptStreamingEnabled)
    }

    // MARK: - The shipped defaults, and the wire

    @Test func shippedDefaultsAreOff() async throws {
        #expect(Config.modelProxyDefault == false)
        #expect(Config.transcriptStreamingDefault == false)
        let db = try TBDDatabase(inMemory: true)
        let config = try await db.config.get()
        #expect(config.modelProxyEnabled == false)
        #expect(config.transcriptStreamingEnabled == false)
        #expect(config.transcriptStreamingEffective == false)
        #expect(config.modelProxyPort == nil)
    }

    @Test func configJSONWithoutTheKeysFollowsTheShippedDefaults() throws {
        let json = #"{"primaryAgentPreference":"claude"}"#
        let config = try JSONDecoder().decode(Config.self, from: Data(json.utf8))
        #expect(config.modelProxyEnabled == Config.modelProxyDefault)
        #expect(config.transcriptStreamingEnabled == Config.transcriptStreamingDefault)
        #expect(config.modelProxyPort == nil)
    }

    @Test func configJSONRoundTripsExplicitChoices() throws {
        var config = Config()
        config.modelProxyEnabled = true
        config.transcriptStreamingEnabled = true
        config.modelProxyPort = 51_234
        let decoded = try JSONDecoder().decode(
            Config.self, from: JSONEncoder().encode(config))
        #expect(decoded.modelProxyEnabled)
        #expect(decoded.transcriptStreamingEnabled)
        #expect(decoded.modelProxyPort == 51_234)
        #expect(decoded.transcriptStreamingEffective)
    }

    // MARK: - Coupling: one direction each

    /// Asking for streaming is asking for the proxy too, because the file
    /// streaming reads is the one the proxy writes.
    @Test func turningStreamingOnTurnsTheProxyOn() async throws {
        let db = try TBDDatabase(inMemory: true)
        try await db.config.setTranscriptStreamingEnabled(true)
        let config = try await db.config.get()
        #expect(config.transcriptStreamingEnabled)
        #expect(config.modelProxyEnabled, "streaming on must have written the proxy flag on")
        #expect(config.transcriptStreamingEffective)
    }

    /// And the reverse: switching the proxy off switches streaming off, so it
    /// cannot silently re-arm when the proxy next comes on.
    @Test func turningTheProxyOffTurnsStreamingOff() async throws {
        let db = try TBDDatabase(inMemory: true)
        try await db.config.setTranscriptStreamingEnabled(true)
        try await db.config.setModelProxyEnabled(false)

        let config = try await db.config.get()
        #expect(config.modelProxyEnabled == false)
        #expect(config.transcriptStreamingEnabled == false)
        #expect(config.transcriptStreamingEffective == false)

        try await db.config.setModelProxyEnabled(true)
        #expect(
            try await db.config.get().transcriptStreamingEnabled == false,
            "streaming must stay off until it is asked for again")
    }

    /// The off-write fires even when streaming was never touched: a fresh row
    /// has `transcript_streaming_enabled` at NULL, and turning the proxy off
    /// is still the gesture that lifts it into an explicit `false` — not a
    /// value that merely happens to resolve to false through the default.
    @Test func turningTheProxyOffFromAFreshRowWritesStreamingExplicitlyFalse() async throws {
        let db = try TBDDatabase(inMemory: true)
        let before = try #require(try await fetchConfigRecord(db))
        #expect(before.transcript_streaming_enabled == nil)

        try await db.config.setModelProxyEnabled(false)

        let after = try #require(try await fetchConfigRecord(db))
        #expect(
            after.transcript_streaming_enabled == false,
            """
            turning the proxy off from a fresh row must write streaming to an \
            explicit 0, not leave it NULL — read back \
            \(String(describing: after.transcript_streaming_enabled)).
            """)
    }

    /// Turning the proxy ON is not coupled: it must leave streaming exactly
    /// where the user left it rather than turning it on as a side effect.
    @Test func turningTheProxyOnLeavesStreamingAlone() async throws {
        let db = try TBDDatabase(inMemory: true)
        try await db.config.setModelProxyEnabled(true)
        let record = try #require(try await fetchConfigRecord(db))
        #expect(record.model_proxy_enabled == true)
        #expect(
            record.transcript_streaming_enabled == nil,
            "turning the proxy on must not lift streaming out of NULL")
        #expect(try await db.config.get().transcriptStreamingEffective == false)
    }

    /// Turning streaming OFF is not coupled either — a user who wants the row
    /// but not the proxy would have no way back otherwise.
    @Test func turningStreamingOffLeavesTheProxyAlone() async throws {
        let db = try TBDDatabase(inMemory: true)
        try await db.config.setModelProxyEnabled(true)
        try await db.config.setTranscriptStreamingEnabled(false)
        let config = try await db.config.get()
        #expect(config.modelProxyEnabled)
        #expect(config.transcriptStreamingEnabled == false)
        #expect(config.transcriptStreamingEffective == false)
    }

    /// The conjunction, against a combination no setter can produce: a
    /// hand-edited row with streaming on and the proxy off streams nothing.
    @Test func effectiveIsFalseWhenStreamingIsOnAndTheProxyIsOff() async throws {
        let db = try TBDDatabase(inMemory: true)
        try await db.writerForTests.write { conn in
            try conn.execute(
                sql: """
                    UPDATE config
                       SET model_proxy_enabled = 0, transcript_streaming_enabled = 1
                     WHERE id = ?
                    """,
                arguments: [ConfigStore.singletonID])
        }
        let config = try await db.config.get()
        #expect(config.modelProxyEnabled == false)
        #expect(config.transcriptStreamingEnabled, "the row's own choice is preserved")
        #expect(
            config.transcriptStreamingEffective == false,
            "streaming without the proxy has no file to read and must resolve off")
    }

    // MARK: - The port

    @Test func ensureModelProxyPortKeepsTheFirstValue() async throws {
        let db = try TBDDatabase(inMemory: true)
        let first = try await db.config.ensureModelProxyPort(minting: 51_234)
        #expect(first == 51_234)
        let second = try await db.config.ensureModelProxyPort(minting: 51_999)
        #expect(second == 51_234, "the second daemon to ask must get the port already minted")
        #expect(try await db.config.get().modelProxyPort == 51_234)
    }

    @Test func setModelProxyPortOverwrites() async throws {
        let db = try TBDDatabase(inMemory: true)
        _ = try await db.config.ensureModelProxyPort(minting: 51_234)
        try await db.config.setModelProxyPort(51_999)
        #expect(try await db.config.get().modelProxyPort == 51_999)
        #expect(
            try await db.config.ensureModelProxyPort(minting: 52_000) == 51_999,
            "the re-minted port is now the one a later ensure must keep")
    }

    /// Zero is the ask the proxy is spawned with, never a stored answer, so a
    /// row holding it is unminted and the next ensure mints over it.
    @Test func ensureModelProxyPortTreatsANonPositiveStoredValueAsUnminted() async throws {
        let db = try TBDDatabase(inMemory: true)
        try await db.config.setModelProxyPort(0)
        #expect(try await db.config.ensureModelProxyPort(minting: 51_234) == 51_234)
        #expect(try await db.config.get().modelProxyPort == 51_234)
    }
}
