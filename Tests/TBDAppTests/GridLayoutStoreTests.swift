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
}
