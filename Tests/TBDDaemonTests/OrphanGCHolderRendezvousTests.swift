import Foundation
import Testing
@testable import TBDDaemonLib
import TBDShared

/// Tier 2: a real rendezvous directory with real unix sockets plus an in-memory
/// database. The holders base, the profiles base, the scratchpad base and the
/// clock are all injected; nothing here resolves a production path and no
/// process is spawned.
///
/// Rooted directly under `/tmp` so the socket paths fit darwin's 104-byte
/// `sun_path`; removed in `deinit`.
@Suite("OrphanGC sweeps holder rendezvous files")
struct OrphanGCHolderRendezvousTests: ~Copyable {
    let fm = FileManager.default
    let sandbox: URL
    let holdersBase: URL
    let clock = Date(timeIntervalSince1970: 1_800_000_000)

    init() {
        sandbox = URL(
            fileURLWithPath: "/tmp/tbd-gchr-\(UUID().uuidString.prefix(8))", isDirectory: true)
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
    /// sweep. Asserted on the filesystem: the measured leak was `sock
    /// exists=False lock exists=True holder log exists=True` on every teardown
    /// path, forever, because nothing reclaimed them.
    @Test func aSweepWithTheFlagOnUnlinksTheWholeTriple() async throws {
        let db = try TBDDatabase(inMemory: true)
        try await db.config.setGCHolderRendezvousEnabled(true)
        let id = UUID()
        let paths = makeDeadHolder(id)

        let result = await makeGC(db: db).sweep()

        for path in paths {
            #expect(fm.fileExists(atPath: path) == false, "\(path) survived the sweep")
        }
        #expect(result.planned.contains("REAP holder-rendezvous \(path(id, "sock"))"))
        #expect(result.reaped >= 1)
    }

    /// The off branch of the gate — the state every install ships in. The same
    /// fixture the test above reaps is left completely alone, and the sweep does
    /// not even plan it.
    @Test func aSweepWithTheFlagOffTouchesNothing() async throws {
        let db = try TBDDatabase(inMemory: true)
        #expect(try await db.config.get().gcHolderRendezvousEnabled == false,
                "the shipped default must be off")
        let id = UUID()
        let paths = makeDeadHolder(id)

        let result = await makeGC(db: db).sweep()

        for path in paths {
            #expect(fm.fileExists(atPath: path), "\(path) was swept with the flag off")
        }
        #expect(result.planned.contains { $0.contains("holder-rendezvous") } == false)
    }

    /// An explicit `false` is the same as never having chosen, for behavior.
    @Test func anExplicitOptOutTouchesNothing() async throws {
        let db = try TBDDatabase(inMemory: true)
        try await db.config.setGCHolderRendezvousEnabled(false)
        let id = UUID()
        let paths = makeDeadHolder(id)
        _ = await makeGC(db: db).sweep()
        #expect(paths.allSatisfy { fm.fileExists(atPath: $0) })
    }

    /// The GC master switch is read on top of the phase flag: both must be on.
    @Test func theMasterSwitchStillGovernsThePhase() async throws {
        let db = try TBDDatabase(inMemory: true)
        try await db.config.setGCHolderRendezvousEnabled(true)
        try await db.config.setGCEnabled(false)
        let id = UUID()
        let paths = makeDeadHolder(id)
        _ = await makeGC(db: db).sweep()
        #expect(paths.allSatisfy { fm.fileExists(atPath: $0) })
    }

    /// `dryRun` bypasses the flag, exactly as it bypasses `gcEnabled`: someone
    /// deciding whether to turn a default-off flag on needs to see what it
    /// would reclaim first. It plans and touches nothing.
    @Test func aDryRunPlansWithTheFlagOffAndUnlinksNothing() async throws {
        let db = try TBDDatabase(inMemory: true)
        let id = UUID()
        let paths = makeDeadHolder(id)

        let result = await makeGC(db: db).sweep(dryRun: true)

        #expect(result.planned.contains("REAP holder-rendezvous \(path(id, "sock"))"))
        #expect(result.reaped == 0)
        #expect(paths.allSatisfy { fm.fileExists(atPath: $0) },
                "a dry run must never touch disk")
    }

    /// The keep-biased young-holder guard, through the real sweep: a socket
    /// inside the grace window survives a flag-on sweep. This is the guard that
    /// stops an on-demand reconcile from destroying a session being born.
    @Test func aYoungHolderSurvivesAFlagOnSweep() async throws {
        let db = try TBDDatabase(inMemory: true)
        try await db.config.setGCHolderRendezvousEnabled(true)
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
