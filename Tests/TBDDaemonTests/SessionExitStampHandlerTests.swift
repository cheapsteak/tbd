import Foundation
import Testing
@testable import TBDDaemonLib
import TBDShared
import TestSupport

/// Thread-safe collector for broadcast StateDeltas, mirroring the pattern in
/// `SupervisionBrakeRPCTests` / `RPCRouterWorktreeCreateBroadcastTests`.
private final class BroadcastDeltas: @unchecked Sendable {
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

    /// Only the hibernation deltas, unwrapped — the SessionStart handler
    /// broadcasts session/activity deltas on the same channel.
    func hibernationDeltas() -> [TerminalHibernationDelta] {
        snapshot().compactMap {
            if case .terminalHibernationChanged(let d) = $0 { return d }
            return nil
        }
    }
}

/// The hook rail that makes "not running" a machine-readable fact.
///
/// Tier 2: an in-memory database and a dry-run tmux manager; no process is
/// spawned and no pane is consulted.
@Suite("SessionEnd exit stamp handlers")
struct SessionExitStampHandlerTests {

    private struct Fixture {
        let router: RPCRouter
        let db: TBDDatabase
        let terminal: Terminal
        let deltas: BroadcastDeltas
    }

    /// A throwaway actuation log per fixture. `ActuationLog` takes a PATH, not a
    /// database — the record is an append-only JSONL file. Rooted under the
    /// run's fenced scratch dir, which `scripts/test.sh` removes even when the
    /// test process is killed; a per-test `temporaryDirectory` would leak.
    private static func scratchLogPath() -> String {
        let directory = URL(
            fileURLWithPath: fencedScratchRoot(prefix: "tbd-exitstamp"), isDirectory: true)
        try? FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true)
        return directory.appendingPathComponent("actuations.jsonl").path
    }

    private func makeFixture() async throws -> Fixture {
        let db = try TBDDatabase(inMemory: true)
        let worktree = try await db.worktrees.createScratch(
            name: "wt", displayName: "wt",
            path: "/tmp/tbd-nonexistent-\(UUID().uuidString)", tmuxServer: "tbd-test")
        let terminal = try await db.terminals.create(
            worktreeID: worktree.id, tmuxWindowID: "@1", tmuxPaneID: "%1",
            label: "claude", claudeSessionID: "sess-1", kind: .claude)
        let tmux = TmuxManager(dryRun: true, dryRunPaneSendTarget: { _, _ in
            .live(terminalID: nil)
        })
        let deltas = BroadcastDeltas()
        let subscriptions = StateSubscriptionManager()
        subscriptions.addSubscriber { data in
            if let delta = try? JSONDecoder().decode(StateDelta.self, from: data) {
                deltas.append(delta)
            }
            return true
        }
        let router = RPCRouter(
            db: db,
            lifecycle: WorktreeLifecycle(
                db: db, git: GitManager(), tmux: tmux, hooks: HookResolver(),
                subscriptions: subscriptions),
            tmux: tmux,
            subscriptions: subscriptions,
            actuationLog: ActuationLog(path: Self.scratchLogPath()))
        return Fixture(router: router, db: db, terminal: terminal, deltas: deltas)
    }

    private func sessionEnded(_ f: Fixture, reason: String?) async throws {
        let data = try JSONEncoder().encode(TerminalSessionEndedParams(
            terminalID: f.terminal.id, reason: reason))
        _ = try await f.router.handleTerminalSessionEnded(data)
    }

    @Test func aLogoutStampsTheTerminalAsExited() async throws {
        let f = try await makeFixture()
        try await sessionEnded(f, reason: "logout")

        let row = try #require(try await f.db.terminals.get(id: f.terminal.id))
        #expect(row.isExitStamped)
        #expect(row.hibernateReason == .exited)
    }

    /// The discriminating negative. `/clear` ends one session inside a LIVE
    /// process; stamping there would refuse every later send to a healthy pane.
    @Test func aClearDoesNotStamp() async throws {
        let f = try await makeFixture()
        try await sessionEnded(f, reason: "clear")

        let row = try #require(try await f.db.terminals.get(id: f.terminal.id))
        #expect(row.hibernatedAt == nil)
        #expect(!row.isExitStamped)
    }

    /// An older `~/.local/bin/tbd` sends no reason at all. Not knowing must not
    /// park — the foreground-process rail still catches a real exit.
    @Test func anAbsentReasonDoesNotStamp() async throws {
        let f = try await makeFixture()
        try await sessionEnded(f, reason: nil)

        let row = try #require(try await f.db.terminals.get(id: f.terminal.id))
        #expect(row.hibernatedAt == nil)
    }

    @Test func sessionStartClearsTheExitStamp() async throws {
        let f = try await makeFixture()
        try await sessionEnded(f, reason: "logout")
        #expect(try #require(try await f.db.terminals.get(id: f.terminal.id)).isExitStamped)

        let data = try JSONEncoder().encode(TerminalSessionEventParams(
            terminalID: f.terminal.id,
            sessionID: "sess-2",
            transcriptPath: "/tmp/sess-2.jsonl",
            source: "startup",
            cwd: nil,
            sessionIncarnationID: nil))
        _ = try await f.router.handleTerminalSessionEvent(data)

        let row = try #require(try await f.db.terminals.get(id: f.terminal.id))
        #expect(row.hibernatedAt == nil)
        #expect(row.hibernateReason == nil)
    }

    /// The park must reach the app as a `.terminalHibernationChanged` delta, not
    /// only as a row the next `terminal.list` happens to refetch: the parked view
    /// materializes on the `isParked` flip and reads its snapshot once, and
    /// wake-on-focus filters on the CACHED `hibernateReason`. Every sibling
    /// writer of `hibernatedAt` publishes this delta; the stamp must too.
    @Test func theStampIsPublishedAsAHibernationDelta() async throws {
        let f = try await makeFixture()
        try await sessionEnded(f, reason: "logout")

        let published = try #require(f.deltas.hibernationDeltas().last)
        #expect(published.terminalID == f.terminal.id)
        #expect(published.worktreeID == f.terminal.worktreeID)
        #expect(published.hibernated)
        #expect(published.hibernateReason == .exited)
    }

    /// And the retraction, symmetrically — otherwise the app keeps showing a moon
    /// on a terminal whose session is demonstrably back.
    @Test func theClearIsPublishedAsAWakeDelta() async throws {
        let f = try await makeFixture()
        try await sessionEnded(f, reason: "logout")
        _ = try await f.router.handleTerminalSessionEvent(sessionStartPayload(f))

        let published = try #require(f.deltas.hibernationDeltas().last)
        #expect(published.terminalID == f.terminal.id)
        #expect(published.worktreeID == f.terminal.worktreeID)
        #expect(!published.hibernated)
        #expect(published.hibernateReason == nil)
    }

    private func sessionStartPayload(_ f: Fixture) throws -> Data {
        try JSONEncoder().encode(TerminalSessionEventParams(
            terminalID: f.terminal.id,
            sessionID: "sess-2",
            transcriptPath: "/tmp/sess-2.jsonl",
            source: "startup",
            cwd: nil,
            sessionIncarnationID: nil))
    }

    /// SessionStart must not un-park a session the OPERATOR parked. It fires on
    /// `/clear` inside a live process too, so a blanket clear would silently
    /// undo a deliberate hibernate.
    @Test func sessionStartLeavesADeliberateParkAlone() async throws {
        let f = try await makeFixture()
        try await f.db.terminals.setHibernated(
            id: f.terminal.id, sessionID: "sess-1", reason: .manual,
            at: Date(timeIntervalSince1970: 1_800_000_000))

        let data = try JSONEncoder().encode(TerminalSessionEventParams(
            terminalID: f.terminal.id,
            sessionID: "sess-2",
            transcriptPath: "/tmp/sess-2.jsonl",
            source: "startup",
            cwd: nil,
            sessionIncarnationID: nil))
        _ = try await f.router.handleTerminalSessionEvent(data)

        let row = try #require(try await f.db.terminals.get(id: f.terminal.id))
        #expect(row.hibernateReason == .manual)
        #expect(row.hibernatedAt != nil)
    }
}
