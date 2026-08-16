import Foundation
import GRDB
import Testing

@testable import TBDDaemonLib
@testable import TBDShared

/// Schema guards for `config.claude_cloud_enabled`
/// (`docs/specs/2026-08-15-cloud-sessions-slice-1-design.md` §7).
///
/// The column is added with **no SQL default**, so "never chose" (NULL) stays
/// distinguishable from "explicitly off" (0). If someone adds `defaults: false`
/// to `v80_config_claude_cloud`, `claudeCloudIsNullBeforeAnyGesture` goes red —
/// that is its only job. The distinction matters more here than for most flags:
/// this feature calls a network service on a schedule, so somebody who turned it
/// off did so deliberately.
@Suite("ClaudeCloudFlagSchema")
struct ClaudeCloudFlagSchemaTests {

    private func fetchConfigRecord(_ db: TBDDatabase) async throws -> ConfigRecord? {
        try await db.writerForTests.read { conn in
            try ConfigRecord.fetchOne(conn, key: ConfigStore.singletonID)
        }
    }

    /// **The load-bearing test.** The `config` singleton row is inserted by v1,
    /// so every install has a row that predates v80. After v80 its
    /// `claude_cloud_enabled` must read NULL, not `0`.
    @Test func claudeCloudIsNullBeforeAnyGesture() async throws {
        let db = try TBDDatabase(inMemory: true)
        let record = try #require(try await fetchConfigRecord(db))
        #expect(
            record.claude_cloud_enabled == nil,
            """
            config.claude_cloud_enabled must be NULL until the toggle is \
            touched — read back \(String(describing: record.claude_cloud_enabled)). \
            A non-nil value here means v80_config_claude_cloud grew a \
            `defaults:` argument; remove it.
            """)
    }

    /// The same guard against a row written by a real pre-v80 daemon: migrate
    /// only through v77, write to the config row, then finish migrating.
    @Test func rowWrittenBeforeV78StillReadsNull() throws {
        let queue = try DatabaseQueue()
        let migrator = TBDDatabase.buildMigratorForTests()
        try migrator.migrate(queue, upTo: "v77_config_supervision_enabled")

        try queue.write { db in
            try db.execute(
                sql: "UPDATE config SET supervision_enabled = 1 WHERE id = ?",
                arguments: [ConfigStore.singletonID])
        }

        try migrator.migrate(queue)

        try queue.read { db in
            let row = try #require(try Row.fetchOne(
                db, sql: "SELECT * FROM config WHERE id = ?",
                arguments: [ConfigStore.singletonID]))
            let raw: DatabaseValue = row["claude_cloud_enabled"]
            #expect(raw.isNull, "a config row written before v80 must read NULL, not \(raw)")
            // The pre-existing write survived — v80 is purely additive.
            #expect(row["supervision_enabled"] == true)
        }
    }

    /// NULL follows `Config.claudeCloudEnabledDefault` wherever it goes; an
    /// explicit `false` does not. This is the property that makes graduation a
    /// one-line constant change with no forcing `UPDATE` migration.
    @Test func explicitFalseSurvivesADefaultFlipWhileNullFollowsIt() async throws {
        let db = try TBDDatabase(inMemory: true)

        let untouched = try #require(try await fetchConfigRecord(db))
        #expect(untouched.claude_cloud_enabled == nil)
        #expect(untouched.toModel(claudeCloudEnabledDefault: false).claudeCloudEnabled == false)
        #expect(
            untouched.toModel(claudeCloudEnabledDefault: true).claudeCloudEnabled == true,
            "a never-chosen row must pick up a changed shipped default")

        try await db.config.setClaudeCloud(false)
        let explicitlyOff = try #require(try await fetchConfigRecord(db))
        #expect(explicitlyOff.claude_cloud_enabled == false)
        #expect(explicitlyOff.toModel(claudeCloudEnabledDefault: false).claudeCloudEnabled == false)
        #expect(
            explicitlyOff.toModel(claudeCloudEnabledDefault: true).claudeCloudEnabled == false,
            "an explicit opt-out must be honored forever, whatever the shipped default becomes")
    }

    /// The shipped default today. Graduation edits this constant and nothing else.
    @Test func shippedDefaultIsOff() async throws {
        #expect(Config.claudeCloudEnabledDefault == false)
        let db = try TBDDatabase(inMemory: true)
        #expect(try await db.config.get().claudeCloudEnabled == false)
    }

    @Test func setClaudeCloudRoundtrips() async throws {
        let db = try TBDDatabase(inMemory: true)
        try await db.config.setClaudeCloud(true)
        #expect(try await db.config.get().claudeCloudEnabled == true)
        try await db.config.setClaudeCloud(false)
        #expect(try await db.config.get().claudeCloudEnabled == false)
    }

    /// The reserved name is a shared constant so the dispatcher, the registry
    /// loader and the app all spell it the same way.
    @Test func theReservedProviderNameIsClaudeCloud() {
        #expect(ClaudeCloudProvider.name == "claude-cloud")
    }

    /// The RPC is what the Settings toggle writes through, and it must
    /// broadcast so another client's capability fetch sees the change without a
    /// reconnect — the same shape every sibling config verb uses.
    @Test func setClaudeCloudRPCPersistsAndBroadcasts() async throws {
        let db = try TBDDatabase(inMemory: true)
        let subs = StateSubscriptionManager()
        let router = RPCRouter(
            db: db,
            lifecycle: WorktreeLifecycle(
                db: db, git: GitManager(), tmux: TmuxManager(dryRun: true), hooks: HookResolver()),
            tmux: TmuxManager(dryRun: true),
            startTime: Date(),
            subscriptions: subs,
            actuationLog: ActuationLog(
                path: FileManager.default.temporaryDirectory
                    .appendingPathComponent("cloud-rpc-\(UUID().uuidString).jsonl").path))

        let params = try JSONEncoder().encode(ConfigSetClaudeCloudParams(enabled: true))
        let response = try await router.handleConfigSetClaudeCloud(params)
        #expect(response.success)
        #expect(try await db.config.get().claudeCloudEnabled == true)

        let off = try JSONEncoder().encode(ConfigSetClaudeCloudParams(enabled: false))
        #expect(try await router.handleConfigSetClaudeCloud(off).success)
        #expect(try await db.config.get().claudeCloudEnabled == false)
    }

    @Test func theRPCMethodNameIsStable() {
        #expect(RPCMethod.configSetClaudeCloud == "config.setClaudeCloud")
    }

    /// The flag reaches the app through `daemon.capabilities`, and it needs the
    /// live/enabled distinction for the same reason `remoteBackendsEnabled`
    /// does: the daemon wires the built-in provider only at boot, so a flag
    /// flipped on afterwards is on-but-not-live.
    @Test func capabilitiesReportEnabledButNotLiveAfterAPostBootFlip() async throws {
        let db = try TBDDatabase(inMemory: true)
        try await db.config.setClaudeCloud(true)
        // `claudeCloudLive` defaults to false — this router stands in for a
        // daemon that booted with the flag off.
        let router = RPCRouter(
            db: db,
            lifecycle: WorktreeLifecycle(
                db: db, git: GitManager(), tmux: TmuxManager(dryRun: true), hooks: HookResolver()),
            tmux: TmuxManager(dryRun: true),
            startTime: Date(),
            actuationLog: ActuationLog(
                path: FileManager.default.temporaryDirectory
                    .appendingPathComponent("cloud-caps-\(UUID().uuidString).jsonl").path))

        let response = try await router.handleDaemonCapabilities()
        let payload = try #require(response.result)
        let caps = try JSONDecoder().decode(
            DaemonCapabilitiesResult.self, from: Data(payload.utf8))
        #expect(caps.claudeCloudEnabled == true)
        #expect(caps.claudeCloudLive == false)
    }

    @Test func capabilitiesReportTheFlagOffWhenNobodyTouchedIt() async throws {
        let db = try TBDDatabase(inMemory: true)
        let router = RPCRouter(
            db: db,
            lifecycle: WorktreeLifecycle(
                db: db, git: GitManager(), tmux: TmuxManager(dryRun: true), hooks: HookResolver()),
            tmux: TmuxManager(dryRun: true),
            startTime: Date(),
            actuationLog: ActuationLog(
                path: FileManager.default.temporaryDirectory
                    .appendingPathComponent("cloud-caps-\(UUID().uuidString).jsonl").path))

        let response = try await router.handleDaemonCapabilities()
        let payload = try #require(response.result)
        let caps = try JSONDecoder().decode(
            DaemonCapabilitiesResult.self, from: Data(payload.utf8))
        #expect(caps.claudeCloudEnabled == Config.claudeCloudEnabledDefault)
        #expect(caps.claudeCloudLive == false)
    }

    /// A daemon that does not send the field cannot serve the feature either,
    /// so an absent value falls through to the shipped default rather than a
    /// hardcoded `false` — the same reading `queuedPromptEnabled` takes.
    @Test func capabilitiesFromAnOlderDaemonFollowTheShippedDefault() throws {
        let json = #"{"controlModeEnabled":false}"#
        let caps = try JSONDecoder().decode(
            DaemonCapabilitiesResult.self, from: Data(json.utf8))
        #expect(caps.claudeCloudEnabled == Config.claudeCloudEnabledDefault)
        #expect(caps.claudeCloudLive == false)
    }
}
