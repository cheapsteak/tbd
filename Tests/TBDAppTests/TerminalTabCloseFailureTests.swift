import Foundation
import Testing
@testable import TBDApp
import TBDShared
import TestSupport

// Tier 1: deterministic, in-process state only. `terminal.delete` goes
// through the injected `terminalDeleter`, which can hold each delete until
// the test releases it (`PanelCallGate`), so the tab strip is read after
// every answer, and the terminal list the app reads back after an error goes
// through `worktreeTerminalsFetcher`. The worktree is marked hydrated so no
// `tab.list` is sent, and the composer-draft report is stubbed. The close's
// `tab.setOrder` has no seam; it fails against the fenced socket as in the
// other tab-close suites.

/// A tab close removes the tab at once and deletes its terminals on the
/// daemon, all at the same time, and settles each terminal as its own delete
/// answers. The daemon can answer with an error and keep one — a tmux row
/// whose Closed Terminals record cannot be written stays, with a message
/// saying so — and that terminal then comes back as a tab of its own at the
/// end of the strip, with its label, unread bold, composer draft and spawn
/// bookkeeping, under one alert for the close. A terminal still closing never
/// gets a tab. A failure that is not the daemon's answer shows nothing until
/// the next terminal list says whether the daemon kept the terminal.
@MainActor
@Suite("Terminal tab close failure")
struct TerminalTabCloseFailureTests {
    private static let refusal =
        "Terminal was not closed. Its session may still be running, so the tab stays open. Try again."

    private static func withState(
        _ body: @MainActor (AppState, TerminalCloseDaemon) async throws -> Void
    ) async rethrows {
        let suite = TestDefaultsSuite("TerminalTabCloseFailureTests")
        defer { suite.tearDown() }
        let state = AppState(userDefaults: suite.defaults)
        let daemon = TerminalCloseDaemon()
        state.terminalDeleter = { @MainActor terminalID in try await daemon.delete(terminalID) }
        state.worktreeTerminalsFetcher = { @MainActor worktreeID in daemon.list(worktreeID: worktreeID) }
        state.composerDraftsSetter = { @MainActor _ in }
        state.tabStatesFetcher = { @MainActor _ in
            Issue.record("unexpected tab.list")
            return TabListResponse(tabs: [], order: [], activeTabID: nil)
        }
        try await body(state, daemon)
    }

    /// A worktree holding `terminalIDs`, on the app and on the daemon, shown
    /// as `tabs`, already hydrated.
    private static func seed(
        _ state: AppState, _ daemon: TerminalCloseDaemon,
        terminalIDs: [UUID], tabs: [TBDShared.Tab]
    ) -> UUID {
        let worktreeID = UUID()
        let terminals = terminalIDs.map { id in
            TBDShared.Terminal(id: id, worktreeID: worktreeID, tmuxWindowID: "@1", tmuxPaneID: "%1",
                               label: "shell", kind: .shell)
        }
        state.terminals[worktreeID] = terminals
        daemon.rows += terminals
        state.tabs[worktreeID] = tabs
        state.worktreeTabOrders[worktreeID] = tabs.map(\.id)
        state.activeTabIndices[worktreeID] = 0
        state.tabStateHydratedWorktreeIDs.insert(worktreeID)
        return worktreeID
    }

    private static func tab(_ terminalID: UUID, label: String? = nil) -> TBDShared.Tab {
        TBDShared.Tab(id: terminalID, content: .terminal(terminalID: terminalID), label: label)
    }

    /// A tab whose layout splits `panes`, rooted at the first.
    private static func splitTab(_ state: AppState, _ panes: [UUID]) -> TBDShared.Tab {
        let tabID = UUID()
        state.layouts[tabID] = .split(
            id: UUID(), direction: .horizontal,
            children: panes.map { .pane(.terminal(terminalID: $0)) },
            ratios: panes.map { _ in 1 / CGFloat(panes.count) })
        return TBDShared.Tab(id: tabID, content: .terminal(terminalID: panes[0]), label: nil)
    }

    private static func tabIDs(_ state: AppState, _ worktreeID: UUID) -> [UUID] {
        state.tabs[worktreeID]?.map(\.id) ?? []
    }

    private static func terminalIDs(_ state: AppState, _ worktreeID: UUID) -> Set<UUID> {
        Set(state.terminals[worktreeID]?.map(\.id) ?? [])
    }

    /// A poll landing: the daemon's terminal list adopted for the worktree.
    private static func poll(_ state: AppState, _ daemon: TerminalCloseDaemon, _ worktreeID: UUID) {
        state.adoptTerminalSnapshot(daemon.list(worktreeID: worktreeID), worktreeID: worktreeID)
    }

    @Test("a refused delete shows one alert and brings the terminal back as a tab at the end, with its draft")
    func refusedDeleteBringsTheTerminalBack() async {
        await Self.withState { state, daemon in
            let (claude, build, agent) = (UUID(), UUID(), UUID())
            let worktreeID = Self.seed(
                state, daemon, terminalIDs: [claude, build, agent],
                tabs: [Self.tab(claude), Self.tab(build), Self.tab(agent)])
            state.composerDraft(for: build).text = "half a sentence"
            daemon.failures[build] = DaemonClientError.rpcError(Self.refusal, code: nil)

            state.closeTab(worktreeID: worktreeID, index: 1)

            let closedAtOnce: [UUID] = [claude, agent]
            #expect(Self.tabIDs(state, worktreeID) == closedAtOnce, "the tab closes before closeTab returns")

            await PanelTabsFixture.drainMainActor()

            let expectedDeletes: [UUID] = [build]
            #expect(daemon.asked == expectedDeletes)
            let back: [UUID] = [claude, agent, build]
            #expect(Self.tabIDs(state, worktreeID) == back,
                    "the kept terminal is a tab of its own at the end of the strip, which the next order write takes")
            #expect(state.alertIsError)
            #expect(state.alertMessage == "Couldn't close terminal: \(Self.refusal)")
            #expect(state.composerDrafts[.terminal(build)]?.text == "half a sentence")
            #expect(Self.terminalIDs(state, worktreeID).contains(build))
            #expect(state.closingTerminals.isEmpty)
        }
    }

    @Test("a refused terminal comes back with its tab's label, its unread bold and its session-start bookkeeping")
    func refusedTerminalKeepsWhatItsTabHeld() async throws {
        try await Self.withState { state, daemon in
            let (claude, build) = (UUID(), UUID())
            let worktreeID = Self.seed(
                state, daemon, terminalIDs: [claude, build],
                tabs: [Self.tab(claude), Self.tab(build, label: "build server")])
            state.unreadTerminals = [build]
            let started = UUID()
            state.lastStartedIncarnation[build] = started
            let waiter = Task { @MainActor in
                await state.awaitSessionStart(terminalID: build, incarnationID: UUID())
            }
            var registered = false
            for _ in 0..<1000 where !registered {
                registered = state.sessionStartWaiters[build] != nil
                if !registered { await Task.yield() }
            }
            try #require(registered, "the session-start waiter never registered")
            daemon.hold([build])
            daemon.failures[build] = DaemonClientError.rpcError(Self.refusal, code: nil)

            state.closeTab(worktreeID: worktreeID, index: 1)
            await PanelTabsFixture.drainMainActor()

            #expect(state.unreadTerminals.contains(build), "nothing is let go while the delete is in flight")
            #expect(state.lastStartedIncarnation[build] == started)
            #expect(state.sessionStartWaiters[build]?.count == 1)

            daemon.release(build)
            await PanelTabsFixture.drainMainActor()

            let returned = try #require(state.tabs[worktreeID]?.last)
            #expect(returned.content == .terminal(terminalID: build))
            #expect(returned.label == "build server", "the tab keeps the name it was given")
            #expect(state.unreadTerminals.contains(build), "the tab comes back bold")
            #expect(state.lastStartedIncarnation[build] == started, "the latch survives the refusal")
            #expect(state.sessionStartWaiters[build]?.count == 1, "the waiter is still waiting, not failed")

            waiter.cancel()
            #expect(await waiter.value == false)
        }
    }

    @Test("each pane of a split settles as its own delete answers, and a poll landing in between gives no closing pane a tab")
    func splitPanesSettleOneByOne() async throws {
        try await Self.withState { state, daemon in
            let (left, middle, right, agent) = (UUID(), UUID(), UUID(), UUID())
            let split = Self.splitTab(state, [left, middle, right])
            let worktreeID = Self.seed(
                state, daemon, terminalIDs: [left, middle, right, agent], tabs: [split, Self.tab(agent)])
            state.composerDraft(for: middle).text = "kept"
            daemon.hold([left, middle, right])
            daemon.failures[middle] = DaemonClientError.rpcError(Self.refusal, code: nil)

            state.closeTab(worktreeID: worktreeID, index: 0)
            await PanelTabsFixture.drainMainActor()

            let asked = Set(daemon.asked)
            let allPanes: Set<UUID> = [left, middle, right]
            #expect(asked == allPanes, "the deletes go out together")
            let onlyAgent: [UUID] = [agent]

            daemon.release(left)
            await PanelTabsFixture.drainMainActor()
            #expect(Self.tabIDs(state, worktreeID) == onlyAgent, "no pane still closing pops up as a tab")
            #expect(!Self.terminalIDs(state, worktreeID).contains(left))

            daemon.markBusy(agent)
            Self.poll(state, daemon, worktreeID)
            #expect(Self.tabIDs(state, worktreeID) == onlyAgent,
                    "a poll's reconcile gives no tab to a pane whose delete is in flight")

            daemon.release(middle)
            await PanelTabsFixture.drainMainActor()
            let middleBack: [UUID] = [agent, middle]
            #expect(Self.tabIDs(state, worktreeID) == middleBack,
                    "the refused pane comes back without waiting for the slowest sibling")
            #expect(state.alertMessage == "Couldn't close terminal: \(Self.refusal)")
            #expect(state.composerDrafts[.terminal(middle)]?.text == "kept")

            daemon.markIdle(agent)
            Self.poll(state, daemon, worktreeID)
            #expect(Self.tabIDs(state, worktreeID) == middleBack,
                    "a poll after the refusal neither duplicates it nor shows the pane still closing")

            daemon.release(right)
            await PanelTabsFixture.drainMainActor()
            #expect(Self.tabIDs(state, worktreeID) == middleBack)
            let restored = try #require(state.tabs[worktreeID]?.last)
            #expect(restored.content == .terminal(terminalID: middle))
            let remaining: Set<UUID> = [middle, agent]
            #expect(Self.terminalIDs(state, worktreeID) == remaining)
            #expect(state.closingTerminals.isEmpty)
        }
    }

    @Test("a split that was the only tab closes with no tab appearing while its panes answer")
    func successfulSplitCloseShowsNoIntermediateTab() async {
        await Self.withState { state, daemon in
            let panes = [UUID(), UUID(), UUID()]
            let worktreeID = Self.seed(state, daemon, terminalIDs: panes, tabs: [Self.splitTab(state, panes)])
            daemon.hold(panes)

            state.closeTab(worktreeID: worktreeID, index: 0)
            await PanelTabsFixture.drainMainActor()

            for pane in panes {
                daemon.release(pane)
                await PanelTabsFixture.drainMainActor()
                #expect(Self.tabIDs(state, worktreeID).isEmpty,
                        "a pane still closing must not come back as a tab, let alone a selected one")
                #expect(state.resolvedActiveTab(worktreeID: worktreeID) == nil)
            }
            #expect(Self.terminalIDs(state, worktreeID).isEmpty)
            #expect(state.alertMessage == nil)
            #expect(state.closingTerminals.isEmpty)
        }
    }

    @Test("several refused panes come back as their own tabs under one alert that lists every message")
    func severalRefusalsShowOneAlert() async {
        await Self.withState { state, daemon in
            let (left, right, agent) = (UUID(), UUID(), UUID())
            let worktreeID = Self.seed(
                state, daemon, terminalIDs: [left, right, agent],
                tabs: [Self.splitTab(state, [left, right]), Self.tab(agent)])
            let leftRefusal = "Terminal \(left) was not closed."
            let rightRefusal = "Terminal \(right) was not closed."
            daemon.failures[left] = DaemonClientError.rpcError(leftRefusal, code: nil)
            daemon.failures[right] = DaemonClientError.rpcError(rightRefusal, code: nil)

            state.closeTab(worktreeID: worktreeID, index: 0)
            await PanelTabsFixture.drainMainActor()

            let settled = Set(Self.tabIDs(state, worktreeID))
            let allBack: Set<UUID> = [agent, left, right]
            #expect(settled == allBack)
            #expect(state.tabs[worktreeID]?.first?.id == agent)
            let alert = state.alertMessage ?? ""
            #expect(alert.hasPrefix("Couldn't close 2 terminals:"))
            #expect(alert.contains(leftRefusal), "each refusal names its own terminal")
            #expect(alert.contains(rightRefusal))
        }
    }

    @Test("a refusal that lands after the close's alert was dismissed shows on its own")
    func refusalAfterTheAlertWasDismissedStartsANewOne() async {
        await Self.withState { state, daemon in
            let (left, right, agent) = (UUID(), UUID(), UUID())
            let worktreeID = Self.seed(
                state, daemon, terminalIDs: [left, right, agent],
                tabs: [Self.splitTab(state, [left, right]), Self.tab(agent)])
            let leftRefusal = "Terminal \(left) was not closed."
            let rightRefusal = "Terminal \(right) was not closed."
            daemon.hold([right])
            daemon.failures[left] = DaemonClientError.rpcError(leftRefusal, code: nil)
            daemon.failures[right] = DaemonClientError.rpcError(rightRefusal, code: nil)

            state.closeTab(worktreeID: worktreeID, index: 0)
            await PanelTabsFixture.drainMainActor()
            #expect(state.alertMessage == "Couldn't close terminal: \(leftRefusal)")

            state.alertMessage = nil
            daemon.release(right)
            await PanelTabsFixture.drainMainActor()
            #expect(state.alertMessage == "Couldn't close terminal: \(rightRefusal)")
        }
    }

    @Test(
        "a failure that is not the daemon's answer shows nothing and keeps the terminal hidden for the next list",
        arguments: [
            DaemonClientError.daemonNotRunning,
            .connectionFailed("connection refused"),
            .receiveFailed("recv timed out after 10s (daemon unresponsive)"),
            .invalidResponse,
        ])
    func failureThatIsNotARefusalShowsNoAlert(_ failure: DaemonClientError) async {
        await Self.withState { state, daemon in
            let (claude, build, agent) = (UUID(), UUID(), UUID())
            let worktreeID = Self.seed(
                state, daemon, terminalIDs: [claude, build, agent],
                tabs: [Self.tab(claude), Self.tab(build), Self.tab(agent)])
            state.composerDraft(for: build).text = "half a sentence"
            daemon.failures[build] = failure

            state.closeTab(worktreeID: worktreeID, index: 1)
            await PanelTabsFixture.drainMainActor()

            let expectedDeletes: [UUID] = [build]
            #expect(daemon.asked == expectedDeletes)
            let closed: [UUID] = [claude, agent]
            #expect(Self.tabIDs(state, worktreeID) == closed)
            #expect(state.alertMessage == nil)
            #expect(state.closingTerminals[build]?.awaitingList == true)
            #expect(state.composerDrafts[.terminal(build)]?.text == "half a sentence",
                    "the draft waits for the list, which may give the terminal back")

            state.reconcileTabs(worktreeID: worktreeID, terminals: state.terminals[worktreeID] ?? [])
            #expect(Self.tabIDs(state, worktreeID) == closed, "a reconcile of the app's own state does not decide it")
        }
    }

    @Test("a terminal whose delete got no answer comes back when the next list holds it, even an unchanged list")
    func unansweredDeleteComesBackWhenTheListHoldsIt() async throws {
        try await Self.withState { state, daemon in
            let (claude, build) = (UUID(), UUID())
            let worktreeID = Self.seed(
                state, daemon, terminalIDs: [claude, build],
                tabs: [Self.tab(claude), Self.tab(build, label: "build server")])
            state.composerDraft(for: build).text = "half a sentence"
            daemon.failures[build] = DaemonClientError.connectionFailed("connection refused")

            state.closeTab(worktreeID: worktreeID, index: 1)
            await PanelTabsFixture.drainMainActor()
            let closed: [UUID] = [claude]
            #expect(Self.tabIDs(state, worktreeID) == closed)

            Self.poll(state, daemon, worktreeID)

            let back: [UUID] = [claude, build]
            #expect(Self.tabIDs(state, worktreeID) == back)
            let returned = try #require(state.tabs[worktreeID]?.last)
            #expect(returned.label == "build server")
            #expect(state.composerDrafts[.terminal(build)]?.text == "half a sentence")
            #expect(state.alertMessage == nil)
            #expect(state.closingTerminals.isEmpty)
        }
    }

    @Test("a terminal whose delete got no answer is gone, with its draft, when the next list lacks it")
    func unansweredDeleteIsGoneWhenTheListLacksIt() async {
        await Self.withState { state, daemon in
            let (claude, build) = (UUID(), UUID())
            let worktreeID = Self.seed(
                state, daemon, terminalIDs: [claude, build], tabs: [Self.tab(claude), Self.tab(build)])
            state.composerDraft(for: build).text = "half a sentence"
            state.unreadTerminals = [build]
            daemon.failures[build] = DaemonClientError.receiveFailed("recv timed out")
            daemon.rowGoneBeforeFailure = [build]

            state.closeTab(worktreeID: worktreeID, index: 1)
            await PanelTabsFixture.drainMainActor()
            Self.poll(state, daemon, worktreeID)

            let closed: [UUID] = [claude]
            #expect(Self.tabIDs(state, worktreeID) == closed)
            #expect(!Self.terminalIDs(state, worktreeID).contains(build))
            #expect(state.composerDrafts[.terminal(build)] == nil)
            #expect(!state.unreadTerminals.contains(build))
            #expect(state.closingTerminals.isEmpty)
        }
    }

    @Test("a refusal brings back only its own terminal, never a sibling whose delete got no answer")
    func refusalBringsBackOnlyItsOwnTerminal() async {
        await Self.withState { state, daemon in
            let (refused, unanswered, agent) = (UUID(), UUID(), UUID())
            let worktreeID = Self.seed(
                state, daemon, terminalIDs: [refused, unanswered, agent],
                tabs: [Self.splitTab(state, [refused, unanswered]), Self.tab(agent)])
            daemon.hold([refused])
            daemon.failures[refused] = DaemonClientError.rpcError(Self.refusal, code: nil)
            daemon.failures[unanswered] = DaemonClientError.connectionFailed("connection refused")

            state.closeTab(worktreeID: worktreeID, index: 0)
            await PanelTabsFixture.drainMainActor()
            daemon.release(refused)
            await PanelTabsFixture.drainMainActor()

            let refusedBack: [UUID] = [agent, refused]
            #expect(Self.tabIDs(state, worktreeID) == refusedBack)
            #expect(state.closingTerminals[unanswered]?.awaitingList == true)

            Self.poll(state, daemon, worktreeID)
            let allBack: [UUID] = [agent, refused, unanswered]
            #expect(Self.tabIDs(state, worktreeID) == allBack, "the list the daemon answers with decides")
        }
    }

    @Test("an error the daemon sends after the row is gone is no refusal: the terminal is gone, with no alert")
    func errorAfterTheRowIsGoneIsNoRefusal() async {
        await Self.withState { state, daemon in
            let (claude, build, agent) = (UUID(), UUID(), UUID())
            let worktreeID = Self.seed(
                state, daemon, terminalIDs: [claude, build, agent],
                tabs: [Self.tab(claude), Self.tab(build), Self.tab(agent)])
            state.composerDraft(for: build).text = "half a sentence"
            state.unreadTerminals = [build]
            daemon.failures[build] = DaemonClientError.rpcError("tab row delete failed", code: nil)
            daemon.rowGoneBeforeFailure = [build]

            state.closeTab(worktreeID: worktreeID, index: 1)
            await PanelTabsFixture.drainMainActor()

            let closed: [UUID] = [claude, agent]
            #expect(Self.tabIDs(state, worktreeID) == closed)
            #expect(state.alertMessage == nil)
            #expect(!Self.terminalIDs(state, worktreeID).contains(build))
            #expect(state.composerDrafts[.terminal(build)] == nil)
            #expect(!state.unreadTerminals.contains(build))
            #expect(state.closingTerminals.isEmpty)
        }
    }

    @Test("a refusal whose terminal list cannot be read stands as a refusal")
    func refusalWithAnUnreadableListStands() async {
        await Self.withState { state, daemon in
            let (claude, build) = (UUID(), UUID())
            let worktreeID = Self.seed(
                state, daemon, terminalIDs: [claude, build], tabs: [Self.tab(claude), Self.tab(build)])
            state.worktreeTerminalsFetcher = { @MainActor _ in
                throw DaemonClientError.receiveFailed("recv timed out")
            }
            daemon.failures[build] = DaemonClientError.rpcError(Self.refusal, code: nil)

            state.closeTab(worktreeID: worktreeID, index: 1)
            await PanelTabsFixture.drainMainActor()

            let back: [UUID] = [claude, build]
            #expect(Self.tabIDs(state, worktreeID) == back)
            #expect(state.alertMessage == "Couldn't close terminal: \(Self.refusal)")
        }
    }

    @Test("a refusal for a terminal whose worktree was archived meanwhile brings nothing back and keeps no draft")
    func refusalAfterTheWorktreeWasArchived() async {
        await Self.withState { state, daemon in
            let (claude, build) = (UUID(), UUID())
            let worktreeID = Self.seed(
                state, daemon, terminalIDs: [claude, build], tabs: [Self.tab(claude), Self.tab(build)])
            state.composerDraft(for: build).text = "half a sentence"
            daemon.hold([build])
            daemon.failures[build] = DaemonClientError.rpcError(Self.refusal, code: nil)

            state.closeTab(worktreeID: worktreeID, index: 1)
            await PanelTabsFixture.drainMainActor()
            state.removeArchivedWorktreeFromState(id: worktreeID)
            daemon.release(build)
            await PanelTabsFixture.drainMainActor()

            let tabsAfter = Self.tabIDs(state, worktreeID)
            #expect(!tabsAfter.contains(build))
            #expect(state.composerDrafts[.terminal(build)] == nil)
            #expect(state.alertMessage == nil)
            #expect(state.closingTerminals.isEmpty)
        }
    }

    @Test("a terminal whose delete got no answer is let go, draft and all, when its worktree is archived")
    func unansweredDeleteThenArchive() async {
        await Self.withState { state, daemon in
            let (claude, build) = (UUID(), UUID())
            let worktreeID = Self.seed(
                state, daemon, terminalIDs: [claude, build], tabs: [Self.tab(claude), Self.tab(build)])
            state.composerDraft(for: build).text = "half a sentence"
            daemon.failures[build] = DaemonClientError.connectionFailed("connection refused")

            state.closeTab(worktreeID: worktreeID, index: 1)
            await PanelTabsFixture.drainMainActor()
            #expect(state.closingTerminals[build]?.awaitingList == true)

            state.removeArchivedWorktreeFromState(id: worktreeID)

            #expect(state.composerDrafts[.terminal(build)] == nil)
            #expect(state.closingTerminals.isEmpty)
        }
    }

    @Test("panel.syncTabs keeps listing a closed tab until its delete answers, so a refused terminal keeps its surface")
    func closedTabStaysInTheSyncUntilItsDeleteAnswers() async {
        await Self.withState { state, daemon in
            let (kept, gone, agent) = (UUID(), UUID(), UUID())
            let worktreeID = Self.seed(
                state, daemon, terminalIDs: [kept, gone, agent],
                tabs: [Self.tab(kept), Self.tab(gone), Self.tab(agent)])
            let syncs = PanelTabsFixture.collectSyncs(state)
            state.markPanelSyncReady(worktreeIDs: [worktreeID])
            await PanelTabsFixture.drainMainActor()
            syncs.reset()
            daemon.hold([kept, gone])
            daemon.failures[kept] = DaemonClientError.rpcError(Self.refusal, code: nil)

            state.closeTab(worktreeID: worktreeID, index: 0)
            state.closeTab(worktreeID: worktreeID, index: 0)
            await PanelTabsFixture.drainMainActor()

            let whileClosing = syncs.sent.last?.tabs.map(\.tabID)
            let heldAfterTheOpenTabs: [UUID] = [agent, kept, gone]
            #expect(whileClosing == heldAfterTheOpenTabs)

            daemon.release(gone)
            await PanelTabsFixture.drainMainActor()
            let afterTheDelete = syncs.sent.last?.tabs.map(\.tabID)
            let goneOmitted: [UUID] = [agent, kept]
            #expect(afterTheDelete == goneOmitted, "a deleted terminal's tab leaves the sync")

            daemon.release(kept)
            await PanelTabsFixture.drainMainActor()
            let afterTheRefusal = syncs.sent.last?.tabs.map(\.tabID)
            #expect(afterTheRefusal == goneOmitted, "the refused terminal's tab is open again, under the same ID")
            let syncsOmittingKept = syncs.sent.filter { !$0.tabs.map(\.tabID).contains(kept) }
            #expect(syncsOmittingKept.isEmpty, "no sync ever deleted the kept tab's surface")
        }
    }

    @Test("a terminal list lacking a terminal no close holds leaves its composer state, since the list may predate it")
    func listLackingAnUnheldTerminalKeepsItsComposer() async throws {
        try await Self.withState { state, daemon in
            let (claude, created) = (UUID(), UUID())
            let worktreeID = Self.seed(
                state, daemon, terminalIDs: [claude, created], tabs: [Self.tab(claude), Self.tab(created)])
            state.composerDraft(for: created).text = "first message"
            let started = UUID()
            state.lastStartedIncarnation[created] = started
            let waiter = Task { @MainActor in
                await state.awaitSessionStart(terminalID: created, incarnationID: UUID())
            }
            var registered = false
            for _ in 0..<1000 where !registered {
                registered = state.sessionStartWaiters[created] != nil
                if !registered { await Task.yield() }
            }
            try #require(registered, "the session-start waiter never registered")
            let answeredBeforeTheCreate = daemon.list(worktreeID: worktreeID).filter { $0.id != created }

            state.adoptTerminalSnapshot(answeredBeforeTheCreate, worktreeID: worktreeID)

            #expect(!Self.terminalIDs(state, worktreeID).contains(created), "the list still sets the rows")
            #expect(state.composerDrafts[.terminal(created)]?.text == "first message")
            #expect(state.lastStartedIncarnation[created] == started)
            #expect(state.sessionStartWaiters[created]?.count == 1, "the waiter is still waiting, not failed")

            waiter.cancel()
            #expect(await waiter.value == false)
        }
    }
}

/// The daemon's end of `terminal.delete` for a tab close: records each
/// terminal asked about, holds the ones named by `hold` until `release`, and
/// fails those named in `failures`; every other delete succeeds. `rows` is
/// what its terminal list answers with: a delete that succeeds removes the
/// row, and a failing one keeps it unless `rowGoneBeforeFailure` names it.
@MainActor
final class TerminalCloseDaemon {
    var failures: [UUID: any Error] = [:]
    var rowGoneBeforeFailure: Set<UUID> = []
    var rows: [TBDShared.Terminal] = []
    private(set) var asked: [UUID] = []
    private var gates: [UUID: PanelCallGate] = [:]

    func hold(_ terminalIDs: [UUID]) {
        for terminalID in terminalIDs { gates[terminalID] = PanelCallGate() }
    }

    func release(_ terminalID: UUID) {
        gates[terminalID]?.release()
    }

    func delete(_ terminalID: UUID) async throws {
        asked.append(terminalID)
        await gates[terminalID]?.wait()
        if let failure = failures[terminalID] {
            if rowGoneBeforeFailure.contains(terminalID) {
                rows.removeAll { $0.id == terminalID }
            }
            throw failure
        }
        rows.removeAll { $0.id == terminalID }
    }

    func list(worktreeID: UUID) -> [TBDShared.Terminal] {
        rows.filter { $0.worktreeID == worktreeID }
    }

    /// Changes a row the way an agent's turn does, so the next list differs.
    func markBusy(_ terminalID: UUID) { setActivity(.working, of: terminalID) }

    func markIdle(_ terminalID: UUID) { setActivity(.idle, of: terminalID) }

    private func setActivity(_ state: TerminalActivityState, of terminalID: UUID) {
        guard let index = rows.firstIndex(where: { $0.id == terminalID }) else { return }
        rows[index].activityState = state
    }
}
