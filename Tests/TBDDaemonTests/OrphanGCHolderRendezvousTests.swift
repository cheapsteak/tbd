import Foundation
import Testing
@testable import TBDDaemonLib
import TBDShared
import TestSupport

/// Tier 2: a real rendezvous directory with real unix sockets plus an in-memory
/// database. The holders base, the profiles base, the scratchpad base and the
/// clock are all injected; nothing here resolves a production path and no
/// process is spawned.
///
/// Rooted under `TBD_TEST_SCRATCH_ROOT` — itself a short path directly under
/// `/tmp`, so the socket paths fit darwin's 104-byte `sun_path` — which is what
/// the wrapper's EXIT trap reclaims when a run is killed part-way. `deinit`
/// removes it on every ordinary path.
@Suite("OrphanGC sweeps holder rendezvous files")
struct OrphanGCHolderRendezvousTests: ~Copyable {
    let fm = FileManager.default
    let sandbox: URL
    let holdersBase: URL
    let clock = Date(timeIntervalSince1970: 1_800_000_000)

    init() {
        sandbox = URL(fileURLWithPath: fencedScratchRoot(prefix: "tbd-gchr"), isDirectory: true)
        holdersBase = sandbox.appendingPathComponent("h", isDirectory: true)
        try? fm.createDirectory(at: holdersBase, withIntermediateDirectories: true)
    }

    deinit { try? fm.removeItem(at: sandbox) }

    // MARK: - Fixtures

    private func path(_ id: UUID, _ ext: String) -> String {
        holdersBase.appendingPathComponent("\(id.uuidString.lowercased()).\(ext)").path
    }

    /// One dead holder's residue, backdated so the GC grace window has elapsed
    /// against this suite's fixed clock.
    @discardableResult
    private func makeDeadHolder(_ id: UUID, age: TimeInterval = 86_400) -> [String] {
        let paths = [path(id, "sock"), path(id, "lock"), path(id, "log")]
        #expect(HolderRendezvousFixture.bindAndAbandon(at: paths[0]))
        fm.createFile(atPath: paths[1], contents: Data())
        fm.createFile(atPath: paths[2], contents: Data("holder: killed\n".utf8))
        let created = clock.addingTimeInterval(-age)
        for path in paths {
            try? fm.setAttributes([.creationDate: created, .modificationDate: created],
                                  ofItemAtPath: path)
        }
        return paths
    }

    private func makeGC(db: TBDDatabase) -> OrphanGC {
        let fixed = clock
        return OrphanGC(
            db: db, git: GitManager(),
            broadcast: { _ in },
            liveCWDsProvider: { [] },
            scratchpadBase: sandbox.appendingPathComponent("s", isDirectory: true),
            now: { fixed },
            profileDirBase: sandbox.appendingPathComponent("p", isDirectory: true),
            holdersBase: holdersBase
        )
    }

    // MARK: - The gate

    /// **The discriminating sweep test.** A socket with no listening process
    /// behind it, plus its lock and log siblings, is gone from disk after one
    /// sweep — on an untouched config, because holder-ness is a transport
    /// property rather than a separate opt-in and this arm runs under
    /// `gcEnabled` like the agent-worktree loop. Asserted on the filesystem:
    /// the measured leak was `sock exists=False lock exists=True holder log
    /// exists=True` on every teardown path, forever, because nothing reclaimed
    /// them.
    @Test func aSweepUnlinksTheWholeTriple() async throws {
        let db = try TBDDatabase(inMemory: true)
        #expect(try await db.config.get().gcEnabled, "GC ships on; this test rides that default")
        let id = UUID()
        let paths = makeDeadHolder(id)

        let result = await makeGC(db: db).sweep()

        for path in paths {
            #expect(fm.fileExists(atPath: path) == false, "\(path) survived the sweep")
        }
        #expect(result.planned.contains("REAP holder-rendezvous \(path(id, "sock"))"))
        #expect(result.reaped >= 1)
    }

    /// The off branch of the derived condition: the GC master switch off leaves
    /// the same fixture completely alone, and the sweep does not even plan it.
    @Test func aSweepWithGCDisabledTouchesNothing() async throws {
        let db = try TBDDatabase(inMemory: true)
        try await db.config.setGCEnabled(false)
        let id = UUID()
        let paths = makeDeadHolder(id)

        let result = await makeGC(db: db).sweep()

        for path in paths {
            #expect(fm.fileExists(atPath: path), "\(path) was swept with GC disabled")
        }
        #expect(result.planned.contains { $0.contains("holder-rendezvous") } == false)
    }

    /// `dryRun` bypasses `gcEnabled` here exactly as it does everywhere else:
    /// someone deciding whether to turn GC on needs to see what it would
    /// reclaim first. It plans and touches nothing.
    @Test func aDryRunPlansWithGCDisabledAndUnlinksNothing() async throws {
        let db = try TBDDatabase(inMemory: true)
        try await db.config.setGCEnabled(false)
        let id = UUID()
        let paths = makeDeadHolder(id)

        let result = await makeGC(db: db).sweep(dryRun: true)

        #expect(result.planned.contains("REAP holder-rendezvous \(path(id, "sock"))"))
        #expect(result.reaped == 0)
        #expect(paths.allSatisfy { fm.fileExists(atPath: $0) },
                "a dry run must never touch disk")
    }

    /// The keep-biased young-holder guard, through the real sweep: a socket
    /// inside the grace window survives a live sweep. This is the guard that
    /// stops an on-demand reconcile from destroying a session being born.
    @Test func aYoungHolderSurvivesASweep() async throws {
        let db = try TBDDatabase(inMemory: true)
        let young = UUID()
        let old = UUID()
        let youngPaths = makeDeadHolder(young, age: 60)
        let oldPaths = makeDeadHolder(old, age: 86_400)

        let result = await makeGC(db: db).sweep()

        #expect(youngPaths.allSatisfy { fm.fileExists(atPath: $0) },
                "a socket inside the grace window must be left alone")
        #expect(oldPaths.allSatisfy { fm.fileExists(atPath: $0) == false },
                "a socket past the window in the same sweep must be reaped")
        #expect(result.planned.contains("KEEP grace \(path(young, "sock"))"))
    }

    // MARK: - The socket-less arm

    /// A lock and a log with no socket beside them — what a holder that exited
    /// cleanly enough to unlink its own socket leaves behind, and what an
    /// earlier sweep's socket reap leaves if it stopped at the socket.
    @discardableResult
    private func makeOrphanPair(_ id: UUID, age: TimeInterval = 86_400) -> [String] {
        let paths = [path(id, "lock"), path(id, "log")]
        fm.createFile(atPath: paths[0], contents: Data())
        fm.createFile(atPath: paths[1], contents: Data("holder: killed\n".utf8))
        let created = clock.addingTimeInterval(-age)
        for path in paths {
            try? fm.setAttributes([.creationDate: created, .modificationDate: created],
                                  ofItemAtPath: path)
        }
        return paths
    }

    /// A holder session row, so a test can give a pair an owner. Returns the
    /// row's id, which is the session id the rendezvous files are named for.
    private func makeHolderRow(_ db: TBDDatabase) async throws -> UUID {
        let repo = try await db.repos.create(
            path: sandbox.appendingPathComponent("repo").path, displayName: "R",
            defaultBranch: "main")
        let worktree = try await db.worktrees.create(
            repoID: repo.id, name: "w", branch: "b",
            path: sandbox.appendingPathComponent("wt").path, tmuxServer: "tbd-gchr")
        let terminal = try await db.terminals.create(
            worktreeID: worktree.id, tmuxWindowID: "@1", tmuxPaneID: "%1",
            transport: .holder, holderPID: 4241, childPID: 4242)
        return terminal.id
    }

    /// **The discriminating sweep test for the second arm.** The pair is gone
    /// after one sweep, on an untouched config — the leak the field measurement
    /// found was 557 such pairs against 53 live sockets, surviving every sweep
    /// because the socket arm has no socket to decide on.
    @Test func aSweepUnlinksAnOrphanPair() async throws {
        let db = try TBDDatabase(inMemory: true)
        let id = UUID()
        let paths = makeOrphanPair(id)

        let result = await makeGC(db: db).sweep()

        for path in paths {
            #expect(fm.fileExists(atPath: path) == false, "\(path) survived the sweep")
        }
        #expect(result.planned.contains("REAP holder-rendezvous-pair \(path(id, "lock"))"))
        #expect(result.reaped >= 1)
    }

    /// A session whose row still exists may be spawning right now: creation
    /// commits the row before the holder becomes discoverable, so the row is
    /// what bounds this arm.
    @Test func anOrphanPairWhoseSessionHasARowSurvivesASweep() async throws {
        let db = try TBDDatabase(inMemory: true)
        let claimed = try await makeHolderRow(db)
        let claimedPaths = makeOrphanPair(claimed)
        let orphan = UUID()
        let orphanPaths = makeOrphanPair(orphan)

        let result = await makeGC(db: db).sweep()

        #expect(claimedPaths.allSatisfy { fm.fileExists(atPath: $0) },
                "a pair whose session row exists must be left alone")
        #expect(orphanPaths.allSatisfy { fm.fileExists(atPath: $0) == false },
                "a row-less pair in the same sweep must be reaped")
        #expect(result.planned.contains("KEEP has-row \(path(claimed, "lock"))"))
    }

    /// A held lock is a live holder or a spawner mid-flight, and unlinking it
    /// would let a racing spawner lock a different file at the same path. This
    /// is the row-less in-flight spawn as the sweep sees it: a new session's
    /// holder is spawned before its row is written, and here the pair is past
    /// the grace window too, so the lock is the only gate left to keep it.
    @Test func aHeldLockKeepsAnOrphanPairThroughASweep() async throws {
        let db = try TBDDatabase(inMemory: true)
        let id = UUID()
        let paths = makeOrphanPair(id)
        let lock = try HolderLock.acquire(path: path(id, "lock"))
        defer { lock.release() }

        let result = await makeGC(db: db).sweep()

        #expect(paths.allSatisfy { fm.fileExists(atPath: $0) },
                "a pair whose lock somebody holds must be left alone")
        #expect(result.planned.contains("KEEP lock-held \(path(id, "lock"))"))
    }

    /// The keep-biased young-pair guard: a sweep can land between a spawner
    /// creating the lock and the holder binding its socket.
    @Test func aYoungOrphanPairSurvivesASweep() async throws {
        let db = try TBDDatabase(inMemory: true)
        let young = UUID()
        let old = UUID()
        let youngPaths = makeOrphanPair(young, age: 60)
        let oldPaths = makeOrphanPair(old, age: 86_400)

        let result = await makeGC(db: db).sweep()

        #expect(youngPaths.allSatisfy { fm.fileExists(atPath: $0) },
                "a pair inside the grace window must be left alone")
        #expect(oldPaths.allSatisfy { fm.fileExists(atPath: $0) == false },
                "a pair past the window in the same sweep must be reaped")
        #expect(result.planned.contains("KEEP grace \(path(young, "lock"))"))
    }

    /// A session whose socket is still on disk belongs to the socket arm, which
    /// has an anchor this one does not. The triple is reclaimed there, and the
    /// socket-less arm has no opinion to offer about it.
    @Test func aPairWithASocketIsLeftToTheSocketArm() async throws {
        let db = try TBDDatabase(inMemory: true)
        let id = UUID()
        let paths = makeDeadHolder(id)

        let result = await makeGC(db: db).sweep()

        for path in paths {
            #expect(fm.fileExists(atPath: path) == false, "\(path) survived the sweep")
        }
        #expect(result.planned.contains("REAP holder-rendezvous \(path(id, "sock"))"))
        #expect(result.planned.contains { $0.hasPrefix("REAP holder-rendezvous-pair") } == false,
                "the socket-less arm must not claim a session that still has a socket")
    }

    /// The off branch of the derived condition: this arm rides `gc_enabled`
    /// with no flag of its own, so the master switch off leaves the pair alone
    /// and does not even plan it.
    @Test func anOrphanPairSurvivesWithGCDisabled() async throws {
        let db = try TBDDatabase(inMemory: true)
        try await db.config.setGCEnabled(false)
        let id = UUID()
        let paths = makeOrphanPair(id)

        let result = await makeGC(db: db).sweep()

        for path in paths {
            #expect(fm.fileExists(atPath: path), "\(path) was swept with GC disabled")
        }
        #expect(result.planned.contains { $0.contains("holder-rendezvous-pair") } == false)
    }

    /// `dryRun` bypasses `gcEnabled` here exactly as it does for the socket
    /// arm: it plans the reclamation and touches nothing.
    @Test func aDryRunPlansAnOrphanPairAndUnlinksNothing() async throws {
        let db = try TBDDatabase(inMemory: true)
        try await db.config.setGCEnabled(false)
        let id = UUID()
        let paths = makeOrphanPair(id)

        let result = await makeGC(db: db).sweep(dryRun: true)

        #expect(result.planned.contains("REAP holder-rendezvous-pair \(path(id, "lock"))"))
        #expect(result.reaped == 0)
        #expect(paths.allSatisfy { fm.fileExists(atPath: $0) },
                "a dry run must never touch disk")
    }
}
