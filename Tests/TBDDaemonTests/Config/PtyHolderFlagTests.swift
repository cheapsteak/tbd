import Foundation
import GRDB
import Testing

@testable import TBDDaemonLib
@testable import TBDShared

/// Schema and resolution guards for `config.pty_holder_enabled` and for the
/// `terminal.transport` discriminator that rides with it.
///
/// The flag column is added by `20260831055718_config_pty_holder` with **no SQL
/// default**, so "never chose" (NULL) stays distinguishable from "explicitly
/// off" (0). If someone adds a `DEFAULT` clause to that migration,
/// `ptyHolderIsNullBeforeAnyGesture` and
/// `rowWrittenBeforeTheMigrationStillReadsNull` go red — that is their only job.
/// The distinction earns its keep here because the holder transport owns a pty
/// and a child process that outlive the daemon: somebody who turned it off did
/// so deliberately and must stay opted out through graduation.
///
/// `transport` is a second model changing in the same commit, and it has its own
/// trap: `Terminal` has a hand-written `init(from:)`, so a defaulted property
/// compiles *without* a decode line and then silently reports `.tmux` for every
/// holder row that crosses the wire. `terminalTransportRoundTripsHolder` is the
/// test that discriminates; the default-direction one passes either way.
@Suite("PtyHolderFlag")
struct PtyHolderFlagTests {

    /// The last migration identifier that predates the flag's column. Migrating
    /// only this far reproduces the schema a real pre-flag daemon ran on.
    private static let lastIdentifierBeforeTheFlag = "20260830022625_shadow_peer_artifacts"

    private func fetchConfigRecord(_ db: TBDDatabase) async throws -> ConfigRecord? {
        try await db.writerForTests.read { conn in
            try ConfigRecord.fetchOne(conn, key: ConfigStore.singletonID)
        }
    }

    // MARK: - Storage: the column is genuinely NULL until somebody chooses

    /// **The load-bearing test.** The `config` singleton row is inserted by v1,
    /// so every install — fresh or years old — has a row that predates this
    /// column. After the migration that row must read NULL, not `0`: a SQL
    /// default would backfill it and make "never chose" indistinguishable from
    /// a deliberate opt-out.
    @Test func ptyHolderIsNullBeforeAnyGesture() async throws {
        let db = try TBDDatabase(inMemory: true)
        let record = try #require(try await fetchConfigRecord(db))
        #expect(
            record.pty_holder_enabled == nil,
            """
            config.pty_holder_enabled must be NULL until the toggle is touched \
            — read back \(String(describing: record.pty_holder_enabled)). A \
            non-nil value here means 20260831055718_config_pty_holder grew a \
            DEFAULT clause; remove it.
            """)
    }

    /// The same guard against a row written by a real pre-flag daemon: migrate
    /// only as far as the last identifier that predates the column, write to
    /// the config row, then finish migrating.
    @Test func rowWrittenBeforeTheMigrationStillReadsNull() throws {
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
            let raw: DatabaseValue = row["pty_holder_enabled"]
            #expect(
                raw.isNull,
                "a config row written before the migration must read NULL, not \(raw)")
            // The pre-existing write survived — the migration is purely additive.
            #expect(row["auto_create_notes_enabled"] == true)
        }
    }

    // MARK: - Resolution: the three states are distinguishable

    /// NULL follows `Config.ptyHolderDefault` wherever it goes; an explicit
    /// `false` does not. That property is what makes graduation a one-line
    /// constant change with no forcing `UPDATE` migration. Exercised against
    /// BOTH possible default values, so it fails if the resolution is ever
    /// wired as `?? false`.
    @Test func explicitFalseSurvivesADefaultFlipWhileNullFollowsIt() async throws {
        let db = try TBDDatabase(inMemory: true)

        let untouched = try #require(try await fetchConfigRecord(db))
        #expect(untouched.pty_holder_enabled == nil)
        #expect(untouched.toModel(ptyHolderDefault: false).ptyHolderEnabled == false)
        #expect(
            untouched.toModel(ptyHolderDefault: true).ptyHolderEnabled == true,
            "a never-chosen row must pick up a changed shipped default")

        try await db.config.setPtyHolderEnabled(false)
        let explicitlyOff = try #require(try await fetchConfigRecord(db))
        #expect(explicitlyOff.pty_holder_enabled == false)
        #expect(explicitlyOff.toModel(ptyHolderDefault: false).ptyHolderEnabled == false)
        #expect(
            explicitlyOff.toModel(ptyHolderDefault: true).ptyHolderEnabled == false,
            "an explicit opt-out must be honored forever, whatever the shipped default becomes")
    }

    /// Mirrored for an explicit `true`: an operator who opted into the soak
    /// stays opted in even if the shipped default never moves.
    @Test func explicitTrueSticks() async throws {
        let db = try TBDDatabase(inMemory: true)
        try await db.config.setPtyHolderEnabled(true)
        let explicitlyOn = try #require(try await fetchConfigRecord(db))
        #expect(explicitlyOn.pty_holder_enabled == true)
        #expect(explicitlyOn.toModel(ptyHolderDefault: false).ptyHolderEnabled == true)
        #expect(explicitlyOn.toModel(ptyHolderDefault: true).ptyHolderEnabled == true)
    }

    /// Isolates the RESOLUTION guard (`toModel()`'s `?? ptyHolderDefault`) from
    /// the STORAGE guard (the migration's missing SQL default) by constructing a
    /// `ConfigRecord` directly — no database, no migration. It catches a
    /// hardening into `?? false` even if the migration guard were broken at the
    /// same time.
    @Test func toModelResolvesNullThroughTheInjectedDefault() {
        let record = ConfigRecord(id: "unstored", pty_holder_enabled: nil)
        #expect(record.toModel(ptyHolderDefault: false).ptyHolderEnabled == false)
        #expect(
            record.toModel(ptyHolderDefault: true).ptyHolderEnabled == true,
            "a NULL record must pick up whatever default is injected, not a hardcoded false")
    }

    // MARK: - The shipped default, and the wire

    /// The shipped default today: OFF. A holder owns a pty and a child process
    /// that outlive the daemon, and until the holder reconcilers land nothing
    /// reclaims one orphaned by a daemon crash — so the transport soaks behind
    /// its own switch. Graduation edits this constant and nothing else.
    @Test func shippedDefaultIsOff() async throws {
        #expect(Config.ptyHolderDefault == false)
        let db = try TBDDatabase(inMemory: true)
        #expect(try await db.config.get().ptyHolderEnabled == false)
    }

    @Test func setPtyHolderEnabledRoundtrips() async throws {
        let db = try TBDDatabase(inMemory: true)
        try await db.config.setPtyHolderEnabled(true)
        #expect(try await db.config.get().ptyHolderEnabled == true)
        try await db.config.setPtyHolderEnabled(false)
        #expect(try await db.config.get().ptyHolderEnabled == false)
    }

    /// JSON from a daemon that predates the flag still decodes, and the absent
    /// key means the sender knew nothing about it — the NULL column's
    /// situation, so it follows the shipped default rather than a hardcoded
    /// `false`.
    @Test func configJSONWithoutTheKeyFollowsTheShippedDefault() throws {
        let json = #"{"primaryAgentPreference":"claude"}"#
        let config = try JSONDecoder().decode(Config.self, from: Data(json.utf8))
        #expect(config.ptyHolderEnabled == Config.ptyHolderDefault)
    }

    /// An explicit `true` on the wire is carried, so the app and the CLI see the
    /// same state the daemon resolved rather than re-deriving it.
    @Test func configJSONRoundTripsAnExplicitChoice() throws {
        var config = Config()
        config.ptyHolderEnabled = true
        let decoded = try JSONDecoder().decode(
            Config.self, from: JSONEncoder().encode(config))
        #expect(decoded.ptyHolderEnabled == true)
    }

    // MARK: - Terminal.transport

    /// A `Terminal` payload from a daemon that predates the column decodes as
    /// `.tmux`, so no existing session is mistaken for a holder session. Every
    /// required key is present — `Terminal.init(from:)` decodes `createdAt`
    /// non-optionally, so a payload omitting it would fail against a *correct*
    /// implementation and prove nothing.
    @Test func terminalTransportDefaultsToTmux() throws {
        let json = """
            {"id":"\(UUID().uuidString)","worktreeID":"\(UUID().uuidString)",\
            "tmuxWindowID":"@1","tmuxPaneID":"%1","label":"main","createdAt":0}
            """
        let decoded = try JSONDecoder().decode(Terminal.self, from: Data(json.utf8))
        #expect(decoded.transport == .tmux)
        #expect(decoded.holderPID == nil)
        #expect(decoded.childPID == nil)
    }

    /// **The discriminating test.** `Terminal` has a hand-written `init(from:)`,
    /// so `transport` compiles fine with no decode line at all and then reads
    /// `.tmux` for every holder row the daemon sends the app or the CLI. Only a
    /// round trip through the real encoder catches that; the default-direction
    /// test above passes either way.
    @Test func terminalTransportRoundTripsHolder() throws {
        let terminal = Terminal(
            worktreeID: UUID(),
            // Holder rows carry empty tmux coordinates: those columns are NOT
            // NULL from the v1 schema and cannot be relaxed, so `transport` is
            // the only thing that may discriminate them.
            tmuxWindowID: "", tmuxPaneID: "",
            transport: .holder, holderPID: 4242, childPID: 4243)
        let decoded = try JSONDecoder().decode(
            Terminal.self, from: JSONEncoder().encode(terminal))
        #expect(
            decoded.transport == .holder,
            "a holder terminal must still be a holder terminal after a wire round trip")
        #expect(decoded.holderPID == 4242)
        #expect(decoded.childPID == 4243)
    }

    /// The column plumbing, end to end through the real store: `create` stamps
    /// the transport and the two PIDs, and `get` reads them back. Without this
    /// the eleven tests above all pass against a `TerminalRecord` that never
    /// writes the column, because they never touch the `terminal` table.
    @Test func terminalTransportRoundTripsThroughTheStore() async throws {
        let db = try TBDDatabase(inMemory: true)
        let repo = try await db.repos.create(
            path: "/tmp/pty-holder-repo-\(UUID().uuidString)",
            displayName: "R", defaultBranch: "main")
        let worktree = try await db.worktrees.create(
            repoID: repo.id, name: "w", branch: "b",
            path: "/tmp/pty-holder-wt-\(UUID().uuidString)", tmuxServer: "tbd-pty-holder")

        let tmux = try await db.terminals.create(
            worktreeID: worktree.id, tmuxWindowID: "@1", tmuxPaneID: "%1")
        #expect(
            try await db.terminals.get(id: tmux.id)?.transport == .tmux,
            "every existing call site must keep creating tmux-backed sessions")

        let holder = try await db.terminals.create(
            worktreeID: worktree.id, tmuxWindowID: "", tmuxPaneID: "",
            transport: .holder, holderPID: 4242, childPID: 4243)
        let reloaded = try #require(try await db.terminals.get(id: holder.id))
        #expect(reloaded.transport == .holder)
        #expect(reloaded.holderPID == 4242)
        #expect(reloaded.childPID == 4243)
    }
}
