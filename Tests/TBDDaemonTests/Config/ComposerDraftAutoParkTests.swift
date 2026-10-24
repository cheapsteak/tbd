import Foundation
import GRDB
import Testing
import TestSupport

@testable import TBDDaemonLib
@testable import TBDShared

/// Records each feature list the router hands `sessionModPluginSync`.
private final class AutoParkPluginSyncRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var calls: [[SessionModFeature]] = []

    func append(_ features: [SessionModFeature]) {
        lock.withLock { calls.append(features) }
    }

    func snapshot() -> [[SessionModFeature]] {
        lock.withLock { calls }
    }
}

/// Automatic parking holds the composer-draft feature on: the idle sweep, the
/// global park-on-merge default, and a worktree's park-on-merge override each
/// turn it on, resolved where `ConfigStore` builds `Config`, without ever
/// writing `composer_draft_enabled`. Every write that can change the result
/// re-syncs the plugin when the features change.
/// Design: docs/specs/2026-10-24-mod-only-park-guard-design.md.
@Suite("Composer draft held on by automatic parking")
struct ComposerDraftAutoParkTests {

    /// Each way TBD parks without a gesture, and none of them.
    enum Trigger: String, CaseIterable, Sendable {
        case none, idleSweep, mergeDefault, worktreeOverride
    }

    /// The three states of the stored flag.
    enum Stored: String, CaseIterable, Sendable {
        case neverChosen, off, on
    }

    private func makeRouter(_ db: TBDDatabase) -> RPCRouter {
        RPCRouter(
            db: db,
            lifecycle: WorktreeLifecycle(
                db: db, git: GitManager(), tmux: TmuxManager(dryRun: true), hooks: HookResolver()),
            tmux: TmuxManager(dryRun: true), startTime: Date(), actuationLog: makeTestActuationLog())
    }

    /// An active worktree whose park-on-merge override starts unset.
    private func makeWorktree(_ db: TBDDatabase) async throws -> UUID {
        let repo = try await db.repos.create(
            path: "/tmp/acme-autopark-\(UUID().uuidString)", displayName: "acme",
            defaultBranch: "main")
        let worktree = try await db.worktrees.create(
            repoID: repo.id, name: "w", branch: "b",
            path: "/tmp/acme-autopark/w-\(UUID().uuidString)", tmuxServer: "tbd-autopark")
        return worktree.id
    }

    private func store(_ stored: Stored, in db: TBDDatabase) async throws {
        switch stored {
        case .neverChosen: break
        case .off: try await db.config.setComposerDraftEnabled(false)
        case .on: try await db.config.setComposerDraftEnabled(true)
        }
    }

    /// Turns `trigger` on or off through the store, as each setter writes it.
    private func set(
        _ trigger: Trigger, _ on: Bool, in db: TBDDatabase, worktreeID: UUID
    ) async throws {
        switch trigger {
        case .none:
            break
        case .idleSweep:
            try await db.config.setAutoHibernate(enabled: on, idleMinutes: 30)
        case .mergeDefault:
            try await db.config.setAutoHibernateOnMergeDefault(on)
        case .worktreeOverride:
            try await db.worktrees.setAutoHibernateOnMerge(id: worktreeID, value: on)
        }
    }

    /// Turns `trigger` on or off through its RPC, the path the app takes.
    private func send(
        _ trigger: Trigger, _ on: Bool, to router: RPCRouter, worktreeID: UUID
    ) async throws {
        let request: RPCRequest
        switch trigger {
        case .none:
            return
        case .idleSweep:
            request = try RPCRequest(
                method: RPCMethod.configSetAutoHibernate,
                params: ConfigSetAutoHibernateParams(enabled: on, idleMinutes: 30))
        case .mergeDefault:
            request = try RPCRequest(
                method: RPCMethod.configSetAutoHibernateOnMergeDefault,
                params: ConfigSetAutoHibernateDefaultParams(enabled: on))
        case .worktreeOverride:
            request = try RPCRequest(
                method: RPCMethod.worktreeSetAutoHibernate,
                params: WorktreeSetAutoHibernateParams(worktreeID: worktreeID, enabled: on))
        }
        let response = await router.handle(request)
        #expect(response.success, "\(trigger) was refused: \(response.error ?? "nil")")
    }

    private func storedFlag(_ db: TBDDatabase) async throws -> Bool? {
        let record = try await db.writerForTests.read { conn in
            try ConfigRecord.fetchOne(conn, key: ConfigStore.singletonID)
        }
        return try #require(record).composer_draft_enabled
    }

    // MARK: - The effective value

    /// The whole matrix: the stored flag ON, OFF and never chosen, crossed
    /// with each way automatic parking can be on and with none of them. The
    /// feature is on when the stored value (through the shipped default) is,
    /// or automatic parking is; automatic parking is what the hold reports;
    /// and the stored column keeps exactly what the person chose.
    @Test(arguments: Stored.allCases, Trigger.allCases)
    func theEffectiveValueIsTheStoredValueOrAutomaticParking(
        _ stored: Stored, _ trigger: Trigger
    ) async throws {
        let db = try TBDDatabase(inMemory: true)
        let worktreeID = try await makeWorktree(db)
        try await store(stored, in: db)
        try await set(trigger, true, in: db, worktreeID: worktreeID)

        let config = try await db.config.get()
        let automatic = trigger != .none
        let storedValue: Bool
        switch stored {
        case .neverChosen: storedValue = Config.composerDraftDefault
        case .off: storedValue = false
        case .on: storedValue = true
        }
        #expect(config.composerDraftEnabled == (storedValue || automatic),
                "stored \(stored) with \(trigger)")
        #expect(config.composerDraftRequiredByAutoPark == automatic,
                "stored \(stored) with \(trigger)")
        let expectedColumn: Bool? = stored == .neverChosen ? nil : stored == .on
        #expect(try await storedFlag(db) == expectedColumn,
                "automatic parking wrote composer_draft_enabled")
    }

    /// An explicit OFF reads on while automatic parking holds it, and holds
    /// again the moment automatic parking is off.
    @Test(arguments: [Trigger.idleSweep, .mergeDefault, .worktreeOverride])
    func anExplicitOffHoldsAgainOnceAutomaticParkingIsOff(_ trigger: Trigger) async throws {
        let db = try TBDDatabase(inMemory: true)
        let worktreeID = try await makeWorktree(db)
        try await db.config.setComposerDraftEnabled(false)

        try await set(trigger, true, in: db, worktreeID: worktreeID)
        var config = try await db.config.get()
        #expect(config.composerDraftEnabled)
        #expect(config.composerDraftRequiredByAutoPark)

        try await set(trigger, false, in: db, worktreeID: worktreeID)
        config = try await db.config.get()
        #expect(!config.composerDraftEnabled)
        #expect(!config.composerDraftRequiredByAutoPark)
        #expect(try await storedFlag(db) == false)
    }

    /// A never-chosen flag still follows the shipped default when nothing
    /// holds it, and automatic parking holds it on whatever the default says.
    @Test func aNeverChosenFlagFollowsTheShippedDefaultUnlessAutomaticParkingHoldsIt() async throws {
        let db = try TBDDatabase(inMemory: true)
        let fetched = try await db.writerForTests.read { conn in
            try ConfigRecord.fetchOne(conn, key: ConfigStore.singletonID)
        }
        let record = try #require(fetched)
        #expect(record.toModel(composerDraftDefault: true).composerDraftEnabled)
        #expect(!record.toModel(composerDraftDefault: false).composerDraftEnabled)
        let held = record.toModel(composerDraftDefault: false, worktreeParksOnMerge: true)
        #expect(held.composerDraftEnabled)
        #expect(held.composerDraftRequiredByAutoPark)
    }

    /// A worktree override of false parks nothing on merge, so it holds
    /// nothing.
    @Test func aWorktreeOverrideOfFalseHoldsNothing() async throws {
        let db = try TBDDatabase(inMemory: true)
        let worktreeID = try await makeWorktree(db)
        try await db.worktrees.setAutoHibernateOnMerge(id: worktreeID, value: false)

        let config = try await db.config.get()
        #expect(!config.composerDraftEnabled)
        #expect(!config.composerDraftRequiredByAutoPark)
    }

    /// An archived worktree's override parks nothing — merge-park acts only
    /// on active worktrees, and a revive disarms the override — so it holds
    /// nothing either.
    @Test func anArchivedWorktreesOverrideHoldsNothing() async throws {
        let db = try TBDDatabase(inMemory: true)
        let worktreeID = try await makeWorktree(db)
        try await db.worktrees.setAutoHibernateOnMerge(id: worktreeID, value: true)
        #expect(try await db.config.get().composerDraftRequiredByAutoPark)

        try await db.worktrees.updateStatus(id: worktreeID, status: .archived)
        let config = try await db.config.get()
        #expect(!config.composerDraftEnabled)
        #expect(!config.composerDraftRequiredByAutoPark)
    }

    @Test func theConfigModelCarriesTheHoldAndDecodesWithoutIt() throws {
        var config = Config()
        config.composerDraftRequiredByAutoPark = true
        let decoded = try JSONDecoder().decode(Config.self, from: JSONEncoder().encode(config))
        #expect(decoded.composerDraftRequiredByAutoPark)

        let older = try JSONDecoder().decode(
            Config.self, from: Data(#"{"primaryAgentPreference":"claude"}"#.utf8))
        #expect(!older.composerDraftRequiredByAutoPark)
    }

    @Test func capabilitiesCarryTheEffectiveValueAndTheHold() async throws {
        let db = try TBDDatabase(inMemory: true)
        let router = makeRouter(db)
        try await db.config.setComposerDraftEnabled(false)
        try await db.config.setAutoHibernate(enabled: true, idleMinutes: 30)

        let caps = try await router.handle(RPCRequest(method: RPCMethod.daemonCapabilities))
            .decodeResult(DaemonCapabilitiesResult.self)
        #expect(caps.composerDraftEnabled)
        #expect(caps.composerDraftRequiredByAutoPark)

        let older = try JSONDecoder().decode(
            DaemonCapabilitiesResult.self,
            from: Data(#"{"controlModeEnabled":false,"controlModeSupported":false}"#.utf8))
        #expect(!older.composerDraftRequiredByAutoPark)
    }

    // MARK: - Plugin re-sync

    /// Turning automatic parking on re-syncs the plugin with the mod; the
    /// same write again changes no feature and re-syncs nothing; turning it
    /// off re-syncs the plugin without it.
    @Test(arguments: [Trigger.idleSweep, .mergeDefault, .worktreeOverride])
    func eachAutomaticParkingWriteResyncsThePluginWhenTheFeaturesChange(
        _ trigger: Trigger
    ) async throws {
        let db = try TBDDatabase(inMemory: true)
        let worktreeID = try await makeWorktree(db)
        let router = makeRouter(db)
        let recorder = AutoParkPluginSyncRecorder()
        router.sessionModPluginSync = { recorder.append($0) }

        try await send(trigger, true, to: router, worktreeID: worktreeID)
        #expect(recorder.snapshot() == [[.composerDraft]])
        try await send(trigger, true, to: router, worktreeID: worktreeID)
        #expect(recorder.snapshot() == [[.composerDraft]],
                "a write that changed no feature re-synced the plugin")
        try await send(trigger, false, to: router, worktreeID: worktreeID)
        #expect(recorder.snapshot() == [[.composerDraft], []])
    }

    /// With the stored flag already on, automatic parking changes no feature,
    /// so no write to it touches the plugin.
    @Test(arguments: [Trigger.idleSweep, .mergeDefault, .worktreeOverride])
    func anAutomaticParkingWriteLeavesThePluginAloneWhenNoFeatureChanges(
        _ trigger: Trigger
    ) async throws {
        let db = try TBDDatabase(inMemory: true)
        let worktreeID = try await makeWorktree(db)
        try await db.config.setComposerDraftEnabled(true)
        let router = makeRouter(db)
        let recorder = AutoParkPluginSyncRecorder()
        router.sessionModPluginSync = { recorder.append($0) }

        try await send(trigger, true, to: router, worktreeID: worktreeID)
        try await send(trigger, false, to: router, worktreeID: worktreeID)
        #expect(recorder.snapshot().isEmpty)
    }

    /// The other branch of the re-sync: with no plugin sync wired, as in mock
    /// mode, each write still lands and reports what changed.
    @Test(arguments: [Trigger.idleSweep, .mergeDefault, .worktreeOverride])
    func withNoPluginSyncWiredTheWriteStillLands(_ trigger: Trigger) async throws {
        let db = try TBDDatabase(inMemory: true)
        let worktreeID = try await makeWorktree(db)
        let router = makeRouter(db)

        try await send(trigger, true, to: router, worktreeID: worktreeID)
        #expect(try await db.config.get().composerDraftRequiredByAutoPark)
    }

    /// What the write helper reports, which decides whether a worktree
    /// override tells the app to reload: a change to the effective value or to
    /// the hold, and nothing else.
    @Test func theWriteHelperReportsWhetherWhatSettingsShowsChanged() async throws {
        let db = try TBDDatabase(inMemory: true)
        let worktreeID = try await makeWorktree(db)
        let router = makeRouter(db)

        let armed = try await router.writeAffectingAutomaticParking {
            try await db.worktrees.setAutoHibernateOnMerge(id: worktreeID, value: true)
        }
        #expect(armed, "arming the override changed nothing Settings shows")
        let again = try await router.writeAffectingAutomaticParking {
            try await db.worktrees.setAutoHibernateOnMerge(id: worktreeID, value: true)
        }
        #expect(!again, "the same write again reported a change")
        let cleared = try await router.writeAffectingAutomaticParking {
            try await db.worktrees.setAutoHibernateOnMerge(id: worktreeID, value: nil)
        }
        #expect(cleared, "clearing the override changed nothing Settings shows")
    }

    // MARK: - Updates

    /// An install that already runs the idle sweep and never touched the
    /// composer-draft flag needs no migration: the first daemon start after
    /// the update resolves the feature on, and the plugin written then carries
    /// the mod.
    @Test func anInstallWithTheIdleSweepOnWritesTheModAtItsFirstStart() async throws {
        let db = try TBDDatabase(inMemory: true)
        try await db.writerForTests.write { conn in
            try conn.execute(
                sql: "UPDATE config SET auto_hibernate_enabled = 1 WHERE id = ?",
                arguments: [ConfigStore.singletonID])
        }
        #expect(try await storedFlag(db) == nil)

        let features = await Daemon.startupSessionModFeatures(config: db.config)
        #expect(features.contains(.composerDraft))

        let root = NSTemporaryDirectory() + "tbd-autopark-plugin-\(UUID().uuidString)"
        defer { try? FileManager.default.removeItem(atPath: root) }
        let writer = PluginDirWriter(applicationSupportRoot: root)
        try writer.writePlugin(sessionModFeatures: features)
        #expect(FileManager.default.fileExists(
            atPath: writer.pluginDirPath() + "/hooks/hooks.json"),
            "the plugin written at startup does not carry the session mod")
        #expect(try await storedFlag(db) == nil, "the startup wrote composer_draft_enabled")
    }

    /// The other side: with automatic parking off and the flag never chosen,
    /// the startup plugin carries no mod.
    @Test func anInstallWithAutomaticParkingOffWritesNoModAtStartup() async throws {
        let db = try TBDDatabase(inMemory: true)
        let features = await Daemon.startupSessionModFeatures(config: db.config)
        #expect(!features.contains(.composerDraft))
    }
}
