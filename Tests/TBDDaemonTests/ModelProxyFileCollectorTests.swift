import Foundation
import Testing
@testable import TBDDaemonLib
import TBDShared

/// Tier 2: a real proxy directory on disk plus an in-memory database. The
/// routes base, the streams base, the scratchpad base and the clock are all
/// injected; nothing here resolves a production path and no process is spawned.
///
/// The sandbox is a fresh directory removed in `deinit`, and every fixture is
/// backdated against a fixed clock so the grace window has elapsed for anything
/// a test does not deliberately make young.
@Suite("Model proxy file GC")
struct ModelProxyFileCollectorTests: ~Copyable {
    let fm = FileManager.default
    let sandbox: URL
    /// `~/tbd/proxy` in production. Holds `routes/` **and** the rendezvous
    /// triple, which is exactly why the collector is pointed one level deeper.
    let proxyBase: URL
    let routesDir: URL
    let streamsDir: URL
    let clock = Date(timeIntervalSince1970: 1_800_000_000)
    let grace = Config.defaultGCGraceSeconds

    init() {
        sandbox = URL(
            fileURLWithPath: "/tmp/tbd-gcmp-\(UUID().uuidString.prefix(8))", isDirectory: true)
        proxyBase = sandbox.appendingPathComponent("proxy", isDirectory: true)
        routesDir = proxyBase.appendingPathComponent("routes", isDirectory: true)
        streamsDir = sandbox.appendingPathComponent("streams", isDirectory: true)
        try? fm.createDirectory(at: routesDir, withIntermediateDirectories: true)
        try? fm.createDirectory(at: streamsDir, withIntermediateDirectories: true)
    }

    deinit { try? fm.removeItem(at: sandbox) }

    // MARK: - Fixtures

    private static let token = "0123456789abcdef0123456789abcdef"

    private func routePath(_ token: String) -> String {
        routesDir.appendingPathComponent("\(token).json").path
    }

    private func streamPath(_ terminalID: UUID) -> String {
        streamsDir.appendingPathComponent(
            TBDConstants.streamFileName(terminalID: terminalID)).path
    }

    /// A route file exactly as `ModelProxyRouteStore` writes one, backdated by
    /// `age` seconds against this suite's fixed clock.
    @discardableResult
    private func makeRoute(
        terminalID: UUID, token: String = ModelProxyFileCollectorTests.token,
        age: TimeInterval = 86_400
    ) -> String {
        let route = ModelProxyRoute(
            token: token, terminalID: terminalID,
            upstream: "https://api.anthropic.com", streamingEnabled: true)
        let path = routePath(token)
        fm.createFile(atPath: path, contents: try? route.encodedForRouteFile())
        backdate(path, by: age)
        return path
    }

    @discardableResult
    private func makeStream(terminalID: UUID, age: TimeInterval = 86_400) -> String {
        let path = streamPath(terminalID)
        fm.createFile(atPath: path, contents: Data(#"{"type":"text_delta"}"#.utf8))
        backdate(path, by: age)
        return path
    }

    /// The rendezvous triple a live proxy leaves in the directory ABOVE
    /// `routes/`, aged well past every window so nothing but a deliberate
    /// exclusion could be keeping it.
    @discardableResult
    private func makeRendezvousTriple(age: TimeInterval = 864_000) -> [String] {
        let paths = ["proxy.lock", "proxy.pid", "proxy.log"].map {
            proxyBase.appendingPathComponent($0).path
        }
        fm.createFile(atPath: paths[0], contents: Data())
        fm.createFile(atPath: paths[1], contents: Data("4242\n".utf8))
        fm.createFile(atPath: paths[2], contents: Data("proxy: listening\n".utf8))
        for path in paths { backdate(path, by: age) }
        return paths
    }

    private func backdate(_ path: String, by age: TimeInterval) {
        let stamp = clock.addingTimeInterval(-age)
        try? fm.setAttributes(
            [.creationDate: stamp, .modificationDate: stamp], ofItemAtPath: path)
    }

    private func makeCollector() -> ModelProxyFileCollector {
        let fixed = clock
        return ModelProxyFileCollector(
            routesDir: routesDir, streamsDir: streamsDir, now: { fixed })
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
            holdersBase: sandbox.appendingPathComponent("h", isDirectory: true),
            modelProxyBase: proxyBase,
            streamsBase: streamsDir
        )
    }

    /// A holder terminal row, with the worktree and repo rows its foreign keys
    /// need. `exited` stamps the row the way a session whose Claude process left
    /// is stamped.
    private func makeHolderTerminal(
        db: TBDDatabase, exited: Bool = false
    ) async throws -> Terminal {
        let repo = try await db.repos.create(
            path: "/tmp/gcmp-repo-\(UUID().uuidString)", displayName: "R", defaultBranch: "main")
        let worktree = try await db.worktrees.create(
            repoID: repo.id, name: "w", branch: "b",
            path: "/tmp/gcmp-wt-\(UUID().uuidString)", tmuxServer: "tbd-gcmp")
        let terminal = try await db.terminals.create(
            worktreeID: worktree.id, tmuxWindowID: "", tmuxPaneID: "",
            transport: .holder)
        if exited {
            try await db.terminals.setHibernated(
                id: terminal.id, sessionID: UUID().uuidString, reason: .exited)
        }
        return try #require(await db.terminals.get(id: terminal.id))
    }

    // MARK: - Enumeration

    /// Route files name their terminal in their CONTENTS (the file name is the
    /// route token, which says nothing about a session); stream files name it
    /// in their NAME, which is the whole scheme the app tails by.
    @Test func candidatesAreRouteAndStreamFiles() {
        let routeTerminal = UUID()
        let streamTerminal = UUID()
        let routeFile = makeRoute(terminalID: routeTerminal)
        let streamFile = makeStream(terminalID: streamTerminal)
        // Neither is a candidate: the route store's own atomic-write temp, and
        // a file with an extension this leg does not own.
        fm.createFile(
            atPath: routesDir.appendingPathComponent(".abc.json.tmp").path, contents: Data())
        fm.createFile(
            atPath: streamsDir.appendingPathComponent("notes.txt").path, contents: Data())

        let candidates = makeCollector().candidates()

        #expect(candidates.map(\.path).sorted() == [routeFile, streamFile].sorted())
        #expect(candidates.first { $0.path == routeFile }?.terminalID == routeTerminal)
        #expect(candidates.first { $0.path == streamFile }?.terminalID == streamTerminal)
    }

    /// **The exclusion that outranks the brief.** `proxy.lock`, `proxy.pid` and
    /// `proxy.log` live one level above `routes/`, and this leg must never
    /// unlink them on the strength of "nobody holds the lock": a retiring proxy
    /// legitimately holds no lock while it drains for up to ten minutes. They
    /// are not enumerated, and a hand-built candidate naming one is refused.
    @Test func theRendezvousTripleIsNeitherEnumeratedNorUnlinked() {
        let triple = makeRendezvousTriple()
        makeRoute(terminalID: UUID())

        let collector = makeCollector()
        let candidates = collector.candidates()

        for path in triple {
            #expect(!candidates.contains { $0.path == path }, "\(path) was enumerated")
            // Even asked directly — the anchoring guard is the last line of
            // defence, because `Candidate` is a public value type.
            #expect(
                collector.reap(
                    ModelProxyFileCandidate(
                        path: path, terminalID: nil, modifiedAt: clock.addingTimeInterval(-86_400))
                ) == false)
            #expect(fm.fileExists(atPath: path), "\(path) was unlinked")
        }
    }

    // MARK: - The gates

    @Test func aYoungFileIsKeptWhateverElseIsTrue() throws {
        let path = makeStream(terminalID: UUID(), age: 5)
        let collector = makeCollector()
        let candidate = try #require(collector.candidates().first { $0.path == path })
        #expect(
            collector.decide(candidate, graceSeconds: grace, liveTerminalIDs: [])
                == .keep(reason: "grace"))
    }

    /// A file whose age cannot be read is kept: an unreadable `stat` is not
    /// evidence of anything, and the grace window is the only thing standing
    /// between this sweep and a session being born.
    @Test func aFileWithNoReadableAgeIsKept() {
        let candidate = ModelProxyFileCandidate(
            path: streamPath(UUID()), terminalID: UUID(), modifiedAt: nil)
        #expect(
            makeCollector().decide(candidate, graceSeconds: grace, liveTerminalIDs: [])
                == .keep(reason: "unknown-age"))
    }

    /// Age alone must not reap: an agent that has been running for a day wrote
    /// its route file once, at the start of that day.
    @Test func anOldFileWhoseTerminalIsLiveIsKept() throws {
        let terminalID = UUID()
        let path = makeRoute(terminalID: terminalID)
        let collector = makeCollector()
        let candidate = try #require(collector.candidates().first { $0.path == path })
        #expect(
            collector.decide(candidate, graceSeconds: grace, liveTerminalIDs: [terminalID])
                == .keep(reason: "live-terminal"))
    }

    @Test func anOldFileWhoseTerminalIsGoneIsReaped() throws {
        let path = makeStream(terminalID: UUID())
        let collector = makeCollector()
        let candidate = try #require(collector.candidates().first { $0.path == path })
        #expect(
            collector.decide(candidate, graceSeconds: grace, liveTerminalIDs: []) == .reap)
    }

    /// A route file the proxy itself would refuse still has to be reclaimable:
    /// it names no terminal, so no terminal can be keeping it, and excluding it
    /// would make malformed route files the one residue nothing sweeps.
    @Test func aMalformedOldRouteFileIsReaped() throws {
        let path = routePath(Self.token)
        fm.createFile(atPath: path, contents: Data("{not json".utf8))
        backdate(path, by: 86_400)

        let collector = makeCollector()
        let candidate = try #require(collector.candidates().first { $0.path == path })

        #expect(candidate.terminalID == nil)
        #expect(collector.decide(candidate, graceSeconds: grace, liveTerminalIDs: []) == .reap)
        #expect(collector.reap(candidate))
        #expect(!fm.fileExists(atPath: path))
    }

    // MARK: - The sweep

    /// **The discriminating sweep test.** A route file and a stream file for a
    /// session that no longer exists are gone from disk after one sweep, on an
    /// untouched config — this leg runs under `gcEnabled` alone, with no flag of
    /// its own.
    @Test func aSweepUnlinksTheFilesOfADeadSession() async throws {
        let db = try TBDDatabase(inMemory: true)
        #expect(try await db.config.get().gcEnabled, "GC ships on; this test rides that default")
        let terminalID = UUID()
        let route = makeRoute(terminalID: terminalID)
        let stream = makeStream(terminalID: terminalID)

        let result = await makeGC(db: db).sweep()

        #expect(!fm.fileExists(atPath: route), "the route file survived the sweep")
        #expect(!fm.fileExists(atPath: stream), "the stream file survived the sweep")
        #expect(result.planned.contains("REAP model-proxy-file \(route)"))
        #expect(result.planned.contains("REAP model-proxy-file \(stream)"))
        #expect(result.reaped >= 2)
    }

    /// The keep half, driven through the real row read: a holder row that has
    /// not exited keeps both of its files however old they are.
    @Test func aSweepKeepsTheFilesOfALiveSession() async throws {
        let db = try TBDDatabase(inMemory: true)
        let terminal = try await makeHolderTerminal(db: db)
        let route = makeRoute(terminalID: terminal.id)
        let stream = makeStream(terminalID: terminal.id)

        let result = await makeGC(db: db).sweep()

        #expect(fm.fileExists(atPath: route))
        #expect(fm.fileExists(atPath: stream))
        #expect(result.planned.contains("KEEP live-terminal \(route)"))
        #expect(result.planned.contains("KEEP live-terminal \(stream)"))
    }

    /// The other side of the same read: a row stamped as exited is a session
    /// whose stream nothing will resume, so its files are reclaimed rather than
    /// kept for a terminal that will never write again.
    @Test func aSweepReapsTheFilesOfAnExitedSession() async throws {
        let db = try TBDDatabase(inMemory: true)
        let terminal = try await makeHolderTerminal(db: db, exited: true)
        let stream = makeStream(terminalID: terminal.id)

        let result = await makeGC(db: db).sweep()

        #expect(!fm.fileExists(atPath: stream))
        #expect(result.planned.contains("REAP model-proxy-file \(stream)"))
    }

    /// `dryRun` plans everything and touches nothing — including the rendezvous
    /// triple, which no run of any kind may reach.
    @Test func aDryRunPlansTheReapsAndUnlinksNothing() async throws {
        let db = try TBDDatabase(inMemory: true)
        let route = makeRoute(terminalID: UUID())
        let stream = makeStream(terminalID: UUID())
        let triple = makeRendezvousTriple()

        let result = await makeGC(db: db).sweep(dryRun: true)

        #expect(result.planned.contains("REAP model-proxy-file \(route)"))
        #expect(result.planned.contains("REAP model-proxy-file \(stream)"))
        for path in [route, stream] + triple {
            #expect(fm.fileExists(atPath: path), "\(path) was unlinked by a dry run")
        }
    }

    /// The master switch off leaves the same fixture completely alone, and the
    /// sweep does not even plan it.
    @Test func gcDisabledPlansAndReapsNothing() async throws {
        let db = try TBDDatabase(inMemory: true)
        try await db.config.setGCEnabled(false)
        let route = makeRoute(terminalID: UUID())

        let result = await makeGC(db: db).sweep()

        #expect(fm.fileExists(atPath: route))
        #expect(result.planned.allSatisfy { !$0.hasSuffix(route) })
    }
}
