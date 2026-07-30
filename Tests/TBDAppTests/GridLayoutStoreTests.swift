import Foundation
import Testing
import TBDShared
@testable import TBDApp

@Suite("GridLayoutStore")
@MainActor
struct GridLayoutStoreTests {
    @Test func gridLayoutsAreNeverPersisted() throws {
        let suiteName = "GridLayoutStoreTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let appState = AppState(userDefaults: defaults)
        let worktreeID = UUID()
        appState.gridLayouts[worktreeID] = .pane(.terminal(terminalID: UUID()))
        appState.layouts[UUID()] = .pane(.note(noteID: UUID()))  // triggers persistLayouts

        let blob = try #require(defaults.data(forKey: "com.tbd.app.layouts"))
        let persisted = try JSONDecoder().decode([UUID: LayoutNode].self, from: blob)
        #expect(persisted[worktreeID] == nil, "grid entries must not reach the persisted blob")
        #expect(persisted.count == 1)
    }

    /// Stale worktree-keyed entries written into `layouts` by the pre-split
    /// grid path (and re-persisted forever via restoreLayouts) must not make
    /// their terminals look "visible" — visibleTerminalIDs only consults the
    /// selected worktrees' active-tab layouts, keyed by tab ID.
    @Test func staleNonTabLayoutEntryDoesNotLeakIntoVisibleTerminalIDs() {
        let suiteName = "GridLayoutStoreTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let appState = AppState(userDefaults: defaults)
        let worktreeID = UUID()
        let visibleTerminal = UUID()
        let tab = TBDShared.Tab(id: UUID(), content: .terminal(terminalID: visibleTerminal), label: nil)
        appState.tabs = [worktreeID: [tab]]
        appState.activeTabIndices = [worktreeID: 0]
        appState.selectedWorktreeIDs = [worktreeID]

        // Legacy pollution: a worktree-keyed entry in the tab-keyed dict.
        let staleTerminal = UUID()
        appState.layouts[worktreeID] = .pane(.terminal(terminalID: staleTerminal))

        #expect(appState.visibleTerminalIDs.contains(visibleTerminal))
        #expect(!appState.visibleTerminalIDs.contains(staleTerminal),
                "stale worktree-keyed layout entries must not count as visible")
    }
}
