import Darwin
import Dispatch
import Foundation
import Testing
@testable import TBDDaemonLib
@testable import TBDShared
import TBDKernel

/// A holder that is **reachable but will not answer** — the only failure shape
/// `adoptAll`'s bounding exists for.
///
/// A *dead* holder is cheap: `connect` fails with `ECONNREFUSED` the moment it
/// is tried, so a hundred of them cost microseconds. A holder that accepts the
/// connection and then says nothing costs the client's whole receive budget,
/// every time, and it is the only way one session can make the daemon look
/// hung. So the fixture binds, listens, accepts, and goes silent — it never
/// speaks the holder protocol at all, because nothing here needs it to.
///
/// It deliberately does **not** spawn a `TBDHolder`: a real holder cannot be
/// made to wedge on demand, and a fake one would be a second implementation of
/// the protocol to keep in step with the first.
///
/// **What it cannot reach is the connect itself.** Because it accepts, every
/// `connect` here returns immediately and the cost measured below is entirely
/// the receive. A rendezvous that binds and never accepts is the other half,
/// and it behaves nothing like this one — it is refused rather than queued, in
/// microseconds, and lands as `ECONNREFUSED`. That half lives in
/// `HolderClientTests`
/// `.aSaturatedRendezvousIsRefusedImmediatelyRatherThanBlocking`.
private final class WedgedRendezvous: @unchecked Sendable {
    let sessionID = UUID()
    let path: String
    private let listenFD: Int32
    private let lock = NSLock()
    private var accepted: [Int32] = []
    private var closed = false

    init?(home: String) {
        let environment = HolderProcessFixture.environment(home: home)
        guard let path = try? HolderRendezvous.socketPath(
            sessionID: sessionID, environment: environment)
        else { return nil }
        self.path = path
        try? FileManager.default.createDirectory(
            at: TBDConstants.holdersDir(environment: environment),
            withIntermediateDirectories: true)

        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        let capacity = MemoryLayout.size(ofValue: address.sun_path)
        let bytes = Array(path.utf8)
        guard bytes.count < capacity else { close(fd); return nil }
        withUnsafeMutablePointer(to: &address.sun_path) { raw in
            raw.withMemoryRebound(to: CChar.self, capacity: capacity) { chars in
                for (index, byte) in bytes.enumerated() { chars[index] = CChar(bitPattern: byte) }
                chars[bytes.count] = 0
            }
        }
        let bound = withUnsafePointer(to: &address) { raw in
            raw.withMemoryRebound(to: sockaddr.self, capacity: 1) { generic in
                Foundation.bind(fd, generic, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard bound == 0, listen(fd, 4) == 0 else { close(fd); return nil }
        listenFD = fd

        // Accepting matters: a connection left in the backlog is a state the
        // kernel, not the peer, is responsible for, and the test would then be
        // measuring an accept queue rather than a silent holder.
        DispatchQueue.global().async { [weak self] in
            while true {
                let client = accept(fd, nil, nil)
                guard client >= 0, let self else {
                    if client >= 0 { close(client) }
                    return
                }
                guard self.retain(client) else { close(client); return }
            }
        }
    }

    /// Keeps an accepted connection open, so the peer parks in `recv` rather
    /// than seeing an EOF. Answers false once teardown has begun.
    private func retain(_ fd: Int32) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !closed else { return false }
        accepted.append(fd)
        return true
    }

    func tearDown() {
        lock.lock()
        let toClose = accepted
        accepted = []
        closed = true
        lock.unlock()
        for fd in toClose { close(fd) }
        close(listenFD)
        unlink(path)
    }

    /// The session row a registry walks to reach this rendezvous.
    var terminal: Terminal {
        Terminal(
            id: sessionID, worktreeID: UUID(), tmuxWindowID: "", tmuxPaneID: "",
            transport: .holder)
    }
}

/// `adoptAll` runs before the socket bind, so its duration is the daemon's
/// silence. These pin that the silence is bounded — per holder, and in total —
/// rather than growing with however many holders happen to be wedged.
///
/// **Every registry here takes short stand-ins for both bounding knobs**, so a
/// wedged row costs half a second rather than the production two, and
/// the suite pays for the shape of the bounding rather than for its size. Each
/// test states what it discriminates against the stand-ins; the one production
/// number the suite depends on — that the adoption timeout sits far below a
/// session connection's — is pinned directly in the first test.
@Suite("HolderRegistry adoptAll bounding")
struct HolderAdoptAllBoundingTests {

    /// The per-row receive timeout every registry here uses in place of
    /// `HolderRegistry.defaultAdoptionReceiveTimeout`.
    ///
    /// It bounds the *healthy* rows too: the two tests that rescue a live
    /// holder adopt it under this same timeout, so it has to cover a real
    /// handshake with room to spare, not only stand in for a wedged one. A
    /// holder answers from a poll that wakes on the connect, in single-digit
    /// milliseconds on an idle machine; half a second leaves room for a
    /// scheduling stall under load and still sits well under the production
    /// two seconds the first test's upper bound must tell it apart from.
    private static let receiveTimeout: Duration = .milliseconds(500)

    /// The phase budget every registry here uses in place of
    /// `HolderRegistry.defaultAdoptAllBudget`. Shorter than one receive timeout
    /// on purpose: the loop checks the budget only *between* rows, and the
    /// first row is always reached — nothing suspends between arming the timer
    /// and the first check — so a budget under one row's cost makes "the walk
    /// stopped after the first wedged row" deterministic rather than a race
    /// between two clocks.
    private static let budget: Duration = .milliseconds(100)

    /// One wedged holder must cost the adoption receive timeout, not the
    /// general-purpose one a long-lived connection gets.
    ///
    /// The discrimination is the gap between the two. This registry is handed
    /// a 500 ms adoption timeout, so a registry that ignored it — falling back
    /// to `HolderClient.defaultReceiveTimeout` (10 s), or to the production
    /// default (2 s) — fails the upper bound outright.
    @Test func anUnresponsiveHolderCostsSecondsNotTens() async throws {
        // The production numbers the stand-ins replace: an adoption is one
        // handshake, so its bound sits well under a session connection's.
        #expect(
            HolderRegistry.defaultAdoptionReceiveTimeout < HolderClient.defaultReceiveTimeout / 2,
            "the adoption receive timeout is no longer far below a session connection's")

        let home = HolderProcessFixture.scratchHome()
        defer { try? FileManager.default.removeItem(atPath: home) }
        let wedged = try #require(WedgedRendezvous(home: home))
        defer { wedged.tearDown() }

        let registry = makeRegistry(home: home, terminals: [wedged.terminal])
        defer { releaseInBackground(registry) }

        let elapsed = await ContinuousClock().measure {
            _ = await registry.adoptAll()
        }
        #expect(
            elapsed < .milliseconds(1500),
            "one wedged holder held the daemon for \(elapsed) before it could bind its socket")
        // Two more assertions, because the upper bound alone passes vacuously:
        // if this fixture's path and the registry's ever diverged, `connect`
        // would fail `ECONNREFUSED` in microseconds and it would be satisfied
        // having probed nothing. The lower bound says the row was not merely
        // reached but waited on; the counter says a round trip was opened
        // against it at all.
        //
        // **Not the recorded status, deliberately.** A holder that is merely
        // silent is exactly a holder that is alive and wedged, so `adoptOne`
        // records nothing for one — the reconcile arm's gate 4 would otherwise
        // delete a live session's row on a timeout. `lastKnownStatus` is
        // therefore `nil` here whether the row was probed or skipped, and can
        // no longer discriminate.
        #expect(
            elapsed > Self.receiveTimeout / 2,
            "the wedged holder cost only \(elapsed), under one receive timeout: nothing waited")
        #expect(
            await registry.attachRoundTripsStarted == 1,
            "the wedged row was never probed at all")
    }

    /// A live session is still rescued when it shares the fleet with wedged
    /// ones — the bounding must cost reachability, never adoption.
    ///
    /// The healthy holder is listed first on purpose: that is the case the
    /// budget must not be allowed to regress, and putting it last would test
    /// the deferral path instead.
    @Test func aHealthyHolderIsAdoptedAlongsideWedgedOnes() async throws {
        let fixture = try await HolderProcessFixture.start(command: "sleep 30")
        defer { fixture.tearDown() }
        // The spawner's handshake connection is the holder's one client slot;
        // an adopter needs it free.
        await fixture.client.close()

        var wedged: [WedgedRendezvous] = []
        for _ in 0..<3 { wedged.append(try #require(WedgedRendezvous(home: fixture.home))) }
        defer { for holder in wedged { holder.tearDown() } }

        let healthy = Terminal(
            id: fixture.sessionID, worktreeID: UUID(), tmuxWindowID: "", tmuxPaneID: "",
            transport: .holder)
        let rows = [healthy] + wedged.map(\.terminal)
        let registry = makeRegistry(owner: fixture.owner, home: fixture.home, terminals: rows)
        defer { releaseInBackground(registry) }

        let elapsed = await ContinuousClock().measure {
            _ = await registry.adoptAll()
        }
        let reader = await registry.reader(for: fixture.sessionID)
        #expect(reader != nil, "the healthy holder was not adopted")
        #expect(
            elapsed < .seconds(3),
            "three wedged holders held the daemon for \(elapsed) after the healthy one was adopted")
    }

    /// The phase as a whole is bounded, not merely each row in it — and the
    /// rows the budget skipped are handed back for the caller to finish, and
    /// finishing them really adopts them.
    ///
    /// **The walk stops.** Two wedged rows ahead of a live one, at a budget
    /// shorter than one row's receive timeout, must leave rows unprobed —
    /// counted by the round trips the registry opened, which is the one
    /// instrument that separates a row it reached from a row it never got to.
    /// Not by the absence of a recorded status: a wedged holder may well be
    /// alive, so `adoptOne` records nothing for a probed one either, and only
    /// nothing *bound* at the rendezvous is evidence the session is over. So
    /// no row here is branded, and the branding cannot tell reached from
    /// skipped.
    ///
    /// **Nothing is dropped.** This is the half that keeps the budget from
    /// being a leak. `adoptAll` is the only caller of `adopt` in the daemon, so
    /// a row it walked away from and did not report would stay undrained for
    /// the process's whole life — and an undrained pty master stops the job on
    /// it from finishing its exit. The healthy holder is listed **last**,
    /// behind the wedged ones, so it is a live session that the bounded pass
    /// provably did not reach.
    @Test func theRowsTheBudgetSkippedAreHandedBackAndStillAdoptable() async throws {
        let fixture = try await HolderProcessFixture.start(command: "sleep 30")
        defer { fixture.tearDown() }
        await fixture.client.close()

        var wedged: [WedgedRendezvous] = []
        for _ in 0..<2 { wedged.append(try #require(WedgedRendezvous(home: fixture.home))) }
        defer { for holder in wedged { holder.tearDown() } }

        let healthy = Terminal(
            id: fixture.sessionID, worktreeID: UUID(), tmuxWindowID: "", tmuxPaneID: "",
            transport: .holder)
        let rows = wedged.map(\.terminal) + [healthy]
        let registry = makeRegistry(owner: fixture.owner, home: fixture.home, terminals: rows)
        defer { releaseInBackground(registry) }

        let clock = ContinuousClock()
        let started = clock.now
        let unreached = await registry.adoptAll()
        let elapsed = started.duration(to: clock.now)

        let probed = await registry.attachRoundTripsStarted
        #expect(
            probed < rows.count,
            "all \(rows.count) rows were probed; the budget never stopped the walk")
        #expect(
            elapsed < .seconds(3),
            "two wedged holders held the daemon for \(elapsed); the phase is not bounded")
        #expect(
            unreached.contains(where: { $0.id == fixture.sessionID }),
            "the live session the budget skipped was not handed back")
        let beforeResuming = await registry.reader(for: fixture.sessionID)
        #expect(beforeResuming == nil, "the bounded pass reached a row it should have deferred")

        await registry.adoptRemaining(unreached)
        let reader = await registry.reader(for: fixture.sessionID)
        #expect(reader != nil, "a deferred session was never adopted by the later pass")
    }

    // MARK: - Support

    /// A registry whose rendezvous paths come from an explicit environment, so
    /// nothing here can reach the developer's real `~/tbd` even for an instant,
    /// built with the suite's stand-ins for both bounding knobs. The default
    /// owner suits a wedged holder, which never names one.
    private func makeRegistry(
        owner: HolderOwnerToken = HolderOwnerToken(rawValue: "acme-installation"),
        home: String,
        terminals: [Terminal]
    ) -> HolderRegistry {
        HolderRegistry(
            owner: owner,
            environment: HolderProcessFixture.environment(home: home),
            listTerminals: { terminals },
            adoptAllBudget: Self.budget,
            adoptionReceiveTimeout: Self.receiveTimeout)
    }
}

/// Releases a registry's readers from a `defer`, which cannot `await`. A reader
/// left running leaks its drain thread and a pty descriptor for the rest of the
/// suite. Releasing is idempotent.
private func releaseInBackground(_ registry: HolderRegistry) {
    Task.detached { await registry.releaseAll() }
}
