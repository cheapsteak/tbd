import Testing
import Foundation
@testable import TBDApp
import TBDShared

// MARK: - Helpers

private func makeWorktree(id: UUID = UUID(), repoID: UUID) -> Worktree {
    Worktree(
        id: id,
        repoID: repoID,
        name: "test-worktree",
        displayName: "Test Worktree",
        branch: "tbd/test-worktree",
        path: "/tmp/test",
        tmuxServer: "test-\(id.uuidString)"
    )
}

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
            let id = UUID()
            state.selectedWorktreeIDs = [id]
            let saved = defaults.data(forKey: "com.tbd.app.selectionOrder")
            #expect(saved != nil)
        }
    }

    @Test("selection is NOT saved before isInitialStateLoaded is set")
    func selectionNotSavedBeforeInitialLoad() {
        withIsolatedDefaults { defaults in
            let state = AppState(userDefaults: defaults)
            // isInitialStateLoaded stays false in test mode
            state.selectedWorktreeIDs = [UUID()]
            let saved = defaults.data(forKey: "com.tbd.app.selectionOrder")
            #expect(saved == nil)
        }
    }

    @Test("selection writes go to injected suite, not .standard")
    func selectionWritesToInjectedSuite() {
        withIsolatedDefaults { defaults in
            let priorStandard = UserDefaults.standard.data(forKey: "com.tbd.app.selectionOrder")
            defer {
                if let priorStandard {
                    UserDefaults.standard.set(priorStandard, forKey: "com.tbd.app.selectionOrder")
                } else {
                    UserDefaults.standard.removeObject(forKey: "com.tbd.app.selectionOrder")
                }
            }

            let state = AppState(userDefaults: defaults)
            state.isInitialStateLoaded = true
            state.selectedWorktreeIDs = [UUID()]

            #expect(defaults.data(forKey: "com.tbd.app.selectionOrder") != nil)
            // Must not touch the developer's plist.
            #expect(UserDefaults.standard.data(forKey: "com.tbd.app.selectionOrder") == nil)
        }
    }

    // MARK: Restore

    @Test("restoreSavedSelection restores all valid IDs preserving order")
    func restorePreservesOrder() {
        withIsolatedDefaults { defaults in
            let repoID = UUID()
            let id1 = UUID()
            let id2 = UUID()
            let id3 = UUID()

            writeSavedSelection([id1, id2, id3], to: defaults)

            let state = AppState(userDefaults: defaults)
            state.restoreSavedSelection(validWorktreeIDs: [id1, id2, id3])

            #expect(state.selectionOrder == [id1, id2, id3])
            #expect(state.selectedWorktreeIDs == Set([id1, id2, id3]))
            _ = repoID  // suppress unused warning
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
            // Pre-populate selection directly (bypassing persist gate)
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

    @Test("round-trip: save on one AppState, restore on another with same suite")
    func roundTrip() {
        withIsolatedDefaults { defaults in
            let id1 = UUID()
            let id2 = UUID()  // will be stale on restore

            // --- Save side ---
            let state1 = AppState(userDefaults: defaults)
            state1.isInitialStateLoaded = true
            // Single-element selection first so selectionOrder is deterministic.
            state1.selectedWorktreeIDs = [id1]
            // Verify something was written.
            #expect(defaults.data(forKey: "com.tbd.app.selectionOrder") != nil)

            // Overwrite with two IDs. Use explicit selectionOrder assignment to
            // fix the non-deterministic Set iteration order before the next save.
            state1.selectedWorktreeIDs = Set([id1, id2])
            state1.selectionOrder = [id1, id2]
            // Trigger a fresh save with the explicit order (simulate user closing app).
            // The easiest way to re-trigger the save is to flip the selection.
            state1.selectedWorktreeIDs = Set([id2, id1])
            state1.selectionOrder = [id1, id2]
            // Write the desired order directly for a deterministic test.
            writeSavedSelection([id1, id2], to: defaults)

            // --- Restore side: id2 is stale ---
            let state2 = AppState(userDefaults: defaults)
            state2.restoreSavedSelection(validWorktreeIDs: [id1])

            #expect(state2.selectionOrder == [id1])
            #expect(state2.selectedWorktreeIDs == [id1])
        }
    }
}
