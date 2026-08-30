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

    func terminate() async { continuation.finish() }
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

/// TBD's own bookkeeping about the sessions it spawned. Empty: the roster's
/// admission rule is exercised in `RosterWatcherTests`, and what matters here
/// is which links it is asked to announce on.
private struct NoSpawnedSessions: LocalSessionDirectory {
    func spawnedSessions() async -> [TBDSpawnedSession] { [] }
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
        let link: FakePeerLink
        let directory: URL
    }

    private static func makeBridge(repos: Set<UUID>) throws -> BridgeHarness {
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
        let roster = PeerRosterRunner(roster: RosterWatcher(
            sessionsDirectory: directory,
            sessions: NoSpawnedSessions(),
            origin: "laptop",
            // Long enough that nothing ticks during a test; the initial refresh
            // `addLink` performs is what these assertions ride on.
            interval: .seconds(3600)))
        let bridge = PeerBridge(
            provider: "cloud",
            manager: manager,
            link: link,
            roster: roster,
            bridges: registry,
            repoScope: { repos })
        return BridgeHarness(
            bridge: bridge, manager: manager, registry: registry,
            roster: roster, link: link, directory: directory)
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
