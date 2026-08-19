import Foundation
import Security
import Testing
@testable import TBDDaemonLib
import TBDShared

/// Tier 2: a real filesystem sandbox plus an in-memory database. The `ps`
/// snapshot, the pid-to-cwd map and the signaller are all injected, so nothing
/// here spawns a process or sends a real signal — the same discipline
/// `AgentReaperTests` keeps, which drives the identical escalation at
/// `.milliseconds(1)`.
@Suite("OrphanGC reclaims orphaned processes")
struct OrphanGCOrphanProcessTests: ~Copyable {
    let fm = FileManager.default
    /// Sandbox root for this test instance; everything lives under it.
    let sandbox: URL
    /// The repo's worktree pool (`repo.worktreeRoot` override), so the
    /// canonical `~/tbd/worktrees` layout is never consulted.
    let pool: URL
    let repoDir: URL
    /// Injected scratchpad base, so the sweep's scratchpad phase can never
    /// reach the developer's real Claude store.
    let scratchpadBase: URL
    /// A directory of the user's own, standing in for the arbitrary location an
    /// adopted worktree lives at. Deliberately outside `pool`, and it holds
    /// things TBD has never managed.
    let adoptionParent: URL

    init() {
        sandbox = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("orphan-gc-process-\(UUID().uuidString)", isDirectory: true)
        pool = sandbox.appendingPathComponent("pool", isDirectory: true)
        repoDir = sandbox.appendingPathComponent("repo", isDirectory: true)
        scratchpadBase = sandbox.appendingPathComponent("scratchpads", isDirectory: true)
        adoptionParent = sandbox.appendingPathComponent("user-projects", isDirectory: true)
        try? fm.createDirectory(at: pool, withIntermediateDirectories: true)
        try? fm.createDirectory(at: repoDir, withIntermediateDirectories: true)
        try? fm.createDirectory(at: scratchpadBase, withIntermediateDirectories: true)
        try? fm.createDirectory(at: adoptionParent, withIntermediateDirectories: true)
    }

    deinit {
        try? fm.removeItem(at: sandbox)
    }

    // MARK: - Fixtures

    /// `realpath`, matching what `lsof` reports and what the sweep resolves
    /// both sides of every comparison to. `NSTemporaryDirectory()` sits under
    /// macOS's `/var` -> `/private/var` symlink, so a fixture path that skips
    /// this lines up with nothing.
    private func canon(_ url: URL) -> String {
        guard let resolved = realpath(url.path, nil) else { return url.path }
        defer { free(resolved) }
        return String(cString: resolved)
    }

    private func makeGC(
        db: TBDDatabase,
        signaller: ProcessSignaller,
        processes: [ProcessSnapshotEntry],
        cwdByPID: [Int32: String],
        now: Date,
        processSnapshotAvailable: Bool = true,
        snapshotProvider: (@Sendable () async -> [ProcessSnapshotEntry]?)? = nil
    ) -> OrphanGC {
        OrphanGC(
            db: db, git: GitManager(),
            broadcast: { _ in },
            liveCWDsProvider: { [] },
            scratchpadBase: scratchpadBase,
            now: { now },
            beforeInterruptedArchiveReap: nil,
            profileDirBase: sandbox.appendingPathComponent("profiles", isDirectory: true),
            credentialsKeychain: NoopKeychain(),
            beforeProfileDirReap: nil,
            processCWDsProvider: { cwdByPID },
            processSnapshotProvider: snapshotProvider
                ?? { processSnapshotAvailable ? processes : nil },
            signaller: signaller,
            orphanProcessGraceAttempts: 2,
            orphanProcessPollInterval: .milliseconds(1)
        )
    }

    /// A repo row whose worktree pool is the sandbox `pool` directory.
    private func makeRepo(db: TBDDatabase) async throws -> Repo {
        let repo = try await db.repos.create(
            path: repoDir.path, displayName: "acme", defaultBranch: "main")
        try await db.repos.updateWorktreeRoot(id: repo.id, path: pool.path)
        return try #require(try await db.repos.get(id: repo.id))
    }

    /// A worktree row plus its directory under the pool. `archived` decides
    /// whether the row is a live one or one the developer has finished with.
    @discardableResult
    private func makeWorktree(
        db: TBDDatabase, repo: Repo, name: String, archived: Bool
    ) async throws -> String {
        let dir = pool.appendingPathComponent(name, isDirectory: true)
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        let row = try await db.worktrees.create(
            repoID: repo.id, name: name, branch: name,
            path: dir.path, tmuxServer: "tbd-test")
        if archived {
            try await db.worktrees.archive(id: row.id)
        }
        return canon(dir)
    }

    /// A worktree row at a path the user chose, the way `adoptWorktree` makes
    /// one: under no worktree pool at all, next to whatever else the user keeps
    /// in that directory.
    @discardableResult
    private func makeAdoptedWorktree(
        db: TBDDatabase, repo: Repo, name: String, archived: Bool
    ) async throws -> String {
        let dir = adoptionParent.appendingPathComponent(name, isDirectory: true)
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        let row = try await db.worktrees.create(
            repoID: repo.id, name: name, branch: name,
            path: dir.path, tmuxServer: "tbd-test")
        if archived {
            try await db.worktrees.archive(id: row.id)
        }
        return canon(dir)
    }

    /// A stray `.deleting/<uuid>` entry, drained by the deletion-queue
    /// collector on every sweep regardless of any soak flag. Present in the
    /// flag tests as the control: it proves the ungated collectors still ran.
    private func makeQueuedEntry() throws -> String {
        let queueDir = WorktreeDeletionQueue().queueDir(forPool: pool.path)
        let entry = queueDir + "/" + UUID().uuidString
        try fm.createDirectory(atPath: entry, withIntermediateDirectories: true)
        return entry
    }

    private func entry(
        pid: Int32, ppid: Int32 = 1, pgid: Int32? = nil,
        elapsed: TimeInterval? = 86_400, command: String = "/usr/bin/node server.js"
    ) -> ProcessSnapshotEntry {
        ProcessSnapshotEntry(
            pid: pid, ppid: ppid, pgid: pgid ?? pid, uid: getuid(),
            elapsedSeconds: elapsed, command: command)
    }

    // MARK: - Flag branches

    @Test("the flag ships off: a matching orphan survives a real sweep untouched")
    func flagOffLeavesTheOrphanRunning() async throws {
        let db = try TBDDatabase(inMemory: true)
        try await db.config.setGCEnabled(true)
        let repo = try await makeRepo(db: db)
        let dead = try await makeWorktree(db: db, repo: repo, name: "gone", archived: true)
        let queued = try makeQueuedEntry()
        let signaller = FakeProcessSignaller()

        let result = await makeGC(
            db: db, signaller: signaller,
            processes: [entry(pid: 4242)],
            cwdByPID: [4242: dead + "/sub"],
            now: Date().addingTimeInterval(7200)
        ).sweep()

        #expect(signaller.terminated.isEmpty)
        #expect(signaller.killed.isEmpty)
        #expect(!result.planned.contains { $0.hasPrefix("REAP orphan-process") })
        #expect(try await db.reapRecords.list(repoPath: nil).allSatisfy { $0.kind != .orphanProcess })
        // The control: ungated GC behavior is unaffected by the flag's state.
        #expect(result.planned.contains("REAP queued-deletion \(queued)"))
        #expect(!fm.fileExists(atPath: queued))
    }

    @Test("flag on: the same orphan is reclaimed and recorded")
    func flagOnReclaimsTheOrphan() async throws {
        let db = try TBDDatabase(inMemory: true)
        try await db.config.setGCEnabled(true)
        try await db.config.setGCOrphanProcessesEnabled(true)
        let repo = try await makeRepo(db: db)
        let dead = try await makeWorktree(db: db, repo: repo, name: "gone", archived: true)
        let queued = try makeQueuedEntry()
        let signaller = FakeProcessSignaller()
        signaller.behaviors[4242] = .init(aliveAfterTerminate: false)

        let result = await makeGC(
            db: db, signaller: signaller,
            processes: [entry(pid: 4242, command: "/usr/bin/node server.js --port 3000")],
            cwdByPID: [4242: dead + "/sub"],
            now: Date().addingTimeInterval(7200)
        ).sweep()

        #expect(signaller.terminated == [4242])
        #expect(signaller.killed.isEmpty, "a process that honors SIGTERM is never SIGKILLed")
        #expect(result.planned.contains("REAP orphan-process pid=4242 tree=1 \(dead)"))

        let record = try #require(
            try await db.reapRecords.list(repoPath: nil).first { $0.kind == .orphanProcess })
        #expect(record.worktreePath == dead, "the dead worktree the process was rooted in")
        #expect(record.repoPath == repoDir.path)
        let description = try #require(record.processDescription)
        #expect(description.hasPrefix("pid=4242 tree=1 "))
        #expect(description.contains("--port 3000"))
        // The path- and git-shaped fields go unused for this kind.
        #expect(record.branch == nil)
        #expect(record.headSHA == nil)
        #expect(record.snapshotRef == nil)
        #expect(record.quarantinePath == nil)
        // Still unaffected in the other direction.
        #expect(result.planned.contains("REAP queued-deletion \(queued)"))
    }

    @Test("gcEnabled off keeps everything even with the orphan-process flag on")
    func masterSwitchStillGoverns() async throws {
        let db = try TBDDatabase(inMemory: true)
        try await db.config.setGCEnabled(false)
        try await db.config.setGCOrphanProcessesEnabled(true)
        let repo = try await makeRepo(db: db)
        let dead = try await makeWorktree(db: db, repo: repo, name: "gone", archived: true)
        let signaller = FakeProcessSignaller()

        let result = await makeGC(
            db: db, signaller: signaller,
            processes: [entry(pid: 4242)],
            cwdByPID: [4242: dead],
            now: Date().addingTimeInterval(7200)
        ).sweep()

        #expect(result.planned == ["gc disabled"])
        #expect(signaller.terminated.isEmpty)
    }

    @Test("with the flag off a dry run still plans what enabling it would reclaim")
    func flagOffDryRunStillPlans() async throws {
        let db = try TBDDatabase(inMemory: true)
        try await db.config.setGCEnabled(true)
        let repo = try await makeRepo(db: db)
        let dead = try await makeWorktree(db: db, repo: repo, name: "gone", archived: true)
        let signaller = FakeProcessSignaller()

        let result = await makeGC(
            db: db, signaller: signaller,
            processes: [entry(pid: 4242)],
            cwdByPID: [4242: dead],
            now: Date().addingTimeInterval(7200)
        ).sweep(dryRun: true)

        #expect(result.planned.contains("REAP orphan-process pid=4242 tree=1 \(dead)"))
        #expect(result.reaped == 0)
        #expect(signaller.terminated.isEmpty, "a dry run touches nothing")
        #expect(signaller.killed.isEmpty)
    }

    // MARK: - Descendant closure

    @Test("a three-generation tree is reclaimed whole, leaf-first, across process groups")
    func reclaimsTheWholeSubtree() async throws {
        let db = try TBDDatabase(inMemory: true)
        try await db.config.setGCEnabled(true)
        try await db.config.setGCOrphanProcessesEnabled(true)
        let repo = try await makeRepo(db: db)
        let dead = try await makeWorktree(db: db, repo: repo, name: "gone", archived: true)
        let signaller = FakeProcessSignaller()
        for pid: Int32 in [700, 701, 702] {
            signaller.behaviors[pid] = .init(aliveAfterTerminate: false)
        }

        let result = await makeGC(
            db: db, signaller: signaller,
            processes: [
                entry(pid: 700, ppid: 1, pgid: 698, command: "process-compose up"),
                entry(pid: 701, ppid: 700, pgid: 698, command: "prefect server start"),
                // The case a plain killpg misses: a grandchild in a process
                // group of its own, unreachable from the root's group.
                entry(pid: 702, ppid: 701, pgid: 702, command: "uvicorn app:api"),
            ],
            cwdByPID: [700: dead, 701: dead, 702: dead + "/nested"],
            now: Date().addingTimeInterval(7200)
        ).sweep()

        #expect(signaller.terminated == [702, 701, 700], "leaf-first, deepest generation first")
        #expect(result.planned.contains("REAP orphan-process pid=700 tree=3 \(dead)"))
        let record = try #require(
            try await db.reapRecords.list(repoPath: nil).first { $0.kind == .orphanProcess })
        #expect(try #require(record.processDescription).hasPrefix("pid=700 tree=3 "))
        // Only the ppid==1 root is a candidate; the children are reclaimed as
        // part of its closure, not as roots of their own.
        #expect(result.planned.filter { $0.hasPrefix("REAP orphan-process") }.count == 1)
    }

    @Test("a subtree member that ignores SIGTERM is escalated to SIGKILL")
    func escalatesSurvivors() async throws {
        let db = try TBDDatabase(inMemory: true)
        try await db.config.setGCEnabled(true)
        try await db.config.setGCOrphanProcessesEnabled(true)
        let repo = try await makeRepo(db: db)
        let dead = try await makeWorktree(db: db, repo: repo, name: "gone", archived: true)
        let signaller = FakeProcessSignaller()
        signaller.behaviors[800] = .init(aliveAfterTerminate: true, aliveAfterKill: false)
        signaller.behaviors[801] = .init(aliveAfterTerminate: false)

        _ = await makeGC(
            db: db, signaller: signaller,
            processes: [entry(pid: 800), entry(pid: 801, ppid: 800)],
            cwdByPID: [800: dead, 801: dead],
            now: Date().addingTimeInterval(7200)
        ).sweep()

        #expect(signaller.terminated == [801, 800])
        #expect(signaller.killed == [800], "only the process still alive after the grace window")
    }

    // MARK: - Keep gates

    @Test("a process inside a LIVE worktree is never a candidate, even at ppid 1")
    func liveWorktreeIsNeverACandidate() async throws {
        let db = try TBDDatabase(inMemory: true)
        try await db.config.setGCEnabled(true)
        try await db.config.setGCOrphanProcessesEnabled(true)
        let repo = try await makeRepo(db: db)
        let alive = try await makeWorktree(db: db, repo: repo, name: "working", archived: false)
        let dead = try await makeWorktree(db: db, repo: repo, name: "gone", archived: true)
        let signaller = FakeProcessSignaller()
        signaller.behaviors[901] = .init(aliveAfterTerminate: false)

        let result = await makeGC(
            db: db, signaller: signaller,
            processes: [entry(pid: 900), entry(pid: 901)],
            cwdByPID: [900: alive + "/src", 901: dead],
            now: Date().addingTimeInterval(7200)
        ).sweep()

        #expect(!signaller.terminated.contains(900), "a detached dev server in live work is safe")
        // The dead one in the same sweep proves the phase ran at all.
        #expect(signaller.terminated == [901])
        #expect(!result.planned.contains { $0.contains("pid=900") })
    }

    @Test("a LIVE worktree's Claude scratchpad is classified with its worktree, not as an orphan")
    func liveWorktreeScratchpadIsNeverACandidate() async throws {
        let db = try TBDDatabase(inMemory: true)
        try await db.config.setGCEnabled(true)
        try await db.config.setGCOrphanProcessesEnabled(true)
        let repo = try await makeRepo(db: db)
        let alive = pool.appendingPathComponent("working", isDirectory: true)
        try await makeWorktree(db: db, repo: repo, name: "working", archived: false)
        // The scratchpad base is itself a TBD-managed pool, so without owner
        // resolution this path would fall into the "absent from the database"
        // arm and become reclaimable while the work is still going on.
        let scratchpad = scratchpadBase.appendingPathComponent(
            ScratchpadCollector.slug(forWorktreePath: alive.path), isDirectory: true)
        try fm.createDirectory(at: scratchpad, withIntermediateDirectories: true)
        let signaller = FakeProcessSignaller()

        _ = await makeGC(
            db: db, signaller: signaller,
            processes: [entry(pid: 4242)],
            cwdByPID: [4242: canon(scratchpad)],
            now: Date().addingTimeInterval(7200)
        ).sweep()

        #expect(signaller.terminated.isEmpty)
    }

    @Test("grace is honored: too young survives, the same orphan is reclaimed once it passes")
    func graceIsHonored() async throws {
        let db = try TBDDatabase(inMemory: true)
        try await db.config.setGCEnabled(true)
        try await db.config.setGCOrphanProcessesEnabled(true)
        let repo = try await makeRepo(db: db)
        let dead = try await makeWorktree(db: db, repo: repo, name: "gone", archived: true)

        // `archive` stamps the row with the real clock, so a sweep clock a
        // minute later is well inside the 3600s window.
        let tooSoon = FakeProcessSignaller()
        _ = await makeGC(
            db: db, signaller: tooSoon,
            processes: [entry(pid: 4242)], cwdByPID: [4242: dead],
            now: Date().addingTimeInterval(60)
        ).sweep()
        #expect(tooSoon.terminated.isEmpty, "an orphan younger than gcGraceSeconds survives")

        let later = FakeProcessSignaller()
        later.behaviors[4242] = .init(aliveAfterTerminate: false)
        _ = await makeGC(
            db: db, signaller: later,
            processes: [entry(pid: 4242)], cwdByPID: [4242: dead],
            now: Date().addingTimeInterval(7200)
        ).sweep()
        #expect(later.terminated == [4242], "the same orphan is reclaimed once the window passes")
    }

    @Test("a directory with no row at all measures grace from process start instead")
    func graceFromProcessStartWhenNoRowSurvives() async throws {
        let db = try TBDDatabase(inMemory: true)
        try await db.config.setGCEnabled(true)
        try await db.config.setGCOrphanProcessesEnabled(true)
        _ = try await makeRepo(db: db)
        // Under the pool, but no worktree row ever existed for it.
        let stray = pool.appendingPathComponent("forgotten", isDirectory: true)
        try fm.createDirectory(at: stray, withIntermediateDirectories: true)

        let young = FakeProcessSignaller()
        _ = await makeGC(
            db: db, signaller: young,
            processes: [entry(pid: 550, elapsed: 60)], cwdByPID: [550: canon(stray)],
            now: Date()
        ).sweep()
        #expect(young.terminated.isEmpty)

        let old = FakeProcessSignaller()
        old.behaviors[550] = .init(aliveAfterTerminate: false)
        _ = await makeGC(
            db: db, signaller: old,
            processes: [entry(pid: 550, elapsed: 86_400)], cwdByPID: [550: canon(stray)],
            now: Date()
        ).sweep()
        #expect(old.terminated == [550])
    }

    @Test("the daemon is never signalled, even with its cwd inside the archived worktree")
    func daemonSelfExclusion() async throws {
        let db = try TBDDatabase(inMemory: true)
        try await db.config.setGCEnabled(true)
        try await db.config.setGCOrphanProcessesEnabled(true)
        let repo = try await makeRepo(db: db)
        let dead = try await makeWorktree(db: db, repo: repo, name: "gone", archived: true)
        let signaller = FakeProcessSignaller()
        signaller.behaviors[999] = .init(aliveAfterTerminate: false)

        let result = await makeGC(
            db: db, signaller: signaller,
            processes: [
                entry(pid: 111, command: dead + "/.build/debug/TBDDaemon"),
                entry(pid: 112, command: dead + "/.build/debug/TBD.app/Contents/MacOS/TBDApp"),
                entry(pid: 999, command: "/usr/bin/node server.js"),
            ],
            cwdByPID: [111: dead, 112: dead, 999: dead],
            now: Date().addingTimeInterval(7200)
        ).sweep()

        #expect(!signaller.terminated.contains(111), "the sweep must never SIGKILL its own daemon")
        #expect(!signaller.terminated.contains(112))
        #expect(!signaller.killed.contains(111))
        #expect(!signaller.killed.contains(112))
        // The ordinary orphan in the same sweep proves the phase ran.
        #expect(signaller.terminated == [999])
        #expect(!result.planned.contains { $0.contains("pid=111") || $0.contains("pid=112") })
    }

    @Test("a candidate whose cwd could not be read is skipped, never reclaimed")
    func unreadableCWDIsASkip() async throws {
        let db = try TBDDatabase(inMemory: true)
        try await db.config.setGCEnabled(true)
        try await db.config.setGCOrphanProcessesEnabled(true)
        let repo = try await makeRepo(db: db)
        let dead = try await makeWorktree(db: db, repo: repo, name: "gone", archived: true)
        let signaller = FakeProcessSignaller()
        signaller.behaviors[601] = .init(aliveAfterTerminate: false)

        let result = await makeGC(
            db: db, signaller: signaller,
            // 600 is absent from the cwd map entirely — absence of evidence.
            processes: [entry(pid: 600), entry(pid: 601)],
            cwdByPID: [601: dead],
            now: Date().addingTimeInterval(7200)
        ).sweep()

        #expect(!signaller.terminated.contains(600))
        #expect(signaller.terminated == [601])
        #expect(!result.planned.contains { $0.contains("pid=600") })
    }

    @Test("an unavailable ps snapshot skips the phase rather than reading it as no orphans")
    func psUnavailableSkipsThePhase() async throws {
        let db = try TBDDatabase(inMemory: true)
        try await db.config.setGCEnabled(true)
        try await db.config.setGCOrphanProcessesEnabled(true)
        let repo = try await makeRepo(db: db)
        let dead = try await makeWorktree(db: db, repo: repo, name: "gone", archived: true)
        let signaller = FakeProcessSignaller()

        let result = await makeGC(
            db: db, signaller: signaller,
            processes: [entry(pid: 4242)], cwdByPID: [4242: dead],
            now: Date().addingTimeInterval(7200),
            processSnapshotAvailable: false
        ).sweep()

        #expect(signaller.terminated.isEmpty)
        #expect(result.planned.contains("KEEP ps-unavailable orphan-processes"))
    }

    /// The Claude scratchpad base is shared with every Claude Code session on
    /// the machine, TBD-managed or not. A directory there naming no worktree
    /// TBD knows is somebody else's, and its processes are not this sweep's to
    /// kill — the whitelist side `ScratchpadCollector.reconcile` already takes.
    @Test("a scratchpad naming no TBD worktree is never a candidate")
    func strayScratchpadIsNeverACandidate() async throws {
        let db = try TBDDatabase(inMemory: true)
        try await db.config.setGCEnabled(true)
        try await db.config.setGCOrphanProcessesEnabled(true)
        let repo = try await makeRepo(db: db)
        let dead = try await makeWorktree(db: db, repo: repo, name: "gone", archived: true)
        // A Claude session run straight from a checkout TBD has never managed.
        let stray = scratchpadBase.appendingPathComponent(
            ScratchpadCollector.slug(forWorktreePath: "/Users/someone/projects/acme"),
            isDirectory: true)
        try fm.createDirectory(at: stray, withIntermediateDirectories: true)
        let signaller = FakeProcessSignaller()
        signaller.behaviors[4243] = .init(aliveAfterTerminate: false)

        let result = await makeGC(
            db: db, signaller: signaller,
            processes: [entry(pid: 4242), entry(pid: 4243)],
            cwdByPID: [4242: canon(stray) + "/sub", 4243: dead],
            now: Date().addingTimeInterval(7200)
        ).sweep()

        #expect(!signaller.terminated.contains(4242))
        #expect(!result.planned.contains { $0.contains("pid=4242") })
        // The genuine orphan in the same sweep proves the phase ran at all.
        #expect(signaller.terminated == [4243])
    }

    /// The sibling of the `ps`-unavailable skip, and the reason both row reads
    /// moved inside the phase: a partial view of which worktrees are alive is
    /// the one input that could turn live work into a candidate.
    @Test("a failed row read skips the phase rather than proceeding on a partial view")
    func dbUnavailableSkipsThePhase() async throws {
        let db = try TBDDatabase(inMemory: true)
        try await db.config.setGCEnabled(true)
        try await db.config.setGCOrphanProcessesEnabled(true)
        let repo = try await makeRepo(db: db)
        let dead = try await makeWorktree(db: db, repo: repo, name: "gone", archived: true)
        let signaller = FakeProcessSignaller()
        signaller.behaviors[4242] = .init(aliveAfterTerminate: false)
        // Make every worktree read fail, the way a corrupt or locked database
        // would, rather than return an empty list.
        try await db.writerForTests.write { conn in
            try conn.execute(sql: "DROP TABLE worktree")
        }

        let result = await makeGC(
            db: db, signaller: signaller,
            processes: [entry(pid: 4242)], cwdByPID: [4242: dead],
            now: Date().addingTimeInterval(7200)
        ).sweep()

        #expect(signaller.terminated.isEmpty)
        #expect(signaller.killed.isEmpty)
        #expect(result.planned.contains("KEEP db-unavailable orphan-processes"))
    }

    // MARK: - Adopted worktrees

    /// `adoptWorktree` puts a row at a path the user chose, under no pool at
    /// all. The classifier gates on pool-or-shared-root membership before it
    /// ever consults the dead list, so without the row's own path admitted as a
    /// shared root this orphan would be `.outside` forever — the very leak this
    /// phase exists to close, for every adopted worktree.
    @Test("an orphan inside an ARCHIVED adopted worktree is reclaimed")
    func archivedAdoptedWorktreeYieldsItsOrphan() async throws {
        let db = try TBDDatabase(inMemory: true)
        try await db.config.setGCEnabled(true)
        try await db.config.setGCOrphanProcessesEnabled(true)
        let repo = try await makeRepo(db: db)
        let adopted = try await makeAdoptedWorktree(
            db: db, repo: repo, name: "adopted-gone", archived: true)
        let signaller = FakeProcessSignaller()
        signaller.behaviors[5100] = .init(aliveAfterTerminate: false)

        let result = await makeGC(
            db: db, signaller: signaller,
            processes: [entry(pid: 5100, command: "/usr/bin/node server.js --port 4000")],
            cwdByPID: [5100: adopted + "/sub"],
            now: Date().addingTimeInterval(7200)
        ).sweep()

        #expect(signaller.terminated == [5100])
        #expect(result.planned.contains("REAP orphan-process pid=5100 tree=1 \(adopted)"))
        let record = try #require(
            try await db.reapRecords.list(repoPath: nil).first { $0.kind == .orphanProcess })
        #expect(record.worktreePath == adopted)
        // The row names its repo even though no pool contains its path.
        #expect(record.repoPath == repoDir.path)
    }

    /// The other half, and the reason the adopted path goes in as a SHARED
    /// root rather than a pool: the directory the user picked is the user's,
    /// and its neighbours are unrelated checkouts, loose files, sometimes a
    /// home directory. A pool would put every one of them in the
    /// "absent from the database" arm and make a stranger's live session
    /// reclaimable.
    @Test("an unrelated sibling of an adopted worktree is never a candidate")
    func adoptedWorktreeSiblingIsNeverACandidate() async throws {
        let db = try TBDDatabase(inMemory: true)
        try await db.config.setGCEnabled(true)
        try await db.config.setGCOrphanProcessesEnabled(true)
        let repo = try await makeRepo(db: db)
        let adopted = try await makeAdoptedWorktree(
            db: db, repo: repo, name: "adopted-gone", archived: true)
        // A checkout of the user's own, sitting next to the adopted worktree
        // and never known to TBD.
        let sibling = adoptionParent.appendingPathComponent("unrelated", isDirectory: true)
        try fm.createDirectory(at: sibling, withIntermediateDirectories: true)
        let signaller = FakeProcessSignaller()
        signaller.behaviors[5200] = .init(aliveAfterTerminate: false)
        signaller.behaviors[5201] = .init(aliveAfterTerminate: false)

        let result = await makeGC(
            db: db, signaller: signaller,
            processes: [entry(pid: 5200), entry(pid: 5201)],
            cwdByPID: [5200: canon(sibling) + "/src", 5201: adopted],
            now: Date().addingTimeInterval(7200)
        ).sweep()

        #expect(!signaller.terminated.contains(5200))
        #expect(!result.planned.contains { $0.contains("pid=5200") })
        // The adopted worktree's own orphan in the same sweep proves the
        // sibling survived a phase that genuinely ran.
        #expect(signaller.terminated == [5201])
    }

    @Test("a process outside every TBD pool is never a candidate")
    func outsideEveryPoolIsNeverACandidate() async throws {
        let db = try TBDDatabase(inMemory: true)
        try await db.config.setGCEnabled(true)
        try await db.config.setGCOrphanProcessesEnabled(true)
        _ = try await makeRepo(db: db)
        let signaller = FakeProcessSignaller()

        _ = await makeGC(
            db: db, signaller: signaller,
            processes: [entry(pid: 4242)],
            cwdByPID: [4242: canon(sandbox) + "/elsewhere"],
            now: Date().addingTimeInterval(7200)
        ).sweep()

        #expect(signaller.terminated.isEmpty)
    }

    // MARK: - Identity at signal time, across a multi-candidate sweep

    /// The amplification case the root-only `age >= cwdAge` gate cannot reach.
    /// `reclaimOrphanProcesses` signals candidates one after another and each
    /// reap blocks for up to `graceAttempts × pollInterval` before the next
    /// one is even examined, so with the half-dozen simultaneous orphans a
    /// field census found, the LAST candidate's tree is signalled many seconds
    /// after the reading that named its pids. Its identity check therefore has
    /// to run at ITS volley, not at the sweep's plan.
    @Test("a later candidate in a multi-orphan sweep is identity-checked at its own volley")
    func lateCandidateIsIdentityChecked() async throws {
        let db = try TBDDatabase(inMemory: true)
        try await db.config.setGCEnabled(true)
        try await db.config.setGCOrphanProcessesEnabled(true)
        let repo = try await makeRepo(db: db)
        let dead = try await makeWorktree(db: db, repo: repo, name: "gone", archived: true)
        let signaller = FakeProcessSignaller()
        // Both honor SIGTERM, so neither reap reaches the SIGKILL escalation
        // and the readings below line up one-to-one with the volleys.
        signaller.behaviors[4242] = .init(aliveAfterTerminate: false)
        signaller.behaviors[4343] = .init(aliveAfterTerminate: false)

        let plan = [entry(pid: 4242), entry(pid: 4343)]
        // While the first candidate was being reaped, 4343 exited and the
        // kernel handed its pid to an unrelated, live, same-uid process.
        let afterFirstReap = [entry(pid: 4242), entry(pid: 4343, elapsed: 4)]
        let readings = ScriptedReadings([plan, plan, afterFirstReap])

        let result = await makeGC(
            db: db, signaller: signaller,
            processes: plan,
            cwdByPID: [4242: dead, 4343: dead],
            now: Date().addingTimeInterval(7200),
            snapshotProvider: { readings.next() }
        ).sweep()

        #expect(signaller.terminated == [4242], "the first candidate still verified and was reclaimed")
        #expect(
            !signaller.terminated.contains(4343),
            "the last candidate's pid was reissued mid-sweep and must not be signalled")
        #expect(signaller.killed.isEmpty)
        #expect(result.planned.contains("KEEP nothing-signalled \(dead)"))
        #expect(result.reaped == 1)
        let records = try await db.reapRecords.list(repoPath: nil).filter { $0.kind == .orphanProcess }
        #expect(records.count == 1)
        #expect(try #require(records.first?.processDescription).hasPrefix("pid=4242 tree=1 "))
    }

    @Test("a ps reading that fails at signal time signals nothing and records nothing")
    func unreadableIdentityAtSignalTimeKeeps() async throws {
        let db = try TBDDatabase(inMemory: true)
        try await db.config.setGCEnabled(true)
        try await db.config.setGCOrphanProcessesEnabled(true)
        let repo = try await makeRepo(db: db)
        let dead = try await makeWorktree(db: db, repo: repo, name: "gone", archived: true)
        let signaller = FakeProcessSignaller()
        let plan = [entry(pid: 4242)]
        // The planning reading succeeds; the pre-signal re-read does not.
        let readings = ScriptedReadings([plan, nil])

        let result = await makeGC(
            db: db, signaller: signaller,
            processes: plan,
            cwdByPID: [4242: dead],
            now: Date().addingTimeInterval(7200),
            snapshotProvider: { readings.next() }
        ).sweep()

        #expect(signaller.terminated.isEmpty, "an identity that cannot be re-read is a skip")
        #expect(signaller.killed.isEmpty)
        #expect(result.reaped == 0)
        #expect(result.planned.contains("REAP orphan-process pid=4242 tree=1 \(dead)"))
        #expect(result.planned.contains("KEEP nothing-signalled \(dead)"))
    }
}

/// Hands out one `ps` reading per call and then repeats the last, so a test can
/// make the process table change between the reading a sweep planned from and
/// the volley that acts on it. `nil` stands for a reading that could not be
/// taken at all.
private final class ScriptedReadings: @unchecked Sendable {
    private let lock = NSLock()
    private var readings: [[ProcessSnapshotEntry]?]

    init(_ readings: [[ProcessSnapshotEntry]?]) {
        self.readings = readings.isEmpty ? [[]] : readings
    }

    func next() -> [ProcessSnapshotEntry]? {
        lock.withLock { readings.count > 1 ? readings.removeFirst() : readings[0] }
    }
}

/// A keychain that records nothing and deletes nothing — this suite never
/// creates a profile dir, so the profile-dir phase has no work, but the sweep
/// still needs a collaborator that cannot reach the real login keychain.
private struct NoopKeychain: ClaudeCredentialsKeychainDeleting {
    func deleteGenericPassword(service: String) -> OSStatus { errSecItemNotFound }
}
