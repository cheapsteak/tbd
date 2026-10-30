import Foundation
import GRDB
import Testing
import DaemonTestSupport
import TestSupport

@testable import TBDDaemonLib
@testable import TBDShared

/// Schema and resolution guards for `config.panel_tabs_enabled`, the
/// default-off gate on the side panel with tabs
/// (docs/specs/2026-10-30-panel-tabs-design.md, "Flag and rollout").
///
/// The column is added by `panel_tabs` with no SQL default, so NULL ("never
/// chose") stays distinct from 0 ("off"). That distinction is what lets
/// graduation be a one-line change to `Config.panelTabsDefault`: NULL rows
/// follow it, and an explicit opt-out does not.
@Suite("PanelTabsFlag")
struct PanelTabsFlagTests {

    /// The newest migration identifier before the flag's file. Migrating only
    /// this far reproduces the schema a pre-flag daemon ran on.
    private static let lastIdentifierBeforeTheFlag = "20261025182152_config_holder_claim_reconcile"

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
        #expect(Config.panelTabsDefault == false)
        #expect(Config().panelTabsEnabled == false)
    }

    /// **The load-bearing test.** A config row written by a daemon that
    /// predates the column must read NULL after the migration, not 0: a SQL
    /// default would backfill it and make "never chose" indistinguishable from
    /// a deliberate opt-out. The NULL resolves to the shipped default.
    @Test func panelTabsColumnIsNullBeforeAnyChoice() throws {
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
            let raw: DatabaseValue = row["panel_tabs_enabled"]
            #expect(raw.isNull,
                    "a config row written before the migration must read NULL, not \(raw)")
            // The pre-existing write survived: the column add is purely additive.
            #expect(row["auto_create_notes_enabled"] == true)
            let record = try #require(try ConfigRecord.fetchOne(db, key: ConfigStore.singletonID))
            #expect(record.panel_tabs_enabled == nil)
            #expect(record.toModel().panelTabsEnabled == Config.panelTabsDefault)
        }
    }

    /// A fresh install's row reads NULL too, through the production store.
    @Test func aFreshInstallReadsNullAndResolvesToTheDefault() async throws {
        let fresh = try TBDDatabase(inMemory: true)
        let record = try #require(try await fetchConfigRecord(fresh))
        #expect(record.panel_tabs_enabled == nil,
                "panel_tabs_enabled grew a DEFAULT clause; remove it.")
        let config = try await fresh.config.get()
        #expect(config.panelTabsEnabled == Config.panelTabsDefault)
    }

    // MARK: - The migration empties the v1 panel tables

    /// The v1 panel rows hold the split-tree layout the v2 model cannot read,
    /// so the `panel_tabs` migration deletes every one of them. Rows written
    /// by a pre-flag daemon are gone afterwards; the worktree they belonged to
    /// is not.
    @Test func migrationEmptiesV1PanelTables() throws {
        let queue = try DatabaseQueue()
        let migrator = TBDDatabase.buildMigratorForTests()
        try migrator.migrate(queue, upTo: Self.lastIdentifierBeforeTheFlag)

        let repoID = "55555555-5555-5555-5555-555555555555"
        let wtID = "66666666-6666-6666-6666-666666666666"
        let tabID = "77777777-7777-7777-7777-777777777777"
        let now = Date()
        try queue.write { db in
            try db.execute(sql: """
                INSERT INTO repo (id, path, displayName, defaultBranch, createdAt)
                VALUES (?, '/tmp/panel-tabs-pre-repo', 'PanelTabs', 'main', ?)
                """, arguments: [repoID, now])
            try db.execute(sql: """
                INSERT INTO worktree (id, repoID, name, displayName, branch, path, status, createdAt, tmuxServer)
                VALUES (?, ?, 'w', 'w', 'main', '/tmp/panel-tabs-pre-wt', 'active', ?, 'tbd-panel-tabs')
                """, arguments: [wtID, repoID, now])
            try db.execute(sql: """
                INSERT INTO workspace_tab_surface
                    (id, worktreeID, primaryContent, position, layout, revision, updatedAt)
                VALUES (?, ?, '{}', 0, '{}', 3, ?)
                """, arguments: [tabID, wtID, now])
            try db.execute(sql: """
                INSERT INTO panel_history (panelID, tabID, history, updatedAt)
                VALUES (?, ?, '[]', ?)
                """, arguments: [UUID().uuidString, tabID, now])
            try db.execute(sql: """
                INSERT INTO panel_operation_receipt
                    (operationID, worktreeID, tabID, revision, result, appliedAt)
                VALUES (?, ?, ?, 3, '{}', ?)
                """, arguments: [UUID().uuidString, wtID, tabID, now])
        }

        try migrator.migrate(queue)

        try queue.read { db in
            let surfaces = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM workspace_tab_surface")
            let history = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM panel_history")
            let receipts = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM panel_operation_receipt")
            #expect(surfaces == 0)
            #expect(history == 0)
            #expect(receipts == 0)
            let worktrees = try Int.fetchOne(
                db, sql: "SELECT COUNT(*) FROM worktree WHERE id = ?", arguments: [wtID])
            #expect(worktrees == 1, "the worktree that owned the v1 rows must survive")
            // The daemon-wide revision counter starts at zero, with no row
            // left above it.
            let counter = try Int64.fetchAll(db, sql: "SELECT value FROM panel_revision_counter")
            #expect(counter == [0])
        }
    }

    // MARK: - Resolution: the three states are distinguishable

    /// NULL follows the default wherever it goes; an explicit `false` does not.
    /// Exercised against both default values, so it fails if the resolution is
    /// ever wired as `?? false` or `?? true`.
    @Test func explicitFalseSurvivesADefaultFlip() async throws {
        let db = try TBDDatabase(inMemory: true)
        let untouched = try #require(try await fetchConfigRecord(db))
        #expect(untouched.toModel(panelTabsDefault: false).panelTabsEnabled == false)
        #expect(untouched.toModel(panelTabsDefault: true).panelTabsEnabled == true,
                "a never-chosen row must pick up a changed shipped default")

        try await db.config.setPanelTabsEnabled(false)
        let explicitlyOff = try #require(try await fetchConfigRecord(db))
        #expect(explicitlyOff.panel_tabs_enabled == false)
        #expect(explicitlyOff.toModel(panelTabsDefault: false).panelTabsEnabled == false)
        #expect(explicitlyOff.toModel(panelTabsDefault: true).panelTabsEnabled == false,
                "an explicit opt-out must be honored whatever the shipped default becomes")
    }

    @Test func explicitTrueSticks() async throws {
        let db = try TBDDatabase(inMemory: true)
        try await db.config.setPanelTabsEnabled(true)
        let explicitlyOn = try #require(try await fetchConfigRecord(db))
        #expect(explicitlyOn.panel_tabs_enabled == true)
        #expect(explicitlyOn.toModel(panelTabsDefault: false).panelTabsEnabled == true)
        #expect(try await db.config.get().panelTabsEnabled == true)
    }

    /// Isolates the resolution (`toModel()`'s `?? panelTabsDefault`) from the
    /// storage guard by building a record with no database at all.
    @Test func toModelResolvesNullThroughTheInjectedDefault() {
        let record = ConfigRecord(id: "unstored", panel_tabs_enabled: nil)
        #expect(record.toModel(panelTabsDefault: false).panelTabsEnabled == false)
        #expect(record.toModel(panelTabsDefault: true).panelTabsEnabled == true)
    }

    // MARK: - The wire

    @Test func modelDecodesWithoutTheKey() throws {
        let json = #"{"primaryAgentPreference":"claude"}"#
        let config = try JSONDecoder().decode(Config.self, from: Data(json.utf8))
        #expect(config.panelTabsEnabled == Config.panelTabsDefault)
    }

    @Test func modelRoundTripsTheValue() throws {
        var config = Config()
        config.panelTabsEnabled = true
        let decoded = try JSONDecoder().decode(Config.self, from: JSONEncoder().encode(config))
        #expect(decoded.panelTabsEnabled == true)
    }

    @Test func capabilitiesDecodeWithoutTheKey() throws {
        let json = #"{"controlModeEnabled":false,"controlModeSupported":false}"#
        let caps = try JSONDecoder().decode(DaemonCapabilitiesResult.self, from: Data(json.utf8))
        #expect(caps.panelTabsEnabled == Config.panelTabsDefault)
    }

    @Test func capabilitiesRoundTripTheValue() throws {
        var caps = DaemonCapabilitiesResult(controlModeEnabled: false)
        caps.panelTabsEnabled = true
        let decoded = try JSONDecoder().decode(
            DaemonCapabilitiesResult.self, from: JSONEncoder().encode(caps))
        #expect(decoded.panelTabsEnabled == true)
    }

    @Test func methodName() {
        #expect(RPCMethod.configSetPanelTabsEnabled == "config.setPanelTabsEnabled")
    }

    // MARK: - The setter RPC and daemon.capabilities

    /// The setter RPC writes the column, and `daemon.capabilities` reports the
    /// resolved value: the default before any choice, then each value set.
    @Test func capabilitiesCarryTheResolvedFlag() async throws {
        let db = try TBDDatabase(inMemory: true)
        let router = makeRouter(db)

        let before = await router.handle(RPCRequest(method: RPCMethod.daemonCapabilities))
        #expect(try before.decodeResult(DaemonCapabilitiesResult.self)
            .panelTabsEnabled == Config.panelTabsDefault)

        for value in [true, false] {
            let response = await router.handle(try RPCRequest(
                method: RPCMethod.configSetPanelTabsEnabled,
                params: ConfigSetPanelTabsParams(enabled: value)))
            #expect(response.success)
            let record = try #require(try await fetchConfigRecord(db))
            #expect(record.panel_tabs_enabled == value)
            let capsResponse = await router.handle(RPCRequest(method: RPCMethod.daemonCapabilities))
            let caps = try capsResponse.decodeResult(DaemonCapabilitiesResult.self)
            #expect(caps.panelTabsEnabled == value)
        }
    }

    /// The setter broadcasts on the config-change channel the app already
    /// listens on, so Settings and the panel gate refresh without a poll.
    @Test func setterBroadcastsAConfigChange() async throws {
        let db = try TBDDatabase(inMemory: true)
        let deltas = PanelTabsFlagDeltas()
        let subs = StateSubscriptionManager()
        subs.addSubscriber { data in
            if let delta = try? JSONDecoder().decode(StateDelta.self, from: data) {
                deltas.append(delta)
            }
            return true
        }
        let tmux = TmuxManager(dryRun: true)
        let router = RPCRouter(
            db: db,
            lifecycle: WorktreeLifecycle(db: db, git: GitManager(), tmux: tmux, hooks: HookResolver()),
            tmux: tmux, startTime: Date(), subscriptions: subs,
            actuationLog: makeTestActuationLog())

        let response = await router.handle(try RPCRequest(
            method: RPCMethod.configSetPanelTabsEnabled,
            params: ConfigSetPanelTabsParams(enabled: true)))
        #expect(response.success)
        let configChanges = deltas.snapshot().filter { delta in
            if case .modelProfilesChanged = delta { return true }
            return false
        }
        #expect(configChanges.count == 1)
    }
}

/// Deltas a test subscriber received, guarded for the subscriber callback.
private final class PanelTabsFlagDeltas: @unchecked Sendable {
    private let lock = NSLock()
    private var deltas: [StateDelta] = []

    func append(_ delta: StateDelta) {
        lock.lock(); defer { lock.unlock() }
        deltas.append(delta)
    }

    func snapshot() -> [StateDelta] {
        lock.lock(); defer { lock.unlock() }
        return deltas
    }
}
