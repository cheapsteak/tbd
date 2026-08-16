import Foundation
import TestSupport
import Testing
@testable import TBDDaemonLib
@testable import TBDShared

/// Shared fixture for the remote halves of `worktree.archive`,
/// `worktree.revive` and the auto-archive-on-merge rail
/// (`docs/specs/2026-08-16-remote-lane-archive-design.md`). Tier 2:
/// in-memory GRDB, dry-run tmux, a real actuation log in a temp directory,
/// and a scripted fake provider invoker — no subprocess, no network, no
/// `TBD_HOME`.
///
/// One fixture rather than three copies, because every one of these tests
/// asks the same two questions of the same wiring: which provider verbs ran,
/// and what landed in the record.
struct RemoteLaneFixture {
    let db: TBDDatabase
    let subscriptions: StateSubscriptionManager
    let manager: RemoteProviderManager
    let invoker: FakeProviderInvoker
    let logPath: String
    let repo: Repo
    private let dir: URL

    /// - Parameters:
    ///   - capabilities: what the provider's `describe` declares.
    ///   - verbs: canned results for the verb calls that follow `describe`,
    ///     in order. Empty means the test expects no verb to be invoked —
    ///     the invoker's script is then exhausted and any call trips its
    ///     `precondition`, which is a stronger statement than an assertion
    ///     after the fact.
    static func make(
        capabilities: [String], verbs: [ProviderResult] = [], tag: String
    ) async throws -> RemoteLaneFixture {
        let db = try TBDDatabase(inMemory: true)
        try await db.config.setRemoteBackendsEnabled(true)
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("tbd-\(tag)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let registryURL = dir.appendingPathComponent("agent-providers.json")
        try #"[{"name": "fake", "exec": "/nonexistent"}]"#
            .write(to: registryURL, atomically: true, encoding: .utf8)

        let caps = capabilities.map { "\"\($0)\"" }.joined(separator: ", ")
        let describe = providerOK(
            #"{"contract_versions": [1], "name": "fake", "capabilities": [\#(caps)]}"#)
        let invoker = FakeProviderInvoker(script: [describe] + verbs)
        let subscriptions = StateSubscriptionManager()
        let manager = RemoteProviderManager(
            db: db, subscriptions: subscriptions, runner: invoker, registryURL: registryURL)
        await manager.loadRegistryAndDescribe()

        let repo = try await db.repos.create(
            path: "/tmp/acme-\(UUID().uuidString)", displayName: "acme", defaultBranch: "main")
        return RemoteLaneFixture(
            db: db, subscriptions: subscriptions, manager: manager, invoker: invoker,
            logPath: dir.appendingPathComponent("actuations.jsonl").path,
            repo: repo, dir: dir)
    }

    func router() -> RPCRouter {
        let tmux = TmuxManager(dryRun: true)
        return RPCRouter(
            db: db,
            lifecycle: WorktreeLifecycle(
                db: db, git: GitManager(), tmux: tmux, hooks: HookResolver(),
                subscriptions: subscriptions),
            tmux: tmux,
            startTime: Date(),
            subscriptions: subscriptions,
            remoteManager: manager,
            actuationLog: ActuationLog(path: logPath))
    }

    func coordinator() -> AutoArchiveOnMergeCoordinator {
        AutoArchiveOnMergeCoordinator(
            db: db,
            lifecycle: WorktreeLifecycle(
                db: db, git: GitManager(), tmux: TmuxManager(dryRun: true),
                hooks: HookResolver(), subscriptions: subscriptions),
            subscriptions: subscriptions,
            actuationLog: ActuationLog(path: logPath),
            remoteManager: manager)
    }

    /// A remote worktree row plus the mirror row it is bound to, so the
    /// routing can read the provider's own report about the session.
    @discardableResult
    func seedLane(
        sessionID: String = "sess-1",
        name: String = "acme-remote",
        status: WorktreeStatus = .active,
        state: RemoteProcessState = .running,
        agentState: RemoteAgentState = .idle,
        meta: [String: String]? = nil,
        archived: Bool? = nil,
        gone: Bool = false
    ) async throws -> Worktree {
        let worktree = try await db.worktrees.createRemote(
            repoID: repo.id, name: name, branch: "acme-branch",
            provider: "fake", sessionID: sessionID, status: status)
        _ = try await db.remoteSessions.upsertOne(
            provider: "fake",
            session: RemoteSessionPayload(
                id: sessionID, state: state, agentState: agentState,
                meta: meta, archived: archived),
            now: Date())
        if gone {
            try await db.remoteSessions.markGone(provider: "fake", sessionID: sessionID)
        }
        return worktree
    }

    /// Every actuation row written so far, decoded.
    func actuationRows() throws -> [[String: Any]] {
        guard let contents = try? String(contentsOfFile: logPath, encoding: .utf8) else { return [] }
        return try contents
            .split(separator: "\n", omittingEmptySubsequences: true)
            .map { line in
                try #require(try JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any])
            }
    }

    func status(of worktree: Worktree) async throws -> WorktreeStatus? {
        try await db.worktrees.get(id: worktree.id)?.status
    }

    func cleanup() {
        try? FileManager.default.removeItem(at: dir)
    }
}
