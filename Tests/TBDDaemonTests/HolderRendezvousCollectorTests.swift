import Foundation
import Testing
@testable import TBDDaemonLib
import TBDShared

/// Tier 2: a real directory with real unix sockets, no `~/tbd`, no database, no
/// spawned process. The base, the clock and the listener probe are injected;
/// nothing here resolves a production path.
///
/// The sandbox is rooted directly under `/tmp` rather than under
/// `NSTemporaryDirectory()` for a mechanical reason: a socket path must fit
/// darwin's 104-byte `sun_path`, and `/var/folders/…/T/` plus two UUIDs does
/// not. It is removed in `deinit`.
@Suite("HolderRendezvousCollector")
struct HolderRendezvousCollectorTests: ~Copyable {
    let fm = FileManager.default
    let base: URL
    /// Fixed clock, far past every fixture's creation date, so the grace window
    /// has elapsed for anything the test does not deliberately make young.
    let clock = Date(timeIntervalSince1970: 1_800_000_000)
    /// The real GC default; the sweep uses `config.gcGraceSeconds`.
    let grace = Config.defaultGCGraceSeconds

    init() {
        base = URL(fileURLWithPath: "/tmp/tbd-hrdv-\(UUID().uuidString.prefix(8))", isDirectory: true)
        try? fm.createDirectory(at: base, withIntermediateDirectories: true)
    }

    deinit { try? fm.removeItem(at: base) }

    // MARK: - Fixtures

    /// The full residue of one dead holder: an abandoned socket plus the lock
    /// and log siblings `HolderLock` and `HolderSpawner` leave behind.
    @discardableResult
    private func makeDeadHolder(_ id: UUID, log: Bool = true, lock: Bool = true) -> [String] {
        var paths = [path(id, "sock")]
        #expect(HolderRendezvousFixture.bindAndAbandon(at: paths[0]))
        if lock {
            fm.createFile(atPath: path(id, "lock"), contents: Data())
            paths.append(path(id, "lock"))
        }
        if log {
            fm.createFile(atPath: path(id, "log"), contents: Data("holder: boom\n".utf8))
            paths.append(path(id, "log"))
        }
        return paths
    }

    private func path(_ id: UUID, _ ext: String) -> String {
        base.appendingPathComponent("\(id.uuidString.lowercased()).\(ext)").path
    }

    private func makeCollector(
        now: Date? = nil,
        isListening: (@Sendable (String) async -> Bool)? = nil
    ) -> HolderRendezvousCollector {
        let fixed = now ?? clock
        return HolderRendezvousCollector(
            base: base, now: { fixed },
            isListening: isListening ?? HolderRendezvousCollector.probeForListener)
    }

    /// A candidate for `id`, built the way `candidates()` builds one, with its
    /// age forced. Used only where a test needs to reach `decide` without
    /// waiting an hour of wall time.
    private func candidate(_ id: UUID, createdAt: Date?) -> HolderRendezvousCandidate {
        HolderRendezvousCandidate(
            sessionID: id, socketPath: path(id, "sock"), createdAt: createdAt)
    }

    // MARK: - Enumeration

    @Test func candidatesAreSocketsNamedForASession() {
        let live = UUID()
        makeDeadHolder(live)
        // A lock and a log with no socket is not a *socket* candidate — the
        // socket is what this arm decides on. It is the socket-less arm's
        // business, under `orphanPairCandidates()` below.
        let lonely = UUID()
        fm.createFile(atPath: path(lonely, "lock"), contents: Data())
        fm.createFile(atPath: path(lonely, "log"), contents: Data())
        // Names that do not parse as a session.
        fm.createFile(atPath: base.appendingPathComponent("notes.sock").path, contents: Data())
        fm.createFile(atPath: base.appendingPathComponent(".DS_Store").path, contents: Data())
        try? fm.createDirectory(
            at: base.appendingPathComponent("\(UUID().uuidString.lowercased()).sock"),
            withIntermediateDirectories: true)

        let found = makeCollector().candidates()
        #expect(found.map(\.sessionID) == [live])
        #expect(found.first?.createdAt != nil, "a socket the collector just made must have an age")
    }

    @Test func missingBaseYieldsNoCandidates() {
        let fixed = clock
        let collector = HolderRendezvousCollector(
            base: base.appendingPathComponent("nope", isDirectory: true),
            now: { fixed }, isListening: { _ in false })
        #expect(collector.candidates().isEmpty)
    }

    // MARK: - Gates

    /// **The discriminating grace test.** `OrphanGC` runs on demand from RPC
    /// handlers, so a sweep can land between a holder binding its socket and
    /// the rest of creation committing. A young socket is kept even though
    /// nothing is listening on it — which is exactly what a socket that has
    /// just been bound by a holder still starting up looks like from here.
    @Test func aYoungSocketIsKeptEvenWithNoListener() async throws {
        let id = UUID()
        makeDeadHolder(id)
        let collector = makeCollector()

        // One second old against the collector's clock: inside the window.
        let fresh = candidate(id, createdAt: clock.addingTimeInterval(-1))
        #expect(await collector.decide(fresh, graceSeconds: grace) == .keep(reason: "grace"))

        // The same abandoned socket past the window IS reaped — so the keep
        // above is the grace gate deciding, not some other gate refusing.
        let old = candidate(id, createdAt: clock.addingTimeInterval(-Double(grace) - 1))
        #expect(await collector.decide(old, graceSeconds: grace) == .reap)
        #expect(fm.fileExists(atPath: path(id, "sock")), "decide must not touch anything")
    }

    @Test func anUnreadableAgeKeeps() async {
        let id = UUID()
        makeDeadHolder(id)
        let decision = await makeCollector().decide(
            candidate(id, createdAt: nil), graceSeconds: grace)
        #expect(decision == .keep(reason: "unknown-age"))
    }

    /// A held `flock` means a live holder or a spawner mid-flight. Unlinking
    /// the lock there is the hazard `HolderLock` documents: a racing spawner
    /// would create and lock a *different* file at the same path.
    @Test func aHeldLockKeeps() async throws {
        let id = UUID()
        makeDeadHolder(id)
        let lock = try HolderLock.acquire(path: path(id, "lock"))
        defer { lock.release() }
        let collector = makeCollector()
        #expect(collector.lockIsHeld(sessionID: id))
        let decision = await collector.decide(
            candidate(id, createdAt: .distantPast), graceSeconds: grace)
        #expect(decision == .keep(reason: "lock-held"))
    }

    @Test func aFreeLockDoesNotKeep() async {
        let id = UUID()
        makeDeadHolder(id)
        #expect(makeCollector().lockIsHeld(sessionID: id) == false)
    }

    /// The lock probe must never create the file it probes: `O_CREAT` here
    /// would materialise a lock for a session that has none and then sweep it,
    /// and would make "no lock file" indistinguishable from "lock free".
    @Test func probingAMissingLockCreatesNothing() {
        let id = UUID()
        #expect(makeCollector().lockIsHeld(sessionID: id) == false)
        #expect(fm.fileExists(atPath: path(id, "lock")) == false)
    }

    /// A socket with a real listener behind it is kept. Uses the production
    /// probe against a real listening socket, so it exercises the same connect
    /// the daemon makes rather than a stub's opinion of it.
    @Test func aListeningSocketIsKept() async throws {
        let id = UUID()
        let fd = try #require(HolderRendezvousFixture.bind(at: path(id, "sock"), listening: true))
        defer { close(fd) }
        let decision = await makeCollector().decide(
            candidate(id, createdAt: .distantPast), graceSeconds: grace)
        #expect(decision == .keep(reason: "listening"))
    }

    // MARK: - Reap

    /// **The discriminating sweep test.** An abandoned socket, its lock and its
    /// log are all gone from disk afterwards. Asserted on the filesystem, not
    /// on a return value — the leak the harness measured was `sock exists=False
    /// lock exists=True holder log exists=True`.
    @Test func reapUnlinksTheSocketAndBothSiblings() async {
        let id = UUID()
        let paths = makeDeadHolder(id)
        #expect(paths.allSatisfy { fm.fileExists(atPath: $0) })

        let collector = makeCollector()
        let target = candidate(id, createdAt: .distantPast)
        #expect(await collector.decide(target, graceSeconds: grace) == .reap)
        let removed = collector.reap(target)

        #expect(Set(removed) == Set(paths))
        for path in paths {
            #expect(fm.fileExists(atPath: path) == false, "\(path) survived the sweep")
        }
    }

    /// A holder that bound but never wrote a log leaves two files, not three.
    /// A missing sibling is not a failure.
    @Test func reapToleratesAMissingSibling() {
        let id = UUID()
        let paths = makeDeadHolder(id, log: false)
        let removed = makeCollector().reap(candidate(id, createdAt: .distantPast))
        #expect(Set(removed) == Set(paths))
        #expect(fm.fileExists(atPath: path(id, "sock")) == false)
    }

    /// The anchor guard. `HolderRendezvousCandidate` is a public value type
    /// anyone can construct, so a path that is not a `<uuid>.sock` immediate
    /// child of the base is refused rather than trusted this close to `unlink`.
    @Test func reapRefusesAnUnanchoredCandidate() {
        let id = UUID()
        let outside = base.appendingPathComponent("nested", isDirectory: true)
        try? fm.createDirectory(at: outside, withIntermediateDirectories: true)
        let victim = outside.appendingPathComponent("\(id.uuidString.lowercased()).sock").path
        fm.createFile(atPath: victim, contents: Data())
        // Also a file in the right place under the wrong name.
        makeDeadHolder(id)

        let collector = makeCollector()
        #expect(collector.reap(
            HolderRendezvousCandidate(sessionID: id, socketPath: victim, createdAt: .distantPast)
        ).isEmpty)
        #expect(fm.fileExists(atPath: victim), "an unanchored path must be left alone")
        #expect(
            collector.reap(HolderRendezvousCandidate(
                sessionID: id,
                socketPath: base.appendingPathComponent("elsewhere.sock").path,
                createdAt: .distantPast)).isEmpty,
            "a name that is not <sessionID>.sock must be refused even inside the base")
        #expect(fm.fileExists(atPath: path(id, "sock")), "the refusal must not unlink by UUID alone")
    }

    // MARK: - The socket-less arm

    /// The residue of a holder whose socket is already gone: a lock and a log
    /// with nothing to anchor them. This is the shape that accumulated 557
    /// pairs against 53 live sockets before the second arm existed.
    @discardableResult
    private func makeOrphanPair(_ id: UUID, log: Bool = true, lock: Bool = true) -> [String] {
        var paths: [String] = []
        if lock {
            fm.createFile(atPath: path(id, "lock"), contents: Data())
            paths.append(path(id, "lock"))
        }
        if log {
            fm.createFile(atPath: path(id, "log"), contents: Data("holder: killed\n".utf8))
            paths.append(path(id, "log"))
        }
        return paths
    }

    /// A pair for `id` with its age forced, built the way
    /// `orphanPairCandidates()` builds one.
    private func pair(_ id: UUID, createdAt: Date?) -> HolderRendezvousOrphanPair {
        HolderRendezvousOrphanPair(
            sessionID: id, lockPath: path(id, "lock"), createdAt: createdAt)
    }

    @Test func orphanPairCandidatesAreTheSocketlessSessions() {
        let orphan = UUID()
        makeOrphanPair(orphan)
        // A session whose socket is still on disk belongs to the socket arm,
        // whatever its lock and log look like.
        let withSocket = UUID()
        makeDeadHolder(withSocket)
        // A log with no lock is still residue nothing else reclaims.
        let logOnly = UUID()
        makeOrphanPair(logOnly, lock: false)
        // Names that do not parse as a session, and a directory wearing one.
        fm.createFile(atPath: base.appendingPathComponent("notes.lock").path, contents: Data())
        try? fm.createDirectory(
            at: base.appendingPathComponent("\(UUID().uuidString.lowercased()).log"),
            withIntermediateDirectories: true)

        let found = makeCollector().orphanPairCandidates()
        #expect(Set(found.map(\.sessionID)) == Set([orphan, logOnly]))
        #expect(found.allSatisfy { $0.createdAt != nil },
                "files the collector just made must have an age")
    }

    @Test func missingBaseYieldsNoOrphanPairs() {
        let fixed = clock
        let collector = HolderRendezvousCollector(
            base: base.appendingPathComponent("nope", isDirectory: true),
            now: { fixed }, isListening: { _ in false })
        #expect(collector.orphanPairCandidates().isEmpty)
    }

    /// The newest file in the pair decides its age, so a week-old lock beside a
    /// log written a second ago is kept — the keep-biased reading of "has
    /// anything recent happened under this UUID".
    @Test func anOrphanPairIsAsYoungAsItsNewestFile() throws {
        let id = UUID()
        makeOrphanPair(id)
        try fm.setAttributes([.creationDate: clock.addingTimeInterval(-604_800)],
                             ofItemAtPath: path(id, "lock"))
        try fm.setAttributes([.creationDate: clock.addingTimeInterval(-1)],
                             ofItemAtPath: path(id, "log"))

        let found = try #require(makeCollector().orphanPairCandidates().first)
        let created = try #require(found.createdAt)
        #expect(clock.timeIntervalSince(created) < 60,
                "the newest file must decide the pair's age, not the oldest")
        #expect(makeCollector().decideOrphanPair(
            found, graceSeconds: grace, claimedSessionIDs: []) == .keep(reason: "grace"))
    }

    /// The grace gate, with its discriminating half: the same pair past the
    /// window is reaped, so the keep is the age deciding and not another gate.
    @Test func aYoungOrphanPairIsKept() {
        let id = UUID()
        let paths = makeOrphanPair(id)
        let collector = makeCollector()

        #expect(collector.decideOrphanPair(
            pair(id, createdAt: clock.addingTimeInterval(-1)),
            graceSeconds: grace, claimedSessionIDs: []) == .keep(reason: "grace"))
        #expect(collector.decideOrphanPair(
            pair(id, createdAt: clock.addingTimeInterval(-Double(grace) - 1)),
            graceSeconds: grace, claimedSessionIDs: []) == .reap)
        #expect(paths.allSatisfy { fm.fileExists(atPath: $0) }, "decide must not touch anything")
    }

    @Test func anUnreadableOrphanPairAgeKeeps() {
        let id = UUID()
        makeOrphanPair(id)
        #expect(makeCollector().decideOrphanPair(
            pair(id, createdAt: nil), graceSeconds: grace, claimedSessionIDs: [])
            == .keep(reason: "unknown-age"))
    }

    /// The row gate — the one that makes this arm safe rather than merely
    /// cautious. Creation commits the session row before the holder becomes
    /// discoverable, so a pair whose session still has a row may belong to a
    /// spawn in flight; one with no row names a UUID no spawner will take that
    /// lock for again.
    @Test func anOrphanPairWhoseSessionHasARowIsKept() {
        let id = UUID()
        makeOrphanPair(id)
        let collector = makeCollector()
        let target = pair(id, createdAt: .distantPast)

        #expect(collector.decideOrphanPair(
            target, graceSeconds: grace, claimedSessionIDs: [id]) == .keep(reason: "has-row"))
        #expect(collector.decideOrphanPair(
            target, graceSeconds: grace, claimedSessionIDs: [UUID()]) == .reap,
            "some other session's row must not keep this pair")
    }

    /// A held `flock` is a live holder or a spawner mid-flight. Unlinking the
    /// lock there is the hazard `HolderLock` documents: a racing spawner would
    /// create and lock a *different* file at the same path.
    @Test func aHeldLockKeepsTheOrphanPair() throws {
        let id = UUID()
        makeOrphanPair(id)
        let collector = makeCollector()
        let target = pair(id, createdAt: .distantPast)
        do {
            let lock = try HolderLock.acquire(path: path(id, "lock"))
            defer { lock.release() }
            #expect(collector.decideOrphanPair(
                target, graceSeconds: grace, claimedSessionIDs: []) == .keep(reason: "lock-held"))
        }
        #expect(collector.decideOrphanPair(
            target, graceSeconds: grace, claimedSessionIDs: []) == .reap,
            "the same pair with the lock released is reaped")
    }

    /// **The in-flight spawn case, with the grace window configured away.** A
    /// new session's holder is spawned before its row is written, so mid-spawn
    /// a UUID has a lock, a log and no row — and `gcGraceSeconds` has no floor,
    /// so the age gate cannot be what saves it. The creation lock is: the
    /// spawner holds it from before the log exists until the holder dies.
    @Test func aRowlessSpawnInFlightIsKeptWithNoGraceWindow() throws {
        let id = UUID()
        makeOrphanPair(id)
        let collector = makeCollector()
        let target = pair(id, createdAt: clock)
        do {
            let lock = try HolderLock.acquire(path: path(id, "lock"))
            defer { lock.release() }
            #expect(collector.decideOrphanPair(
                target, graceSeconds: 0, claimedSessionIDs: []) == .keep(reason: "lock-held"))
        }
        #expect(collector.decideOrphanPair(
            target, graceSeconds: 0, claimedSessionIDs: []) == .reap,
            "with the lock released and no grace window the same pair is reaped, so the keep above is the lock deciding")
    }

    @Test func reapOrphanPairUnlinksTheLockAndTheLog() {
        let id = UUID()
        let paths = makeOrphanPair(id)
        let removed = makeCollector().reapOrphanPair(pair(id, createdAt: .distantPast))
        #expect(Set(removed) == Set(paths))
        #expect(paths.allSatisfy { fm.fileExists(atPath: $0) == false })
    }

    /// The late gate. The gates ran against one listing; a spawner that bound a
    /// socket since then owns this UUID, and its lock is not ours to unlink —
    /// nor is the socket this arm has no verdict on.
    @Test func reapOrphanPairRefusesOnceASocketExists() {
        let id = UUID()
        let paths = makeOrphanPair(id)
        #expect(HolderRendezvousFixture.bindAndAbandon(at: path(id, "sock")))

        #expect(makeCollector().reapOrphanPair(pair(id, createdAt: .distantPast)).isEmpty)
        #expect(paths.allSatisfy { fm.fileExists(atPath: $0) })
        #expect(fm.fileExists(atPath: path(id, "sock")),
                "this arm must never unlink a socket")
    }

    /// The anchor guard, as on the socket arm: `HolderRendezvousOrphanPair` is
    /// a public value type anyone can construct.
    @Test func reapOrphanPairRefusesAnUnanchoredPair() {
        let id = UUID()
        let outside = base.appendingPathComponent("nested", isDirectory: true)
        try? fm.createDirectory(at: outside, withIntermediateDirectories: true)
        let victim = outside.appendingPathComponent("\(id.uuidString.lowercased()).lock").path
        fm.createFile(atPath: victim, contents: Data())
        let paths = makeOrphanPair(id)

        let collector = makeCollector()
        #expect(collector.reapOrphanPair(HolderRendezvousOrphanPair(
            sessionID: id, lockPath: victim, createdAt: .distantPast)).isEmpty)
        #expect(fm.fileExists(atPath: victim), "an unanchored path must be left alone")
        #expect(collector.reapOrphanPair(HolderRendezvousOrphanPair(
            sessionID: id,
            lockPath: base.appendingPathComponent("elsewhere.lock").path,
            createdAt: .distantPast)).isEmpty,
            "a name that is not <sessionID>.lock must be refused even inside the base")
        #expect(paths.allSatisfy { fm.fileExists(atPath: $0) },
                "the refusal must not unlink by UUID alone")
    }
}
