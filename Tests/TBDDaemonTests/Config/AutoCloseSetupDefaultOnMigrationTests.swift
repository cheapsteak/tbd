import Foundation
import GRDB
import Testing
import DaemonTestSupport
import TestSupport

@testable import TBDDaemonLib
@testable import TBDShared

/// `config.auto_close_setup_enabled` ships on. The frozen
/// `v57_config_auto_close_setup` added it as `BOOLEAN DEFAULT 0`, which gave
/// every existing row a 0 nobody chose, so
/// `20261104175902_auto_close_setup_default_on` resets the column to NULL:
/// every install reads the shipped default, a deliberate 0 included, since it
/// cannot be told from the backfill. From then on the column is tri-state like
/// the flags that carry no SQL default: NULL follows
/// `Config.autoCloseSetupDefault`, and an explicit choice survives a change to
/// it.
@Suite("AutoCloseSetupDefaultOn")
struct AutoCloseSetupDefaultOnMigrationTests {

    private static let migrationID = "20261104175902_auto_close_setup_default_on"

    private func fetchConfigRecord(_ db: TBDDatabase) async throws -> ConfigRecord? {
        try await db.writerForTests.read { conn in
            try ConfigRecord.fetchOne(conn, key: ConfigStore.singletonID)
        }
    }

    /// Migrates to the end of the frozen block, where v57 has added the
    /// column, stores `stored` in it as an install from before the migration
    /// would hold it, runs the rest of the chain, and returns the raw column
    /// and the resolved flag.
    private func migrated(from stored: Int) throws -> (raw: DatabaseValue, resolved: Bool) {
        let queue = try DatabaseQueue()
        let migrator = TBDDatabase.buildMigratorForTests()
        try migrator.migrate(queue, upTo: SchemaBaselineDriftTests.frozenBlockLastIdentifier)
        try queue.write { db in
            try db.execute(
                sql: "UPDATE config SET auto_close_setup_enabled = ? WHERE id = ?",
                arguments: [stored, ConfigStore.singletonID])
        }
        let before = try queue.read { db in
            try Int.fetchOne(
                db, sql: "SELECT auto_close_setup_enabled FROM config WHERE id = ?",
                arguments: [ConfigStore.singletonID])
        }
        #expect(before == stored, "the pre-migration row did not hold \(stored)")

        try migrator.migrate(queue)

        return try queue.read { db in
            let row = try #require(try Row.fetchOne(
                db, sql: "SELECT * FROM config WHERE id = ?",
                arguments: [ConfigStore.singletonID]))
            let raw: DatabaseValue = row["auto_close_setup_enabled"]
            let record = try #require(
                try ConfigRecord.fetchOne(db, key: ConfigStore.singletonID))
            return (raw, record.toModel().autoCloseSetupEnabled)
        }
    }

    // MARK: - The migration

    @Test func theMigrationIsRegistered() {
        let registered = SQLMigrationLoader.migrationsForRegistration().map(\.identifier)
        #expect(registered.contains(Self.migrationID))
    }

    /// Every install from before the migration holds v57's backfilled 0. It
    /// reads NULL afterwards, and on.
    @Test func aBackfilledZeroReadsOnAfterTheMigration() throws {
        let (raw, resolved) = try migrated(from: 0)
        #expect(raw.isNull, "auto_close_setup_enabled read \(raw) after the reset, not NULL")
        #expect(resolved)
    }

    /// A deliberate on is reset too, and still reads on.
    @Test func anExplicitOneIsResetAndReadsOn() throws {
        let (raw, resolved) = try migrated(from: 1)
        #expect(raw.isNull, "auto_close_setup_enabled read \(raw) after the reset, not NULL")
        #expect(resolved)
    }

    /// A fresh install runs the whole chain: its row reads NULL and on.
    @Test func aFreshInstallReadsNullAndOn() async throws {
        let db = try TBDDatabase(inMemory: true)
        let record = try #require(try await fetchConfigRecord(db))
        #expect(record.auto_close_setup_enabled == nil)
        #expect(try await db.config.get().autoCloseSetupEnabled)
    }

    // MARK: - The three states after the migration

    /// An explicit off written after the migration is stored as 0 and reads
    /// off, whatever the shipped default is.
    @Test func anExplicitFalseWrittenAfterTheMigrationSurvives() async throws {
        let db = try TBDDatabase(inMemory: true)
        try await db.config.setAutoCloseSetup(enabled: false)
        let off = try #require(try await fetchConfigRecord(db))
        #expect(off.auto_close_setup_enabled == false)
        #expect(try await db.config.get().autoCloseSetupEnabled == false)
        #expect(off.toModel(autoCloseSetupDefault: true).autoCloseSetupEnabled == false,
                "an explicit off must be honored whatever the default is")
    }

    @Test func anExplicitTrueSticks() async throws {
        let db = try TBDDatabase(inMemory: true)
        try await db.config.setAutoCloseSetup(enabled: true)
        let on = try #require(try await fetchConfigRecord(db))
        #expect(on.auto_close_setup_enabled == true)
        #expect(on.toModel(autoCloseSetupDefault: false).autoCloseSetupEnabled)
    }

    /// NULL follows the shipped default wherever it goes.
    @Test func nullFollowsTheInjectedDefault() {
        let record = ConfigRecord(id: "unstored", auto_close_setup_enabled: nil)
        #expect(record.toModel(autoCloseSetupDefault: true).autoCloseSetupEnabled)
        #expect(record.toModel(autoCloseSetupDefault: false).autoCloseSetupEnabled == false)
    }

    // MARK: - The shipped default and the wire

    @Test func shippedDefaultIsOn() {
        #expect(Config.autoCloseSetupDefault == true)
        #expect(Config().autoCloseSetupEnabled == true)
    }

    @Test func configJSONWithoutTheKeyFollowsTheShippedDefault() throws {
        let json = #"{"primaryAgentPreference":"claude"}"#
        let config = try JSONDecoder().decode(Config.self, from: Data(json.utf8))
        #expect(config.autoCloseSetupEnabled == Config.autoCloseSetupDefault)
    }

    @Test func capabilitiesWithoutTheKeyFollowTheShippedDefault() throws {
        let json = #"{"controlModeEnabled":false,"controlModeSupported":false}"#
        let caps = try JSONDecoder().decode(DaemonCapabilitiesResult.self, from: Data(json.utf8))
        #expect(caps.autoCloseSetupEnabled == Config.autoCloseSetupDefault)
    }

    /// The daemon reports the resolved value: on for a row nobody chose, off
    /// once somebody turns it off.
    @Test func capabilitiesReportTheResolvedValue() async throws {
        let db = try TBDDatabase(inMemory: true)
        let router = RPCRouter(
            db: db,
            lifecycle: WorktreeLifecycle(
                db: db, git: GitManager(), tmux: TmuxManager(dryRun: true), hooks: HookResolver()),
            tmux: TmuxManager(dryRun: true), startTime: Date(), actuationLog: makeTestActuationLog())

        let untouched = try await router.handle(RPCRequest(method: RPCMethod.daemonCapabilities))
            .decodeResult(DaemonCapabilitiesResult.self)
        #expect(untouched.autoCloseSetupEnabled)

        try await db.config.setAutoCloseSetup(enabled: false)
        let off = try await router.handle(RPCRequest(method: RPCMethod.daemonCapabilities))
            .decodeResult(DaemonCapabilitiesResult.self)
        #expect(off.autoCloseSetupEnabled == false)
    }
}
