import Foundation
import Testing
@testable import TBDApp
@testable import TBDShared

/// Tier 1. The fold behind `AppState.refreshPRBindings`.
///
/// Its two-branch contract had been documented but never asserted, and it is
/// exactly the semantics a refactor of the surrounding task group breaks
/// silently: a FAILED per-worktree fetch must keep the previous value (a hiccup
/// must not blank the toolbar), while an EMPTY result must drop the key
/// (everything-detached is a real answer).
@Suite("PR binding refresh merge")
struct PRBindingRefreshTests {

    private func binding(_ number: Int, worktreeID: UUID) -> PRBinding {
        let url = "https://github.com/acme/acme-prod/pull/\(number)"
        return PRBinding(
            worktreeID: worktreeID, owner: "acme", repo: "acme-prod",
            number: number, url: url,
            status: PRStatus(number: number, url: url, state: .mergeable),
            source: .hook)
    }

    private func failed(_ worktreeID: UUID) -> PRBindingFetchOutcome {
        PRBindingFetchOutcome(worktreeID: worktreeID, result: nil, failure: "daemon not running")
    }

    private func ok(_ worktreeID: UUID, _ bindings: [PRBinding],
                    detachedCount: Int? = 0) -> PRBindingFetchOutcome {
        PRBindingFetchOutcome(
            worktreeID: worktreeID,
            result: PRBindingsResult(bindings: bindings, detachedCount: detachedCount))
    }

    @Test("a FAILED fetch keeps the previous value")
    func failureKeepsPrevious() {
        let wt = UUID()
        let previous = PRBindingRefresh.State(
            bindings: [wt: [binding(412, worktreeID: wt)]], detachedCounts: [wt: 2])
        let merged = PRBindingRefresh.merge(previous, applying: [failed(wt)])
        #expect(merged.bindings[wt]?.map(\.number) == [412])
        #expect(merged.detachedCounts[wt] == 2)
    }

    @Test("an EMPTY result drops the key")
    func emptyDropsTheKey() {
        let wt = UUID()
        let previous = PRBindingRefresh.State(bindings: [wt: [binding(412, worktreeID: wt)]])
        let merged = PRBindingRefresh.merge(previous, applying: [ok(wt, [])])
        #expect(merged.bindings[wt] == nil)
    }

    /// The whole point of the count: the live list empties AND the tombstone is
    /// recorded, in one fold, so the legacy-status fallback stays suppressed.
    @Test("detaching the last PR empties the bindings and records the tombstone")
    func emptyWithTombstonesRecordsTheCount() {
        let wt = UUID()
        let previous = PRBindingRefresh.State(bindings: [wt: [binding(412, worktreeID: wt)]])
        let merged = PRBindingRefresh.merge(previous, applying: [ok(wt, [], detachedCount: 1)])
        #expect(merged.bindings[wt] == nil)
        #expect(merged.detachedCounts[wt] == 1)
    }

    @Test("a tombstone revived by attach clears the count again")
    func reviveClearsTheCount() {
        let wt = UUID()
        let previous = PRBindingRefresh.State(detachedCounts: [wt: 1])
        let merged = PRBindingRefresh.merge(
            previous, applying: [ok(wt, [binding(412, worktreeID: wt)], detachedCount: 0)])
        #expect(merged.bindings[wt]?.map(\.number) == [412])
        #expect(merged.detachedCounts[wt] == nil)
    }

    /// An older daemon omits the field entirely. `nil` must read as zero — the
    /// pre-existing behaviour — not as "unknown, so suppress".
    @Test("an absent detachedCount reads as zero")
    func absentCountReadsAsZero() {
        let wt = UUID()
        let previous = PRBindingRefresh.State(detachedCounts: [wt: 1])
        let merged = PRBindingRefresh.merge(
            previous, applying: [ok(wt, [], detachedCount: nil)])
        #expect(merged.detachedCounts[wt] == nil)
    }

    @Test("worktrees absent from the round are untouched")
    func untouchedWorktreesSurvive() {
        let kept = UUID()
        let refreshed = UUID()
        let previous = PRBindingRefresh.State(
            bindings: [kept: [binding(1, worktreeID: kept)],
                       refreshed: [binding(2, worktreeID: refreshed)]])
        let merged = PRBindingRefresh.merge(previous, applying: [ok(refreshed, [])])
        #expect(merged.bindings[kept]?.map(\.number) == [1])
        #expect(merged.bindings[refreshed] == nil)
    }

    /// One failure in a batch must not take the successes down with it, which
    /// is the shape a windowed task group has to preserve.
    @Test("a mixed batch applies each worktree's own outcome")
    func mixedBatch() {
        let failing = UUID()
        let emptying = UUID()
        let arriving = UUID()
        let previous = PRBindingRefresh.State(
            bindings: [failing: [binding(1, worktreeID: failing)],
                       emptying: [binding(2, worktreeID: emptying)]])
        let merged = PRBindingRefresh.merge(previous, applying: [
            failed(failing),
            ok(emptying, [], detachedCount: 3),
            ok(arriving, [binding(3, worktreeID: arriving)])
        ])
        #expect(merged.bindings[failing]?.map(\.number) == [1])
        #expect(merged.bindings[emptying] == nil)
        #expect(merged.detachedCounts[emptying] == 3)
        #expect(merged.bindings[arriving]?.map(\.number) == [3])
    }
}

/// Tier 1. The window that bounds how many blocking daemon calls a poll may
/// have in flight. An unbounded group put one `connect`/`recv` per worktree on
/// the cooperative pool — ~40 on a full fleet, every tick.
@Suite("Bounded concurrency")
struct BoundedConcurrencyTests {

    /// Counts how many operations overlap, so the test asserts the window
    /// rather than merely that the results arrived.
    private actor Peak {
        private var current = 0
        private(set) var peak = 0
        func enter() { current += 1; peak = max(peak, current) }
        func leave() { current -= 1 }
    }

    @Test("never more than `limit` operations run at once")
    func windowIsRespected() async {
        let peak = Peak()
        let outputs = await mapConcurrently(Array(1...40), limit: 4) { value -> Int in
            await peak.enter()
            // Yield enough times that a genuinely unbounded group would have
            // every child inside the window simultaneously.
            for _ in 0..<20 { await Task.yield() }
            await peak.leave()
            return value
        }
        #expect(outputs.sorted() == Array(1...40))
        #expect(await peak.peak <= 4)
    }

    @Test("every item is processed exactly once")
    func processesEveryItem() async {
        let outputs = await mapConcurrently(Array(1...17), limit: 5) { $0 * 2 }
        #expect(outputs.sorted() == (1...17).map { $0 * 2 })
    }

    @Test("an empty input does no work")
    func emptyInput() async {
        let outputs = await mapConcurrently([Int](), limit: 4) { $0 }
        #expect(outputs.isEmpty)
    }

    /// A zero or negative window would otherwise seed no children and return an
    /// empty result for a non-empty input — silently losing every fetch.
    @Test("a non-positive limit is clamped to one rather than dropping the work")
    func nonPositiveLimitIsClamped() async {
        let peak = Peak()
        let outputs = await mapConcurrently(Array(1...5), limit: 0) { value -> Int in
            await peak.enter()
            await Task.yield()
            await peak.leave()
            return value
        }
        #expect(outputs.sorted() == Array(1...5))
        #expect(await peak.peak == 1)
    }

    @MainActor
    @Test("the fleet-poll window is small enough to bound the pool")
    func appStateWindowIsBounded() {
        #expect(AppState.prBindingFetchConcurrency >= 1)
        #expect(AppState.prBindingFetchConcurrency <= 8)
    }
}
