import Testing
import Foundation
@testable import TBDApp
import TBDShared

// DaemonClient is a concrete actor (no protocol), so we can't inject a stub.
// These tests verify pure-Swift state mutations on AppState — the persistence
// path (setTabLabel / setTabOrder) is covered by daemon-side tests in
// `Tests/TBDDaemonTests/TabRPCHandlersTests.swift`.

@MainActor
@Test func reorderMovesTabAndPreservesActiveSelection() {
    let state = AppState()
    let worktreeID = UUID()
    let ids = [UUID(), UUID(), UUID()]
    state.tabs[worktreeID] = ids.map { Tab(id: $0, content: .terminal(terminalID: $0), label: nil) }
    state.activeTabIndices[worktreeID] = 0  // first tab active
    // Move first tab to after the third (.trailing of last)
    state.reorderTab(
        draggedID: ids[0],
        in: worktreeID,
        relativeTo: ids[2],
        edge: .trailing
    )
    let newOrder = state.tabs[worktreeID]!.map(\.id)
    #expect(newOrder == [ids[1], ids[2], ids[0]])
    // Active index should now point at the same tab.id (was ids[0], still ids[0])
    let activeIdx = state.activeTabIndices[worktreeID]!
    #expect(state.tabs[worktreeID]![activeIdx].id == ids[0])
    // worktreeTabOrders should reflect the new order
    #expect(state.worktreeTabOrders[worktreeID] == [ids[1], ids[2], ids[0]])
}

@MainActor
@Test func reorderDropOnSelfIsNoOp() {
    let state = AppState()
    let worktreeID = UUID()
    let ids = [UUID(), UUID()]
    state.tabs[worktreeID] = ids.map { Tab(id: $0, content: .terminal(terminalID: $0), label: nil) }
    state.reorderTab(draggedID: ids[0], in: worktreeID, relativeTo: ids[0], edge: .leading)
    #expect(state.tabs[worktreeID]!.map(\.id) == ids)
}

@MainActor
@Test func reorderLeadingEdgeInsertsBeforeTarget() {
    let state = AppState()
    let worktreeID = UUID()
    let ids = [UUID(), UUID(), UUID()]
    state.tabs[worktreeID] = ids.map { Tab(id: $0, content: .terminal(terminalID: $0), label: nil) }
    // Move third tab to before the first (.leading of first)
    state.reorderTab(
        draggedID: ids[2],
        in: worktreeID,
        relativeTo: ids[0],
        edge: .leading
    )
    let newOrder = state.tabs[worktreeID]!.map(\.id)
    #expect(newOrder == [ids[2], ids[0], ids[1]])
}

@MainActor
@Test func renameTabWithEmptyStringClearsLabel() {
    let state = AppState()
    let worktreeID = UUID()
    let tabID = UUID()
    state.tabs[worktreeID] = [Tab(id: tabID, content: .terminal(terminalID: tabID), label: "old")]
    // Daemon RPC will fail (no daemon running in tests) but the synchronous
    // in-memory mutation still happens first.
    state.renameTab(tabID: tabID, worktreeID: worktreeID, newLabel: "   ")
    #expect(state.tabs[worktreeID]!.first?.label == nil)
}

@MainActor
@Test func renameTabTrimsAndUpdatesInMemory() {
    let state = AppState()
    let worktreeID = UUID()
    let tabID = UUID()
    state.tabs[worktreeID] = [Tab(id: tabID, content: .terminal(terminalID: tabID), label: nil)]
    state.renameTab(tabID: tabID, worktreeID: worktreeID, newLabel: "  Hello  ")
    #expect(state.tabs[worktreeID]!.first?.label == "Hello")
}

@MainActor
@Test func applyStoredOrderReordersTabsToMatchStoredOrder() {
    let state = AppState()
    let worktreeID = UUID()
    let ids = [UUID(), UUID(), UUID()]
    state.tabs[worktreeID] = ids.map { Tab(id: $0, content: .terminal(terminalID: $0), label: nil) }
    // Stored order is reversed.
    state.worktreeTabOrders[worktreeID] = [ids[2], ids[1], ids[0]]
    state.applyStoredOrder(worktreeID: worktreeID)
    #expect(state.tabs[worktreeID]!.map(\.id) == [ids[2], ids[1], ids[0]])
}

@MainActor
@Test func applyStoredOrderPlacesUnknownIDsAtEnd() {
    let state = AppState()
    let worktreeID = UUID()
    let known = [UUID(), UUID()]
    let newTab = UUID()
    // Tabs include a new tab (newTab) that wasn't in the stored order.
    state.tabs[worktreeID] = [known[0], newTab, known[1]].map {
        Tab(id: $0, content: .terminal(terminalID: $0), label: nil)
    }
    state.worktreeTabOrders[worktreeID] = [known[1], known[0]]
    state.applyStoredOrder(worktreeID: worktreeID)
    let result = state.tabs[worktreeID]!.map(\.id)
    // Known tabs come first in stored order; unknown tab goes to the end.
    #expect(result == [known[1], known[0], newTab])
}

@MainActor
@Test func applyStoredOrderIsNoOpWhenStoredOrderEmpty() {
    let state = AppState()
    let worktreeID = UUID()
    let ids = [UUID(), UUID(), UUID()]
    state.tabs[worktreeID] = ids.map { Tab(id: $0, content: .terminal(terminalID: $0), label: nil) }
    // No worktreeTabOrders entry — applyStoredOrder should not mutate.
    state.applyStoredOrder(worktreeID: worktreeID)
    #expect(state.tabs[worktreeID]!.map(\.id) == ids)
}

@MainActor
@Test func setActiveTabUpdatesInMemoryIndex() {
    let state = AppState()
    let worktreeID = UUID()
    let ids = [UUID(), UUID(), UUID()]
    state.tabs[worktreeID] = ids.map { Tab(id: $0, content: .terminal(terminalID: $0), label: nil) }
    // The daemon RPC will fail (no daemon running) but the synchronous
    // in-memory mutation still happens first.
    state.setActiveTab(worktreeID: worktreeID, tabIndex: 2)
    #expect(state.activeTabIndices[worktreeID] == 2)
}

@MainActor
@Test func setActiveTabIgnoresOutOfBoundsIndexForPersistButStillStoresIndex() {
    let state = AppState()
    let worktreeID = UUID()
    let ids = [UUID(), UUID()]
    state.tabs[worktreeID] = ids.map { Tab(id: $0, content: .terminal(terminalID: $0), label: nil) }
    // Out-of-bounds index — helper still updates the dictionary so the view
    // layer can recover; the persist path bails before constructing a tab ID.
    state.setActiveTab(worktreeID: worktreeID, tabIndex: 99)
    #expect(state.activeTabIndices[worktreeID] == 99)
}

@MainActor
@Test func closeFocusedTabRemovesFocusedTabAndLayout() {
    let state = AppState()
    let worktreeID = UUID()
    let ids = [UUID(), UUID(), UUID()]
    state.tabs[worktreeID] = ids.map { Tab(id: $0, content: .terminal(terminalID: $0), label: nil) }
    state.layouts[ids[1]] = .pane(.terminal(terminalID: ids[1]))
    state.focusedTabCloseContext = .init(worktreeID: worktreeID, tabID: ids[1])

    state.closeFocusedTab()

    #expect(state.tabs[worktreeID]?.map(\.id) == [ids[0], ids[2]])
    #expect(state.layouts[ids[1]] == nil)
    #expect(state.activeTabIndices[worktreeID] == 1)
    #expect(state.focusedTabCloseContext == nil)
}

@MainActor
@Test func closeFocusedTabUsesFocusedContextInsteadOfSelectedWorktree() {
    let state = AppState()
    let selectedWorktreeID = UUID()
    let focusedWorktreeID = UUID()
    let selectedTabID = UUID()
    let focusedTabIDs = [UUID(), UUID()]
    state.selectedWorktreeIDs = [selectedWorktreeID]
    state.tabs[selectedWorktreeID] = [Tab(id: selectedTabID, content: .terminal(terminalID: selectedTabID), label: nil)]
    state.tabs[focusedWorktreeID] = focusedTabIDs.map { Tab(id: $0, content: .terminal(terminalID: $0), label: nil) }
    state.focusedTabCloseContext = .init(worktreeID: focusedWorktreeID, tabID: focusedTabIDs[1])

    state.closeFocusedTab()

    #expect(state.tabs[selectedWorktreeID]?.map(\.id) == [selectedTabID])
    #expect(state.tabs[focusedWorktreeID]?.map(\.id) == [focusedTabIDs[0]])
}

@MainActor
@Test func canCloseFocusedTabRequiresLiveFocusedContext() {
    let state = AppState()
    let worktreeID = UUID()
    let tabID = UUID()
    state.tabs[worktreeID] = [Tab(id: tabID, content: .terminal(terminalID: tabID), label: nil)]

    #expect(state.canCloseFocusedTab == false)

    state.focusedTabCloseContext = .init(worktreeID: worktreeID, tabID: tabID)
    #expect(state.canCloseFocusedTab == true)

    state.focusedTabCloseContext = .init(worktreeID: worktreeID, tabID: UUID())
    #expect(state.canCloseFocusedTab == false)
}
