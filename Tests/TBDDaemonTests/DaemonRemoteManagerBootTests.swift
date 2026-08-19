import Foundation
import Testing
@testable import TBDDaemonLib
@testable import TBDShared
import TestSupport

/// `Daemon.makeRemoteProviderManager` is the only production construction of
/// `RemoteProviderManager` (`Daemon.swift`'s boot block, Task 7). Before this
/// suite it was inline in `Daemon.start()` and reachable from no test — every
/// cloud test built the manager by hand instead, which is exactly how an
/// earlier draft of the delivery nearly shipped without `actuationLog:`
/// (dropping it silently disables `syncFilingDecisions` for every provider
/// behind one `.debug` log line, with the suite still green).
///
/// Tier 2: in-memory GRDB, a scripted `FakeProviderInvoker` standing in for
/// `subprocess`, no real `claude` binary, no `~/tbd` — every call below
/// passes an explicit `registryURL` in a temp directory rather than the
/// default `TBDConstants.agentProvidersPath`, which would otherwise read the
/// developer's real registry.
@Suite("Daemon.makeRemoteProviderManager")
struct DaemonRemoteManagerBootTests {
    private func tempRegistryURL(tag: String) -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("boot-registry-\(tag)-\(UUID().uuidString).json")
    }

    private func names(_ statuses: [RemoteProviderStatus]) -> Set<String> {
        Set(statuses.map { $0.config.name })
    }

    // MARK: - The three branches

    @Test func remoteBackendsDisabledReturnsNoManager() async throws {
        let db = try TBDDatabase(inMemory: true)
        // Nobody called setRemoteBackendsEnabled: NULL resolves through
        // Config.remoteBackendsEnabledDefault, which ships false.
        let outcome = await Daemon.makeRemoteProviderManager(
            database: db, subs: StateSubscriptionManager(), actuationLog: makeTestActuationLog(),
            registryURL: tempRegistryURL(tag: "off"))
        #expect(outcome.manager == nil)
        #expect(outcome.claudeCloudLive == false)
    }

    @Test func outerFlagOnCloudFlagOffReturnsAManagerWithNoCloudProvider() async throws {
        let db = try TBDDatabase(inMemory: true)
        try await db.config.setRemoteBackendsEnabled(true)
        let outcome = await Daemon.makeRemoteProviderManager(
            database: db, subs: StateSubscriptionManager(), actuationLog: makeTestActuationLog(),
            registryURL: tempRegistryURL(tag: "cloud-off"))
        let manager = try #require(outcome.manager, "the outer flag alone must still build a manager")
        #expect(outcome.claudeCloudLive == false)
        #expect(!names(await manager.providerStatuses()).contains(ClaudeCloudProvider.name))
    }

    @Test func bothFlagsOnAndTheResolverSucceedingRegistersCloud() async throws {
        let db = try TBDDatabase(inMemory: true)
        try await db.config.setRemoteBackendsEnabled(true)
        try await db.config.setClaudeCloud(true)
        let outcome = await Daemon.makeRemoteProviderManager(
            database: db, subs: StateSubscriptionManager(), actuationLog: makeTestActuationLog(),
            registryURL: tempRegistryURL(tag: "cloud-live"),
            resolveClaudeExecutable: { "/opt/acme/claude" })
        let manager = try #require(outcome.manager)
        #expect(outcome.claudeCloudLive == true)
        let statuses = await manager.providerStatuses()
        #expect(names(statuses).contains(ClaudeCloudProvider.name))
        #expect(statuses.first { $0.config.name == ClaudeCloudProvider.name }?.config.exec == "/opt/acme/claude")
    }

    @Test func bothFlagsOnAndTheResolverThrowingRegistersNoCloudButKeepsTheManager() async throws {
        struct NoClaudeOnThisBox: Error {}
        let db = try TBDDatabase(inMemory: true)
        try await db.config.setRemoteBackendsEnabled(true)
        try await db.config.setClaudeCloud(true)
        let outcome = await Daemon.makeRemoteProviderManager(
            database: db, subs: StateSubscriptionManager(), actuationLog: makeTestActuationLog(),
            registryURL: tempRegistryURL(tag: "cloud-unresolved"),
            resolveClaudeExecutable: { throw NoClaudeOnThisBox() })
        let manager = try #require(
            outcome.manager, "a resolver failure must not take down remote backends entirely")
        #expect(outcome.claudeCloudLive == false)
        #expect(!names(await manager.providerStatuses()).contains(ClaudeCloudProvider.name))
    }

    // MARK: - The `actuationLog:` regression this factory exists to prevent

    /// Proves `actuationLog` reaches the constructed manager by observing
    /// its one visible effect — `syncFilingDecisions` filing a row — rather
    /// than by introspecting a private property. Uses a registry-loaded
    /// provider declaring `archive`, not `claude-cloud`: `claude-cloud`'s own
    /// `describe` no longer declares `archive` (finding 3 of this round),
    /// so it can no longer drive this path.
    @Test func theConstructedManagerHasAWorkingFilingSync() async throws {
        let db = try TBDDatabase(inMemory: true)
        try await db.config.setRemoteBackendsEnabled(true)
        let registryURL = tempRegistryURL(tag: "filing-sync")
        try #"[{"name": "fake", "exec": "/nonexistent"}]"#
            .write(to: registryURL, atomically: true, encoding: .utf8)
        let describe = providerOK(#"{"contract_versions": [1], "name": "fake", "capabilities": ["archive"]}"#)
        let subprocess = FakeProviderInvoker(script: [describe])
        let actuationLog = makeTestActuationLog(tag: "boot-filing-sync")

        let outcome = await Daemon.makeRemoteProviderManager(
            database: db, subs: StateSubscriptionManager(), actuationLog: actuationLog,
            registryURL: registryURL, subprocess: subprocess)
        let manager = try #require(outcome.manager)
        await manager.loadRegistryAndDescribe()

        let repo = try await db.repos.create(
            path: "/tmp/acme-\(UUID().uuidString)", displayName: "acme", defaultBranch: "main")
        let worktree = try await db.worktrees.createRemote(
            repoID: repo.id, name: "acme-remote", branch: "acme-branch",
            provider: "fake", sessionID: "sess-1")

        try await manager.apply(
            snapshot: [RemoteSessionPayload(id: "sess-1", state: .running, agentState: .idle, archived: true)],
            provider: "fake")

        let after = try await db.worktrees.get(id: worktree.id)
        #expect(
            after?.status == .archived,
            "the filing sync did not run — actuationLog was not threaded through the production factory")
    }

    /// Discriminates the pin above: the identical scenario, but on a manager
    /// built with `actuationLog: nil` — what dropping the argument at the
    /// production call site would produce — leaves the row untouched. Without
    /// this, the test above could pass for a reason unrelated to
    /// `actuationLog` and nobody would notice.
    @Test func withoutAnActuationLogTheSameSnapshotLeavesTheRowUnarchived() async throws {
        let db = try TBDDatabase(inMemory: true)
        let registryURL = tempRegistryURL(tag: "filing-sync-regressed")
        try #"[{"name": "fake", "exec": "/nonexistent"}]"#
            .write(to: registryURL, atomically: true, encoding: .utf8)
        let describe = providerOK(#"{"contract_versions": [1], "name": "fake", "capabilities": ["archive"]}"#)
        let subprocess = FakeProviderInvoker(script: [describe])
        // Hand-built, bypassing the factory, with actuationLog OMITTED —
        // exactly the regression the factory's non-defaulted parameter now
        // makes impossible at the real call site.
        let manager = RemoteProviderManager(
            db: db, subscriptions: StateSubscriptionManager(),
            runner: ProviderDispatcher(subprocess: subprocess, builtIns: [:]),
            registryURL: registryURL)
        await manager.loadRegistryAndDescribe()

        let repo = try await db.repos.create(
            path: "/tmp/acme-\(UUID().uuidString)", displayName: "acme", defaultBranch: "main")
        let worktree = try await db.worktrees.createRemote(
            repoID: repo.id, name: "acme-remote", branch: "acme-branch",
            provider: "fake", sessionID: "sess-1")

        try await manager.apply(
            snapshot: [RemoteSessionPayload(id: "sess-1", state: .running, agentState: .idle, archived: true)],
            provider: "fake")

        let after = try await db.worktrees.get(id: worktree.id)
        #expect(after?.status == .active, "sanity: an absent actuationLog must skip the filing sync")
    }
}
