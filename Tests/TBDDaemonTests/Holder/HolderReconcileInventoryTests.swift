import Darwin
import Foundation
import TestSupport
import Testing
@testable import TBDDaemonLib
@testable import TBDShared

/// The **inventory direction** of the holder reconciler: the holder is gone and
/// the session row is still there
/// (`docs/specs/2026-08-30-pty-holder-session-transport-design.md`,
/// "Reconciliation").
///
/// `HolderReconcileExemptionTests` covers the other half — a holder row this
/// daemon knows nothing about must survive the tmux sweep untouched — and the
/// two suites are deliberately separate: that one asserts an exemption, this
/// one asserts the judgement the exemption was holding a place for.
///
/// **Tier 2, and that is checked rather than assumed.** Nothing here spawns a
/// `TBDHolder`: the "holder is gone" fixture is a rendezvous directory with no
/// socket in it, which is exactly what a holder that died leaves behind, and
/// the classification tests drive the production classifier with a pinned
/// answer. Only a fixture that spawns a real holder is tier 3
/// (`HolderReaderTestSupport.swift`), so the plan's path is right this time.
@Suite("Holder rows the sweep may judge")
struct HolderReconcileInventoryTests {

    // MARK: - Fixture

    /// A rendezvous root with nothing listening in it — a holder that died.
    ///
    /// Short on purpose: the socket path derived under it is handed to
    /// `connect(2)`, and `sun_path` is 104 bytes.
    private func vanishedHolderEnvironment() -> [String: String] {
        ["TBD_HOME": "/tmp/tbdrec-\(UUID().uuidString.prefix(8).lowercased())"]
    }

    private func registry(environment: [String: String]) -> HolderRegistry {
        HolderRegistry(
            owner: HolderOwnerToken(rawValue: UUID().uuidString),
            environment: environment,
            listTerminals: { [] })
    }

    /// Dry-run tmux with every window reported dead — the state a holder row
    /// produces against a real server, since `windowExists("")` cannot succeed.
    private func deadWindowTmux() -> TmuxManager {
        TmuxManager(dryRun: true, dryRunWindowIsDead: { _ in true })
    }

    private func seedRepo(db: TBDDatabase, at repoPath: String) async throws -> (Repo, Worktree) {
        let repo = try await db.repos.create(
            path: repoPath, displayName: "acme", defaultBranch: "main")
        let main = try await db.worktrees.createMain(
            repoID: repo.id, name: "main", branch: "main", path: repoPath,
            tmuxServer: TmuxManager.serverName(forRepoPath: repoPath))
        return (repo, main)
    }

    /// A signaller for which every pid named here is gone. The production one
    /// would run `kill(pid, 0)` against the developer's live process table,
    /// where a fixture pid may well name somebody's real process.
    private func deadJobs(_ pids: [Int32]) -> FakeProcessSignaller {
        let signaller = FakeProcessSignaller()
        for pid in pids {
            signaller.behaviors[pid] = FakeProcessSignaller.Behavior(aliveInitially: false)
        }
        return signaller
    }

    private func makeLifecycle(
        db: TBDDatabase, signaller: ProcessSignaller, registry: HolderRegistry?
    ) -> WorktreeLifecycle {
        var lifecycle = WorktreeLifecycle(
            db: db, git: GitManager(), tmux: deadWindowTmux(), hooks: HookResolver(),
            processSignaller: signaller)
        lifecycle.holderRegistry = registry
        return lifecycle
    }

    private func description(
        owner: HolderOwnerToken, status: HolderChildStatus, childPID: Int32 = 4243
    ) -> HolderChildDescription {
        HolderChildDescription(
            childPID: childPID,
            ttyName: "/dev/ttys009",
            status: status,
            launch: HolderLaunchRequest(
                executable: "/bin/sh", arguments: ["-c", "true"], workingDirectory: "/tmp",
                environment: [:], columns: 80, rows: 24),
            owner: owner)
    }

    // MARK: - The sweep

    @Test("a holder-backed row whose holder is gone is parked or deleted")
    func vanishedHolderRowsAreReconciled() async throws {
        let (tempDir, repoDir) = try await createTestRepoResolvingSymlinks()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let db = try TBDDatabase(inMemory: true)
        let lifecycle = makeLifecycle(
            db: db,
            signaller: deadJobs([4243, 4245]),
            registry: registry(environment: vanishedHolderEnvironment()))
        let (repo, main) = try await seedRepo(db: db, at: repoDir.path)

        let claude = try await db.terminals.create(
            worktreeID: main.id, tmuxWindowID: "", tmuxPaneID: "",
            label: TerminalLabel.claudeCode, claudeSessionID: "sess-holder",
            kind: .claude, transport: .holder, holderPID: 4242, childPID: 4243)
        let shell = try await db.terminals.create(
            worktreeID: main.id, tmuxWindowID: "", tmuxPaneID: "",
            kind: .shell, transport: .holder, holderPID: 4244, childPID: 4245)

        try await lifecycle.reconcile(
            repoID: repo.id,
            actuationLog: makeTestActuationLog(),
            reapSharedScratchTmuxResources: true)

        let parked = try #require(
            try await db.terminals.get(id: claude.id),
            "the sweep deleted a resumable Claude row instead of parking it")
        #expect(
            parked.hibernatedAt != nil,
            "a holder-backed Claude row whose holder is gone was left unparked")
        #expect(parked.hibernateReason == .recovery)
        #expect(
            try await db.terminals.get(id: shell.id) == nil,
            "a holder-backed shell row whose holder is gone was left in the inventory")
    }

    @Test("a holder-backed row whose job is still running is left alone")
    func aLiveJobKeepsItsRow() async throws {
        let (tempDir, repoDir) = try await createTestRepoResolvingSymlinks()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let db = try TBDDatabase(inMemory: true)
        // The holder is gone by the same fixture as above; only the job's
        // liveness differs, which is the fact under test.
        let signaller = FakeProcessSignaller()
        signaller.behaviors[4243] = FakeProcessSignaller.Behavior(aliveInitially: true)
        signaller.behaviors[4245] = FakeProcessSignaller.Behavior(aliveInitially: true)
        let lifecycle = makeLifecycle(
            db: db, signaller: signaller,
            registry: registry(environment: vanishedHolderEnvironment()))
        let (repo, main) = try await seedRepo(db: db, at: repoDir.path)

        let claude = try await db.terminals.create(
            worktreeID: main.id, tmuxWindowID: "", tmuxPaneID: "",
            label: TerminalLabel.claudeCode, claudeSessionID: "sess-holder",
            kind: .claude, transport: .holder, holderPID: 4242, childPID: 4243)
        let shell = try await db.terminals.create(
            worktreeID: main.id, tmuxWindowID: "", tmuxPaneID: "",
            kind: .shell, transport: .holder, holderPID: 4244, childPID: 4245)

        try await lifecycle.reconcile(
            repoID: repo.id,
            actuationLog: makeTestActuationLog(),
            reapSharedScratchTmuxResources: true)

        let survivingClaude = try #require(
            try await db.terminals.get(id: claude.id),
            "the sweep deleted the row that is the only record of a running job's pid")
        #expect(
            survivingClaude.hibernatedAt == nil,
            "the sweep parked a row whose job is still running")
        #expect(
            try await db.terminals.get(id: shell.id) != nil,
            "the sweep deleted the row that is the only record of a running job's pid")
    }

    // MARK: - The classification

    @Test("nothing at the rendezvous is an exit nobody observed, never a clean one")
    func absenceIsStatusUnknown() async throws {
        let owner = HolderOwnerToken(rawValue: "owner-a")
        for code in [ENOENT, ECONNREFUSED] {
            let verdict = await WorktreeLifecycle.holderRowVerdict(expecting: owner) {
                throw HolderClient.Error.cannotConnect(path: "/tmp/gone.sock", errno: code)
            }
            #expect(verdict == .sessionOver(.exitedStatusUnknown))
            #expect(
                verdict != .sessionOver(.exited(code: 0)),
                "an exit nobody observed was reported as a clean exit")
        }
    }

    @Test("a rejected connection is terminal in both directions")
    func aRejectionIsNeverAnExit() async {
        let verdict = await WorktreeLifecycle.holderRowVerdict(
            expecting: HolderOwnerToken(rawValue: "owner-a")
        ) {
            throw HolderClient.Error.rejected(version: 1)
        }
        #expect(
            verdict == .keep(reason: "rejected"),
            "a live holder serving somebody else was read as a dead one")
    }

    @Test("a round trip that merely failed establishes nothing")
    func anUnreadableAnswerKeeps() async {
        let owner = HolderOwnerToken(rawValue: "owner-a")
        // EMFILE describes THIS process failing to open a connection, and says
        // nothing whatever about the child.
        let unreachable = await WorktreeLifecycle.holderRowVerdict(expecting: owner) {
            throw HolderClient.Error.cannotConnect(path: "/tmp/busy.sock", errno: EMFILE)
        }
        #expect(unreachable == .keep(reason: "unestablished"))

        let hungUp = await WorktreeLifecycle.holderRowVerdict(expecting: owner) {
            throw HolderClient.Error.peerClosed
        }
        #expect(hungUp == .keep(reason: "unestablished"))
    }

    @Test("a holder that answers decides the row by what it says")
    func adescribedHolderDecidesTheRow() async {
        let owner = HolderOwnerToken(rawValue: "owner-a")

        let alive = await WorktreeLifecycle.holderRowVerdict(expecting: owner) {
            description(owner: owner, status: .alive)
        }
        #expect(alive == .keep(reason: "alive"))

        let exited = await WorktreeLifecycle.holderRowVerdict(expecting: owner) {
            description(owner: owner, status: .exited(code: 3))
        }
        #expect(
            exited == .sessionOver(.exited(code: 3)),
            "a real exit code was not carried through")

        let foreign = await WorktreeLifecycle.holderRowVerdict(expecting: owner) {
            description(owner: HolderOwnerToken(rawValue: "owner-b"), status: .exitedStatusUnknown)
        }
        #expect(
            foreign == .keep(reason: "foreign-owner"),
            "another installation's holder was allowed to decide one of our rows")
    }
}
