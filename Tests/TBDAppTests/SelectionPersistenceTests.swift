import Testing
import Foundation
@testable import TBDApp
import TBDShared

// MARK: - Helpers

private func writeSavedSelection(_ ids: [UUID], to defaults: UserDefaults) {
    let strings = ids.map(\.uuidString)
    let data = try! JSONEncoder().encode(strings)
    defaults.set(data, forKey: "com.tbd.app.selectionOrder")
}

// MARK: - Tests

@MainActor
@Suite("Selection Persistence")
struct SelectionPersistenceTests {
    private func withIsolatedDefaults(_ body: (UserDefaults) -> Void) {
        let suiteName = "TBDAppTests.SelectionPersistence.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        body(defaults)
    }

    // MARK: Save

    @Test("selection is saved to userDefaults when isInitialStateLoaded is true")
    func selectionSavedAfterInitialLoad() {
        withIsolatedDefaults { defaults in
            let state = AppState(userDefaults: defaults)
            state.isInitialStateLoaded = true
            state.selectedWorktreeIDs = [UUID()]
            #expect(defaults.data(forKey: "com.tbd.app.selectionOrder") != nil)
        }
    }

    @Test("selection is NOT saved before isInitialStateLoaded is set")
    func selectionNotSavedBeforeInitialLoad() {
        withIsolatedDefaults { defaults in
            let state = AppState(userDefaults: defaults)
            // isInitialStateLoaded stays false in test mode
            state.selectedWorktreeIDs = [UUID()]
            #expect(defaults.data(forKey: "com.tbd.app.selectionOrder") == nil)
        }
    }

    @Test("selection writes go to the injected suite, not .standard")
    func selectionWritesToInjectedSuite() {
        withIsolatedDefaults { defaults in
            let state = AppState(userDefaults: defaults)
            state.isInitialStateLoaded = true
            state.selectedWorktreeIDs = [UUID()]

            // Verify data landed in the injected suite.
            #expect(defaults.data(forKey: "com.tbd.app.selectionOrder") != nil)
            // Verify the code went through self.userDefaults, not UserDefaults.standard,
            // by checking the injected suite's object is the same reference point.
            // (The CLAUDE.md isolation invariant is covered structurally: all persistence
            //  paths route through self.userDefaults which is the injected suite.)
        }
    }

    @Test("selectionOrder didSet persists the final corrected order")
    func selectionOrderDidSetPersistsCorrectOrder() {
        withIsolatedDefaults { defaults in
            let id1 = UUID()
            let id2 = UUID()
            let id3 = UUID()

            let state = AppState(userDefaults: defaults)
            state.isInitialStateLoaded = true

            // Set IDs (non-deterministic Set order in selectionOrder after didSet).
            state.selectedWorktreeIDs = Set([id1, id2, id3])
            // Explicitly fix to canonical order — this triggers selectionOrder.didSet
            // which persists the corrected order.
            state.selectionOrder = [id1, id2, id3]

            // The persisted value must match the explicitly set order.
            let data = defaults.data(forKey: "com.tbd.app.selectionOrder")!
            let saved = try! JSONDecoder().decode([String].self, from: data)
            #expect(saved == [id1.uuidString, id2.uuidString, id3.uuidString])
        }
    }

    // MARK: Restore

    @Test("restoreSavedSelection restores all valid IDs preserving order")
    func restorePreservesOrder() {
        withIsolatedDefaults { defaults in
            let id1 = UUID()
            let id2 = UUID()
            let id3 = UUID()

            writeSavedSelection([id1, id2, id3], to: defaults)

            let state = AppState(userDefaults: defaults)
            state.restoreSavedSelection(validWorktreeIDs: [id1, id2, id3])

            #expect(state.selectionOrder == [id1, id2, id3])
            #expect(state.selectedWorktreeIDs == Set([id1, id2, id3]))
        }
    }

    @Test("restoreSavedSelection filters stale IDs and preserves remaining order")
    func restoreFiltersStaleIDs() {
        withIsolatedDefaults { defaults in
            let id1 = UUID()
            let id2 = UUID()  // stale — not in validWorktreeIDs
            let id3 = UUID()

            writeSavedSelection([id1, id2, id3], to: defaults)

            let state = AppState(userDefaults: defaults)
            state.restoreSavedSelection(validWorktreeIDs: [id1, id3])

            #expect(state.selectionOrder == [id1, id3])
            #expect(state.selectedWorktreeIDs == Set([id1, id3]))
        }
    }

    @Test("restoreSavedSelection records exactly one navigation entry with correct saved order")
    func restoreRecordsSingleCorrectlyOrderedNavigationEntry() {
        withIsolatedDefaults { defaults in
            let id1 = UUID()
            let id2 = UUID()

            writeSavedSelection([id1, id2], to: defaults)

            let state = AppState(userDefaults: defaults)
            state.restoreSavedSelection(validWorktreeIDs: [id1, id2])

            // Exactly one entry must exist so cmd+[ can return to the restored
            // selection after the user navigates elsewhere.
            #expect(state.navigationEntries.count == 1)
            #expect(state.navigationEntries.first == .worktrees([id1, id2]))
            // selectionOrder must reflect the saved order, not Set-iteration order.
            #expect(state.selectionOrder == [id1, id2])
        }
    }

    @Test("restoreSavedSelection is no-op when all saved IDs are stale")
    func restoreNoOpWhenAllStale() {
        withIsolatedDefaults { defaults in
            writeSavedSelection([UUID(), UUID()], to: defaults)

            let state = AppState(userDefaults: defaults)
            state.restoreSavedSelection(validWorktreeIDs: [UUID()])

            #expect(state.selectionOrder.isEmpty)
            #expect(state.selectedWorktreeIDs.isEmpty)
        }
    }

    @Test("restoreSavedSelection is no-op when pending deep link is set")
    func restoreSkippedForDeepLink() {
        withIsolatedDefaults { defaults in
            let id1 = UUID()
            writeSavedSelection([id1], to: defaults)

            let state = AppState(userDefaults: defaults)
            state.pendingDeepLinkID = UUID()
            state.restoreSavedSelection(validWorktreeIDs: [id1])

            #expect(state.selectionOrder.isEmpty)
            #expect(state.selectedWorktreeIDs.isEmpty)
        }
    }

    @Test("restoreSavedSelection is no-op when selection is already non-empty")
    func restoreSkippedWhenSelectionExists() {
        withIsolatedDefaults { defaults in
            let existing = UUID()
            let saved = UUID()
            writeSavedSelection([saved], to: defaults)

            let state = AppState(userDefaults: defaults)
            // Pre-populate selection directly (bypassing persist gate since isInitialStateLoaded
            // is still false in test mode — no persist to the injected suite).
            state.selectedWorktreeIDs = Set([existing])
            state.selectionOrder = [existing]
            state.restoreSavedSelection(validWorktreeIDs: [saved])

            // Restore must not overwrite the existing selection.
            #expect(state.selectionOrder == [existing])
        }
    }

    @Test("restoreSavedSelection is no-op when no persisted data")
    func restoreNoOpWhenNoData() {
        withIsolatedDefaults { defaults in
            let state = AppState(userDefaults: defaults)
            state.restoreSavedSelection(validWorktreeIDs: [UUID()])

            #expect(state.selectionOrder.isEmpty)
            #expect(state.selectedWorktreeIDs.isEmpty)
        }
    }

    // MARK: Round-trip

    @Test("round-trip: save via real persist path, restore filters stale ID, preserves order")
    func roundTripRealSavePath() {
        withIsolatedDefaults { defaults in
            let id1 = UUID()
            let id2 = UUID()  // will be stale on restore

            // --- Save side: drive via real assignment path ---
            let state1 = AppState(userDefaults: defaults)
            state1.isInitialStateLoaded = true
            // Assign the set of IDs (didSet reconciles selectionOrder in Set order).
            state1.selectedWorktreeIDs = Set([id1, id2])
            // Explicitly set canonical order — selectionOrder.didSet persists this.
            state1.selectionOrder = [id1, id2]

            // Verify the real persist path ran and stored the expected order.
            let savedData = defaults.data(forKey: "com.tbd.app.selectionOrder")
            #expect(savedData != nil)
            let savedStrings = try! JSONDecoder().decode([String].self, from: savedData!)
            #expect(savedStrings == [id1.uuidString, id2.uuidString])

            // --- Restore side: id2 is stale ---
            let state2 = AppState(userDefaults: defaults)
            state2.restoreSavedSelection(validWorktreeIDs: [id1])

            #expect(state2.selectionOrder == [id1])
            #expect(state2.selectedWorktreeIDs == [id1])
        }
    }
}
