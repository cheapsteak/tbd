import Foundation
import Testing
@testable import TBDApp
import TBDShared

// Tier 1: deterministic, in-process state only. No sleeps, no subprocesses,
// no `~/tbd`. Every `AppState` here is built against a throwaway
// `UserDefaults` suite — `UserDefaults.standard` on this unbundled executable
// is the developer's real `TBDApp.plist`.

private func makeWorktree(
    id: UUID = UUID(),
    repoID: UUID?,
    status: WorktreeStatus = .active,
    sortOrder: Int = 0,
    parentWorktreeID: UUID? = nil
) -> Worktree {
    Worktree(
        id: id,
        repoID: repoID,
        name: "test-\(id.uuidString.prefix(8))",
        displayName: "Test \(id.uuidString.prefix(8))",
        branch: "main",
        path: "/tmp/test",
        status: status,
        tmuxServer: "test-server",
        sortOrder: sortOrder,
        parentWorktreeID: parentWorktreeID
    )
}

/// The pre-memoization `children(of:)` body, verbatim. Every index assertion
/// below is stated against this oracle so the memoized index cannot silently
/// drift from the semantics it replaced.
@MainActor
private func referenceChildren(_ state: AppState, of parentID: UUID) -> [Worktree] {
    state.worktrees.values
        .flatMap { $0 }
        .filter { $0.parentWorktreeID == parentID && ($0.status == .active || $0.status == .creating) }
        .sorted { $0.sortOrder < $1.sortOrder }
}

@MainActor
private func withState(_ body: (AppState) -> Void) {
    let suiteName = "TBDAppTests.AppStateDerivedCache.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suiteName)!
    defer { defaults.removePersistentDomain(forName: suiteName) }
    body(AppState(userDefaults: defaults))
}

/// `children(of:)` is served from a memoized parent-keyed index rather than
/// re-running an O(N) flatMap/filter/sort per call — the sidebar calls it once
/// per row, which made a render pass O(N²) (measured 79.5 ms at 127
/// worktrees). These tests pin both halves: the index must agree with the old
/// implementation, and it must be invalidated on every `worktrees` mutation.
@MainActor
@Suite("children(of:) memoized index")
struct ChildrenIndexTests {

    @Test func matchesReferenceOnAFreshState() {
        withState { state in
            let repoID = UUID()
            let parentID = UUID()
            let parent = makeWorktree(id: parentID, repoID: repoID)
            let childA = makeWorktree(repoID: repoID, sortOrder: 2, parentWorktreeID: parentID)
            let childB = makeWorktree(repoID: repoID, sortOrder: 1, parentWorktreeID: parentID)
            state.worktrees = [repoID: [parent, childA, childB]]

            #expect(state.children(of: parentID).map(\.id) == [childB.id, childA.id])
            #expect(state.children(of: parentID) == referenceChildren(state, of: parentID))
            // A parent with no children resolves to empty, not to some other
            // bucket's rows.
            #expect(state.children(of: UUID()).isEmpty)
        }
    }

    @Test func reflectsAnAddedChild() {
        withState { state in
            let repoID = UUID()
            let parentID = UUID()
            state.worktrees = [repoID: [makeWorktree(id: parentID, repoID: repoID)]]
            // Warm the cache before mutating — a missing invalidation would
            // keep serving this empty answer.
            #expect(state.children(of: parentID).isEmpty)

            let child = makeWorktree(repoID: repoID, sortOrder: 1, parentWorktreeID: parentID)
            state.worktrees[repoID]?.append(child)

            #expect(state.children(of: parentID).map(\.id) == [child.id])
            #expect(state.children(of: parentID) == referenceChildren(state, of: parentID))
        }
    }

    @Test func reflectsARemovedChild() {
        withState { state in
            let repoID = UUID()
            let parentID = UUID()
            let child = makeWorktree(repoID: repoID, sortOrder: 1, parentWorktreeID: parentID)
            state.worktrees = [repoID: [makeWorktree(id: parentID, repoID: repoID), child]]
            #expect(state.children(of: parentID).count == 1)

            state.worktrees[repoID]?.removeAll { $0.id == child.id }

            #expect(state.children(of: parentID).isEmpty)
            #expect(state.children(of: parentID) == referenceChildren(state, of: parentID))
        }
    }

    @Test func reflectsAReparent() {
        withState { state in
            let repoID = UUID()
            let firstParent = UUID()
            let secondParent = UUID()
            let child = makeWorktree(repoID: repoID, sortOrder: 1, parentWorktreeID: firstParent)
            state.worktrees = [repoID: [
                makeWorktree(id: firstParent, repoID: repoID),
                makeWorktree(id: secondParent, repoID: repoID),
                child
            ]]
            #expect(state.children(of: firstParent).map(\.id) == [child.id])

            // In-place element write through the subscript — still a
            // get-modify-set on the stored property, so `didSet` fires.
            let index = state.worktrees[repoID]!.firstIndex { $0.id == child.id }!
            state.worktrees[repoID]?[index].parentWorktreeID = secondParent

            #expect(state.children(of: firstParent).isEmpty)
            #expect(state.children(of: secondParent).map(\.id) == [child.id])
            #expect(state.children(of: secondParent) == referenceChildren(state, of: secondParent))
        }
    }

    @Test func statusChangeToArchivedDropsTheChild() {
        withState { state in
            let repoID = UUID()
            let parentID = UUID()
            let child = makeWorktree(repoID: repoID, sortOrder: 1, parentWorktreeID: parentID)
            state.worktrees = [repoID: [makeWorktree(id: parentID, repoID: repoID), child]]
            #expect(state.children(of: parentID).count == 1)

            let index = state.worktrees[repoID]!.firstIndex { $0.id == child.id }!
            state.worktrees[repoID]?[index].status = .archived

            #expect(state.children(of: parentID).isEmpty)
            #expect(state.children(of: parentID) == referenceChildren(state, of: parentID))
        }
    }

    @Test func onlyActiveAndCreatingRowsAreIncluded() {
        withState { state in
            let repoID = UUID()
            let parentID = UUID()
            let active = makeWorktree(repoID: repoID, status: .active, sortOrder: 1, parentWorktreeID: parentID)
            let creating = makeWorktree(repoID: repoID, status: .creating, sortOrder: 2, parentWorktreeID: parentID)
            let archived = makeWorktree(repoID: repoID, status: .archived, sortOrder: 3, parentWorktreeID: parentID)
            state.worktrees = [repoID: [active, creating, archived]]

            #expect(state.children(of: parentID).map(\.id) == [active.id, creating.id])
            #expect(state.children(of: parentID) == referenceChildren(state, of: parentID))
        }
    }

    @Test func reflectsASortOrderChange() {
        withState { state in
            let repoID = UUID()
            let parentID = UUID()
            let first = makeWorktree(repoID: repoID, sortOrder: 1, parentWorktreeID: parentID)
            let second = makeWorktree(repoID: repoID, sortOrder: 2, parentWorktreeID: parentID)
            state.worktrees = [repoID: [first, second]]
            #expect(state.children(of: parentID).map(\.id) == [first.id, second.id])

            let index = state.worktrees[repoID]!.firstIndex { $0.id == first.id }!
            state.worktrees[repoID]?[index].sortOrder = 99

            #expect(state.children(of: parentID).map(\.id) == [second.id, first.id])
            #expect(state.children(of: parentID) == referenceChildren(state, of: parentID))
        }
    }

    @Test func wholesaleDictReplacementInvalidatesTheIndex() {
        withState { state in
            let repoID = UUID()
            let parentID = UUID()
            let child = makeWorktree(repoID: repoID, sortOrder: 1, parentWorktreeID: parentID)
            state.worktrees = [repoID: [child]]
            #expect(state.children(of: parentID).count == 1)

            state.worktrees = [:]

            #expect(state.children(of: parentID).isEmpty)
        }
    }

    @Test func bucketsChildrenAcrossRepos() {
        withState { state in
            let repoA = UUID()
            let repoB = UUID()
            let parentID = UUID()
            // A child of the same parent living under a different repo key —
            // the index must not be repo-partitioned.
            let childA = makeWorktree(repoID: repoA, sortOrder: 1, parentWorktreeID: parentID)
            let childB = makeWorktree(repoID: repoB, sortOrder: 2, parentWorktreeID: parentID)
            state.worktrees = [repoA: [childA], repoB: [childB]]

            #expect(state.children(of: parentID).map(\.id) == [childA.id, childB.id])
            #expect(state.children(of: parentID) == referenceChildren(state, of: parentID))
        }
    }

    /// `children(of:)` is dict-only by design: a scratch space can never be a
    /// child (`createNestedWorktree` requires a `repoID`, `createScratch`
    /// never sets `parentWorktreeID`). The index must keep that scope even
    /// when a scratch row is hand-stamped with a parent.
    @Test func excludesScratchWorktrees() {
        withState { state in
            let repoID = UUID()
            let parentID = UUID()
            let realChild = makeWorktree(repoID: repoID, sortOrder: 1, parentWorktreeID: parentID)
            state.worktrees = [repoID: [realChild]]
            state.scratchWorktrees = [
                makeWorktree(repoID: nil, sortOrder: 0, parentWorktreeID: parentID)
            ]

            #expect(state.children(of: parentID).map(\.id) == [realChild.id])
            #expect(state.children(of: parentID) == referenceChildren(state, of: parentID))
        }
    }

    /// A scratch mutation must not disturb the child index (it invalidates
    /// only the `allWorktrees` cache), and must still not leak into it.
    @Test func scratchMutationsNeverEnterTheIndex() {
        withState { state in
            let repoID = UUID()
            let parentID = UUID()
            let realChild = makeWorktree(repoID: repoID, sortOrder: 1, parentWorktreeID: parentID)
            state.worktrees = [repoID: [realChild]]
            #expect(state.children(of: parentID).map(\.id) == [realChild.id])

            state.scratchWorktrees.append(
                makeWorktree(repoID: nil, sortOrder: 0, parentWorktreeID: parentID)
            )

            #expect(state.children(of: parentID).map(\.id) == [realChild.id])
        }
    }
}

/// `allWorktrees` is memoized behind the same two `didSet`s. It must stay
/// scratch-inclusive and must follow BOTH sources.
@MainActor
@Suite("allWorktrees memoization")
struct AllWorktreesCacheTests {

    @Test func followsWorktreeDictMutations() {
        withState { state in
            let repoID = UUID()
            let first = makeWorktree(repoID: repoID)
            state.worktrees = [repoID: [first]]
            #expect(state.allWorktrees.map(\.id) == [first.id])

            let second = makeWorktree(repoID: repoID)
            state.worktrees[repoID]?.append(second)

            #expect(Set(state.allWorktrees.map(\.id)) == Set([first.id, second.id]))
        }
    }

    @Test func followsScratchMutations() {
        withState { state in
            let repoID = UUID()
            let repoRow = makeWorktree(repoID: repoID)
            state.worktrees = [repoID: [repoRow]]
            #expect(state.allWorktrees.map(\.id) == [repoRow.id])

            let scratch = makeWorktree(repoID: nil)
            state.scratchWorktrees.append(scratch)

            #expect(Set(state.allWorktrees.map(\.id)) == Set([repoRow.id, scratch.id]))

            state.scratchWorktrees.removeAll()
            #expect(state.allWorktrees.map(\.id) == [repoRow.id])
        }
    }

    @Test func followsInPlaceFieldEdits() {
        withState { state in
            let repoID = UUID()
            let row = makeWorktree(repoID: repoID)
            state.worktrees = [repoID: [row]]
            #expect(state.allWorktrees.first?.displayName == row.displayName)

            state.worktrees[repoID]?[0].displayName = "Renamed"

            #expect(state.allWorktrees.first?.displayName == "Renamed")
        }
    }
}

/// A `UserDefaults` that counts writes per key, so a test can assert how many
/// encode+write round-trips one selection change costs.
private final class WriteCountingUserDefaults: UserDefaults {
    nonisolated(unsafe) var writesByKey: [String: Int] = [:]

    override func set(_ value: Any?, forKey defaultName: String) {
        writesByKey[defaultName, default: 0] += 1
        super.set(value, forKey: defaultName)
    }
}

/// `selectedWorktreeIDs`'s `didSet` used to mutate `selectionOrder` in place —
/// one `removeAll` plus one `append` per newly-selected id — and
/// `selectionOrder`'s own `didSet` runs a full `JSONEncoder` + `UserDefaults`
/// write. One selection of N worktrees therefore cost N+1 encodes and writes.
/// The order it produces must be byte-identical to the old behavior.
@MainActor
@Suite("Selection order persists once per selection change")
struct SelectionOrderWriteCoalescingTests {

    /// Key literal, because `AppState.selectionOrderKey` is `private static`.
    private static let selectionOrderKey = "com.tbd.app.selectionOrder"

    private func withCountingState(_ body: (AppState, WriteCountingUserDefaults) -> Void) {
        let suiteName = "TBDAppTests.SelectionOrderWrites.\(UUID().uuidString)"
        let defaults = WriteCountingUserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let state = AppState(userDefaults: defaults)
        // `persistSelectionOrder` is gated on this; startup must not clobber a
        // saved value before the restore has run.
        state.isInitialStateLoaded = true
        defaults.writesByKey.removeAll()
        body(state, defaults)
    }

    private func writes(_ defaults: WriteCountingUserDefaults) -> Int {
        defaults.writesByKey[Self.selectionOrderKey] ?? 0
    }

    @Test func selectingFiveWorktreesWritesOnce() {
        withCountingState { state, defaults in
            let repoID = UUID()
            let rows = (0..<5).map { makeWorktree(repoID: repoID, sortOrder: $0) }
            state.worktrees = [repoID: rows]

            state.selectedWorktreeIDs = Set(rows.map(\.id))

            // Old code: 1 `removeAll` + 5 `append` = 6 writes.
            #expect(writes(defaults) == 1)
            #expect(Set(state.selectionOrder) == Set(rows.map(\.id)))
        }
    }

    @Test func selectingOneWorktreeWritesOnce() {
        withCountingState { state, defaults in
            let repoID = UUID()
            let row = makeWorktree(repoID: repoID)
            state.worktrees = [repoID: [row]]

            state.selectedWorktreeIDs = [row.id]

            // Old code: 1 `removeAll` + 1 `append` = 2 writes.
            #expect(writes(defaults) == 1)
            #expect(state.selectionOrder == [row.id])
        }
    }

    @Test func reassigningTheSameSelectionWritesNothing() {
        withCountingState { state, defaults in
            let repoID = UUID()
            let row = makeWorktree(repoID: repoID)
            state.worktrees = [repoID: [row]]
            state.selectedWorktreeIDs = [row.id]
            #expect(writes(defaults) == 1)

            // A no-op selection change must not re-encode and re-write.
            state.selectedWorktreeIDs = [row.id]

            #expect(writes(defaults) == 1)
            #expect(state.selectionOrder == [row.id])
        }
    }

    @Test func deselectingWritesOnce() {
        withCountingState { state, defaults in
            let repoID = UUID()
            let rows = (0..<3).map { makeWorktree(repoID: repoID, sortOrder: $0) }
            state.worktrees = [repoID: rows]
            state.selectedWorktreeIDs = Set(rows.map(\.id))
            defaults.writesByKey.removeAll()

            state.selectedWorktreeIDs = [rows[0].id]

            #expect(writes(defaults) == 1)
            #expect(state.selectionOrder == [rows[0].id])
        }
    }
}

/// The order `selectionOrder` ends up in must be exactly what the in-place
/// mutation produced: survivors keep their relative order, newly-selected ids
/// land after them.
@MainActor
@Suite("Selection order contents are unchanged")
struct SelectionOrderSemanticsTests {

    @Test func survivorsKeepRelativeOrderAndNewIDsAppend() {
        withState { state in
            let repoID = UUID()
            let rows = (0..<4).map { makeWorktree(repoID: repoID, sortOrder: $0) }
            state.worktrees = [repoID: rows]
            state.isInitialStateLoaded = true

            // Build a deliberate cmd+click order: 2, then 0, then 1.
            state.selectedWorktreeIDs = [rows[2].id]
            state.selectedWorktreeIDs = [rows[2].id, rows[0].id]
            state.selectedWorktreeIDs = [rows[2].id, rows[0].id, rows[1].id]
            #expect(state.selectionOrder == [rows[2].id, rows[0].id, rows[1].id])

            // Drop the middle survivor and add a brand-new id in one change:
            // 2 and 1 keep their relative order, 3 is appended after them.
            state.selectedWorktreeIDs = [rows[2].id, rows[1].id, rows[3].id]

            #expect(state.selectionOrder == [rows[2].id, rows[1].id, rows[3].id])
        }
    }

    @Test func clearingSelectionEmptiesTheOrder() {
        withState { state in
            let repoID = UUID()
            let rows = (0..<2).map { makeWorktree(repoID: repoID, sortOrder: $0) }
            state.worktrees = [repoID: rows]
            state.isInitialStateLoaded = true
            state.selectedWorktreeIDs = [rows[0].id]
            state.selectedWorktreeIDs = [rows[0].id, rows[1].id]
            #expect(state.selectionOrder == [rows[0].id, rows[1].id])

            state.selectedWorktreeIDs = []

            #expect(state.selectionOrder.isEmpty)
        }
    }

    /// The bookkeeping that runs after the loop must still see the final
    /// `selectionOrder` — `recentWorktreeIDs` is fed from `selectionOrder.last`.
    @Test func recentWorktreeIDsStillSeeTheFinalOrder() {
        withState { state in
            let repoID = UUID()
            let rows = (0..<2).map { makeWorktree(repoID: repoID, sortOrder: $0) }
            state.worktrees = [repoID: rows]
            state.isInitialStateLoaded = true

            state.selectedWorktreeIDs = [rows[0].id]
            #expect(state.recentWorktreeIDs.first == rows[0].id)

            state.selectedWorktreeIDs = [rows[0].id, rows[1].id]
            #expect(state.selectionOrder.last == rows[1].id)
            #expect(state.recentWorktreeIDs.first == rows[1].id)
        }
    }
}
