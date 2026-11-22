import Foundation
import DaemonTestSupport
import TestSupport
import Testing
@testable import TBDDaemonLib
@testable import TBDShared

/// Closing a live tmux row (`WorktreeLifecycle.closeLeftoverTmuxRow`) and every
/// teardown that deletes one: the Closed Terminals entry it writes is marked
/// with the tmux server its session may still run in, a hard delete keeps the
/// marked entries, and a mark that cannot be written refuses the whole act
/// before anything else is done — no tombstone, no holder disposed of, no row
/// deleted — worded for the act.
///
/// Every fixture injects a recording probe that answers `.running`, so no test
/// asks a real socket. A mark that cannot be written is produced by
/// `TBDDatabase.failTerminalHistoryWritesForTests`, an SQLite trigger that
/// aborts every `terminal_history` insert and update.
@Suite("Closing leftover tmux rows")
struct LeftoverTmuxCloseTests {

    // MARK: - An empty server

    /// A worktree whose tmux server is recorded empty names no server, so a
    /// close of its live tmux row writes no entry and does not throw. The
    /// control closes the same row with a server named, and that close marks
    /// it: the row is one the close would otherwise mark.
    @Test func anEmptyServerLeavesNoEntryAndANamedOneIsMarked() async throws {
        let f = try await makeCloseTestsLifecycleFixture()
        defer { f.tearDown() }
        let row = try await f.openLiveTmuxRow(session: "sess-acme-empty")

        try await WorktreeLifecycle.closeLeftoverTmuxRow(
            row, server: "", history: f.db.terminalHistory)
        try await WorktreeLifecycle.closeLeftoverTmuxRow(
            row, server: nil, history: f.db.terminalHistory)

        #expect(try await f.db.terminalHistory.list(worktreeID: f.worktree.id).isEmpty,
                "a close with no server wrote an entry")

        try await WorktreeLifecycle.closeLeftoverTmuxRow(
            row, server: "tbd-acme", history: f.db.terminalHistory)

        let entries = try await f.db.terminalHistory.list(worktreeID: f.worktree.id)
        #expect(entries.map(\.id) == [row.id])
        #expect(entries.first?.liveOnTmuxServer == "tbd-acme")
    }

    /// A mark that stores an empty server names nothing to probe, so the gate
    /// lets a start of its session through without asking. The store does
    /// return the empty server, so it is the gate that drops it. The control
    /// marks another session with a real server, and the gate asks about that
    /// one and refuses.
    @Test func theResumeGateNeverAsksAboutAStoredEmptyMark() async throws {
        let f = try await makeCloseTestsLifecycleFixture()
        defer { f.tearDown() }
        let emptyMarked = TBDShared.Terminal(
            worktreeID: f.worktree.id, tmuxWindowID: "@11", tmuxPaneID: "%11",
            claudeSessionID: "sess-acme-empty-mark", kind: .claude)
        try await f.db.terminalHistory.recordLiveTmuxClose(terminal: emptyMarked, server: "")
        try #require(try await f.db.terminalHistory
            .liveOnTmuxServers(sessionIDs: ["sess-acme-empty-mark"]) == [""])

        #expect(try await f.lifecycle.tmuxResumeRefusal(
            resuming: ["sess-acme-empty-mark"], worktreeServer: nil) == nil)
        #expect(try await f.lifecycle.tmuxResumeRefusal(
            resuming: ["sess-acme-empty-mark"], worktreeServer: "") == nil)
        #expect(f.probe.servers.isEmpty, "the gate asked about an empty server: \(f.probe.servers)")

        let marked = TBDShared.Terminal(
            worktreeID: f.worktree.id, tmuxWindowID: "@12", tmuxPaneID: "%12",
            claudeSessionID: "sess-acme-real-mark", kind: .claude)
        try await f.db.terminalHistory.recordLiveTmuxClose(terminal: marked, server: "tbd-acme")

        #expect(try await f.lifecycle.tmuxResumeRefusal(resuming: ["sess-acme-real-mark"])
            == TmuxResumeRefusal(server: "tbd-acme"))
        #expect(f.probe.servers == ["tbd-acme"])
    }

    // MARK: - A park in flight

    /// A row whose park is in flight is closed as a live row, and its marked
    /// entry keeps the screen the park saved. An unparked row's marked entry
    /// keeps no screen, even when the row still carries one from an earlier
    /// park that a wake left behind: only a park in flight passes its screen
    /// on, so an entry with that stale text fails this test.
    @Test func aParkInFlightRowsMarkKeepsTheParksScreenAndAnUnparkedRowsKeepsNone() async throws {
        let f = try await makeCloseTestsLifecycleFixture()
        defer { f.tearDown() }
        let snapshot = "acme park screen\nsecond line"

        let inFlight = try await f.openLiveTmuxRow(session: "sess-acme-in-flight")
        _ = try #require(try await f.db.terminals.beginHibernatedShellRespawn(
            id: inFlight.id, expectedState: TerminalHibernationSnapshot(terminal: inFlight),
            snapshot: snapshot, reason: .auto))
        let parking = try #require(try await f.db.terminals.get(id: inFlight.id))
        try #require(parking.isParked)
        try #require(parking.pendingSessionIncarnationID != nil)
        try #require(parking.suspendedSnapshot == snapshot)

        let woken = try await f.openLiveTmuxRow(session: "sess-acme-woken")
        try await f.db.terminals.setHibernated(
            id: woken.id, sessionID: "sess-acme-woken", snapshot: "acme stale screen",
            reason: .auto)
        try await f.db.terminals.clearHibernated(id: woken.id)
        let unparked = try #require(try await f.db.terminals.get(id: woken.id))
        try #require(!unparked.isParked)
        try #require(unparked.suspendedSnapshot == "acme stale screen")

        try await WorktreeLifecycle.closeLeftoverTmuxRow(
            parking, server: "tbd-acme", history: f.db.terminalHistory)
        try await WorktreeLifecycle.closeLeftoverTmuxRow(
            unparked, server: "tbd-acme", history: f.db.terminalHistory)

        let entries = try await f.db.terminalHistory.list(worktreeID: f.worktree.id)
        let inFlightEntry = try #require(entries.first { $0.id == inFlight.id })
        #expect(inFlightEntry.liveOnTmuxServer == "tbd-acme")
        #expect(inFlightEntry.lineCount == 2)
        let inFlightText = try String(
            contentsOfFile: f.db.terminalHistory.contentPath(
                worktreeID: f.worktree.id, terminalID: inFlight.id),
            encoding: .utf8)
        #expect(inFlightText == snapshot)

        let unparkedEntry = try #require(entries.first { $0.id == woken.id })
        #expect(unparkedEntry.liveOnTmuxServer == "tbd-acme")
        #expect(unparkedEntry.lineCount == 0)
        #expect(!FileManager.default.fileExists(atPath: f.db.terminalHistory.contentPath(
            worktreeID: f.worktree.id, terminalID: woken.id)))
    }

    // MARK: - The refusal's wording

    /// Closing one tab is refused as that tab; every other act says the whole
    /// act did not happen, in its own words and in no other act's. A swapped
    /// or shared outcome phrase fails here.
    @Test func eachActsRefusalSaysWhatDidNotHappen() {
        let id = UUID()
        let tab = LeftoverTmuxMarkUnwritable(
            terminalID: id, server: "tbd-acme", reason: "acme disk full")
        #expect(tab.act == .closingTab)
        #expect(tab.message.hasPrefix("Terminal \(id) was not closed."))
        #expect(tab.message.contains("tmux server tbd-acme"))
        #expect(tab.message.contains("(acme disk full)"))
        #expect(tab.message.contains("so the tab stays open"))
        #expect(tab.errorDescription == tab.message)
        #expect(tab.description == tab.message)

        let outcomes: [(act: LeftoverTmuxMarkUnwritable.Act, outcome: String)] = [
            (.archivingWorktree, "the worktree was not archived"),
            (.archivingScratchSpace, "the scratch space was not archived"),
            (.forgettingWorktree, "the worktree was not forgotten"),
            (.deletingScratchSpace, "the scratch space was not deleted"),
            (.removingRepo, "the repository was not removed"),
        ]
        for (act, outcome) in outcomes {
            let refusal = tab.during(act)
            #expect(refusal.act == act)
            #expect(refusal.terminalID == id)
            #expect(refusal.server == "tbd-acme")
            #expect(refusal.reason == "acme disk full")
            let message = refusal.message
            #expect(message.hasPrefix("Tab \(id) is on tmux"), "\(act): \(message)")
            #expect(message.contains("tmux server tbd-acme"), "\(act): \(message)")
            #expect(message.contains("(acme disk full)"), "\(act): \(message)")
            #expect(message.contains("so \(outcome) and that tab stays open"), "\(act): \(message)")
            #expect(!message.contains("was not closed"), "\(act): \(message)")
            for other in outcomes where other.act != act {
                #expect(!message.contains(other.outcome), "\(act) names \(other.act)'s outcome")
            }
            #expect(refusal.errorDescription == message)
            #expect(refusal.description == message)
        }
        #expect(tab.during(.removingRepo).during(.closingTab).message == tab.message)
    }

    // MARK: - Hard deletes

    /// The store's hard delete removes a worktree's entries and their screens,
    /// all but the marked ones, which stay readable to the gate.
    @Test func deleteForWorktreeRemovesUnmarkedEntriesAndKeepsMarkedOnes() async throws {
        let f = try await makeCloseTestsLifecycleFixture()
        defer { f.tearDown() }
        let closed = TBDShared.Terminal(
            worktreeID: f.worktree.id, tmuxWindowID: "", tmuxPaneID: "",
            claudeSessionID: "sess-acme-closed", kind: .claude)
        let marked = TBDShared.Terminal(
            worktreeID: f.worktree.id, tmuxWindowID: "@13", tmuxPaneID: "%13",
            claudeSessionID: "sess-acme-marked", kind: .claude)
        await f.db.terminalHistory.recordOnClose(terminal: closed, capture: "acme closed screen")
        try await f.db.terminalHistory.recordLiveTmuxClose(terminal: marked, server: "tbd-acme")
        let closedPath = f.db.terminalHistory.contentPath(
            worktreeID: f.worktree.id, terminalID: closed.id)
        try #require(Set(try await f.db.terminalHistory.list(worktreeID: f.worktree.id).map(\.id))
            == [closed.id, marked.id])
        try #require(FileManager.default.fileExists(atPath: closedPath))

        try await f.db.terminalHistory.deleteForWorktree(worktreeID: f.worktree.id)

        let after = try await f.db.terminalHistory.list(worktreeID: f.worktree.id)
        #expect(after.map(\.id) == [marked.id])
        #expect(after.first?.liveOnTmuxServer == "tbd-acme")
        #expect(!FileManager.default.fileExists(atPath: closedPath))
        #expect(try await f.db.terminalHistory.liveOnTmuxServers(sessionIDs: ["sess-acme-marked"])
            == ["tbd-acme"])
    }

    /// Forget closes the live tmux row with a mark, disposes of the holder,
    /// and hard-deletes the worktree's history except that mark. The mark is
    /// then the only record of the session, and the gate still refuses a
    /// resume of it while the server may run.
    @Test func forgetKeepsTheMarkOfALiveTmuxRowAfterTheWorktreeIsGone() async throws {
        let f = try await makeCloseTestsLifecycleFixture()
        defer { f.tearDown() }
        let tmuxRow = try await f.openLiveTmuxRow(session: "sess-acme-forget")
        let holderRow = try await f.spawnHolderClaude(session: "sess-acme-forget-holder")
        let closed = TBDShared.Terminal(
            worktreeID: f.worktree.id, tmuxWindowID: "", tmuxPaneID: "",
            claudeSessionID: "sess-acme-forget-closed", kind: .claude)
        await f.db.terminalHistory.recordOnClose(terminal: closed, capture: "acme closed screen")

        try await f.lifecycle.forgetWorktree(worktreeID: f.worktree.id)

        #expect(try await f.db.worktrees.get(id: f.worktree.id) == nil)
        #expect(try await f.db.forgottenWorktrees.contains(path: f.worktreePath))
        #expect(try await f.db.terminals.list(worktreeID: f.worktree.id).isEmpty)
        #expect(f.holder.abandonments.map(\.terminalID) == [holderRow.id])
        let entries = try await f.db.terminalHistory.list(worktreeID: f.worktree.id)
        #expect(entries.map(\.id) == [tmuxRow.id])
        #expect(entries.first?.liveOnTmuxServer == "tbd-acme")
        #expect(try await f.lifecycle.tmuxResumeRefusal(resuming: ["sess-acme-forget"])
            == TmuxResumeRefusal(server: "tbd-acme"))
    }

    /// A forget whose mark cannot be written is refused before its tombstone
    /// and before any holder is disposed of: the worktree, every row and the
    /// holder stay as they were, and the refusal says the worktree was not
    /// forgotten. The same fixture's forget disposes of the holder when the
    /// mark can be written (`forgetKeepsTheMarkOfALiveTmuxRowAfterTheWorktreeIsGone`),
    /// so an empty `abandonments` here means the refusal came first.
    @Test func aForgetWhoseMarkCannotBeWrittenIsRefusedBeforeTheTombstoneAndAnyHolder() async throws {
        let f = try await makeCloseTestsLifecycleFixture()
        defer { f.tearDown() }
        let tmuxRow = try await f.openLiveTmuxRow(session: "sess-acme-refused")
        _ = try await f.spawnHolderClaude(session: "sess-acme-refused-holder")
        let rowsBefore = try await f.db.terminals.list(worktreeID: f.worktree.id)
        try #require(rowsBefore.count == 2)
        try await f.db.failTerminalHistoryWritesForTests()

        let error = await #expect(throws: LeftoverTmuxMarkUnwritable.self) {
            try await f.lifecycle.forgetWorktree(worktreeID: f.worktree.id)
        }

        #expect(error?.act == .forgettingWorktree)
        #expect(error?.terminalID == tmuxRow.id)
        #expect(error?.message.contains("the worktree was not forgotten") == true,
                "message: \(error?.message ?? "nil")")
        #expect(try await f.db.worktrees.get(id: f.worktree.id) != nil)
        #expect(!(try await f.db.forgottenWorktrees.contains(path: f.worktreePath)),
                "the forget tombstoned the path although it was refused")
        #expect(try await f.db.terminals.list(worktreeID: f.worktree.id) == rowsBefore)
        #expect(f.holder.abandonments.isEmpty,
                "the forget disposed of a holder before it was refused: \(f.holder.abandonments)")
        #expect(try await f.db.terminalHistory.list(worktreeID: f.worktree.id).isEmpty)
    }

    /// `scratch.delete` marks a live tmux row's entry with the scratch space's
    /// server, and its hard delete keeps that entry while removing the
    /// unmarked one. The scratch folder does not exist, so nothing is moved to
    /// the Trash.
    @Test func scratchDeleteKeepsALiveTmuxRowsMarkedEntry() async throws {
        let f = try await makeCloseTestsRouterFixture()
        defer { f.tearDown() }
        let scratch = try await f.db.worktrees.createScratch(
            name: "acme-scratch", displayName: "Acme Scratch",
            path: f.root.appendingPathComponent("acme-scratch-folder").path,
            tmuxServer: "tbd-acme-scratch")
        try #require(!FileManager.default.fileExists(atPath: scratch.localPath))
        let row = try await f.openLiveTmuxRow(in: scratch, session: "sess-acme-scratch")
        let closed = TBDShared.Terminal(
            worktreeID: scratch.id, tmuxWindowID: "", tmuxPaneID: "",
            claudeSessionID: "sess-acme-scratch-closed", kind: .claude)
        await f.db.terminalHistory.recordOnClose(terminal: closed, capture: "acme closed screen")

        let response = try await f.send(
            RPCMethod.scratchDelete, ScratchDeleteParams(worktreeID: scratch.id))

        #expect(response.success, "error: \(response.error ?? "nil")")
        #expect(try await f.db.worktrees.get(id: scratch.id) == nil)
        let entries = try await f.db.terminalHistory.list(worktreeID: scratch.id)
        #expect(entries.map(\.id) == [row.id])
        #expect(entries.first?.liveOnTmuxServer == "tbd-acme-scratch")
    }

    /// A `scratch.delete` whose mark cannot be written is refused as a delete,
    /// not as an archive, with the scratch space and its row kept.
    @Test func aScratchDeleteWhoseMarkCannotBeWrittenIsRefusedAsADelete() async throws {
        let f = try await makeCloseTestsRouterFixture()
        defer { f.tearDown() }
        let scratch = try await f.db.worktrees.createScratch(
            name: "acme-scratch", displayName: "Acme Scratch",
            path: f.root.appendingPathComponent("acme-scratch-folder").path,
            tmuxServer: "tbd-acme-scratch")
        let row = try await f.openLiveTmuxRow(in: scratch, session: "sess-acme-scratch")
        try await f.db.failTerminalHistoryWritesForTests()

        let response = try await f.send(
            RPCMethod.scratchDelete, ScratchDeleteParams(worktreeID: scratch.id))

        #expect(!response.success)
        let error = try #require(response.error)
        #expect(error.contains("the scratch space was not deleted"), "error: \(error)")
        #expect(error.contains("Tab \(row.id) is on tmux"), "error: \(error)")
        #expect(try await f.db.worktrees.get(id: scratch.id) != nil)
        #expect(try await f.db.terminals.list(worktreeID: scratch.id) == [row])
    }

    // MARK: - repo.remove

    /// A forced `repo.remove` with no active worktree archives nothing, so no
    /// archive closes the main worktree's tmux row or an archived worktree's.
    /// It closes them itself: each entry is marked with its own worktree's
    /// server and outlives the repo.
    @Test func aForcedRepoRemovalMarksTheTmuxRowsNoArchiveReaches() async throws {
        let f = try await makeCloseTestsRouterFixture()
        defer { f.tearDown() }
        let repoPath = f.root.appendingPathComponent("acme-repo").path
        let repo = try await f.db.repos.create(
            path: repoPath, displayName: "acme", defaultBranch: "main")
        let main = try await f.db.worktrees.createMain(
            repoID: repo.id, name: "main", branch: "main", path: repoPath,
            tmuxServer: "tbd-acme-main")
        let archived = try await f.db.worktrees.create(
            repoID: repo.id, name: "acme-old", branch: "acme-old",
            path: f.root.appendingPathComponent("acme-old").path, tmuxServer: "tbd-acme-old")
        try await f.db.worktrees.archive(id: archived.id)
        let mainRow = try await f.openLiveTmuxRow(in: main, session: "sess-acme-main")
        let archivedRow = try await f.openLiveTmuxRow(in: archived, session: "sess-acme-old")

        let response = try await f.send(
            RPCMethod.repoRemove, RepoRemoveParams(repoID: repo.id, force: true))

        #expect(response.success, "error: \(response.error ?? "nil")")
        #expect(try await f.db.repos.get(id: repo.id) == nil)
        #expect(try await f.db.terminals.get(id: mainRow.id) == nil)
        let mainEntry = try #require(try await f.db.terminalHistory.list(worktreeID: main.id)
            .first { $0.id == mainRow.id })
        #expect(mainEntry.liveOnTmuxServer == "tbd-acme-main")
        let archivedEntry = try #require(try await f.db.terminalHistory
            .list(worktreeID: archived.id).first { $0.id == archivedRow.id })
        #expect(archivedEntry.liveOnTmuxServer == "tbd-acme-old")
        #expect(try await f.db.terminalHistory.liveOnTmuxServers(
            sessionIDs: ["sess-acme-main", "sess-acme-old"]) == ["tbd-acme-main", "tbd-acme-old"])
    }

    /// A `repo.remove` whose main worktree's mark cannot be written is refused
    /// as a removal, with the repo, the main worktree and its tmux row kept.
    @Test func aRepoRemovalWhoseMarkCannotBeWrittenIsRefusedWithEveryRowKept() async throws {
        let f = try await makeCloseTestsRouterFixture()
        defer { f.tearDown() }
        let repoPath = f.root.appendingPathComponent("acme-repo").path
        let repo = try await f.db.repos.create(
            path: repoPath, displayName: "acme", defaultBranch: "main")
        let main = try await f.db.worktrees.createMain(
            repoID: repo.id, name: "main", branch: "main", path: repoPath,
            tmuxServer: "tbd-acme-main")
        let mainRow = try await f.openLiveTmuxRow(in: main, session: "sess-acme-main")
        try await f.db.failTerminalHistoryWritesForTests()

        let response = try await f.send(
            RPCMethod.repoRemove, RepoRemoveParams(repoID: repo.id, force: true))

        #expect(!response.success)
        let error = try #require(response.error)
        #expect(error.contains("the repository was not removed"), "error: \(error)")
        #expect(error.contains("Tab \(mainRow.id) is on tmux"), "error: \(error)")
        #expect(error.contains("tmux server tbd-acme-main"), "error: \(error)")
        #expect(try await f.db.repos.get(id: repo.id) != nil)
        #expect(try await f.db.worktrees.get(id: main.id) != nil)
        #expect(try await f.db.terminals.get(id: mainRow.id) == mainRow)
        #expect(try await f.db.terminalHistory.list(worktreeID: main.id).isEmpty)
    }

    /// The cascade archives the first worktree, then stops at the second,
    /// whose live tmux row cannot be marked. The removal is refused with the
    /// repo and the second worktree kept, and the first, already archived,
    /// still gets the phase 2 every archive gets: its directory leaves its
    /// slot and `onWorktreeRemoved` fires for it. A stopped cascade that left
    /// its completed archives without phase 2 never fires it, and the wait
    /// times out.
    @Test func aCascadeStoppedByAnUnwritableMarkStillFinishesTheArchiveItCompleted() async throws {
        let f = try await makeCloseTestsRouterFixture()
        defer { f.tearDown() }
        let repo = try await f.db.repos.create(
            path: f.root.appendingPathComponent("acme-repo").path,
            displayName: "acme", defaultBranch: "main")
        let first = try await f.makeActiveWorktree(
            repoID: repo.id, name: "acme-first", server: "tbd-acme-first")
        let second = try await f.makeActiveWorktree(
            repoID: repo.id, name: "acme-second", server: "tbd-acme-second")
        try #require(try await f.db.worktrees.list(repoID: repo.id, status: .active).map(\.id)
            == [first.id, second.id], "the cascade does not take the worktrees in this order")
        let tmuxRow = try await f.openLiveTmuxRow(in: second, session: "sess-acme-second")
        try await f.db.failTerminalHistoryWritesForTests()

        let response = try await f.send(
            RPCMethod.repoRemove, RepoRemoveParams(repoID: repo.id, force: true))

        #expect(!response.success)
        let error = try #require(response.error)
        #expect(error.contains("the repository was not removed"), "error: \(error)")
        #expect(error.contains("Tab \(tmuxRow.id) is on tmux"), "error: \(error)")
        #expect(try await f.db.repos.get(id: repo.id) != nil)
        #expect(try await f.db.worktrees.get(id: first.id)?.status == .archived)
        #expect(try await f.db.worktrees.get(id: second.id)?.status == .active)
        #expect(try await f.db.terminals.get(id: tmuxRow.id) == tmuxRow)

        try await f.waitForPhase2(of: first.localPath)

        #expect(!FileManager.default.fileExists(atPath: first.localPath))
        #expect(FileManager.default.fileExists(atPath: second.localPath))
    }

    // MARK: - Reconcile

    /// Reconcile's archive of a worktree whose checkout is gone closes its
    /// tmux rows before it ends any holder session. While the live tmux row's
    /// mark cannot be written, the sweep leaves the worktree for the next one:
    /// no holder is disposed of and both rows stay. The next sweep that can
    /// write the mark is the control: it disposes of the holder, marks the
    /// tmux row's entry and archives the worktree.
    @Test func reconcileDisposesOfNoHolderWhileATmuxMarkCannotBeWrittenAndDisposesOnceItCan() async throws {
        let (tempDir, repoDir) = try await createTestRepoResolvingSymlinks()
        defer { try? FileManager.default.removeItem(at: tempDir) }
        let db = try TBDDatabase(
            inMemory: true, terminalHistoryDir: tempDir.appendingPathComponent("history").path)
        let holder = FakeHolderLaunch()
        let probe = RecordingLeftoverTmuxProbe { _ in .running }
        let lifecycle = makeCloseTestsLifecycle(
            db: db, root: tempDir, holder: holder,
            manager: makeCloseTestsConfigDirManager(root: tempDir), probe: probe)
        let repo = try await db.repos.create(
            path: repoDir.path, displayName: "acme", defaultBranch: "main")
        let worktree = try await db.worktrees.create(
            repoID: repo.id, name: "gone", branch: "gone-branch",
            path: tempDir.appendingPathComponent("vanished").path, tmuxServer: "tbd-acme-gone")
        let holderRow = try await spawnCloseTestsHolderClaude(
            lifecycle: lifecycle, holder: holder, worktreeID: worktree.id,
            workingDirectory: tempDir.path, session: "sess-acme-gone-holder")
        let created = try await db.terminals.create(
            worktreeID: worktree.id, tmuxWindowID: "@14", tmuxPaneID: "%14",
            label: TerminalLabel.claudeCode, claudeSessionID: "sess-acme-gone-tmux",
            kind: .claude, transport: .tmux)
        let tmuxRow = try #require(try await db.terminals.get(id: created.id))
        try await db.failTerminalHistoryWritesForTests()

        try await lifecycle.reconcile(repoID: repo.id, actuationLog: makeTestActuationLog())

        #expect(holder.abandonments.isEmpty,
                "reconcile disposed of a holder although a tmux mark could not be written: \(holder.abandonments)")
        #expect(Set(try await db.terminals.list(worktreeID: worktree.id).map(\.id))
            == [holderRow.id, tmuxRow.id])
        let keptHolder = try #require(try await db.terminals.get(id: holderRow.id))
        #expect(!keptHolder.isParked)
        #expect(keptHolder.holderPID == holderRow.holderPID)
        #expect(keptHolder.childPID == holderRow.childPID)
        #expect(try await db.terminals.get(id: tmuxRow.id) == tmuxRow)
        #expect(try await db.worktrees.get(id: worktree.id)?.status == .active)
        #expect(try await db.terminalHistory.list(worktreeID: worktree.id).isEmpty)

        try await db.restoreTerminalHistoryWritesForTests()
        try await lifecycle.reconcile(repoID: repo.id, actuationLog: makeTestActuationLog())

        #expect(holder.abandonments.map(\.terminalID) == [holderRow.id])
        #expect(try await db.worktrees.get(id: worktree.id)?.status == .archived)
        #expect(try await db.terminals.list(worktreeID: worktree.id).isEmpty)
        let entries = try await db.terminalHistory.list(worktreeID: worktree.id)
        let tmuxEntry = try #require(entries.first { $0.id == tmuxRow.id })
        #expect(tmuxEntry.liveOnTmuxServer == "tbd-acme-gone")
        let holderEntry = try #require(entries.first { $0.id == holderRow.id })
        #expect(holderEntry.liveOnTmuxServer == nil)
    }
}

// MARK: - Fixtures

/// A lifecycle whose spawns go to `holder` when it is given, whose holder jobs
/// read as running (`ScriptedLivenessSignaller.doubleJobsRunning`), and whose
/// profile, session and Codex paths sit under `root` or nowhere real.
private func makeCloseTestsLifecycle(
    db: TBDDatabase, root: URL, holder: FakeHolderLaunch?,
    manager: ClaudeProfileConfigDirManager, probe: RecordingLeftoverTmuxProbe
) -> WorktreeLifecycle {
    var lifecycle = WorktreeLifecycle(
        db: db, git: GitManager(), hooks: HookResolver(),
        configDirManager: manager,
        processSignaller: ScriptedLivenessSignaller.doubleJobsRunning,
        codexExecutableResolver: CodexLaunchTestStub.executableResolver,
        codexHomeEnsurer: CodexLaunchTestStub.homeEnsurer,
        sessionsDir: root.appendingPathComponent("sessions"),
        leftoverTmuxProbe: probe.probe)
    if let holder {
        lifecycle.holderRegistry = makeHolderRegistryDouble(launch: holder)
    }
    return lifecycle
}

private func makeCloseTestsConfigDirManager(root: URL) -> ClaudeProfileConfigDirManager {
    ClaudeProfileConfigDirManager(
        baseDirectory: root.appendingPathComponent("profiles"),
        hostBaseDirectory: root.appendingPathComponent("claude"))
}

/// A Claude tab on `session`, started on the holder through the spawn double.
private func spawnCloseTestsHolderClaude(
    lifecycle: WorktreeLifecycle, holder: FakeHolderLaunch, worktreeID: UUID,
    workingDirectory: String, session: String
) async throws -> TBDShared.Terminal {
    let transport = try TerminalSpawnTransport.decide(registry: lifecycle.holderRegistry).get()
    let spawned = try await lifecycle.spawnTerminal(
        id: UUID(), worktreeID: worktreeID, workingDirectory: workingDirectory,
        command: "claude --session-id \(session)", env: [:], sensitiveEnv: [:],
        cols: 80, rows: 24, label: TerminalLabel.claudeCode,
        claudeSessionID: session, profileID: nil, kind: .claude, transport: transport)
    try #require(holder.launch(for: spawned.id) != nil)
    return try #require(try await lifecycle.db.terminals.get(id: spawned.id))
}

/// A live tmux Claude row on `session` in `worktreeID`, as read back.
private func openCloseTestsLiveTmuxRow(
    db: TBDDatabase, worktreeID: UUID, session: String
) async throws -> TBDShared.Terminal {
    let created = try await db.terminals.create(
        worktreeID: worktreeID, tmuxWindowID: "@7", tmuxPaneID: "%7",
        label: TerminalLabel.claudeCode, claudeSessionID: session, kind: .claude,
        transport: .tmux)
    return try #require(try await db.terminals.get(id: created.id))
}

/// One active worktree, on tmux server `tbd-acme`, of a repo row, with a
/// lifecycle over a holder spawn double and a probe that answers `.running`.
private struct CloseTestsLifecycleFixture {
    let root: URL
    let db: TBDDatabase
    let holder: FakeHolderLaunch
    let probe: RecordingLeftoverTmuxProbe
    let lifecycle: WorktreeLifecycle
    let worktree: Worktree
    let worktreePath: String

    func tearDown() { try? FileManager.default.removeItem(at: root) }

    func openLiveTmuxRow(session: String) async throws -> TBDShared.Terminal {
        try await openCloseTestsLiveTmuxRow(db: db, worktreeID: worktree.id, session: session)
    }

    func spawnHolderClaude(session: String) async throws -> TBDShared.Terminal {
        try await spawnCloseTestsHolderClaude(
            lifecycle: lifecycle, holder: holder, worktreeID: worktree.id,
            workingDirectory: worktreePath, session: session)
    }
}

private func makeCloseTestsLifecycleFixture() async throws -> CloseTestsLifecycleFixture {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("leftover-tmux-close-\(UUID())")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let db = try TBDDatabase(
        inMemory: true, terminalHistoryDir: root.appendingPathComponent("history").path)
    let holder = FakeHolderLaunch()
    let probe = RecordingLeftoverTmuxProbe { _ in .running }
    let lifecycle = makeCloseTestsLifecycle(
        db: db, root: root, holder: holder,
        manager: makeCloseTestsConfigDirManager(root: root), probe: probe)
    let repo = try await db.repos.create(
        path: root.appendingPathComponent("acme-repo").path,
        displayName: "acme", defaultBranch: "main")
    let worktreePath = root.appendingPathComponent("acme").path
    try FileManager.default.createDirectory(atPath: worktreePath, withIntermediateDirectories: true)
    let worktree = try await db.worktrees.create(
        repoID: repo.id, name: "acme", branch: "acme", path: worktreePath,
        tmuxServer: "tbd-acme")
    return CloseTestsLifecycleFixture(
        root: root, db: db, holder: holder, probe: probe, lifecycle: lifecycle,
        worktree: worktree, worktreePath: worktreePath)
}

/// Every path `onWorktreeRemoved` was called with, in order.
private final class CloseTestsRemovedPaths: @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [String] = []

    func record(_ path: String) { lock.withLock { recorded.append(path) } }
    var paths: [String] { lock.withLock { recorded } }
}

/// Carries what the wait observed onto the primary failure line.
private struct CloseTestsWaitTimeout: Error, CustomStringConvertible {
    let what: String
    let observed: String
    let elapsed: Duration
    var description: String {
        "still waiting for \(what) after \(elapsed) — observed \(observed)"
    }
}

/// A router over a lifecycle with no holder registry, a probe that answers
/// `.running` for both, and a recorder on `onWorktreeRemoved`, which phase 2
/// of an archive calls once the directory has left its slot.
private struct CloseTestsRouterFixture {
    let root: URL
    let db: TBDDatabase
    let router: RPCRouter
    let removed: CloseTestsRemovedPaths

    func tearDown() { try? FileManager.default.removeItem(at: root) }

    func send<P: Encodable>(_ method: String, _ params: P) async throws -> RPCResponse {
        await router.handle(try RPCRequest(method: method, params: params))
    }

    func openLiveTmuxRow(in worktree: Worktree, session: String) async throws -> TBDShared.Terminal {
        try await openCloseTestsLiveTmuxRow(db: db, worktreeID: worktree.id, session: session)
    }

    /// An active worktree whose directory holds a file, so phase 2's rename
    /// into the deletion queue succeeds and reaches `onWorktreeRemoved`.
    func makeActiveWorktree(repoID: UUID, name: String, server: String) async throws -> Worktree {
        let path = root.appendingPathComponent(name).path
        try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
        try "content".write(toFile: path + "/file.txt", atomically: true, encoding: .utf8)
        return try await db.worktrees.create(
            repoID: repoID, name: name, branch: name, path: path, tmuxServer: server)
    }

    /// Waits for phase 2 of the archive of the worktree at `path`, which a
    /// detached task runs.
    func waitForPhase2(of path: String) async throws {
        let started = ContinuousClock.now
        switch await pollUntilTrue(
            timeout: TestDeadlines.saturatedPass, pollInterval: .milliseconds(10),
            { removed.paths.contains(path) }
        ) {
        case .satisfied:
            return
        case .cancelled:
            throw CancellationError()
        case .timedOut:
            throw CloseTestsWaitTimeout(
                what: "phase 2 of the archive of \(path)",
                observed: "onWorktreeRemoved paths \(removed.paths)",
                elapsed: ContinuousClock.now - started)
        }
    }
}

private func makeCloseTestsRouterFixture() async throws -> CloseTestsRouterFixture {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("leftover-tmux-close-rpc-\(UUID())")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let db = try TBDDatabase(
        inMemory: true, terminalHistoryDir: root.appendingPathComponent("history").path)
    let probe = RecordingLeftoverTmuxProbe { _ in .running }
    let removed = CloseTestsRemovedPaths()
    let manager = makeCloseTestsConfigDirManager(root: root)
    var lifecycle = makeCloseTestsLifecycle(
        db: db, root: root, holder: nil, manager: manager, probe: probe)
    lifecycle.onWorktreeRemoved = { _, path, _ in removed.record(path) }
    let router = RPCRouter(
        db: db, lifecycle: lifecycle, configDirManager: manager,
        codexExecutableResolver: CodexLaunchTestStub.executableResolver,
        codexHomeEnsurer: CodexLaunchTestStub.homeEnsurer,
        sessionsDir: root.appendingPathComponent("sessions"),
        actuationLog: ActuationLog(path: root.appendingPathComponent("actuations.jsonl").path))
    await router.hibernationCoordinator.setLeftoverTmuxProbe(probe.probe)
    return CloseTestsRouterFixture(
        root: root, db: db, router: router, removed: removed)
}
