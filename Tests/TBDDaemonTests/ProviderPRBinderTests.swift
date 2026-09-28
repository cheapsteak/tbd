import Foundation
import Testing
import TestSupport
@testable import TBDDaemonLib
@testable import TBDShared

/// Provider-named PRs (`meta.prs`) bind to the session's row as `.provider`
/// (`docs/specs/2026-09-26-remote-session-status-bar-design.md`).
///
/// Tier 1: the binder's rules through its closure seams — no DB, no `gh`.
@Suite("Provider-named PR binding")
struct ProviderPRBinderTests {
    private struct Call: Sendable {
        let worktreeID: UUID
        let parsed: ParsedPRURL
    }

    private actor Recorder {
        var calls: [Call] = []
        var lookups = 0
        func record(_ id: UUID, _ parsed: ParsedPRURL) { calls.append(Call(worktreeID: id, parsed: parsed)) }
        func recordLookup() { lookups += 1 }
    }

    private static func remoteRow(_ sessionID: String) -> Worktree {
        Worktree(repoID: UUID(), name: "r", displayName: "r", branch: "main",
                 path: WorktreeLocation.remote(provider: "fake", sessionID: sessionID).storagePath ?? "",
                 tmuxServer: "", location: .remote(provider: "fake", sessionID: sessionID))
    }

    private static func session(_ id: String, prs: String?) -> RemoteSessionPayload {
        var meta = ["repo": "acme/api"]
        if let prs { meta["prs"] = prs }
        return RemoteSessionPayload(id: id, state: .running, meta: meta)
    }

    private func binder(rows: [String: Worktree], recorder: Recorder) -> ProviderPRBinder {
        ProviderPRBinder(
            findRow: { _, sessionID in
                await recorder.recordLookup()
                return rows[sessionID]
            },
            bind: { id, parsed in
                await recorder.record(id, parsed)
                return .alreadyBound
            })
    }

    @Test("each parsed URL is bound to the session's row, in order")
    func bindsEachURL() async {
        let row = Self.remoteRow("a")
        let rec = Recorder()
        await binder(rows: ["a": row], recorder: rec).bindNamedPRs(
            sessions: [Self.session("a", prs: "https://github.com/acme/api/pull/1 https://github.com/acme/web/pull/2")],
            provider: "fake")
        let calls = await rec.calls
        #expect(calls.map { $0.worktreeID } == [row.id, row.id])
        #expect(calls.map { $0.parsed.number } == [1, 2])
        #expect(calls.map { $0.parsed.repo } == ["api", "web"])
    }

    @Test("a GitHub Enterprise URL is bound with its own host")
    func bindsEnterpriseURL() async {
        let rec = Recorder()
        await binder(rows: ["a": Self.remoteRow("a")], recorder: rec).bindNamedPRs(
            sessions: [Self.session("a", prs: "https://ghe.acme.example/acme/api/pull/3")],
            provider: "fake")
        #expect(await rec.calls.map { $0.parsed.host } == ["ghe.acme.example"])
    }

    @Test("a session with no row gets no bindings")
    func unadoptedSessionBindsNothing() async {
        let rec = Recorder()
        await binder(rows: [:], recorder: rec).bindNamedPRs(
            sessions: [Self.session("a", prs: "https://github.com/acme/api/pull/1")], provider: "fake")
        #expect(await rec.calls.isEmpty)
    }

    /// A landed lane is `.local` but keeps its origin, so `findRemote` still
    /// returns it. It is a local worktree now and gets no provider bindings.
    @Test("a landed lane gets no provider bindings")
    func landedLaneBindsNothing() async {
        var landed = Worktree(repoID: UUID(), name: "l", displayName: "l", branch: "b",
                              path: "/tmp/landed", tmuxServer: "t")
        landed.origin = WorktreeOrigin(provider: "fake", sessionID: "a")
        let rec = Recorder()
        await binder(rows: ["a": landed], recorder: rec).bindNamedPRs(
            sessions: [Self.session("a", prs: "https://github.com/acme/api/pull/1")], provider: "fake")
        #expect(await rec.calls.isEmpty)
    }

    @Test("at most 20 URLs per session are bound")
    func capsAtTwenty() async {
        let rec = Recorder()
        let urls = (1...25).map { "https://github.com/acme/api/pull/\($0)" }.joined(separator: " ")
        await binder(rows: ["a": Self.remoteRow("a")], recorder: rec).bindNamedPRs(
            sessions: [Self.session("a", prs: urls)], provider: "fake")
        #expect(await rec.calls.map { $0.parsed.number } == Array(1...20))
    }

    @Test("no prs key: no lookup and no bind")
    func absentKeyDoesNothing() async {
        let rec = Recorder()
        await binder(rows: ["a": Self.remoteRow("a")], recorder: rec).bindNamedPRs(
            sessions: [Self.session("a", prs: nil)], provider: "fake")
        #expect(await rec.calls.isEmpty)
        #expect(await rec.lookups == 0)
    }

    @Test("unparseable entries are skipped without affecting the others")
    func rejectedEntriesAreSkipped() async {
        let rec = Recorder()
        await binder(rows: ["a": Self.remoteRow("a")], recorder: rec).bindNamedPRs(
            sessions: [Self.session("a", prs: "not-a-url https://github.com/acme/api/pull/4 http://github.com/acme/api/pull/5")],
            provider: "fake")
        #expect(await rec.calls.map { $0.parsed.number } == [4])
    }
}

/// The binder wired through the real manager, store and coordinator: the
/// snapshot and events paths both bind, and a binding outlives the list that
/// named it.
///
/// Tier 1: in-memory GRDB and a fake provider invoker that is never asked
/// anything (`apply`/`applyUpsert` do not invoke the provider).
@Suite("Provider-named PR binding through the manager", .fastPassBounded)
struct ProviderPRBinderManagerTests {
    let db: TBDDatabase
    let subs: StateSubscriptionManager
    let registryURL: URL
    let repo: Repo

    init() async throws {
        db = try TBDDatabase(inMemory: true)
        subs = StateSubscriptionManager()
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("provider-pr-binder-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        registryURL = dir.appendingPathComponent("agent-providers.json")
        try "[]".write(to: registryURL, atomically: true, encoding: .utf8)
        repo = try await db.repos.create(
            path: "/tmp/provider-pr-binder-\(UUID().uuidString)", displayName: "api",
            defaultBranch: "main", remoteURL: "https://github.com/acme/api")
    }

    private func manager() async -> (RemoteProviderManager, PRBindingCoordinator) {
        let coordinator = PRBindingCoordinator(
            store: db.prBindings, resolveRepo: { _ in ("acme", "api", "github.com") },
            isGitLabHost: { _, _ in false })
        let m = RemoteProviderManager(
            db: db, subscriptions: subs,
            runner: FakeProviderInvoker(script: []), registryURL: registryURL)
        await m.setProviderPRBinder(ProviderPRBinder(db: db, coordinator: coordinator))
        return (m, coordinator)
    }

    private func session(_ id: String, meta extra: [String: String]) -> RemoteSessionPayload {
        var meta = ["repo": "acme/api"]
        meta.merge(extra) { _, new in new }
        return RemoteSessionPayload(id: id, state: .running, agentState: .working, meta: meta)
    }

    private func liveNumbers(_ worktreeID: UUID) async throws -> [Int] {
        try await db.prBindings.list(worktreeID: worktreeID).map(\.number)
    }

    @Test("a snapshot binds named PRs as provider, and they outlive the list and the branch")
    func snapshotBindsAndKeeps() async throws {
        let (m, _) = await manager()
        try await m.apply(
            snapshot: [session("a", meta: ["prs": "https://github.com/acme/api/pull/7", "branch": "claude/x"])],
            provider: "fake")
        let row = try #require(try await db.worktrees.findRemote(provider: "fake", sessionID: "a"))
        let bound = try await db.prBindings.list(worktreeID: row.id)
        #expect(bound.map(\.number) == [7])
        #expect(bound.first?.source == .provider)

        // The list is a pointer, never an unbind: dropping the URL changes nothing.
        try await m.apply(snapshot: [session("a", meta: ["prs": "", "branch": "claude/x"])], provider: "fake")
        #expect(try await liveNumbers(row.id) == [7])

        // Nor does the live branch moving.
        try await m.apply(snapshot: [session("a", meta: ["branch": "claude/y"])], provider: "fake")
        #expect(try await liveNumbers(row.id) == [7])
    }

    @Test("a detached provider PR is not revived by the next snapshot naming it")
    func detachIsDurable() async throws {
        let (m, coordinator) = await manager()
        let named = session("a", meta: ["prs": "https://github.com/acme/api/pull/7"])
        try await m.apply(snapshot: [named], provider: "fake")
        let row = try #require(try await db.worktrees.findRemote(provider: "fake", sessionID: "a"))
        #expect(try await liveNumbers(row.id) == [7])

        let parsed = ParsedPRURL(host: "github.com", owner: "acme", repo: "api", number: 7,
                                 url: "https://github.com/acme/api/pull/7")
        #expect(try await coordinator.detach(worktreeID: row.id, parsed: parsed))
        try await m.apply(snapshot: [named], provider: "fake")
        #expect(try await liveNumbers(row.id).isEmpty)
    }

    @Test("the events path binds too")
    func upsertBinds() async throws {
        let (m, _) = await manager()
        await m.applyUpsert(session("b", meta: ["prs": "https://github.com/acme/api/pull/8"]), provider: "fake")
        let row = try #require(try await db.worktrees.findRemote(provider: "fake", sessionID: "b"))
        #expect(try await liveNumbers(row.id) == [8])
    }

    @Test("without a binder installed, naming PRs binds nothing")
    func noBinderNoBindings() async throws {
        let m = RemoteProviderManager(
            db: db, subscriptions: subs,
            runner: FakeProviderInvoker(script: []), registryURL: registryURL)
        try await m.apply(
            snapshot: [session("c", meta: ["prs": "https://github.com/acme/api/pull/9"])], provider: "fake")
        let row = try #require(try await db.worktrees.findRemote(provider: "fake", sessionID: "c"))
        #expect(try await liveNumbers(row.id).isEmpty)
    }
}
