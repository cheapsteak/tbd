import Foundation
import Testing
@testable import TBDDaemonLib
import TBDShared

/// `OrphanGC`'s supervision-desk leg: the reconciler that answers "who reclaims
/// an orphaned hosted desk" (repo `CLAUDE.md`).
///
/// The boundary this closes: the sweep's agent-worktree leg iterates
/// `db.repos.list()`, so it only ever sees repo-backed worktrees, and its
/// archived legs only touch rows that are already `.archived`. A desk's scratch
/// space is neither, so a live desk was never at risk from those legs — right —
/// and an orphaned one was reclaimed by nothing.
///
/// Tier 2 — real filesystem plus an in-memory database, the desk record injected
/// into a sandbox, the clock fixed, and `lsof` replaced by an explicit list.
@Suite("OrphanGC reclaims orphaned supervision desks")
struct OrphanGCSupervisionDeskTests: ~Copyable {
    let fm = FileManager.default
    let sandbox: URL
    let desks: SupervisionDesksStore
    /// Fixed sweep clock, far past every fixture's spawn stamp so the grace
    /// window has elapsed without backdating anything.
    let clock = Date(timeIntervalSince1970: 1_800_000_000)

    init() {
        sandbox = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("orphan-gc-desk-\(UUID().uuidString)", isDirectory: true)
        try? fm.createDirectory(at: sandbox, withIntermediateDirectories: true)
        desks = SupervisionDesksStore(fileURL: sandbox.appendingPathComponent("desks.json"))
    }

    deinit {
        try? fm.removeItem(at: sandbox)
    }

    // MARK: - Fixtures

    private func makeGC(db: TBDDatabase, liveCWDs: [String] = []) -> OrphanGC {
        let fixed = clock
        return OrphanGC(
            db: db, git: GitManager(),
            broadcast: { _ in },
            liveCWDsProvider: { liveCWDs },
            scratchpadBase: sandbox.appendingPathComponent("scratchpads", isDirectory: true),
            now: { fixed },
            profileDirBase: sandbox.appendingPathComponent("profiles", isDirectory: true),
            supervisionDesks: desks)
    }

    /// A desk on disk: a scratch worktree under the scratch base, a terminal row
    /// in it, and an entry in the record — the three things a spawn leaves
    /// behind.
    private func makeDesk(
        project: String, db: TBDDatabase, spawnedAgo: TimeInterval = 86_400
    ) async throws -> (worktree: Worktree, terminal: Terminal) {
        let base = TBDConstants.scratchDir
        try fm.createDirectory(at: base, withIntermediateDirectories: true)
        let path = base.appendingPathComponent("desk-\(UUID().uuidString.prefix(8))")
        try fm.createDirectory(at: path, withIntermediateDirectories: true)

        let worktree = try await db.worktrees.createScratch(
            name: path.lastPathComponent, displayName: "Supervisor · \(project)",
            path: path.path, tmuxServer: "tbd-scratch")
        let terminal = try await db.terminals.create(
            id: UUID(), worktreeID: worktree.id, tmuxWindowID: "@1", tmuxPaneID: "%1",
            label: TerminalLabel.claudeCode, claudeSessionID: nil, profileID: nil, kind: .claude)

        var file = try desks.load()
        file = file.recording(
            SupervisionDeskEntry(
                terminal: terminal.id, worktree: worktree.id,
                spawnedAt: SupervisionInstant(clock.addingTimeInterval(-spawnedAgo)),
                conductHash: "abc"),
            for: project)
        try desks.save(file)
        return (worktree, terminal)
    }

    private func enable(_ db: TBDDatabase, desks: Bool) async throws {
        try await db.config.setGCEnabled(true)
        try await db.config.setGCSupervisionDesksEnabled(desks)
    }

    // MARK: - Never reclaim a live desk

    @Test("a live desk survives a sweep: its record and its scratch space are untouched")
    func liveDeskSurvives() async throws {
        let db = try TBDDatabase(inMemory: true)
        try await enable(db, desks: true)
        let desk = try await makeDesk(project: "acme-web", db: db)

        // A process sitting in the desk's directory is the desk running — the
        // same evidence the agent-worktree leg gates on.
        let result = await makeGC(
            db: db, liveCWDs: [AgentWorktreeCollector.canon(desk.worktree.localPath)]
        ).sweep()

        #expect(result.planned.contains { $0 == "KEEP desk-live desk:acme-web" })
        #expect(!result.planned.contains { $0.hasPrefix("REAP supervision-desk") })
        #expect(try desks.load().desk(for: "acme-web") != nil)
        let row = try await db.worktrees.get(id: desk.worktree.id)
        #expect(row?.status == .active)
    }

    @Test("a desk spawned moments ago is kept, however quiet lsof is about it")
    func youngDeskIsKept() async throws {
        let db = try TBDDatabase(inMemory: true)
        try await enable(db, desks: true)
        _ = try await makeDesk(project: "acme-web", db: db, spawnedAgo: 5)

        let result = await makeGC(db: db).sweep()
        #expect(result.planned.contains { $0 == "KEEP desk-within-grace desk:acme-web" })
        #expect(try desks.load().desk(for: "acme-web") != nil)
    }

    // MARK: - Reclaim an orphan

    @Test("an orphaned desk is reclaimed: the record is dropped and the space archived")
    func orphanedDeskIsReclaimed() async throws {
        let db = try TBDDatabase(inMemory: true)
        try await enable(db, desks: true)
        let desk = try await makeDesk(project: "acme-web", db: db)

        // Nothing is running in it any more.
        let result = await makeGC(db: db).sweep()

        #expect(result.planned.contains {
            $0 == "REAP supervision-desk desk-process-gone desk:acme-web"
        })
        #expect(try desks.load().desk(for: "acme-web") == nil)
        // Handed to the archive path the sweep already runs; the deletion-queue
        // and scratchpad legs reclaim the directory from there.
        let row = try await db.worktrees.get(id: desk.worktree.id)
        #expect(row?.status == .archived)
    }

    @Test("a desk whose terminal row is gone is reclaimed too")
    func terminalRowGoneIsReclaimed() async throws {
        let db = try TBDDatabase(inMemory: true)
        try await enable(db, desks: true)
        let desk = try await makeDesk(project: "acme-web", db: db)
        try await db.terminals.delete(id: desk.terminal.id)

        let result = await makeGC(db: db).sweep()
        #expect(result.planned.contains {
            $0.hasPrefix("REAP supervision-desk desk-terminal-row-gone")
        })
        #expect(try desks.load().desk(for: "acme-web") == nil)
    }

    @Test("a record pointing at a worktree row that is gone is dropped, with nothing to archive")
    func worktreeRowGoneDropsTheRecord() async throws {
        let db = try TBDDatabase(inMemory: true)
        try await enable(db, desks: true)
        try desks.save(SupervisionDesksFile(desks: [
            "acme-web": SupervisionDeskEntry(
                terminal: UUID(), worktree: UUID(),
                spawnedAt: SupervisionInstant(clock.addingTimeInterval(-86_400)),
                conductHash: "abc")
        ]))

        let result = await makeGC(db: db).sweep()
        #expect(result.planned.contains {
            $0.hasPrefix("REAP supervision-desk desk-worktree-row-gone")
        })
        #expect(try desks.load().desk(for: "acme-web") == nil)
    }

    // MARK: - The soak gate

    @Test("the desk flag ships off: a real sweep leaves an orphan untouched")
    func flagOffIsNoOp() async throws {
        let db = try TBDDatabase(inMemory: true)
        try await enable(db, desks: false)
        let desk = try await makeDesk(project: "acme-web", db: db)

        let result = await makeGC(db: db).sweep()

        #expect(!result.planned.contains { $0.hasPrefix("REAP supervision-desk") })
        #expect(try desks.load().desk(for: "acme-web") != nil)
        let row = try await db.worktrees.get(id: desk.worktree.id)
        #expect(row?.status == .active)
    }

    @Test("a dry run plans what enabling the flag would reclaim, and touches nothing")
    func dryRunPlansPastTheFlag() async throws {
        let db = try TBDDatabase(inMemory: true)
        try await enable(db, desks: false)
        let desk = try await makeDesk(project: "acme-web", db: db)

        // Someone deciding whether to flip a default-off flag needs to see what
        // flipping it would reclaim before flipping it.
        let result = await makeGC(db: db).sweep(dryRun: true)

        #expect(result.planned.contains { $0.hasPrefix("REAP supervision-desk") })
        #expect(result.reaped == 0)
        #expect(try desks.load().desk(for: "acme-web") != nil)
        let row = try await db.worktrees.get(id: desk.worktree.id)
        #expect(row?.status == .active)
    }

    @Test("gc disabled wholesale leaves the record alone, flag or no flag")
    func gcDisabledIsNoOp() async throws {
        let db = try TBDDatabase(inMemory: true)
        try await db.config.setGCEnabled(false)
        try await db.config.setGCSupervisionDesksEnabled(true)
        _ = try await makeDesk(project: "acme-web", db: db)

        let result = await makeGC(db: db).sweep()
        #expect(result.planned == ["gc disabled"])
        #expect(try desks.load().desk(for: "acme-web") != nil)
    }
}
