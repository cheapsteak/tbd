import Foundation
import GRDB
import Testing

@testable import TBDDaemonLib
@testable import TBDShared

// MARK: - Fakes

/// A `ProcessSignaller` that never signals anything real, and that records
/// **which door** each signal came through.
///
/// The distinction is the point rather than bookkeeping: `terminate` and
/// `forceKill` widen to the process group when the pid is a group leader, which
/// on a recycled pid resolves to a stranger's group entirely. A shadow peer
/// helper is one process TBD spawned and recorded, so the reconciler must only
/// ever use the pid-exact door — and a test that did not separate the two could
/// not tell.
private final class FakeSignaller: ProcessSignaller, @unchecked Sendable {
    private let lock = NSLock()
    private var alivePIDs: Set<Int32>
    private var terminatedPIDs: [Int32] = []
    private var forceKilledPIDs: [Int32] = []
    private var groupSignalledPIDs: [Int32] = []

    init(alive: Set<Int32>) {
        self.alivePIDs = alive
    }

    func isAlive(_ pid: Int32) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return alivePIDs.contains(pid)
    }

    func terminate(_ pid: Int32) {
        lock.lock()
        defer { lock.unlock() }
        groupSignalledPIDs.append(pid)
    }

    func forceKill(_ pid: Int32) {
        lock.lock()
        defer { lock.unlock() }
        groupSignalledPIDs.append(pid)
    }

    func terminateProcessOnly(_ pid: Int32) {
        lock.lock()
        defer { lock.unlock() }
        terminatedPIDs.append(pid)
        alivePIDs.remove(pid)
    }

    func forceKillProcessOnly(_ pid: Int32) {
        lock.lock()
        defer { lock.unlock() }
        forceKilledPIDs.append(pid)
        alivePIDs.remove(pid)
    }

    func children(ofServerPID serverPID: Int32) -> [Int32] { [] }
    func commandLine(_ pid: Int32) -> String? { nil }
    func stat(_ pid: Int32) -> String? { nil }

    var terminated: [Int32] {
        lock.lock()
        defer { lock.unlock() }
        return terminatedPIDs
    }

    var forceKilled: [Int32] {
        lock.lock()
        defer { lock.unlock() }
        return forceKilledPIDs
    }

    /// Anything signalled through the group-capable door. Must always be empty.
    var groupSignalled: [Int32] {
        lock.lock()
        defer { lock.unlock() }
        return groupSignalledPIDs
    }
}

/// What the live links say they are publishing.
private struct FakeBridge: ShadowPeerBridgeInspecting {
    var inventories: [ShadowPeerBridgeInventory] = []

    func bridgedShadows() async -> [ShadowPeerBridgeInventory] { inventories }
}

/// A probe that answers from a set of paths a test declares to be listening,
/// and otherwise mirrors production: a file that is not there is `.absent`, and
/// one that is there with no listener refuses the connect.
private struct FakeProbe: ShadowPeerSocketProbing {
    var listening: Set<String> = []
    var inconclusive: Set<String> = []

    func listenerState(atPath path: String) -> ShadowPeerListenerState {
        if inconclusive.contains(path) { return .inconclusive("test") }
        if listening.contains(path) { return .listening }
        return FileManager.default.fileExists(atPath: path) ? .refused : .absent
    }
}

// MARK: - Tests

/// `ShadowPeerReconciler` — the named reconciler for a shadow peer's helper
/// process, socket and record
/// (`docs/specs/2026-08-29-remote-peer-messaging-design.md`, "Reclamation and
/// detection").
///
/// Tier 1: no process is signalled, no socket is bound, and every path the
/// sweep touches is one the test itself planted under the process temp
/// directory. The registry the real thing sweeps is shared with every Claude
/// Code session on the machine, which is exactly why nothing here goes near it.
@Suite("ShadowPeerReconciler")
struct ShadowPeerReconcilerTests {

    private static let generation = "gen-current"
    private static let previousGeneration = "gen-previous"
    /// Every planted row is stamped well before this, so the publication grace
    /// is never what a test is accidentally measuring — except in the one test
    /// that measures it deliberately.
    private static let sweepTime = Date(timeIntervalSince1970: 1_800_000_000)
    private static let longAgo = Date(timeIntervalSince1970: 1_700_000_000)

    /// A scratch registry directory — never the developer's `~/.claude`, and
    /// never `~/tbd`.
    private static func makeScratchDirectory() throws -> URL {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("tbd-shadow-peer-reconciler-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private struct PlantedShadow {
        let pid: pid_t
        let handle: String
        let recordPath: String
        let socketPath: String
    }

    /// Plant one shadow's three artifacts: a whitelist row, a record on disk,
    /// and a socket file. The record goes through `ShadowPeerRecordStore`, so
    /// what the sweep reads back is what the helper would really have written.
    @discardableResult
    private static func plant(
        directory: URL,
        store: ShadowPeerArtifactStore,
        pid: pid_t,
        handle: String,
        provider: String = "cloud",
        sessionID: String = "session-1",
        recordSessionID: String? = nil,
        procStart: String? = "Sat Aug 29 22:07:57 2026",
        generation: String = ShadowPeerReconcilerTests.generation,
        publishedAt: Date = ShadowPeerReconcilerTests.longAgo,
        writeRecord: Bool = true,
        writeSocket: Bool = true
    ) async throws -> PlantedShadow {
        let recordStore = ShadowPeerRecordStore(sessionsDirectory: directory)
        let socketPath = directory.appendingPathComponent("\(pid).sock").path
        if writeRecord {
            try recordStore.write(ShadowPeerRecord(
                pid: pid,
                procStart: procStart ?? "unknown",
                messagingSocketPath: socketPath,
                name: "cloud:\(handle)",
                status: "idle",
                peerProtocol: 1,
                cwd: directory.path,
                sessionID: recordSessionID ?? sessionID))
        }
        if writeSocket {
            #expect(FileManager.default.createFile(atPath: socketPath, contents: Data()))
        }
        let recordPath = recordStore.recordURL(pid: pid).path
        try await store.upsert(ShadowPeerArtifact(
            pid: pid, provider: provider, handle: handle, name: "cloud:\(handle)",
            sessionID: sessionID, procStart: procStart, socketPath: socketPath,
            recordPath: recordPath, daemonGeneration: generation, publishedAt: publishedAt))
        return PlantedShadow(
            pid: pid, handle: handle, recordPath: recordPath, socketPath: socketPath)
    }

    /// Plant a **neighbour's** two artifacts at the pid-named paths with **no
    /// ledger row at all** — a real Claude Code session that happens to sit in
    /// the same registry directory and the same socket directory, which is
    /// every session on this machine.
    ///
    /// Nothing recorded these, so nothing may reclaim them. That is the whole
    /// of "MUST NOT reclaim by inference", expressed as files on disk.
    private static func plantUnrecordedNeighbour(
        directory: URL, pid: pid_t
    ) throws -> PlantedShadow {
        let recordStore = ShadowPeerRecordStore(sessionsDirectory: directory)
        let socketPath = directory.appendingPathComponent("\(pid).sock").path
        try recordStore.write(ShadowPeerRecord(
            pid: pid,
            procStart: "Sat Aug 29 10:00:00 2026",
            messagingSocketPath: socketPath,
            name: "acme-laptop:somebody-elses-session %3",
            status: "idle",
            peerProtocol: 1,
            cwd: directory.path,
            sessionID: "a-session-tbd-never-published"))
        #expect(FileManager.default.createFile(atPath: socketPath, contents: Data()))
        return PlantedShadow(
            pid: pid, handle: "not-a-shadow",
            recordPath: recordStore.recordURL(pid: pid).path, socketPath: socketPath)
    }

    /// A write-temp beside the record for `pid`, named by the same rule
    /// `ShadowPeerRecordStore.write` names its own — a daemon that died between
    /// the write and the `rename(2)` leaves exactly this.
    @discardableResult
    private static func plantWriteTemp(directory: URL, forPID pid: pid_t) -> String {
        let path = directory.appendingPathComponent(
            ".\(pid).json.\(UUID().uuidString).tmp").path
        #expect(FileManager.default.createFile(
            atPath: path, contents: Data(#"{"pid":"#.utf8)))
        return path
    }

    private static func makeReconciler(
        store: ShadowPeerArtifactStore,
        bridge: FakeBridge,
        signaller: FakeSignaller,
        probe: FakeProbe = FakeProbe(),
        procStarts: [pid_t: String] = [:]
    ) -> ShadowPeerReconciler {
        ShadowPeerReconciler(
            artifacts: store,
            bridges: bridge,
            generation: Self.generation,
            signaller: signaller,
            probe: probe,
            procStart: { procStarts[$0] },
            now: { Self.sweepTime },
            publicationGrace: 30,
            interval: .seconds(60),
            graceAttempts: 3,
            pollInterval: .milliseconds(1))
    }

    private static func exists(_ path: String) -> Bool {
        FileManager.default.fileExists(atPath: path)
    }

    // MARK: - The whole pass, both halves

    /// **The load-bearing test, and it is deliberately one sweep.** Three
    /// ghosts go in — a record whose helper is dead, the socket beside it, and
    /// a helper still running with no bridged session behind it — and a live
    /// shadow sits alongside them. Reclaiming the first three proves the sweep
    /// works; the live shadow's three artifacts surviving the *same* pass is
    /// the half that matters more, because a reaper that eats live state is
    /// worse than one that leaks.
    @Test func theGhostsAreReclaimedAndALiveShadowSurvivesTheSamePass() async throws {
        let directory = try Self.makeScratchDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let db = try TBDDatabase(inMemory: true)
        let store = db.shadowPeerArtifacts

        let ghost = try await Self.plant(
            directory: directory, store: store, pid: 901, handle: "remote-dead")
        let orphan = try await Self.plant(
            directory: directory, store: store, pid: 902, handle: "remote-orphan")
        let live = try await Self.plant(
            directory: directory, store: store, pid: 903, handle: "remote-live")

        // 902 and 903 are running; 901's pid is gone. Only 903 is one a link
        // vouches for.
        let signaller = FakeSignaller(alive: [902, 903])
        let bridge = FakeBridge(inventories: [
            ShadowPeerBridgeInventory(provider: "cloud", pidsByHandle: ["remote-live": 903]),
        ])
        let reconciler = Self.makeReconciler(
            store: store, bridge: bridge, signaller: signaller,
            procStarts: [902: "Sat Aug 29 22:07:57 2026", 903: "Sat Aug 29 22:07:57 2026"])

        let result = await reconciler.sweep()

        #expect(result.helpersKilled == 1)
        #expect(result.recordsUnlinked == 2)
        #expect(result.socketsUnlinked == 2)
        #expect(result.rowsForgotten == 2)
        #expect(result.reclaimedArtifacts == 5)
        #expect(result.liveShadowsKept == 1)

        // The orphaned helper, killed pid-exactly and never through the
        // group-capable door.
        #expect(signaller.terminated == [902])
        #expect(signaller.groupSignalled.isEmpty)

        // Both ghosts' artifacts are gone, and so are their rows.
        #expect(!Self.exists(ghost.recordPath))
        #expect(!Self.exists(ghost.socketPath))
        #expect(!Self.exists(orphan.recordPath))
        #expect(!Self.exists(orphan.socketPath))
        let remaining = try await store.all().map(\.pid)
        #expect(remaining == [903])

        // The live shadow: process untouched, record and socket still on disk.
        #expect(signaller.isAlive(903))
        #expect(Self.exists(live.recordPath))
        #expect(Self.exists(live.socketPath))
    }

    /// **The discriminator for "MUST NOT reclaim by inference", and the test
    /// the rest of this file cannot be.**
    ///
    /// Every other planted shadow here has a ledger row, so an implementation
    /// that globbed `<int>.json` / `<int>.sock` and unlinked whatever refused a
    /// connect would pass all of them. This plants a neighbour's record, socket
    /// and write-temp with **no row at all**, beside a ghost that has one, and
    /// asserts the sweep takes the ghost's three and leaves the neighbour's
    /// three exactly where they are. `/tmp/cc-socks` and the session registry
    /// are shared with every Claude Code session on the machine; a sweep that
    /// reclaimed by shape would delist live teammates.
    @Test func artifactsWithNoLedgerRowSurviveThePassThatReclaimsTheRecordedOnes() async throws {
        let directory = try Self.makeScratchDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let db = try TBDDatabase(inMemory: true)
        let store = db.shadowPeerArtifacts

        let ghost = try await Self.plant(
            directory: directory, store: store, pid: 801, handle: "remote-dead")
        let ghostTemp = Self.plantWriteTemp(directory: directory, forPID: 801)
        let neighbour = try Self.plantUnrecordedNeighbour(directory: directory, pid: 802)
        let neighbourTemp = Self.plantWriteTemp(directory: directory, forPID: 802)

        // Both pids are gone and neither socket has a listener, so nothing but
        // the ledger distinguishes the two.
        let signaller = FakeSignaller(alive: [])
        let bridge = FakeBridge(inventories: [
            ShadowPeerBridgeInventory(provider: "cloud", pidsByHandle: [:]),
        ])
        let reconciler = Self.makeReconciler(
            store: store, bridge: bridge, signaller: signaller)

        let result = await reconciler.sweep()

        #expect(result.recordsUnlinked == 1)
        #expect(result.socketsUnlinked == 1)
        #expect(result.recordTemporariesUnlinked == 1)
        #expect(!Self.exists(ghost.recordPath))
        #expect(!Self.exists(ghost.socketPath))
        #expect(!Self.exists(ghostTemp))

        #expect(Self.exists(neighbour.recordPath),
                "a record no ledger row names is somebody else's and must never be unlinked")
        #expect(Self.exists(neighbour.socketPath),
                "a socket no ledger row names is somebody else's, listener or not")
        #expect(Self.exists(neighbourTemp),
                "a write-temp no ledger row leads to is somebody else's half-written record")
    }

    // MARK: - The recycled-pid ghost

    /// The measured case Claude Code's own reaper provably will not collect: it
    /// checks pid liveness and nothing else, so a record whose pid has been
    /// reused by an unrelated process survives it forever.
    ///
    /// The artifacts are reclaimed and **the pid is never signalled** — it now
    /// belongs to somebody else's process, and killing it would be the worst
    /// thing this sweep could do.
    @Test func aRecycledPIDGhostIsReclaimedWithoutEverSignallingThatPID() async throws {
        let directory = try Self.makeScratchDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let db = try TBDDatabase(inMemory: true)
        let store = db.shadowPeerArtifacts

        let ghost = try await Self.plant(
            directory: directory, store: store, pid: 950, handle: "remote-recycled",
            procStart: "Sat Aug 29 22:07:57 2026")

        let signaller = FakeSignaller(alive: [950])
        let bridge = FakeBridge(inventories: [
            ShadowPeerBridgeInventory(provider: "cloud", pidsByHandle: [:]),
        ])
        // The pid is alive, but it started at a different moment — so it is not
        // the helper TBD recorded.
        let reconciler = Self.makeReconciler(
            store: store, bridge: bridge, signaller: signaller,
            procStarts: [950: "Sun Aug 30 09:15:02 2026"])

        let result = await reconciler.sweep()

        #expect(result.helpersKilled == 0)
        #expect(signaller.terminated.isEmpty)
        #expect(signaller.forceKilled.isEmpty)
        #expect(signaller.groupSignalled.isEmpty)
        #expect(signaller.isAlive(950), "the stranger holding the recycled pid must still be running")

        #expect(result.recordsUnlinked == 1)
        #expect(result.socketsUnlinked == 1)
        #expect(!Self.exists(ghost.recordPath))
        #expect(!Self.exists(ghost.socketPath))
        let remaining = try await store.all()
        #expect(remaining.isEmpty)
    }

    /// The other half of the recycled pid, and the reason a record is verified
    /// rather than unlinked on the strength of its path: the pid's new owner is
    /// a real Claude Code session, which has written **its own** record at
    /// exactly `<pid>.json`. Unlinking that would delist a live teammate.
    @Test func aRecordARecycledPIDsNewOwnerWroteIsLeftOnDisk() async throws {
        let directory = try Self.makeScratchDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let db = try TBDDatabase(inMemory: true)
        let store = db.shadowPeerArtifacts

        let ghost = try await Self.plant(
            directory: directory, store: store, pid: 951, handle: "remote-recycled",
            sessionID: "ours", recordSessionID: "someone-elses")

        let signaller = FakeSignaller(alive: [951])
        let bridge = FakeBridge(inventories: [
            ShadowPeerBridgeInventory(provider: "cloud", pidsByHandle: [:]),
        ])
        let reconciler = Self.makeReconciler(
            store: store, bridge: bridge, signaller: signaller,
            procStarts: [951: "Sun Aug 30 09:15:02 2026"])

        let result = await reconciler.sweep()

        #expect(result.recordsUnlinked == 0)
        #expect(result.foreignArtifactsLeftAlone == 1)
        #expect(Self.exists(ghost.recordPath), "a record TBD did not publish must never be unlinked")
        #expect(signaller.terminated.isEmpty)
        // Nothing is left to recognise, so the row retires rather than naming a
        // stranger's file forever.
        let remaining = try await store.all()
        #expect(remaining.isEmpty)
    }

    /// The socket half of the same rule. TBD created the path, but something is
    /// listening on it now, so it is no longer TBD's file — and unlinking a
    /// bound socket would delist whoever owns it.
    @Test func aSocketSomethingIsListeningOnIsNeverUnlinked() async throws {
        let directory = try Self.makeScratchDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let db = try TBDDatabase(inMemory: true)
        let store = db.shadowPeerArtifacts

        let ghost = try await Self.plant(
            directory: directory, store: store, pid: 960, handle: "remote-rebound")

        let signaller = FakeSignaller(alive: [])
        let bridge = FakeBridge(inventories: [
            ShadowPeerBridgeInventory(provider: "cloud", pidsByHandle: [:]),
        ])
        let probe = FakeProbe(listening: [ghost.socketPath])
        let reconciler = Self.makeReconciler(
            store: store, bridge: bridge, signaller: signaller, probe: probe)

        let result = await reconciler.sweep()

        #expect(result.socketsUnlinked == 0)
        #expect(result.foreignArtifactsLeftAlone == 1)
        #expect(Self.exists(ghost.socketPath))
        #expect(result.recordsUnlinked == 1)
    }

    /// An undecided probe is not a licence. The socket, and the row that names
    /// it, both survive for the next pass.
    @Test func anUndecidedProbeDefersTheWholeRow() async throws {
        let directory = try Self.makeScratchDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let db = try TBDDatabase(inMemory: true)
        let store = db.shadowPeerArtifacts

        let ghost = try await Self.plant(
            directory: directory, store: store, pid: 961, handle: "remote-unknown")

        let signaller = FakeSignaller(alive: [])
        let bridge = FakeBridge(inventories: [
            ShadowPeerBridgeInventory(provider: "cloud", pidsByHandle: [:]),
        ])
        let probe = FakeProbe(inconclusive: [ghost.socketPath])
        let reconciler = Self.makeReconciler(
            store: store, bridge: bridge, signaller: signaller, probe: probe)

        let result = await reconciler.sweep()

        #expect(result.deferred == 1)
        #expect(result.rowsForgotten == 0)
        #expect(Self.exists(ghost.socketPath))
        let remaining = try await store.all().map(\.pid)
        #expect(remaining == [961])
    }

    // MARK: - Undecided is its own answer

    /// **A live helper whose start time was never recorded is not a ghost.**
    ///
    /// The store deliberately records NULL when the kernel refuses the
    /// start-time read at publication, so "alive, and no recorded start time"
    /// is TBD's own running helper as often as it is anything else. Reading it
    /// as the recycled-pid case is the worst outcome this sweep can produce: no
    /// kill (correctly), and then the record path decodes the live helper's own
    /// record, finds the session id this very row published, and unlinks it —
    /// the shadow vanishes from every `ListAgents` while its socket keeps
    /// accepting and discarding. The socket then reads as somebody else's, the
    /// row is counted settled and retired, and one pass has destroyed live
    /// state *and* created an orphan nothing can recognise.
    @Test func aLiveHelperWithNoRecordedStartTimeIsLeftEntirelyAlone() async throws {
        let directory = try Self.makeScratchDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let db = try TBDDatabase(inMemory: true)
        let store = db.shadowPeerArtifacts

        let live = try await Self.plant(
            directory: directory, store: store, pid: 4242, handle: "remote-null-start",
            procStart: nil)

        // The link is up and publishing nothing — the remote session ended and
        // the manager has not caught up — which is the scenario that puts an
        // empty inventory in front of a live helper.
        let signaller = FakeSignaller(alive: [4242])
        let bridge = FakeBridge(inventories: [
            ShadowPeerBridgeInventory(provider: "cloud", pidsByHandle: [:]),
        ])
        let reconciler = Self.makeReconciler(
            store: store, bridge: bridge, signaller: signaller,
            procStarts: [4242: "Sat Aug 29 22:07:57 2026"])

        let result = await reconciler.sweep()

        #expect(result.deferred == 1)
        #expect(result.reclaimedArtifacts == 0)
        #expect(result.recordsUnlinked == 0)
        #expect(result.foreignArtifactsLeftAlone == 0,
                "an unprovable pid is undecided, never demonstrably somebody else's")
        #expect(signaller.terminated.isEmpty)
        #expect(signaller.forceKilled.isEmpty)
        #expect(Self.exists(live.recordPath),
                "the live helper's own record was unlinked out from under it")
        #expect(Self.exists(live.socketPath))
        let remaining = try await store.all().map(\.pid)
        #expect(remaining == [4242], "the row is the only recognition TBD has; it must survive")
    }

    /// The mirror image, and the same answer: the row has a start time but the
    /// kernel will not give one **now**. A comparison with a missing side
    /// proves nothing in either direction.
    @Test func aLivePIDTheKernelWillNotDateIsLeftEntirelyAlone() async throws {
        let directory = try Self.makeScratchDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let db = try TBDDatabase(inMemory: true)
        let store = db.shadowPeerArtifacts

        let live = try await Self.plant(
            directory: directory, store: store, pid: 4243, handle: "remote-undatable")

        let signaller = FakeSignaller(alive: [4243])
        let bridge = FakeBridge(inventories: [
            ShadowPeerBridgeInventory(provider: "cloud", pidsByHandle: [:]),
        ])
        // No entry for 4243: the read fails this time round.
        let reconciler = Self.makeReconciler(
            store: store, bridge: bridge, signaller: signaller, procStarts: [:])

        let result = await reconciler.sweep()

        #expect(result.deferred == 1)
        #expect(result.reclaimedArtifacts == 0)
        #expect(signaller.terminated.isEmpty)
        #expect(Self.exists(live.recordPath))
        #expect(Self.exists(live.socketPath))
        let remaining = try await store.all().map(\.pid)
        #expect(remaining == [4243])
    }

    /// A record TBD cannot read is not a record it has proved belongs to
    /// somebody else. Collapsing the two retires the row — the only entry
    /// naming the file — while leaving the file on disk, so nothing can ever
    /// recognise it again. The socket and the row both wait for the next pass.
    @Test func anUndecodableRecordDefersTheRowRatherThanRetiringIt() async throws {
        let directory = try Self.makeScratchDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let db = try TBDDatabase(inMemory: true)
        let store = db.shadowPeerArtifacts

        let ghost = try await Self.plant(
            directory: directory, store: store, pid: 962, handle: "remote-torn-record")
        // Whatever is at the recorded path now, it is not something this build
        // can decode — a truncated read, a half-written file, a schema change.
        try Data("not a shadow record".utf8)
            .write(to: URL(fileURLWithPath: ghost.recordPath))

        let signaller = FakeSignaller(alive: [])
        let bridge = FakeBridge(inventories: [
            ShadowPeerBridgeInventory(provider: "cloud", pidsByHandle: [:]),
        ])
        let reconciler = Self.makeReconciler(
            store: store, bridge: bridge, signaller: signaller)

        let result = await reconciler.sweep()

        #expect(result.deferred == 1)
        #expect(result.recordsUnlinked == 0)
        #expect(result.foreignArtifactsLeftAlone == 0,
                "unreadable is not proof of a recycled pid, and the log must not say it is")
        #expect(result.rowsForgotten == 0)
        #expect(result.socketsUnlinked == 0, "an undecided record settles nothing after it")
        #expect(Self.exists(ghost.recordPath))
        #expect(Self.exists(ghost.socketPath))
        let remaining = try await store.all().map(\.pid)
        #expect(remaining == [962])
    }

    // MARK: - The record's write-temps

    /// The fourth durable artifact. `ShadowPeerRecordStore` stages every record
    /// rewrite through a hidden `.<pid>.json.<uuid>.tmp` sibling and removes it
    /// only on its throwing paths, so a death between the write and the
    /// `rename(2)` strands one — and a shadow's record is rewritten on every
    /// status change, for its whole life. The leading dot keeps it out of every
    /// glob and the registry loader reads `<int>.json` and nothing else, so
    /// this sweep is the only thing that will ever collect one.
    @Test func aStrandedWriteTempIsReclaimedWithTheRecordItBelongsTo() async throws {
        let directory = try Self.makeScratchDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let db = try TBDDatabase(inMemory: true)
        let store = db.shadowPeerArtifacts

        let ghost = try await Self.plant(
            directory: directory, store: store, pid: 971, handle: "remote-torn-write")
        let first = Self.plantWriteTemp(directory: directory, forPID: 971)
        let second = Self.plantWriteTemp(directory: directory, forPID: 971)
        // A temp for a different record, in the same directory. The rule is
        // "this row's record path", never "anything shaped like a temp".
        let strangers = Self.plantWriteTemp(directory: directory, forPID: 972)

        let signaller = FakeSignaller(alive: [])
        let bridge = FakeBridge(inventories: [
            ShadowPeerBridgeInventory(provider: "cloud", pidsByHandle: [:]),
        ])
        let reconciler = Self.makeReconciler(
            store: store, bridge: bridge, signaller: signaller)

        let result = await reconciler.sweep()

        #expect(result.recordTemporariesUnlinked == 2)
        #expect(!Self.exists(first))
        #expect(!Self.exists(second))
        #expect(Self.exists(strangers))
        #expect(!Self.exists(ghost.recordPath))
        #expect(result.rowsForgotten == 1)
    }

    /// A helper this pass killed leaves its own stranded temp, and liveness is
    /// re-read after the kill so the same pass takes it back. Reusing the
    /// liveness read from before the kill would skip it and then retire the row
    /// that named it.
    @Test func aWriteTempTheSweepsOwnKillStrandedIsReclaimedInTheSamePass() async throws {
        let directory = try Self.makeScratchDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let db = try TBDDatabase(inMemory: true)
        let store = db.shadowPeerArtifacts

        try await Self.plant(
            directory: directory, store: store, pid: 973, handle: "remote-orphan-writer")
        let temp = Self.plantWriteTemp(directory: directory, forPID: 973)

        let signaller = FakeSignaller(alive: [973])
        let bridge = FakeBridge(inventories: [
            ShadowPeerBridgeInventory(provider: "cloud", pidsByHandle: [:]),
        ])
        let reconciler = Self.makeReconciler(
            store: store, bridge: bridge, signaller: signaller,
            procStarts: [973: "Sat Aug 29 22:07:57 2026"])

        let result = await reconciler.sweep()

        #expect(result.helpersKilled == 1)
        #expect(result.recordTemporariesUnlinked == 1)
        #expect(!Self.exists(temp))
    }

    /// A temp beside a pid somebody else now holds is left alone: that process
    /// can be halfway through the `rename(2)` this file is the source of, and
    /// unlinking it would tear a live session's record write in half.
    @Test func aWriteTempBesideAStrangersLivePIDIsLeftAlone() async throws {
        let directory = try Self.makeScratchDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let db = try TBDDatabase(inMemory: true)
        let store = db.shadowPeerArtifacts

        try await Self.plant(
            directory: directory, store: store, pid: 974, handle: "remote-recycled-writer",
            sessionID: "ours", recordSessionID: "someone-elses")
        let temp = Self.plantWriteTemp(directory: directory, forPID: 974)

        let signaller = FakeSignaller(alive: [974])
        let bridge = FakeBridge(inventories: [
            ShadowPeerBridgeInventory(provider: "cloud", pidsByHandle: [:]),
        ])
        let reconciler = Self.makeReconciler(
            store: store, bridge: bridge, signaller: signaller,
            procStarts: [974: "Sun Aug 30 09:15:02 2026"])

        let result = await reconciler.sweep()

        #expect(result.recordTemporariesUnlinked == 0)
        #expect(Self.exists(temp))
        #expect(signaller.terminated.isEmpty)
    }

    // MARK: - Never reclaim what nothing can vouch for

    /// A current-generation row whose provider no link answers for is left
    /// alone. Nothing can tell a live shadow from an orphan there, and the
    /// keep-favoring direction is the only safe one — a wiring gap must not
    /// present as a reaper that kills every live shadow on the machine.
    @Test func aRowIsLeftAloneWhenNothingVouchesForItsProvider() async throws {
        let directory = try Self.makeScratchDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let db = try TBDDatabase(inMemory: true)
        let store = db.shadowPeerArtifacts

        let shadow = try await Self.plant(
            directory: directory, store: store, pid: 970, handle: "remote-unvouched")

        let signaller = FakeSignaller(alive: [970])
        let reconciler = Self.makeReconciler(
            store: store, bridge: FakeBridge(), signaller: signaller,
            procStarts: [970: "Sat Aug 29 22:07:57 2026"])

        let result = await reconciler.sweep()

        #expect(result.unvouchedFor == 1)
        #expect(result.reclaimedArtifacts == 0)
        #expect(signaller.terminated.isEmpty)
        #expect(Self.exists(shadow.recordPath))
        #expect(Self.exists(shadow.socketPath))
        let remaining = try await store.all().map(\.pid)
        #expect(remaining == [970])
    }

    /// A row from a previous daemon generation needs no vouching at all: the
    /// daemon that published it is gone, and no link here is carrying it. This
    /// is the pass that runs at startup, and it is what stops a `SIGKILL`ed
    /// daemon's shadows outliving it forever.
    @Test func aPreviousGenerationRowIsReclaimedWithNoBridgeAtAll() async throws {
        let directory = try Self.makeScratchDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let db = try TBDDatabase(inMemory: true)
        let store = db.shadowPeerArtifacts

        let stale = try await Self.plant(
            directory: directory, store: store, pid: 980, handle: "remote-stale",
            generation: Self.previousGeneration, publishedAt: Self.sweepTime)

        // Its helper somehow survived the daemon that spawned it — stdin EOF is
        // the mechanism, and this is the case where the mechanism failed.
        let signaller = FakeSignaller(alive: [980])
        let reconciler = Self.makeReconciler(
            store: store, bridge: FakeBridge(), signaller: signaller,
            procStarts: [980: "Sat Aug 29 22:07:57 2026"])

        let result = await reconciler.sweep()

        #expect(result.helpersKilled == 1)
        #expect(signaller.terminated == [980])
        #expect(signaller.groupSignalled.isEmpty)
        #expect(!Self.exists(stale.recordPath))
        #expect(!Self.exists(stale.socketPath))
        let remaining = try await store.all()
        #expect(remaining.isEmpty)
    }

    /// A shadow published moments ago survives, even though no inventory names
    /// it yet. The row is written the instant its helper exists — before the
    /// manager has installed the shadow in the table an inventory is read from
    /// — so without this grace a sweep landing in that window would kill a
    /// seconds-old shadow.
    @Test func aShadowPublishedMomentsAgoIsNotReclaimed() async throws {
        let directory = try Self.makeScratchDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let db = try TBDDatabase(inMemory: true)
        let store = db.shadowPeerArtifacts

        let fresh = try await Self.plant(
            directory: directory, store: store, pid: 990, handle: "remote-fresh",
            publishedAt: Self.sweepTime)

        let signaller = FakeSignaller(alive: [990])
        let bridge = FakeBridge(inventories: [
            ShadowPeerBridgeInventory(provider: "cloud", pidsByHandle: [:]),
        ])
        let reconciler = Self.makeReconciler(
            store: store, bridge: bridge, signaller: signaller,
            procStarts: [990: "Sat Aug 29 22:07:57 2026"])

        let result = await reconciler.sweep()

        #expect(result.withinGrace == 1)
        #expect(result.reclaimedArtifacts == 0)
        #expect(signaller.terminated.isEmpty)
        #expect(Self.exists(fresh.recordPath))
        #expect(Self.exists(fresh.socketPath))
        let remaining = try await store.all().map(\.pid)
        #expect(remaining == [990])
    }

    /// A pid a link is using is never signalled, whichever row happens to name
    /// it — the belt to the handle check's braces, for the case where a stale
    /// row and a live shadow have collided on one recycled pid.
    @Test func aPIDALiveLinkIsUsingIsNeverSignalled() async throws {
        let directory = try Self.makeScratchDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let db = try TBDDatabase(inMemory: true)
        let store = db.shadowPeerArtifacts

        try await Self.plant(
            directory: directory, store: store, pid: 995, handle: "remote-old-handle")

        let signaller = FakeSignaller(alive: [995])
        let bridge = FakeBridge(inventories: [
            ShadowPeerBridgeInventory(provider: "cloud", pidsByHandle: ["remote-new-handle": 995]),
        ])
        let reconciler = Self.makeReconciler(
            store: store, bridge: bridge, signaller: signaller,
            procStarts: [995: "Sat Aug 29 22:07:57 2026"])

        let result = await reconciler.sweep()

        #expect(result.liveShadowsKept == 1)
        #expect(signaller.terminated.isEmpty)
        let remaining = try await store.all().map(\.pid)
        #expect(remaining == [995])
    }

    /// An empty whitelist is the ordinary state of every install that never
    /// turned the feature on. The sweep must do nothing at all — in particular
    /// it must not consult the process table or the filesystem on their behalf.
    @Test func anEmptyWhitelistReclaimsNothing() async throws {
        let db = try TBDDatabase(inMemory: true)
        let signaller = FakeSignaller(alive: [1])
        let reconciler = Self.makeReconciler(
            store: db.shadowPeerArtifacts, bridge: FakeBridge(), signaller: signaller)

        let result = await reconciler.sweep()

        #expect(result == ShadowPeerSweepResult())
        #expect(signaller.terminated.isEmpty)
        #expect(signaller.groupSignalled.isEmpty)
    }
}

// MARK: - The durable whitelist itself

/// `ShadowPeerArtifactStore` and the `shadow_peer_artifact` table
/// (`20260830022625_shadow_peer_artifacts`).
@Suite("ShadowPeerArtifactStore")
struct ShadowPeerArtifactStoreTests {

    @Test func theTableIsCreatedByTheMigration() async throws {
        let db = try TBDDatabase(inMemory: true)
        let exists = try await db.writerForTests.read { conn in
            try conn.tableExists("shadow_peer_artifact")
        }
        #expect(exists)
    }

    /// The recording path stamps what the bridge does not know: the generation,
    /// the kernel's start time for the helper, and when the row was written.
    @Test func recordingStampsTheGenerationAndTheKernelStartTime() async throws {
        let db = try TBDDatabase(inMemory: true)
        let published = Date(timeIntervalSince1970: 1_800_000_000)
        let store = ShadowPeerArtifactStore(
            writer: db.writerForTests,
            generation: "gen-7",
            procStart: { _ in "Sat Aug 29 22:07:57 2026" },
            now: { published })

        await store.recordPublished(
            provider: "cloud", handle: "remote-1", name: "cloud:fix-ci", pid: 4242,
            sessionID: "session-1", socketPath: "/tmp/cc-socks/4242.sock",
            recordPath: "/tmp/sessions/4242.json")

        let rows = try await store.all()
        #expect(rows == [ShadowPeerArtifact(
            pid: 4242, provider: "cloud", handle: "remote-1", name: "cloud:fix-ci",
            sessionID: "session-1", procStart: "Sat Aug 29 22:07:57 2026",
            socketPath: "/tmp/cc-socks/4242.sock", recordPath: "/tmp/sessions/4242.json",
            daemonGeneration: "gen-7", publishedAt: published)])
    }

    /// A kernel that refuses the start-time read leaves NULL rather than a
    /// fabricated value — the value the recycled-pid check exists to catch.
    @Test func anUnreadableStartTimeIsRecordedAsNothing() async throws {
        let db = try TBDDatabase(inMemory: true)
        let store = ShadowPeerArtifactStore(
            writer: db.writerForTests, generation: "gen-7", procStart: { _ in nil })

        await store.recordPublished(
            provider: "cloud", handle: "remote-1", name: "cloud:fix-ci", pid: 4242,
            sessionID: "session-1", socketPath: "/tmp/cc-socks/4242.sock",
            recordPath: "/tmp/sessions/4242.json")

        let rows = try await store.all()
        #expect(rows.first?.procStart == nil)
    }

    /// Re-recording the same pid replaces its row. A pid TBD has just spawned a
    /// helper under is one whose previous occupant is provably gone, and both
    /// file artifacts are named after the pid — so the new row names exactly
    /// the paths the old one did.
    @Test func recordingTheSamePIDTwiceReplacesTheRow() async throws {
        let db = try TBDDatabase(inMemory: true)
        let store = db.shadowPeerArtifacts

        try await store.upsert(ShadowPeerArtifact(
            pid: 4242, provider: "cloud", handle: "old", name: "cloud:old", sessionID: "s1",
            procStart: "start-1", socketPath: "/tmp/a.sock", recordPath: "/tmp/a.json",
            daemonGeneration: "gen-1", publishedAt: Date(timeIntervalSince1970: 1)))
        try await store.upsert(ShadowPeerArtifact(
            pid: 4242, provider: "cloud", handle: "new", name: "cloud:new", sessionID: "s2",
            procStart: "start-2", socketPath: "/tmp/b.sock", recordPath: "/tmp/b.json",
            daemonGeneration: "gen-2", publishedAt: Date(timeIntervalSince1970: 2)))

        let rows = try await store.all()
        #expect(rows.count == 1)
        #expect(rows.first?.handle == "new")
        #expect(rows.first?.daemonGeneration == "gen-2")
    }

    @Test func forgettingRetiresOnlyThatRow() async throws {
        let db = try TBDDatabase(inMemory: true)
        let store = db.shadowPeerArtifacts
        for pid in pid_t(10)...pid_t(12) {
            try await store.upsert(ShadowPeerArtifact(
                pid: pid, provider: "cloud", handle: "h-\(pid)", name: "n", sessionID: "s",
                procStart: nil, socketPath: "/tmp/\(pid).sock", recordPath: "/tmp/\(pid).json",
                daemonGeneration: "gen-1", publishedAt: Date(timeIntervalSince1970: 1)))
        }

        await store.forgetPublished(pid: 11)

        let remaining = try await store.all().map(\.pid)
        #expect(remaining == [10, 12])
    }
}
