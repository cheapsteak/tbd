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
}
