import Foundation
import Testing
@testable import TBDApp
import TBDShared
import TestSupport

// Tier 1: deterministic, in-process state only. `terminal.delete`,
// `tab.setOrder` and the composer-draft report go through injected seams, the
// worktree is marked hydrated so no `tab.list` is sent, and every stub answers
// without suspending, so draining the main actor runs the close to its end.

/// A tab close removes the tab at once and then asks the daemon to delete its
/// terminals. The daemon can keep one — a tmux row whose Closed Terminals
/// record cannot be written stays, with a message saying so — and the close
/// then has to show that message, put the tab back where it was, and leave the
/// stored tab order holding it. The order is written only once every delete
/// has succeeded; a delete that cannot reach the daemon writes no order and
/// shows no alert.
@MainActor
@Suite("Terminal tab close failure")
struct TerminalTabCloseFailureTests {
    private static let refusal =
        "Terminal was not closed. Its session may still be running, so the tab stays open. Try again."

    /// A worktree with three terminal tabs, the selection on the last, and a
    /// draft in the middle tab's composer, which is the one each case closes.
    private struct Seeded {
        let worktreeID: UUID
        let claude: UUID
        let build: UUID
        let agent: UUID
    }

    private static func withState(
        _ body: @MainActor (AppState, TerminalCloseDaemon) async -> Void
    ) async {
        let suite = TestDefaultsSuite("TerminalTabCloseFailureTests")
        defer { suite.tearDown() }
        let state = AppState(userDefaults: suite.defaults)
        let daemon = TerminalCloseDaemon()
        state.terminalDeleter = { @MainActor terminalID in try daemon.delete(terminalID) }
        state.tabOrderSender = { @MainActor _, order in daemon.setOrder(order) }
        state.composerDraftsSetter = { @MainActor _ in }
        state.tabStatesFetcher = { @MainActor _ in
            Issue.record("unexpected tab.list")
            return TabListResponse(tabs: [], order: [], activeTabID: nil)
        }
        await body(state, daemon)
    }

    private static func seed(_ state: AppState) -> Seeded {
        let worktreeID = UUID()
        let seeded = Seeded(worktreeID: worktreeID, claude: UUID(), build: UUID(), agent: UUID())
        state.terminals[worktreeID] = [
            terminal(seeded.claude, worktreeID: worktreeID, label: "claude"),
            terminal(seeded.build, worktreeID: worktreeID, label: "build"),
            terminal(seeded.agent, worktreeID: worktreeID, label: "agent"),
        ]
        state.tabs[worktreeID] = [
            TBDShared.Tab(id: seeded.claude, content: .terminal(terminalID: seeded.claude), label: nil),
            TBDShared.Tab(id: seeded.build, content: .terminal(terminalID: seeded.build), label: "build"),
            TBDShared.Tab(id: seeded.agent, content: .terminal(terminalID: seeded.agent), label: nil),
        ]
        state.worktreeTabOrders[worktreeID] = [seeded.claude, seeded.build, seeded.agent]
        state.activeTabIndices[worktreeID] = 2
        state.tabStateHydratedWorktreeIDs.insert(worktreeID)
        state.composerDraft(for: seeded.build).text = "half a sentence"
        return seeded
    }

    private static func terminal(_ id: UUID, worktreeID: UUID, label: String) -> Terminal {
        Terminal(
            id: id, worktreeID: worktreeID, tmuxWindowID: "@\(label)", tmuxPaneID: "%\(label)",
            label: label, kind: .shell)
    }

    private static func tabIDs(_ state: AppState, _ seeded: Seeded) -> [UUID] {
        state.tabs[seeded.worktreeID]?.map(\.id) ?? []
    }

    @Test("a delete the daemon refuses shows its message and puts the tab back where it was, with its draft")
    func refusedDeletePutsTheTabBack() async {
        await Self.withState { state, daemon in
            let seeded = Self.seed(state)
            daemon.deleteFailure = DaemonClientError.rpcError(Self.refusal, code: nil)

            state.closeTab(worktreeID: seeded.worktreeID, index: 1)

            let whileDeleting = Self.tabIDs(state, seeded)
            let closedAtOnce: [UUID] = [seeded.claude, seeded.agent]
            #expect(whileDeleting == closedAtOnce, "the tab closes before closeTab returns")

            await PanelTabsFixture.drainMainActor()

            let expectedDeletes: [UUID] = [seeded.build]
            #expect(daemon.deleted == expectedDeletes)
            let restored = Self.tabIDs(state, seeded)
            let original: [UUID] = [seeded.claude, seeded.build, seeded.agent]
            #expect(restored == original, "the tab comes back in its place")
            #expect(state.tabs[seeded.worktreeID]?[1].label == "build", "with its label")
            #expect(state.resolvedActiveTab(worktreeID: seeded.worktreeID)?.id == seeded.agent,
                    "the selection stays where it was")
            #expect(state.worktreeTabOrders[seeded.worktreeID] == original,
                    "the next order written keeps the tab")
            #expect(daemon.orders.isEmpty, "no order without the tab reaches the daemon")
            #expect(state.alertIsError)
            #expect(state.alertMessage?.contains(Self.refusal) == true,
                    "the alert carries the daemon's message, observed: \(state.alertMessage ?? "nil")")
            #expect(state.composerDrafts[.terminal(seeded.build)]?.text == "half a sentence")
        }
    }

    @Test("a delete that succeeds writes the order without the tab, shows nothing and drops the draft")
    func successfulDeleteWritesTheOrder() async {
        await Self.withState { state, daemon in
            let seeded = Self.seed(state)

            state.closeTab(worktreeID: seeded.worktreeID, index: 1)
            await PanelTabsFixture.drainMainActor()

            let expectedDeletes: [UUID] = [seeded.build]
            #expect(daemon.deleted == expectedDeletes)
            let remaining: [UUID] = [seeded.claude, seeded.agent]
            #expect(Self.tabIDs(state, seeded) == remaining)
            let expectedOrders: [[UUID]] = [remaining]
            #expect(daemon.orders == expectedOrders)
            #expect(state.alertMessage == nil)
            #expect(state.composerDrafts[.terminal(seeded.build)] == nil)
            let terminalIDs: [UUID] = state.terminals[seeded.worktreeID]?.map(\.id) ?? []
            #expect(!terminalIDs.contains(seeded.build))
        }
    }

    @Test("a delete that cannot reach the daemon writes no order and shows no alert")
    func unreachableDeleteWritesNoOrder() async {
        await Self.withState { state, daemon in
            let seeded = Self.seed(state)
            daemon.deleteFailure = DaemonClientError.daemonNotRunning

            state.closeTab(worktreeID: seeded.worktreeID, index: 1)
            await PanelTabsFixture.drainMainActor()

            let expectedDeletes: [UUID] = [seeded.build]
            #expect(daemon.deleted == expectedDeletes)
            let remaining: [UUID] = [seeded.claude, seeded.agent]
            #expect(Self.tabIDs(state, seeded) == remaining)
            #expect(daemon.orders.isEmpty)
            #expect(state.alertMessage == nil)
            #expect(state.composerDrafts[.terminal(seeded.build)] == nil,
                    "the tab is gone, so its draft goes with it")
        }
    }
}

/// The daemon's end of a tab close: every `terminal.delete` and `tab.setOrder`
/// in the order sent, with each delete failing with `deleteFailure` when set.
@MainActor
final class TerminalCloseDaemon {
    var deleteFailure: (any Error)?
    private(set) var deleted: [UUID] = []
    private(set) var orders: [[UUID]] = []

    func delete(_ terminalID: UUID) throws {
        deleted.append(terminalID)
        if let deleteFailure { throw deleteFailure }
    }

    func setOrder(_ order: [UUID]) {
        orders.append(order)
    }
}
