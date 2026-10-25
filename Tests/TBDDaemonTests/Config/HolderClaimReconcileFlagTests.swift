import Foundation
import GRDB
import Testing
import TestSupport

@testable import TBDDaemonLib
@testable import TBDShared

/// Schema and resolution guards for `config.holder_claim_reconcile_enabled`,
/// the default-off gate on the holder viewer-claim sweep
/// (docs/specs/2026-10-25-holder-claim-reconcile-design.md).
///
/// The column is added by `config_holder_claim_reconcile` with no SQL default,
/// so NULL ("never chose") stays distinct from 0 ("off"). That distinction is
/// what lets graduation be a one-line change to
/// `Config.holderClaimReconcileEnabledDefault`: NULL rows follow it, and an
/// explicit opt-out does not.
@Suite("HolderClaimReconcileFlag")
struct HolderClaimReconcileFlagTests {

    /// The newest migration identifier before the flag's file. Migrating only
    /// this far reproduces the schema a pre-flag daemon ran on.
    private static let lastIdentifierBeforeTheFlag = "20261025003424_claude_spawn_extras"

    private func fetchConfigRecord(_ db: TBDDatabase) async throws -> ConfigRecord? {
        try await db.writerForTests.read { conn in
            try ConfigRecord.fetchOne(conn, key: ConfigStore.singletonID)
        }
    }

    private func makeRouter(_ db: TBDDatabase) -> RPCRouter {
        let tmux = TmuxManager(dryRun: true)
        return RPCRouter(
            db: db,
            lifecycle: WorktreeLifecycle(db: db, git: GitManager(), tmux: tmux, hooks: HookResolver()),
            tmux: tmux, startTime: Date(), actuationLog: makeTestActuationLog())
    }

    // MARK: - Storage: the column is genuinely NULL until somebody chooses

    @Test func shippedDefaultIsOff() {
        #expect(Config.holderClaimReconcileEnabledDefault == false)
        #expect(Config().holderClaimReconcileEnabled == false)
    }

    /// **The load-bearing test.** A config row written by a daemon that
    /// predates the column must read NULL after the migration, not 0: a SQL
    /// default would backfill it and make "never chose" indistinguishable from
    /// a deliberate opt-out. The NULL resolves to the shipped default.
    @Test func holderClaimReconcileColumnIsNullBeforeAnyChoice() throws {
        let queue = try DatabaseQueue()
        let migrator = TBDDatabase.buildMigratorForTests()
        try migrator.migrate(queue, upTo: Self.lastIdentifierBeforeTheFlag)
        // A pre-flag daemon touching config: the row exists and has been
        // written to, but knows nothing about the new column.
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
            let raw: DatabaseValue = row["holder_claim_reconcile_enabled"]
            #expect(raw.isNull,
                    "a config row written before the migration must read NULL, not \(raw)")
            // The pre-existing write survived: the migration is purely additive.
            #expect(row["auto_create_notes_enabled"] == true)
            let record = try #require(try ConfigRecord.fetchOne(db, key: ConfigStore.singletonID))
            #expect(record.holder_claim_reconcile_enabled == nil)
            #expect(record.toModel().holderClaimReconcileEnabled
                    == Config.holderClaimReconcileEnabledDefault)
        }
    }

    /// A fresh install's row reads NULL too, through the production store.
    @Test func aFreshInstallReadsNullAndResolvesToTheDefault() async throws {
        let fresh = try TBDDatabase(inMemory: true)
        let record = try #require(try await fetchConfigRecord(fresh))
        #expect(record.holder_claim_reconcile_enabled == nil,
                "holder_claim_reconcile_enabled grew a DEFAULT clause; remove it.")
        let config = try await fresh.config.get()
        #expect(config.holderClaimReconcileEnabled == Config.holderClaimReconcileEnabledDefault)
    }

    // MARK: - Resolution: the three states are distinguishable

    /// NULL follows the default wherever it goes; an explicit `false` does not.
    /// Exercised against both default values, so it fails if the resolution is
    /// ever wired as `?? false` or `?? true`.
    @Test func explicitFalseSurvivesADefaultFlip() async throws {
        let db = try TBDDatabase(inMemory: true)
        let untouched = try #require(try await fetchConfigRecord(db))
        #expect(untouched.toModel(holderClaimReconcileDefault: false)
            .holderClaimReconcileEnabled == false)
        #expect(untouched.toModel(holderClaimReconcileDefault: true)
            .holderClaimReconcileEnabled == true,
            "a never-chosen row must pick up a changed shipped default")

        try await db.config.setHolderClaimReconcileEnabled(false)
        let explicitlyOff = try #require(try await fetchConfigRecord(db))
        #expect(explicitlyOff.holder_claim_reconcile_enabled == false)
        #expect(explicitlyOff.toModel(holderClaimReconcileDefault: false)
            .holderClaimReconcileEnabled == false)
        #expect(explicitlyOff.toModel(holderClaimReconcileDefault: true)
            .holderClaimReconcileEnabled == false,
            "an explicit opt-out must be honored whatever the shipped default becomes")
    }

    @Test func explicitTrueSticks() async throws {
        let db = try TBDDatabase(inMemory: true)
        try await db.config.setHolderClaimReconcileEnabled(true)
        let explicitlyOn = try #require(try await fetchConfigRecord(db))
        #expect(explicitlyOn.holder_claim_reconcile_enabled == true)
        #expect(explicitlyOn.toModel(holderClaimReconcileDefault: false)
            .holderClaimReconcileEnabled == true)
        #expect(try await db.config.get().holderClaimReconcileEnabled == true)
    }

    /// Isolates the resolution (`toModel()`'s `?? holderClaimReconcileDefault`)
    /// from the storage guard by building a record with no database at all.
    @Test func toModelResolvesNullThroughTheInjectedDefault() {
        let record = ConfigRecord(id: "unstored", holder_claim_reconcile_enabled: nil)
        #expect(record.toModel(holderClaimReconcileDefault: false)
            .holderClaimReconcileEnabled == false)
        #expect(record.toModel(holderClaimReconcileDefault: true)
            .holderClaimReconcileEnabled == true)
    }

    // MARK: - The wire

    @Test func modelDecodesWithoutTheKey() throws {
        let json = #"{"primaryAgentPreference":"claude"}"#
        let config = try JSONDecoder().decode(Config.self, from: Data(json.utf8))
        #expect(config.holderClaimReconcileEnabled == Config.holderClaimReconcileEnabledDefault)
    }

    @Test func modelRoundTripsTheValue() throws {
        var config = Config()
        config.holderClaimReconcileEnabled = true
        let decoded = try JSONDecoder().decode(Config.self, from: JSONEncoder().encode(config))
        #expect(decoded.holderClaimReconcileEnabled == true)
    }

    @Test func capabilitiesDecodeWithoutTheKey() throws {
        let json = #"{"controlModeEnabled":false,"controlModeSupported":false}"#
        let caps = try JSONDecoder().decode(DaemonCapabilitiesResult.self, from: Data(json.utf8))
        #expect(caps.holderClaimReconcileEnabled == Config.holderClaimReconcileEnabledDefault)
    }

    @Test func capabilitiesRoundTripTheValue() throws {
        var caps = DaemonCapabilitiesResult(controlModeEnabled: false)
        caps.holderClaimReconcileEnabled = true
        let decoded = try JSONDecoder().decode(
            DaemonCapabilitiesResult.self, from: JSONEncoder().encode(caps))
        #expect(decoded.holderClaimReconcileEnabled == true)
    }

    @Test func methodName() {
        #expect(RPCMethod.configSetHolderClaimReconcileEnabled
            == "config.setHolderClaimReconcileEnabled")
    }

    // MARK: - The setter RPC and daemon.capabilities

    /// The setter RPC writes the column, and `daemon.capabilities` reports the
    /// resolved value: the default before any choice, then each value set.
    @Test func capabilitiesCarryTheResolvedFlag() async throws {
        let db = try TBDDatabase(inMemory: true)
        let router = makeRouter(db)

        let before = await router.handle(RPCRequest(method: RPCMethod.daemonCapabilities))
        #expect(try before.decodeResult(DaemonCapabilitiesResult.self)
            .holderClaimReconcileEnabled == Config.holderClaimReconcileEnabledDefault)

        for value in [true, false] {
            let response = await router.handle(try RPCRequest(
                method: RPCMethod.configSetHolderClaimReconcileEnabled,
                params: ConfigSetHolderClaimReconcileParams(enabled: value)))
            #expect(response.success)
            let record = try #require(try await fetchConfigRecord(db))
            #expect(record.holder_claim_reconcile_enabled == value)
            let capsResponse = await router.handle(RPCRequest(method: RPCMethod.daemonCapabilities))
            let caps = try capsResponse.decodeResult(DaemonCapabilitiesResult.self)
            #expect(caps.holderClaimReconcileEnabled == value)
        }
    }
}
