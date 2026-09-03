import Darwin
import Dispatch
import Foundation
import Testing
@testable import TBDDaemonLib
@testable import TBDShared

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
@Suite("HolderRegistry adoptAll bounding")
struct HolderAdoptAllBoundingTests {

    /// One wedged holder must cost the adoption budget, not the general-purpose
    /// receive budget a long-lived connection gets.
    ///
    /// The discrimination is the gap between the two: `defaultReceiveTimeout` is
    /// 10 s, so a per-row bound anywhere near it fails this outright.
    @Test func anUnresponsiveHolderCostsSecondsNotTens() async throws {
        let home = HolderProcessFixture.scratchHome()
        defer { try? FileManager.default.removeItem(atPath: home) }
        let wedged = try #require(WedgedRendezvous(home: home))
        defer { wedged.tearDown() }

        let registry = makeRegistry(home: home, terminals: [wedged.terminal])
        defer { releaseInBackground(registry) }

        let elapsed = await ContinuousClock().measure {
            await registry.adoptAll()
        }
        #expect(
            elapsed < .seconds(6),
            "one wedged holder held the daemon for \(elapsed) before it could bind its socket")
    }

    /// The phase as a whole is bounded, not merely each holder in it.
    ///
    /// Four wedged holders at a two-second per-row bound is eight seconds of
    /// silence if nothing stops the walk, so the budget has to leave at least
    /// one row unprobed. **Unprobed means no status recorded**: a row the pass
    /// never reached must not be branded `exitedStatusUnknown`, which is a claim
    /// about a holder that answered nothing — and which downstream reads as a
    /// session whose job may be gone.
    @Test func aWedgedFleetStopsAtTheBudgetRatherThanProbingEveryRow() async throws {
        let home = HolderProcessFixture.scratchHome()
        defer { try? FileManager.default.removeItem(atPath: home) }
        var wedged: [WedgedRendezvous] = []
        for _ in 0..<4 { wedged.append(try #require(WedgedRendezvous(home: home))) }
        defer { for holder in wedged { holder.tearDown() } }

        let rows = wedged.map(\.terminal)
        let registry = makeRegistry(home: home, terminals: rows)
        defer { releaseInBackground(registry) }

        let elapsed = await ContinuousClock().measure {
            await registry.adoptAll()
        }
        #expect(
            elapsed < .seconds(12),
            "four wedged holders held the daemon for \(elapsed); the phase is not bounded")

        var unprobed = 0
        for row in rows {
            if await registry.lastKnownStatus(for: row.id) == nil { unprobed += 1 }
        }
        #expect(
            unprobed > 0,
            "every wedged row was probed, so the budget never stopped the walk")
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
        let registry = HolderRegistry(
            owner: fixture.owner,
            environment: HolderProcessFixture.environment(home: fixture.home),
            listTerminals: { rows })
        defer { releaseInBackground(registry) }

        let elapsed = await ContinuousClock().measure {
            await registry.adoptAll()
        }
        let reader = await registry.reader(for: fixture.sessionID)
        #expect(reader != nil, "the healthy holder was not adopted")
        #expect(
            elapsed < .seconds(12),
            "three wedged holders held the daemon for \(elapsed) after the healthy one was adopted")
    }

    /// The rows the budget skipped are handed back for the caller to finish,
    /// and finishing them really adopts them.
    ///
    /// This is the half that keeps the budget from being a leak. `adoptAll` is
    /// the only caller of `adopt` in the daemon, so a row it walked away from
    /// and did not report would stay undrained for the process's whole life —
    /// and an undrained pty master stops the job on it from finishing its exit.
    /// The healthy holder is listed **last**, behind enough wedged ones to
    /// spend the budget, so it is a live session that the bounded pass provably
    /// did not reach.
    @Test func theRowsTheBudgetSkippedAreHandedBackAndStillAdoptable() async throws {
        let fixture = try await HolderProcessFixture.start(command: "sleep 30")
        defer { fixture.tearDown() }
        await fixture.client.close()

        var wedged: [WedgedRendezvous] = []
        for _ in 0..<4 { wedged.append(try #require(WedgedRendezvous(home: fixture.home))) }
        defer { for holder in wedged { holder.tearDown() } }

        let healthy = Terminal(
            id: fixture.sessionID, worktreeID: UUID(), tmuxWindowID: "", tmuxPaneID: "",
            transport: .holder)
        let rows = wedged.map(\.terminal) + [healthy]
        let registry = HolderRegistry(
            owner: fixture.owner,
            environment: HolderProcessFixture.environment(home: fixture.home),
            listTerminals: { rows })
        defer { releaseInBackground(registry) }

        let unreached = await registry.adoptAll()
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
    /// nothing here can reach the developer's real `~/tbd` even for an instant.
    /// The owner is irrelevant to a wedged holder, which never names one.
    private func makeRegistry(home: String, terminals: [Terminal]) -> HolderRegistry {
        HolderRegistry(
            owner: HolderOwnerToken(rawValue: "acme-installation"),
            environment: HolderProcessFixture.environment(home: home),
            listTerminals: { terminals })
    }
}

/// Releases a registry's readers from a `defer`, which cannot `await`. A reader
/// left running leaks its drain thread and a pty descriptor for the rest of the
/// suite. Releasing is idempotent.
private func releaseInBackground(_ registry: HolderRegistry) {
    Task.detached { await registry.releaseAll() }
}
