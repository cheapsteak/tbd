import Foundation
import DaemonTestSupport
import TestSupport
import Testing
@testable import TBDDaemonLib
@testable import TBDShared

/// Archive keeps a live tmux row's tab in the worktree's archived record,
/// marked, and a revive that would relaunch a marked tab asks the leftover-tmux
/// probe about the worktree's server first (`liveTmuxReviveRefusal`).
///
/// Each fixture is a real git worktree with a holder Claude tab, spawned
/// through the holder double, beside a seeded tmux Claude row. The probe is
/// injected and records what it was asked, so no test runs tmux or asks a
/// real socket.
@Suite("Revive gate for tabs live on tmux at archive")
struct LiveTmuxReviveGateTests {
    struct Fixture {
        let tempDir: URL
        let db: TBDDatabase
        let repo: Repo
        let worktree: Worktree
        let holder: FakeHolderLaunch
        let probe: RecordingLeftoverTmuxProbe
        let lifecycle: WorktreeLifecycle
        /// The session id of the seeded tmux row.
        let tmuxSessionID: String

        func tearDown() {
            try? FileManager.default.removeItem(at: tempDir)
        }

        func archivedRow() async throws -> Worktree {
            try #require(try await db.worktrees.get(id: worktree.id))
        }
    }

    /// An archived worktree whose tmux row was live, or parked when
    /// `tmuxRowParked`, at archive, with a probe that answers `serverState`.
    func archivedFixture(
        serverState: LeftoverTmuxServerState, tmuxRowParked: Bool = false
    ) async throws -> Fixture {
        let (tempDir, repoDir) = try await createTestRepo()
        let db = try TBDDatabase(inMemory: true)
        let holder = FakeHolderLaunch()
        let probe = RecordingLeftoverTmuxProbe { _ in serverState }
        var lifecycle = makeLifecycle(db: db, holder: holder)
        lifecycle.leftoverTmuxProbe = probe.probe
        let repo = try await makeTestRepo(db: db, tempDir: tempDir, repoDir: repoDir)

        let worktree = try await lifecycle.createWorktree(repoID: repo.id, skipClaude: false)
        let tmuxSessionID = UUID().uuidString.lowercased()
        let tmuxRow = try await db.terminals.create(
            worktreeID: worktree.id, tmuxWindowID: "@7", tmuxPaneID: "%7",
            label: "Claude Code", claudeSessionID: tmuxSessionID, kind: .claude,
            transport: .tmux)
        if tmuxRowParked {
            try await db.terminals.setSuspended(id: tmuxRow.id, sessionID: tmuxSessionID)
        }
        try await lifecycle.archiveWorktree(worktreeID: worktree.id, force: true)

        return Fixture(
            tempDir: tempDir, db: db, repo: repo, worktree: worktree, holder: holder,
            probe: probe, lifecycle: lifecycle, tmuxSessionID: tmuxSessionID)
    }

    @Test func archiveKeepsALiveTmuxRowsTabMarked() async throws {
        let fixture = try await archivedFixture(serverState: .running)
        defer { fixture.tearDown() }

        let tabs = try #require(try await fixture.archivedRow().archivedAgentTabs)
        let tmuxTab = try #require(tabs.first { $0.identity.sessionID == fixture.tmuxSessionID })
        #expect(tmuxTab.liveOnTmuxAtArchive == true)
        let holderTabs = tabs.filter { $0.identity.sessionID != fixture.tmuxSessionID }
        #expect(!holderTabs.isEmpty)
        #expect(holderTabs.allSatisfy { $0.liveOnTmuxAtArchive == nil })
        // Archive marks the row from the row alone; it asks no probe.
        #expect(fixture.probe.servers.isEmpty)
    }

    @Test func reviveRefusesWhileTheServerMayRunAndLeavesTheRecord() async throws {
        let fixture = try await archivedFixture(serverState: .running)
        defer { fixture.tearDown() }
        let before = try await fixture.archivedRow()
        let launchesBefore = fixture.holder.launches.count

        await #expect(throws: LiveTmuxReviveRefusal(server: fixture.worktree.tmuxServer)) {
            _ = try await fixture.lifecycle.reviveWorktree(
                worktreeID: fixture.worktree.id, skipClaude: false)
        }

        let after = try await fixture.archivedRow()
        #expect(after.status == .archived)
        #expect(after.archivedAgentTabs == before.archivedAgentTabs)
        #expect(after.archivedClaudeSessions == before.archivedClaudeSessions)
        #expect(try await fixture.db.terminals.list(worktreeID: fixture.worktree.id).isEmpty)
        #expect(fixture.holder.launches.count == launchesBefore)
        #expect(!FileManager.default.fileExists(atPath: fixture.worktree.localPath))
        #expect(fixture.probe.servers == [fixture.worktree.tmuxServer])
    }

    @Test func reviveRelaunchesOnTheHolderOnceTheServerIsGone() async throws {
        let fixture = try await archivedFixture(serverState: .absent)
        defer { fixture.tearDown() }

        let revived = try await fixture.lifecycle.reviveWorktree(
            worktreeID: fixture.worktree.id, skipClaude: false)

        let terminals = try await fixture.db.terminals.list(worktreeID: revived.id)
        let relaunched = try #require(terminals.first { $0.claudeSessionID == fixture.tmuxSessionID })
        #expect(relaunched.transport == .holder)
        #expect(fixture.holder.launches.contains { $0.terminalID == relaunched.id })
        #expect(terminals.allSatisfy { $0.transport == .holder })
        #expect(fixture.probe.servers == [fixture.worktree.tmuxServer])
    }

    /// The probe answers `.running`, so a revive that asked it would refuse:
    /// the success proves it was not asked.
    @Test func aParkedTmuxRowsTabIsUnmarkedAndRevivesWithoutTheProbe() async throws {
        let fixture = try await archivedFixture(serverState: .running, tmuxRowParked: true)
        defer { fixture.tearDown() }

        let tabs = try #require(try await fixture.archivedRow().archivedAgentTabs)
        let tmuxTab = try #require(tabs.first { $0.identity.sessionID == fixture.tmuxSessionID })
        #expect(tmuxTab.liveOnTmuxAtArchive == nil)

        let revived = try await fixture.lifecycle.reviveWorktree(
            worktreeID: fixture.worktree.id, skipClaude: false)

        let terminals = try await fixture.db.terminals.list(worktreeID: revived.id)
        let relaunched = try #require(terminals.first { $0.claudeSessionID == fixture.tmuxSessionID })
        #expect(relaunched.transport == .holder)
        #expect(fixture.holder.launches.contains { $0.terminalID == relaunched.id })
        #expect(fixture.probe.servers.isEmpty)
    }

    /// A revive that skips the agent tabs relaunches none of them, so a marked
    /// tab is no reason to ask, and the record stays for a later revive.
    @Test func aReviveThatSkipsTheAgentTabsAsksNothing() async throws {
        let fixture = try await archivedFixture(serverState: .running)
        defer { fixture.tearDown() }

        let revived = try await fixture.lifecycle.reviveWorktree(
            worktreeID: fixture.worktree.id, skipClaude: true)

        #expect(revived.status == .active)
        let terminals = try await fixture.db.terminals.list(worktreeID: revived.id)
        #expect(!terminals.contains { $0.claudeSessionID == fixture.tmuxSessionID })
        #expect(fixture.probe.servers.isEmpty)
    }

    /// Resuming the marked conversation on a fresh branch asks the same
    /// question, before any new worktree exists.
    @Test func aFreshBranchReviveOfTheMarkedConversationRefuses() async throws {
        let fixture = try await archivedFixture(serverState: .running)
        defer { fixture.tearDown() }
        let worktreesBefore = try await fixture.db.worktrees.list(repoID: fixture.repo.id).count

        await #expect(throws: LiveTmuxReviveRefusal(server: fixture.worktree.tmuxServer)) {
            _ = try await fixture.lifecycle.reviveConversationOnFreshBranch(
                archivedWorktreeID: fixture.worktree.id, sessionID: fixture.tmuxSessionID)
        }

        #expect(try await fixture.db.worktrees.list(repoID: fixture.repo.id).count == worktreesBefore)
        #expect(fixture.probe.servers == [fixture.worktree.tmuxServer])
    }

    @Test func theRefusalCarriesTheTmuxCodeAndTheCommandThatEndsTheServer() {
        let refusal = LiveTmuxReviveRefusal(server: "tbd-acme")
        #expect(refusal.coded.code == .terminalOnTmux)
        #expect(refusal.coded.text == refusal.message)
        #expect(refusal.message.contains("tmux -L tbd-acme kill-server"))
        #expect(refusal.message.contains("restart the Mac"))
    }
}
