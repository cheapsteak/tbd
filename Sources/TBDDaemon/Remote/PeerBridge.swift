import Foundation
import os
import TBDShared

private let bridgeLogger = Logger(subsystem: "com.tbd.daemon", category: "shadowPeer")

// MARK: - The stream half, narrowed

/// The peer-link stream as a bridge drives it: send frames, start, stop, and
/// answer what state it is in.
///
/// `PeerLinkSupervisor` is the only production conformer. The protocol exists
/// so a test can wire a whole bridge — its roster links, its reclaimer
/// registration, its teardown — against a stream that spawns no child process,
/// which is the difference between a Tier 1 test and one that forks a provider
/// on every run.
protocol PeerLinkDriving: PeerLinkSending {
    func start() async
    func stop() async
    func linkState() async -> PeerLinkState
}

extension PeerLinkSupervisor: PeerLinkDriving {
    /// `state` as a method, so it can witness the protocol requirement above.
    /// A `var` requirement would work equally well; a method keeps every
    /// conformer's shape identical whether or not it stores the value.
    func linkState() -> PeerLinkState { state }
}

/// The outbound half of a link before the link exists.
///
/// **The one cycle in this subsystem, broken here rather than everywhere
/// else.** `ShadowPeerManager` takes its link at construction (every frame it
/// writes goes through one), and `PeerLinkSupervisor` takes its handler at
/// construction (a supervisor that could be started with no handler would
/// decode frames into nothing, silently). Neither ordering exists, so the
/// manager is built against this, the supervisor is built against the manager,
/// and this is pointed at the supervisor before anything starts.
///
/// A send before the bind reports the link as down, which is exactly what it
/// is: the stream has not been opened. It is a real answer, not a placeholder —
/// the design's clean-failure rule means a send on a down link simply fails.
///
/// `OSAllocatedUnfairLock` with scoped `withLock` rather than a bare `NSLock`:
/// `send` is `async`, where `lock()`/`unlock()` are unavailable under Swift 6.
final class LatePeerLink: PeerLinkSending, @unchecked Sendable {
    private let bound = OSAllocatedUnfairLock<(any PeerLinkSending)?>(initialState: nil)

    func bind(_ link: any PeerLinkSending) {
        bound.withLock { $0 = link }
    }

    func send(_ frame: PeerBridgeFrame) async throws {
        guard let link = bound.withLock({ $0 }) else {
            throw PeerLinkSendFailure.linkDown
        }
        try await link.send(frame)
    }
}

/// The link's handler, with link-state transitions copied to a second observer.
///
/// **The same cycle `LatePeerLink` breaks, from the other side.** The
/// supervisor takes its handler at construction and the bridge is built last,
/// so the bridge cannot itself be the handler — and it needs the transitions:
/// the manager empties its handle table on `.down`, and the roster's record of
/// what each link was told has to go at the same moment or the two disagree
/// (see `PeerBridge.linkStateChanged`).
///
/// Frames are forwarded untouched and transitions reach the manager *first*, so
/// nothing observes a reset roster before the table it mirrors has been
/// cleared. The observer is held as a closure capturing the bridge weakly: the
/// bridge owns the supervisor that owns this, and a strong reference here would
/// close that loop.
///
/// `OSAllocatedUnfairLock` with scoped `withLock` rather than a bare `NSLock`,
/// for the reason `LatePeerLink` gives: `lock()`/`unlock()` are unavailable
/// around an `async` call under Swift 6.
final class PeerLinkStateFanout: PeerLinkHandler, @unchecked Sendable {
    private let inner: any PeerLinkHandler
    private let observer =
        OSAllocatedUnfairLock<(@Sendable (PeerLinkState) async -> Void)?>(initialState: nil)

    init(forwardingTo inner: any PeerLinkHandler) {
        self.inner = inner
    }

    func bind(_ observer: @escaping @Sendable (PeerLinkState) async -> Void) {
        self.observer.withLock { $0 = observer }
    }

    func handle(_ frame: PeerBridgeFrame) async {
        await inner.handle(frame)
    }

    func linkStateChanged(to state: PeerLinkState) async {
        await inner.linkStateChanged(to: state)
        if let notify = self.observer.withLock({ $0 }) {
            await notify(state)
        }
    }
}

// MARK: - What a bridge answers

/// One provider's live bridge, as the diagnostics path reads it.
protocol PeerBridging: Sendable {
    var provider: String { get }
    /// Open the stream, start announcing the local roster, and become the party
    /// that vouches for this provider's shadows.
    func start() async
    /// Close everything this bridge owns, in the order that leaves nothing
    /// unowned. Returns only once the shadows are gone.
    func stop() async
    /// This bridge's half of `peer.status`.
    func status() async -> PeerProviderBridgeStatus
    /// The provider's session id and link state behind each live shadow, by the
    /// helper's pid — the join `tbd peer list` cannot make for itself, since the
    /// durable ledger records the *record's* session id rather than the remote
    /// one.
    func liveShadows() async -> [pid_t: PeerLiveShadow]
}

/// What a live link knows about one shadow that its durable row does not.
struct PeerLiveShadow: Sendable, Equatable {
    let provider: String
    let remoteSessionID: String?
    let linkState: PeerLinkState
}

// MARK: - The bridge

/// Everything one provider's peer messaging needs, wired together and owned as
/// one thing.
///
/// The pieces all existed and nothing constructed them; this is that
/// construction, and it is a type rather than a function because the four
/// relationships it establishes have to be undone in a particular order:
///
/// - the **stream** (`PeerLinkSupervisor`) carries frames both ways and
///   publishes link state to the manager;
/// - the **manager** (`ShadowPeerManager`) owns the local half — the handle
///   table, the helper processes, the frames;
/// - the **roster** (`RosterWatcher`) announces TBD's own sessions outward on
///   this link, scoped to the repositories the provider actually hosts sessions
///   in, and mints its handles through the manager so an inbound frame resolves
///   in the same table it was minted from;
/// - the **reclaimer registry** (`ShadowPeerBridgeRegistry`) is how
///   `ShadowPeerReconciler` tells a live shadow from an orphan. Until something
///   registers, the sweep counts rows as unvouched-for and reclaims nothing,
///   which is why this registration is what completes the reclaim path rather
///   than an optimisation on it.
///
/// **Repository scope is reconciled on a tick, not computed once.** The rule is
/// the design's: a local session is announced only to a host whose remote
/// session resolves to the same repository. Which repositories those are
/// changes whenever a remote lane is created or retired, and nothing tells this
/// bridge when that happens — so it is a small periodic reconcile against
/// TBD's own rows, in the shape every other durable-state reconciler here
/// takes. Its clock is injected, per the root `CLAUDE.md` rule for anything
/// that sleeps.
///
/// Design: `docs/specs/2026-08-29-remote-peer-messaging-design.md`.
actor PeerBridge: PeerBridging {
    nonisolated let provider: String
    private let manager: ShadowPeerManager
    private let link: any PeerLinkDriving
    private let roster: PeerRosterRunner
    private let bridges: ShadowPeerBridgeRegistry
    /// The repositories this provider currently hosts sessions in. A closure
    /// rather than a store, so the scope rule is stated at the wiring site and
    /// a test can move it without a database.
    private let repoScope: @Sendable () async -> Set<UUID>
    private let peerProtocol: Int
    private let scopeInterval: Duration
    private let clock: any Clock<Duration>

    /// repository → the roster registration announcing this link's sessions for
    /// it. One registration per repository, because that is the granularity the
    /// roster scopes at.
    private var registrationsByRepo: [UUID: UUID] = [:]
    private var scopeTask: Task<Void, Never>?
    private var started = false

    init(
        provider: String,
        manager: ShadowPeerManager,
        link: any PeerLinkDriving,
        roster: PeerRosterRunner,
        bridges: ShadowPeerBridgeRegistry,
        repoScope: @escaping @Sendable () async -> Set<UUID>,
        peerProtocol: Int = PeerBridgeFrameCodec.peerProtocol,
        scopeInterval: Duration = .seconds(30),
        clock: any Clock<Duration> = ContinuousClock()
    ) {
        self.provider = provider
        self.manager = manager
        self.link = link
        self.roster = roster
        self.bridges = bridges
        self.repoScope = repoScope
        self.peerProtocol = peerProtocol
        self.scopeInterval = scopeInterval
        self.clock = clock
    }

    /// Build the whole bridge for one provider, including the cycle between the
    /// manager and the stream.
    ///
    /// The order is forced: the late link first, then the manager against it,
    /// then the supervisor against the manager, then the bind. Nothing is
    /// started here — `start()` is a separate step so a caller can install the
    /// bridge in its own table before any frame can arrive.
    ///
    /// - Parameter makeLink: builds the stream around the handler this method
    ///   composed, and exists so the wiring below can be tested. The one thing
    ///   `make` does that no assembled-by-hand bridge does is bind
    ///   `PeerLinkStateFanout` to *both* the manager and the bridge, and that
    ///   binding is what carries a reconnect to `resetAnnouncements`; a test
    ///   that constructs `PeerBridge(...)` directly cannot fail when it is
    ///   deleted. Passing a stream that spawns nothing hands the test the very
    ///   handler the default hands `PeerLinkSupervisor`, so a transition can be
    ///   delivered through it without forking a provider child. Nil in
    ///   production, which is the only shape the daemon uses.
    static func make(
        config: RemoteProviderConfig,
        contractVersion: Int,
        origin: String,
        siteResolver: any ShadowPeerSiteResolving,
        artifactRecorder: any ShadowPeerArtifactRecording,
        sessionsDirectory: URL,
        roster: PeerRosterRunner,
        bridges: ShadowPeerBridgeRegistry,
        repoScope: @escaping @Sendable () async -> Set<UUID>,
        clock: any Clock<Duration> = ContinuousClock(),
        makeLink: (@Sendable (any PeerLinkHandler) -> any PeerLinkDriving)? = nil
    ) -> PeerBridge {
        let late = LatePeerLink()
        let manager = ShadowPeerManager(
            provider: config.name,
            link: late,
            siteResolver: siteResolver,
            sessionsDirectory: sessionsDirectory,
            artifactRecorder: artifactRecorder)
        // The manager is still the handler; the fanout only copies link-state
        // transitions onward, so the bridge learns about a reconnect at the
        // moment the manager forgets its handles rather than a tick later.
        let fanout = PeerLinkStateFanout(forwardingTo: manager)
        let stream: any PeerLinkDriving
        if let makeLink {
            stream = makeLink(fanout)
        } else {
            stream = PeerLinkSupervisor(
                config: config,
                contractVersion: contractVersion,
                origin: origin,
                handler: fanout,
                clock: clock)
        }
        late.bind(stream)
        let bridge = PeerBridge(
            provider: config.name,
            manager: manager,
            link: stream,
            roster: roster,
            bridges: bridges,
            repoScope: repoScope,
            clock: clock)
        fanout.bind { [weak bridge] state in
            guard let bridge else { return }
            await bridge.linkStateChanged(to: state)
        }
        return bridge
    }

    // MARK: Lifecycle

    func start() async {
        guard !started else { return }
        started = true

        // Registered BEFORE the stream opens. The reclaimer's rule is that a
        // provider absent from the inventory is one nothing can vouch for, so
        // a shadow published in the window between opening the stream and
        // registering would be a row the very next sweep read as unvouched-for.
        await bridges.register(provider: provider) { [manager] in
            var inventory: [String: pid_t] = [:]
            for shadow in await manager.artifacts() {
                inventory[shadow.handle] = shadow.pid
            }
            return inventory
        }

        // The shared roster ticks only while a bridge needs it: with the flag
        // off nothing is constructed here, so nothing scans the registry
        // directory every two seconds for a feature nobody turned on.
        await roster.retain()
        await link.start()
        await reconcileRepoScope()
        scopeTask = Task { [weak self] in
            guard let self else { return }
            await self.reconcileRepoScopeForever()
        }
        bridgeLogger.info(
            "peer bridge for \(self.provider, privacy: .public) is up")
    }

    /// Teardown, in the order that leaves nothing unowned.
    ///
    /// The roster goes first so no further `peer` line is written into a stream
    /// that is closing; the stream next, whose `.down` transition is what tells
    /// the manager to unpublish every shadow; the manager's own `shutdown()`
    /// after that, which returns only once every helper is confirmed gone; and
    /// the registry last, because deregistering is what makes this provider's
    /// rows reclaimable and nothing should be reclaimable while its helpers are
    /// still being closed.
    func stop() async {
        scopeTask?.cancel()
        scopeTask = nil
        for (_, registrationID) in registrationsByRepo.sorted(by: {
            $0.key.uuidString < $1.key.uuidString
        }) {
            // Silence is correct *here* and only here: the stream is about to
            // close, and the far side unlinks every shadow it published for it.
            await roster.removeLink(id: registrationID, because: .streamEnded)
        }
        registrationsByRepo.removeAll()
        await roster.release()
        await link.stop()
        await manager.shutdown()
        await bridges.deregister(provider: provider)
        started = false
        bridgeLogger.info(
            "peer bridge for \(self.provider, privacy: .public) is down")
    }

    // MARK: Repository scope

    private func reconcileRepoScopeForever() async {
        while !Task.isCancelled {
            do {
                try await clock.sleep(for: scopeInterval)
            } catch {
                return  // cancelled mid-sleep
            }
            guard !Task.isCancelled else { return }
            await reconcileRepoScope()
        }
    }

    /// Add a roster link for every repository this provider now hosts sessions
    /// in, and drop the ones it no longer does.
    ///
    /// Adding announces this link the whole roster for that repository from
    /// scratch, which is the design's resync rule rather than a convenience.
    ///
    /// **Dropping writes `peer-gone` for everything it announced**, because the
    /// stream is still open. A repository leaves this scope when its last
    /// remote lane for the provider is archived, and the far host does not
    /// unlink anything on that event — it unlinks when a *stream* ends. Dropping
    /// the registration silently would leave that host holding shadows for the
    /// repository's local sessions with their handles still resolving in the
    /// manager's table, so a remote session with no lane in that project could
    /// keep messaging into it. The design's Trust section forbids exactly that,
    /// and the divergence is invisible from here — `applyInventory` diffs
    /// against `localPeers`, which would still hold the handles.
    func reconcileRepoScope() async {
        let scope = await repoScope()

        for repoID in scope.subtracting(registrationsByRepo.keys).sorted(by: {
            $0.uuidString < $1.uuidString
        }) {
            let registrationID = UUID()
            registrationsByRepo[repoID] = registrationID
            await roster.addLink(RosterLinkRegistration(
                id: registrationID,
                repoID: repoID,
                peerProtocol: peerProtocol,
                // The manager, deliberately: minting and resolving must be the
                // same table, or every inbound frame resolves to nothing.
                handles: manager,
                send: { [link] frame in
                    // The link counts its own drops, and there is no mailbox on
                    // this channel: a `peer` line written while the stream is
                    // down is simply lost, and the next `hello` re-announces
                    // the whole roster.
                    _ = try? await link.send(frame)
                }))
        }

        for (repoID, registrationID) in registrationsByRepo.sorted(by: {
            $0.key.uuidString < $1.key.uuidString
        }) where !scope.contains(repoID) {
            registrationsByRepo[repoID] = nil
            await roster.removeLink(id: registrationID, because: .stillOpen)
        }
    }

    /// A link-state transition, delivered in stream order by the observer
    /// `make` binds to this bridge.
    ///
    /// **The roster's half of what the manager already does.**
    /// `ShadowPeerManager` empties both halves of its handle table on `.down`,
    /// deliberately — a handle names one session for the life of one connection.
    /// Nothing cleared the roster's record of what these links were told, so
    /// after any reconnect the two disagreed: the next scan minted a fresh
    /// handle for a session and announced it, while the stale handle beside it
    /// had no line and was announced gone, taking the freshly bound socket with
    /// it. Every reconnect therefore started a two-second churn that never
    /// stopped and that dropped every message in both directions, on a link
    /// reporting `up` throughout.
    ///
    /// Reset on **both** transitions, not just one. On `.down` because the
    /// handles the roster remembers no longer resolve anywhere; on `.up`
    /// because the far side unlinked every shadow when the stream ended, so
    /// what it needs is the whole roster again — and a roster still holding the
    /// lines it "sent" into a dead stream would announce nothing at all.
    ///
    /// Observed rather than polled: a link that dropped and came back between
    /// two ticks of any timer here would be missed entirely, and that is the
    /// common case — the supervisor reconnects with sub-second backoff.
    func linkStateChanged(to state: PeerLinkState) async {
        for registrationID in registrationsByRepo.values.sorted(by: {
            $0.uuidString < $1.uuidString
        }) {
            await roster.resetAnnouncements(linkID: registrationID)
        }
        bridgeLogger.debug("""
            peer bridge \(self.provider, privacy: .public) link \
            \(state.diagnosticName, privacy: .public); the roster will re-announce from scratch
            """)
    }

    // MARK: Diagnostics

    func status() async -> PeerProviderBridgeStatus {
        let snapshot = await manager.snapshot()
        var drops: [String: Int] = [:]
        for reason in ShadowPeerDropReason.allCases where snapshot.drops[reason] > 0 {
            drops[reason.rawValue] = snapshot.drops[reason]
        }
        return PeerProviderBridgeStatus(
            provider: provider,
            declaresMessages: true,
            bridged: true,
            linkState: await link.linkState().diagnosticName,
            remoteOrigin: snapshot.origin,
            shadowCount: snapshot.shadows.count,
            unmirroredHandles: snapshot.unmirroredHandles,
            inventorySurplus: snapshot.inventorySurplus,
            inventoryMissing: snapshot.inventoryMissing,
            drops: drops)
    }

    func liveShadows() async -> [pid_t: PeerLiveShadow] {
        let state = await link.linkState()
        var live: [pid_t: PeerLiveShadow] = [:]
        for shadow in await manager.artifacts() {
            live[shadow.pid] = PeerLiveShadow(
                provider: provider,
                remoteSessionID: shadow.remoteSessionID,
                linkState: state)
        }
        return live
    }

    /// Test seam: the repositories this bridge currently announces on, so the
    /// scoping rule is observable without reaching into the roster.
    func announcedRepoIDsForTests() -> Set<UUID> {
        Set(registrationsByRepo.keys)
    }
}

extension PeerLinkState {
    /// The word `tbd peer list` prints. A method on the enum rather than a
    /// mapping at the call site, so the two readers of this value cannot drift.
    public var diagnosticName: String {
        switch self {
        case .up: return "up"
        case .down: return "down"
        }
    }
}

// MARK: - Origin

/// The origin label TBD declares in its `hello`, and the namespace every name
/// it announces outward is prefixed with.
///
/// **Namespacing is TBD's job, and it is not optional.** A remote host is
/// multi-tenant: two laptops bridging to the same host would otherwise publish
/// colliding names for sessions on different machines belonging to different
/// people, and a collision there is a misdelivery rather than a display glitch.
///
/// The local host name is the natural namespace and the only identifier the
/// machine already has that a human recognises. It is sanitised because the
/// composed name is `<origin>:<display name> %<pane>`, so a colon or a space
/// inside the origin would make the name ambiguous to read even though nothing
/// parses it.
public enum PeerLinkOrigin {
    /// Fallback when the host name is empty or sanitises away to nothing. A
    /// constant rather than a random id: an origin that changed on every daemon
    /// start would rename every peer TBD announces, and a stable wrong-ish
    /// label is far better than an unstable correct one.
    public static let unknownHost = "tbd-host"

    public static func local(
        hostName: String = ProcessInfo.processInfo.hostName
    ) -> String {
        var trimmed = hostName.trimmingCharacters(in: .whitespacesAndNewlines)
        // Bonjour's `.local` suffix says nothing and doubles the length of
        // every name it appears in.
        if trimmed.hasSuffix(".local") {
            trimmed = String(trimmed.dropLast(".local".count))
        }
        let sanitised = String(trimmed.map { character in
            character.isLetter || character.isNumber || character == "-" || character == "_"
                ? character : "-"
        })
        // A name of nothing but separators sanitises to nothing but dashes,
        // which is no more of a namespace than an empty string.
        let meaningful = sanitised.contains { $0.isLetter || $0.isNumber }
        return meaningful ? sanitised : unknownHost
    }
}

// MARK: - The shared roster

/// Owns the one `RosterWatcher` every peer link announces through, and runs its
/// tick for exactly as long as at least one bridge needs it.
///
/// **One watcher, many links.** The roster is a scan of a single per-user
/// directory (`~/.claude/sessions`) that has no notion of provider, so a
/// watcher per bridge would scan the same directory N times to answer the same
/// question. The scoping that differs per link is a property of the link's
/// registration, not of the scan.
///
/// **Reference counted, so the tick is part of the flag's blast radius.** With
/// `remote_peer_messaging_enabled` off, no bridge is constructed, nothing
/// retains this, and the directory is never scanned — rather than a two-second
/// timer running forever on every install for a feature nobody turned on. The
/// count goes back to zero when the last bridge stops, which is also what
/// happens on daemon shutdown.
actor PeerRosterRunner {
    private let roster: RosterWatcher
    private var holders = 0
    private var task: Task<Void, Never>?

    init(roster: RosterWatcher) {
        self.roster = roster
    }

    func retain() {
        holders += 1
        guard task == nil else { return }
        task = Task { [roster] in await roster.run() }
    }

    func release() {
        holders = max(0, holders - 1)
        guard holders == 0 else { return }
        task?.cancel()
        task = nil
    }

    func addLink(_ registration: RosterLinkRegistration) async {
        await roster.addLink(registration)
    }

    func removeLink(id: UUID, because removal: RosterLinkRemoval) async {
        await roster.removeLink(id: id, because: removal)
    }

    func resetAnnouncements(linkID: UUID) async {
        await roster.resetAnnouncements(linkID: linkID)
    }

    /// Test seam: whether the tick is armed. The point of the refcount is that
    /// it is *not* armed with the flag off, and an assertion needs to see that.
    func isTicking() -> Bool { task != nil }
}

// MARK: - Wiring

/// What `RemoteProviderManager` needs in order to build a bridge, and the two
/// questions it asks before it does.
///
/// A pair of closures rather than a bag of dependencies, so the manager takes
/// on no knowledge of the roster, the registry, the artifact ledger or the
/// registry directory — none of which are its subject — and so a test can gate
/// and construct without a database or a child process.
struct PeerBridgeWiring: Sendable {
    /// `remote_peer_messaging_enabled`, resolved at the moment a provider's
    /// streams are armed.
    ///
    /// Read live rather than captured at boot, and the difference is
    /// deliberate: the flag is the feature's only opt-in, and the gate is
    /// consulted exactly where the events gate beside it is, so both branches
    /// are reachable from a test without booting a daemon.
    let isEnabled: @Sendable () async -> Bool
    /// Build one provider's bridge, given its config and the contract major
    /// already negotiated for it. Returns nil when the bridge cannot be built,
    /// which is treated exactly as a refused gate.
    let make: @Sendable (RemoteProviderConfig, Int) async -> (any PeerBridging)?

    init(
        isEnabled: @escaping @Sendable () async -> Bool,
        make: @escaping @Sendable (RemoteProviderConfig, Int) async -> (any PeerBridging)?
    ) {
        self.isEnabled = isEnabled
        self.make = make
    }
}

/// The daemon-side half of `peer.status`: one row per registered provider, and
/// the facts only a live link holds.
struct PeerBridgeReport: Sendable {
    var providers: [PeerProviderBridgeStatus] = []
    /// Helper pid → what its live link knows about it. The durable ledger
    /// records the id of the record the helper published; the remote session's
    /// own id lives only for the life of the connection that announced it, so
    /// it comes from here or it is absent.
    var liveShadowsByPID: [pid_t: PeerLiveShadow] = [:]

    init() {}
}
