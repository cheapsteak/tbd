import Foundation
import os
import Testing

@testable import TBDDaemonLib
@testable import TBDShared

// MARK: - Fakes

/// A bridge that constructs nothing. Every gate assertion below is about
/// whether one of these was *asked for* at all, because "nothing spawns,
/// nothing is published, no stream opens" is exactly the statement "no bridge
/// was built".
private actor CountingBridge: PeerBridging {
    nonisolated let provider: String
    private(set) var starts = 0
    private(set) var stops = 0

    init(provider: String) {
        self.provider = provider
    }

    func start() async { starts += 1 }
    func stop() async { stops += 1 }

    func status() async -> PeerProviderBridgeStatus {
        PeerProviderBridgeStatus(
            provider: provider, declaresMessages: true, bridged: true, linkState: "up")
    }

    func liveShadows() async -> [pid_t: PeerLiveShadow] { [:] }
}

/// Records every provider a bridge was requested for, so the gate is asserted
/// at its source rather than through a side effect.
private final class BridgeFactory: @unchecked Sendable {
    private struct State {
        var requested: [String] = []
        var bridges: [String: CountingBridge] = [:]
    }
    private let state = OSAllocatedUnfairLock(initialState: State())

    var requested: [String] { state.withLock { $0.requested } }

    func bridge(for provider: String) -> CountingBridge? {
        state.withLock { $0.bridges[provider] }
    }

    func wiring(enabled: Bool) -> PeerBridgeWiring {
        PeerBridgeWiring(
            isEnabled: { enabled },
            make: { [state] config, _ in
                state.withLock { inner -> (any PeerBridging)? in
                    inner.requested.append(config.name)
                    let bridge = CountingBridge(provider: config.name)
                    inner.bridges[config.name] = bridge
                    return bridge
                }
            })
    }
}

/// A stream that spawns nothing. The real supervisor's `start()` forks the
/// provider's `messages` child; this one records that it was asked to.
private actor FakePeerLink: PeerLinkDriving {
    private(set) var starts = 0
    private(set) var stops = 0
    private(set) var sent: [PeerBridgeFrame] = []
    private var state: PeerLinkState = .down

    func start() async {
        starts += 1
        state = .up
    }

    func stop() async {
        stops += 1
        state = .down
    }

    func linkState() async -> PeerLinkState { state }

    func send(_ frame: PeerBridgeFrame) async throws { sent.append(frame) }
}

/// A helper handle that is not a process. Enough to make the manager's publish
/// path complete so the reclaimer's inventory has something to see.
private final class StubHelper: ShadowPeerHelperHandle, @unchecked Sendable {
    let pid: pid_t
    let socketPath: String
    let recordPath: String
    let lines: AsyncStream<String>
    private let continuation: AsyncStream<String>.Continuation

    init(pid: pid_t, directory: URL) {
        self.pid = pid
        self.socketPath = directory.appendingPathComponent("\(pid).sock").path
        self.recordPath = directory.appendingPathComponent("\(pid).json").path
        let (stream, continuation) = AsyncStream.makeStream(of: String.self)
        self.lines = stream
        self.continuation = continuation
    }

    func send(_ frame: PeerBridgeFrame) async throws {}

    /// `.clean` because a stub has no artifacts to leave behind: it never
    /// bound a socket or published a record, so there is nothing for the
    /// reclaimer's row to name afterwards.
    func terminate() async -> ShadowPeerHelperTermination {
        continuation.finish()
        return .clean
    }
}

private actor StubSpawner: ShadowPeerHelperSpawning {
    private let directory: URL
    private var nextPID: pid_t = 7000

    init(directory: URL) { self.directory = directory }

    func spawn(
        _ invocation: ShadowPeerHelperInvocation
    ) async throws -> any ShadowPeerHelperHandle {
        nextPID += 1
        return StubHelper(pid: nextPID, directory: directory)
    }
}

private struct StubSiteResolver: ShadowPeerSiteResolving {
    let path: String

    func site(forProviderSessionID sessionID: String) async -> ShadowPeerSite? {
        ShadowPeerSite(worktreeDisplayName: "api-lane", path: path)
    }
}

private actor StubLocalDelivery: LocalPeerDelivering {
    func deliver(_ payload: Data, toSocketPath path: String) async throws {}
}

/// TBD's own bookkeeping about the sessions it spawned. Empty for the tests
/// about *which links* the roster is asked to announce on — the admission rule
/// itself is exercised in `RosterWatcherTests` — and populated for the two that
/// need a real session to follow all the way onto the wire.
private struct SpawnedSessions: LocalSessionDirectory {
    let sessions: [TBDSpawnedSession]

    init(_ sessions: [TBDSpawnedSession] = []) {
        self.sessions = sessions
    }

    func spawnedSessions() async -> [TBDSpawnedSession] { sessions }
}

/// The provider's repository scope, movable mid-test. The production closure
/// reads TBD's own rows, and what those rows say changes when a remote lane is
/// created or archived.
private actor MutableRepoScope {
    private var repos: Set<UUID>

    init(_ repos: Set<UUID>) { self.repos = repos }

    func current() -> Set<UUID> { repos }
    func set(_ repos: Set<UUID>) { self.repos = repos }
}

// MARK: - The gate

/// The two gates in front of the remote peer-messaging bridge, and the wiring
/// behind them.
///
/// Tier 1: no provider child is spawned (`FakeProviderInvoker` answers every
/// verb), no helper process exists, and every directory touched is under the
/// process temp directory — never `~/.claude`, never `~/tbd`.
@Suite("Peer bridge wiring")
struct PeerBridgeWiringTests {

    private static func scratchDirectory() throws -> URL {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("tbd-peer-bridge-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private static func describeJSON(capabilities: [String]) -> String {
        let list = capabilities.map { "\"\($0)\"" }.joined(separator: ",")
        return #"{"contract_versions": [1], "name": "fake", "capabilities": [\#(list)]}"#
    }

    private static func makeManager(
        capabilities: [String], wiring: PeerBridgeWiring?
    ) throws -> (RemoteProviderManager, URL) {
        let registry = FileManager.default.temporaryDirectory
            .appendingPathComponent("providers-\(UUID().uuidString).json")
        try Data(#"[{"name":"fake","exec":"/bin/true"}]"#.utf8).write(to: registry)
        let invoker = FakeProviderInvoker(script: [
            providerOK(describeJSON(capabilities: capabilities)),
            // In case the 60s poll's first tick fires before teardown.
            providerOK(#"{"sessions": []}"#),
        ])
        let manager = RemoteProviderManager(
            db: try TBDDatabase(inMemory: true),
            subscriptions: StateSubscriptionManager(),
            runner: invoker,
            registryURL: registry,
            peerBridging: wiring)
        return (manager, registry)
    }

    /// **Flag off is a structural refusal, not a quiet one.** A provider that
    /// declares the capability while `remote_peer_messaging_enabled` is off
    /// gets nothing built at all — so no helper is spawned, no record is
    /// published into the directory every session on this machine reads, and no
    /// `messages` stream is opened.
    @Test func theFlagBeingOffBuildsNothingEvenForACapableProvider() async throws {
        let factory = BridgeFactory()
        let (manager, registry) = try Self.makeManager(
            capabilities: ["messages"], wiring: factory.wiring(enabled: false))
        defer { try? FileManager.default.removeItem(at: registry) }

        await manager.start()

        #expect(await manager.hasPeerBridge(named: "fake") == false)
        #expect(factory.requested.isEmpty, "the flag is off; nothing may even be constructed")
        await manager.stopAll()
    }

    /// The other branch of the same conditional: flag on, capability declared,
    /// the whole path constructs and is started.
    @Test func theFlagBeingOnBridgesACapableProvider() async throws {
        let factory = BridgeFactory()
        let (manager, registry) = try Self.makeManager(
            capabilities: ["messages"], wiring: factory.wiring(enabled: true))
        defer { try? FileManager.default.removeItem(at: registry) }

        await manager.start()

        #expect(await manager.hasPeerBridge(named: "fake"))
        #expect(factory.requested == ["fake"])
        #expect(await factory.bridge(for: "fake")?.starts == 1)
        await manager.stopAll()
    }

    /// The capability gate, independent of the flag. An old shim declares
    /// nothing, so TBD opens no stream against a verb it cannot implement —
    /// and the diagnostic reports the absence rather than leaving an empty
    /// listing to be misread as "no remote sessions".
    @Test func aProviderThatDoesNotDeclareMessagesIsNotBridgedAndIsReported() async throws {
        let factory = BridgeFactory()
        let (manager, registry) = try Self.makeManager(
            capabilities: ["events"], wiring: factory.wiring(enabled: true))
        defer { try? FileManager.default.removeItem(at: registry) }

        await manager.start()

        #expect(await manager.hasPeerBridge(named: "fake") == false)
        #expect(factory.requested.isEmpty)

        let report = await manager.peerBridgeReport()
        let row = try #require(report.providers.first { $0.provider == "fake" })
        #expect(row.declaresMessages == false)
        #expect(row.bridged == false)
        await manager.stopAll()
    }

    /// A bridge owns helper processes, sockets and registry records, so a
    /// teardown that dropped the reference rather than awaiting `stop()` would
    /// leave listeners bound that nothing on the machine could close.
    @Test func tearingDownTheManagerStopsTheBridge() async throws {
        let factory = BridgeFactory()
        let (manager, registry) = try Self.makeManager(
            capabilities: ["messages"], wiring: factory.wiring(enabled: true))
        defer { try? FileManager.default.removeItem(at: registry) }

        await manager.start()
        await manager.stopAll()

        #expect(await manager.hasPeerBridge(named: "fake") == false)
        #expect(await factory.bridge(for: "fake")?.stops == 1)
    }

    // MARK: - What the bridge wires up

    private struct BridgeHarness {
        let bridge: PeerBridge
        let manager: ShadowPeerManager
        let registry: ShadowPeerBridgeRegistry
        let roster: PeerRosterRunner
        /// The watcher inside `roster`, so a test can drive a scan itself
        /// rather than waiting on a tick that is deliberately an hour away.
        let watcher: RosterWatcher
        let scope: MutableRepoScope
        let link: FakePeerLink
        let directory: URL
    }

    private static func makeBridge(
        repos: Set<UUID>,
        spawned: [TBDSpawnedSession] = [],
        livePIDs: [pid_t: String] = [:]
    ) throws -> BridgeHarness {
        let directory = try scratchDirectory()
        let link = FakePeerLink()
        let manager = ShadowPeerManager(
            provider: "cloud",
            link: link,
            siteResolver: StubSiteResolver(path: directory.path),
            spawner: StubSpawner(directory: directory),
            delivery: StubLocalDelivery(),
            socketDirectory: directory,
            sessionsDirectory: directory)
        let registry = ShadowPeerBridgeRegistry()
        let watcher = RosterWatcher(
            sessionsDirectory: directory,
            sessions: SpawnedSessions(spawned),
            origin: "laptop",
            // Long enough that nothing ticks during a test; the initial refresh
            // `addLink` performs is what these assertions ride on.
            interval: .seconds(3600),
            // Liveness is injected, so nothing here reads a real process table.
            procStartForPID: { livePIDs[$0] })
        let roster = PeerRosterRunner(roster: watcher)
        let scope = MutableRepoScope(repos)
        let bridge = PeerBridge(
            provider: "cloud",
            manager: manager,
            link: link,
            roster: roster,
            bridges: registry,
            repoScope: { await scope.current() })
        return BridgeHarness(
            bridge: bridge, manager: manager, registry: registry,
            roster: roster, watcher: watcher, scope: scope,
            link: link, directory: directory)
    }

    /// The instant the fixture session started, and the two renderings of it.
    /// The record carries the literal; the injected kernel lookup answers with
    /// the production formatter's output, so the comparison the roster makes is
    /// between two independently produced values rather than one with itself.
    private static let liveStartedAt = Date(timeIntervalSince1970: 1_788_041_277)
    private static let recordedProcStart = "Sat Aug 29 22:07:57 2026"
    private static var liveProcStart: String {
        ProcessStartTime.format(liveStartedAt) ?? "unrenderable"
    }
    private static let fixtureSocketPath = "/tmp/cc-socks/4242.sock"
    private static let fixtureSessionID = "4E12DD65-92B8-4D8E-9920-214C6553FC63"

    /// One local session TBD spawned, and the registry record describing it —
    /// the two halves the roster's admission rule joins.
    private static func localSession(repoID: UUID) -> TBDSpawnedSession {
        TBDSpawnedSession(
            worktreeID: UUID(),
            repoID: repoID,
            terminalID: UUID(),
            displayName: "useful-swallow",
            worktreePath: "/tmp/tbd-peer-bridge-fixture/useful-swallow",
            tmuxPaneID: "%3541",
            claudeSessionID: fixtureSessionID)
    }

    private static func writeRegistryRecord(in directory: URL) throws {
        let fields: [String: Any] = [
            "sessionId": fixtureSessionID,
            "cwd": "/tmp/tbd-peer-bridge-fixture/useful-swallow",
            "messagingSocketPath": fixtureSocketPath,
            // The link negotiates this side's protocol, and a session speaking
            // another one is deliberately not announced — so the fixture has to
            // read it from the codec rather than hardcode a number.
            "peerProtocol": PeerBridgeFrameCodec.peerProtocol,
            "status": "busy",
            "tmux": "main:@3541.%3541",
            "procStart": recordedProcStart,
        ]
        let data = try JSONSerialization.data(withJSONObject: fields, options: [.sortedKeys])
        try data.write(to: directory.appendingPathComponent("4242.json"))
    }

    private static func announcedHandles(_ frames: [PeerBridgeFrame]) -> [String] {
        frames.compactMap { frame -> String? in
            guard case .peer(let peer) = frame else { return nil }
            return peer.handle
        }
    }

    private static func goneHandles(_ frames: [PeerBridgeFrame]) -> [String] {
        frames.compactMap { frame -> String? in
            guard case .peerGone(let handle) = frame else { return nil }
            return handle
        }
    }

    /// **This is what completes the reclaim path.** Until a bridge registers,
    /// `ShadowPeerReconciler` has nothing to vouch for a live shadow with, so
    /// it counts every row as unvouched-for and reclaims nothing.
    @Test func aPublishedShadowAppearsInTheReclaimersInventory() async throws {
        let harness = try Self.makeBridge(repos: [])
        defer { try? FileManager.default.removeItem(at: harness.directory) }

        // Nothing vouches for this provider before the bridge starts, which is
        // a different fact from an empty inventory: the first says the sweep
        // must leave the rows alone, the second licenses reclaiming them.
        #expect(await harness.registry.bridgedShadows().isEmpty)

        await harness.bridge.start()
        await harness.manager.handle(.peer(PeerBridgePeer(
            handle: "remote-1", name: "ignored", status: "idle",
            peerProtocol: PeerBridgeFrameCodec.peerProtocol, sessionID: "sess-42")))

        let inventories = await harness.registry.bridgedShadows()
        let cloud = try #require(inventories.first { $0.provider == "cloud" })
        let publishedPID = try #require(await harness.manager.artifacts().first?.pid)
        #expect(cloud.pidsByHandle == ["remote-1": publishedPID])

        await harness.bridge.stop()
        // Deregistering is what makes the rows reclaimable again, and it is the
        // half a teardown that only stopped the stream would miss.
        #expect(await harness.registry.bridgedShadows().isEmpty)
    }

    /// The outward scoping rule: TBD's own sessions are announced to a provider
    /// only for the repositories that provider actually hosts sessions in.
    @Test func theRosterIsAnnouncedOnlyForTheProvidersRepositories() async throws {
        let repoA = UUID()
        let harness = try Self.makeBridge(repos: [repoA])
        defer { try? FileManager.default.removeItem(at: harness.directory) }

        await harness.bridge.start()

        #expect(await harness.bridge.announcedRepoIDsForTests() == [repoA])
        // The shared roster ticks only while a bridge needs it.
        #expect(await harness.roster.isTicking())

        await harness.bridge.stop()
        #expect(await harness.bridge.announcedRepoIDsForTests().isEmpty)
        #expect(await harness.roster.isTicking() == false)
    }

    /// The stream is opened by starting the bridge and closed by stopping it —
    /// the "no stream opens" half of the flag-off assertion, stated positively
    /// so the negative one above is not vacuous.
    @Test func startingTheBridgeOpensTheStreamAndStoppingItClosesIt() async throws {
        let harness = try Self.makeBridge(repos: [])
        defer { try? FileManager.default.removeItem(at: harness.directory) }

        #expect(await harness.link.starts == 0)
        await harness.bridge.start()
        #expect(await harness.link.starts == 1)
        await harness.bridge.stop()
        #expect(await harness.link.stops == 1)
    }

    // MARK: - Reconnects and scope changes

    /// **A reconnect must not leave the far side holding a handle nothing can
    /// resolve.**
    ///
    /// The manager empties both halves of its handle table on `.down`. Nothing
    /// used to clear what the roster remembered telling the link, so the next
    /// scan minted a fresh handle and announced it while the stale one beside
    /// it was announced gone — taking the freshly bound socket with it. The far
    /// side then held a handle absent from `localPeers`, so every inbound frame
    /// dropped as an unknown handle and every reply had no sender to resolve,
    /// on a link reporting `up` throughout. And it repeated every tick.
    ///
    /// No test drove a transition before this one, which is why it shipped.
    @Test func aReconnectReAnnouncesTheRosterWithoutChurningItsHandles() async throws {
        let repo = UUID()
        let harness = try Self.makeBridge(
            repos: [repo],
            spawned: [Self.localSession(repoID: repo)],
            livePIDs: [4242: Self.liveProcStart])
        defer { try? FileManager.default.removeItem(at: harness.directory) }
        try Self.writeRegistryRecord(in: harness.directory)

        await harness.bridge.start()
        let first = try #require(Self.announcedHandles(await harness.link.sent).last)
        #expect(await harness.manager.snapshot().localHandles == [first])

        // The stream dropped and came back, in the order the supervisor
        // publishes it: the manager first, then the observer `make` binds.
        await harness.manager.linkStateChanged(to: .down)
        await harness.bridge.linkStateChanged(to: .down)
        await harness.manager.linkStateChanged(to: .up)
        await harness.bridge.linkStateChanged(to: .up)

        await harness.watcher.refresh()
        let afterReconnect = try #require(Self.announcedHandles(await harness.link.sent).last)
        // The fresh connection is told about the session again — the far side
        // unlinked every shadow when the stream ended — and the handle it was
        // told still resolves in the table that minted it.
        #expect(afterReconnect != first)
        #expect(await harness.manager.snapshot().localHandles == [afterReconnect])

        // And it settles: further scans announce nothing, mint nothing, and
        // withdraw nothing. Before the fix this grew by a `peer` and a
        // `peer-gone` on every single scan, forever.
        let quiescent = await harness.link.sent.count
        await harness.watcher.refresh()
        await harness.watcher.refresh()
        #expect(await harness.link.sent.count == quiescent)
        #expect(await harness.manager.snapshot().localHandles == [afterReconnect])

        await harness.bridge.stop()
    }

    /// **Retiring a repository's scope has to unreach its sessions.**
    ///
    /// A provider hosting lanes in two repositories loses one when its last
    /// lane there is archived. The registration was dropped in silence, so the
    /// far host kept its shadows for that repository's local sessions and their
    /// handles kept resolving — a remote session with no lane in the project
    /// could still message into it, which the design's Trust section forbids.
    /// It was invisible too: `applyInventory` diffs against `localPeers`, which
    /// still held the handles, so not even the divergence warning fired.
    @Test func retiringARepositoryScopeWithdrawsAndAnnouncesItsSessionsGone() async throws {
        let repo = UUID()
        let harness = try Self.makeBridge(
            repos: [repo],
            spawned: [Self.localSession(repoID: repo)],
            livePIDs: [4242: Self.liveProcStart])
        defer { try? FileManager.default.removeItem(at: harness.directory) }
        try Self.writeRegistryRecord(in: harness.directory)

        await harness.bridge.start()
        let handle = try #require(Self.announcedHandles(await harness.link.sent).last)
        #expect(await harness.manager.snapshot().localHandles == [handle])

        // The lane in that repository is archived, so the repository leaves the
        // provider's scope. The stream stays open throughout.
        await harness.scope.set([])
        await harness.bridge.reconcileRepoScope()

        #expect(await harness.bridge.announcedRepoIDsForTests().isEmpty)
        #expect(Self.goneHandles(await harness.link.sent) == [handle])
        #expect(await harness.manager.snapshot().localHandles.isEmpty)
        #expect(await harness.link.linkState() == .up, "the stream is what stayed open")

        await harness.bridge.stop()
    }

    // MARK: - The origin label

    /// The origin is the namespace every name TBD announces outward is prefixed
    /// with, and the composed name is `<origin>:<display name> %<pane>` — so a
    /// colon or a space inside it would make that name ambiguous to read.
    @Test func theOriginLabelIsSanitisedAndStable() {
        #expect(PeerLinkOrigin.local(hostName: "workbench.local") == "workbench")
        #expect(PeerLinkOrigin.local(hostName: "my box:2") == "my-box-2")
        #expect(PeerLinkOrigin.local(hostName: "") == PeerLinkOrigin.unknownHost)
        #expect(PeerLinkOrigin.local(hostName: "...") == PeerLinkOrigin.unknownHost)
    }
}

// MARK: - The repo-scope resolver

/// A worktree read that can be made to fail on demand.
///
/// The whole point of `ProviderRepoScope` is what it does when this throws, so
/// the failure has to be injectable — a real database would have to be broken
/// to reach that branch, and a broken one is not a transient one.
private final class StubWorktreeReads: @unchecked Sendable {
    struct ReadFailure: Error, Sendable {}

    private struct State {
        var next: Result<[Worktree], ReadFailure>
        var reads = 0
    }

    private let state: OSAllocatedUnfairLock<State>

    init(_ next: Result<[Worktree], ReadFailure>) {
        state = OSAllocatedUnfairLock(initialState: State(next: next))
    }

    var reads: Int { state.withLock { $0.reads } }

    func succeed(_ rows: [Worktree]) {
        state.withLock { $0.next = .success(rows) }
    }

    func fail() {
        state.withLock { $0.next = .failure(ReadFailure()) }
    }

    func read() throws -> [Worktree] {
        try state.withLock { inner in
            inner.reads += 1
            return try inner.next.get()
        }
    }
}

/// The scope resolver behind `Daemon.makePeerBridging`'s `repoScope` closure.
///
/// The bug these pin is a conflation: `(try? await …) ?? []` spelled "the read
/// failed" and "this provider hosts no repositories" with the same value, and
/// the two mean opposite things now that dropping a repository from the scope
/// withdraws its roster registration and writes `peer-gone` for every session
/// announced on it. Every test name below therefore says *which* nothing it is
/// about.
///
/// Tier 1: no database, no filesystem, no process.
@Suite("Provider repo scope")
struct ProviderRepoScopeTests {

    private static func lane(
        repoID: UUID?, provider: String?, name: String = "useful-swallow"
    ) -> Worktree {
        let location: WorktreeLocation
        if let provider {
            location = .remote(provider: provider, sessionID: UUID().uuidString)
        } else {
            location = .local
        }
        return Worktree(
            repoID: repoID,
            name: name,
            displayName: name,
            branch: "tbd/\(name)",
            path: location.storagePath ?? "/tmp/tbd-scope-fixture/\(name)",
            tmuxServer: "tbd-scope-fixture",
            location: location)
    }

    private static func resolver(
        _ reads: StubWorktreeReads, provider: String = "cloud"
    ) -> ProviderRepoScope {
        ProviderRepoScope(provider: provider, listWorktrees: { try reads.read() })
    }

    // MARK: A read that works

    @Test func aSuccessfulReadResolvesToThisProvidersRepositories() async {
        let mine = UUID()
        let theirs = UUID()
        let reads = StubWorktreeReads(.success([
            Self.lane(repoID: mine, provider: "cloud"),
            // Another provider's lane, a purely local worktree, and a scratch
            // space with no repo at all: none of them widen this scope.
            Self.lane(repoID: theirs, provider: "other"),
            Self.lane(repoID: theirs, provider: nil),
            Self.lane(repoID: nil, provider: "cloud"),
        ]))
        let scope = Self.resolver(reads)
        let expected: Set<UUID> = [mine]

        #expect(await scope.resolve() == expected)
        #expect(await scope.failedReads == 0)
    }

    /// The other half of the conflation, and the one that keeps the fix honest:
    /// a provider that genuinely hosts nothing must still resolve to a real,
    /// empty scope — `Set()`, not "no scope" — because that answer is what
    /// legitimately retires a registration.
    @Test func aSuccessfulReadFindingNoLanesResolvesToAnEmptyScopeNotToNoScope() async {
        let reads = StubWorktreeReads(.success([Self.lane(repoID: UUID(), provider: "other")]))
        let scope = Self.resolver(reads)

        let resolved = await scope.resolve()
        #expect(resolved != nil, "a read that succeeded always yields a scope")
        #expect(resolved?.isEmpty == true)
    }

    // MARK: A read that fails after one that worked

    /// The regression itself. One transient database error on a 30-second tick
    /// used to resolve to `[]`, and an empty scope unannounces every repository
    /// in it.
    @Test func aFailedReadAfterASuccessfulOneKeepsThePreviousScopeRatherThanEmptyingIt() async {
        let mine = UUID()
        let reads = StubWorktreeReads(.success([Self.lane(repoID: mine, provider: "cloud")]))
        let scope = Self.resolver(reads)
        let expected: Set<UUID> = [mine]
        #expect(await scope.resolve() == expected)

        reads.fail()
        #expect(await scope.resolve() == expected, "the last known good scope, not an empty one")
        #expect(await scope.resolve() == expected, "and it survives a run of failures")

        #expect(await scope.failedReads == 2)
        #expect(await scope.consecutiveFailures == 2)
        #expect(reads.reads == 3, "every resolve really did attempt a read")
    }

    @Test func aSuccessfulReadAfterAFailureReplacesTheStaleScopeAndClearsTheRun() async {
        let first = UUID()
        let second = UUID()
        let reads = StubWorktreeReads(.success([Self.lane(repoID: first, provider: "cloud")]))
        let scope = Self.resolver(reads)
        let firstScope: Set<UUID> = [first]
        let secondScope: Set<UUID> = [second]
        #expect(await scope.resolve() == firstScope)

        reads.fail()
        #expect(await scope.resolve() == firstScope)

        reads.succeed([Self.lane(repoID: second, provider: "cloud")])
        #expect(await scope.resolve() == secondScope, "stale state is replaced, never merged")
        #expect(await scope.consecutiveFailures == 0)
        #expect(await scope.failedReads == 1, "the lifetime count still remembers the flicker")
    }

    /// A retirement that a read genuinely observed must still happen — the
    /// guard holds the last *good* answer, not the widest one ever seen.
    @Test func aSuccessfulReadThatLostARepositoryStillNarrowsTheScope() async {
        let kept = UUID()
        let dropped = UUID()
        let reads = StubWorktreeReads(.success([
            Self.lane(repoID: kept, provider: "cloud"),
            Self.lane(repoID: dropped, provider: "cloud", name: "brisk-otter"),
        ]))
        let scope = Self.resolver(reads)
        let both: Set<UUID> = [kept, dropped]
        let narrowed: Set<UUID> = [kept]
        #expect(await scope.resolve() == both)

        reads.succeed([Self.lane(repoID: kept, provider: "cloud")])
        #expect(await scope.resolve() == narrowed)
    }

    // MARK: A read that fails before any has ever worked

    /// The second "nothing", and a different one: nothing has been announced
    /// yet, so there is no scope to reconcile toward — which is not the same
    /// claim as "the scope is empty". The wiring collapses this to `[]` at the
    /// one call site where that is provably harmless.
    @Test func aFailedFirstReadYieldsNoScopeRatherThanAnEmptyScope() async {
        let reads = StubWorktreeReads(.failure(StubWorktreeReads.ReadFailure()))
        let scope = Self.resolver(reads)

        #expect(await scope.resolve() == nil)
        #expect(await scope.resolve() == nil, "still nothing known after a second failure")
        #expect(await scope.failedReads == 2)
    }

    @Test func aFirstSuccessAfterFailedReadsEndsTheNoScopeState() async {
        let mine = UUID()
        let reads = StubWorktreeReads(.failure(StubWorktreeReads.ReadFailure()))
        let scope = Self.resolver(reads)
        let expected: Set<UUID> = [mine]
        #expect(await scope.resolve() == nil)

        reads.succeed([Self.lane(repoID: mine, provider: "cloud")])
        #expect(await scope.resolve() == expected)

        reads.fail()
        #expect(await scope.resolve() == expected, "and from here a failure is never nil again")
    }
}
