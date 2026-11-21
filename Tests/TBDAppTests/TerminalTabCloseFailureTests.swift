import Foundation
import Testing
@testable import TBDApp
import TBDShared
import TestSupport

// Tier 1: deterministic, in-process state only. `terminal.delete` goes
// through the injected `terminalDeleter`, which can hold each delete until
// the test releases it (`PanelCallGate`), so the tab strip is read after
// every answer. The worktree is marked hydrated so no `tab.list` is sent, and
// the composer-draft report is stubbed. The close's `tab.setOrder` has no
// seam; it fails against the fenced socket as in the other tab-close suites.

/// A tab close removes the tab at once and deletes its terminals on the
/// daemon, all at the same time. The daemon can answer with an error and keep
/// one — a tmux row whose Closed Terminals record cannot be written stays,
/// with a message saying so — and that terminal then comes back as a tab of
/// its own at the end of the strip, with its composer draft and one alert for
/// the close. Until every delete has answered, no closed terminal gets a tab:
/// a split whose panes answer one by one shows nothing in between. A failure
/// that is not the daemon's answer shows no alert.
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
        state.composerDraftsSetter = { @MainActor _ in }
        state.tabStatesFetcher = { @MainActor _ in
            Issue.record("unexpected tab.list")
            return TabListResponse(tabs: [], order: [], activeTabID: nil)
        }
        try await body(state, daemon)
    }

    /// A worktree holding `terminalIDs`, shown as `tabs`, already hydrated.
    private static func seed(
        _ state: AppState, terminalIDs: [UUID], tabs: [TBDShared.Tab]
    ) -> UUID {
        let worktreeID = UUID()
        state.terminals[worktreeID] = terminalIDs.map { id in
            Terminal(id: id, worktreeID: worktreeID, tmuxWindowID: "@1", tmuxPaneID: "%1",
                     label: "shell", kind: .shell)
        }
        state.tabs[worktreeID] = tabs
        state.worktreeTabOrders[worktreeID] = tabs.map(\.id)
        state.activeTabIndices[worktreeID] = 0
        state.tabStateHydratedWorktreeIDs.insert(worktreeID)
        return worktreeID
    }

    private static func tab(_ terminalID: UUID) -> TBDShared.Tab {
        TBDShared.Tab(id: terminalID, content: .terminal(terminalID: terminalID), label: nil)
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

    @Test("a refused delete shows one alert and brings the terminal back as a tab at the end, with its draft")
    func refusedDeleteBringsTheTerminalBack() async {
        await Self.withState { state, daemon in
            let (claude, build, agent) = (UUID(), UUID(), UUID())
            let worktreeID = Self.seed(
                state, terminalIDs: [claude, build, agent],
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
            #expect(state.closingTerminalIDs.isEmpty)
        }
    }

    @Test("a refused pane of a split comes back on its own once every pane has answered, and the deleted panes stay gone")
    func refusedPaneOfASplitComesBackAlone() async throws {
        try await Self.withState { state, daemon in
            let (left, middle, right, agent) = (UUID(), UUID(), UUID(), UUID())
            let split = Self.splitTab(state, [left, middle, right])
            let worktreeID = Self.seed(
                state, terminalIDs: [left, middle, right, agent], tabs: [split, Self.tab(agent)])
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

            daemon.release(middle)
            await PanelTabsFixture.drainMainActor()
            #expect(Self.tabIDs(state, worktreeID) == onlyAgent, "the refusal waits for the close to settle")
            #expect(state.alertMessage == nil)

            daemon.release(right)
            await PanelTabsFixture.drainMainActor()
            let settled: [UUID] = [agent, middle]
            #expect(Self.tabIDs(state, worktreeID) == settled)
            let restored = try #require(state.tabs[worktreeID]?.last)
            #expect(restored.content == .terminal(terminalID: middle))
            let remaining: Set<UUID> = [middle, agent]
            #expect(Self.terminalIDs(state, worktreeID) == remaining)
            #expect(state.alertMessage == "Couldn't close terminal: \(Self.refusal)")
            #expect(state.composerDrafts[.terminal(middle)]?.text == "kept")
            #expect(state.closingTerminalIDs.isEmpty)
        }
    }

    @Test("a split that was the only tab closes with no tab appearing while its panes answer")
    func successfulSplitCloseShowsNoIntermediateTab() async {
        await Self.withState { state, daemon in
            let panes = [UUID(), UUID(), UUID()]
            let worktreeID = Self.seed(state, terminalIDs: panes, tabs: [Self.splitTab(state, panes)])
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
            #expect(state.closingTerminalIDs.isEmpty)
        }
    }

    @Test("several refused panes come back as their own tabs under one alert that names the count")
    func severalRefusalsShowOneAlert() async {
        await Self.withState { state, daemon in
            let (left, right, agent) = (UUID(), UUID(), UUID())
            let worktreeID = Self.seed(
                state, terminalIDs: [left, right, agent],
                tabs: [Self.splitTab(state, [left, right]), Self.tab(agent)])
            daemon.failures[left] = DaemonClientError.rpcError(Self.refusal, code: nil)
            daemon.failures[right] = DaemonClientError.rpcError(Self.refusal, code: nil)

            state.closeTab(worktreeID: worktreeID, index: 0)
            await PanelTabsFixture.drainMainActor()

            let settled: [UUID] = [agent, left, right]
            #expect(Self.tabIDs(state, worktreeID) == settled)
            #expect(state.alertMessage == "Couldn't close 2 terminals: \(Self.refusal)")
        }
    }

    @Test(
        "a failure that is not the daemon's answer shows no alert and leaves the tab closed",
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
                state, terminalIDs: [claude, build, agent],
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
            #expect(state.composerDrafts[.terminal(build)] == nil)
            #expect(state.closingTerminalIDs.isEmpty)
        }
    }
}

/// The daemon's end of `terminal.delete` for a tab close: records each
/// terminal asked about, holds the ones named by `hold` until `release`, and
/// fails those named in `failures`; every other delete succeeds.
@MainActor
final class TerminalCloseDaemon {
    var failures: [UUID: any Error] = [:]
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
        if let failure = failures[terminalID] { throw failure }
    }
}
