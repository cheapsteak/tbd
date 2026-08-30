import Foundation
import TestSupport
import Testing
@testable import TBDApp
@testable import TBDShared

/// Tier 1. The transform behind `AppState.refreshPRBindings`, and the poll that
/// drives it.
///
/// The daemon reports every worktree's bindings in one `pr.bindingsAll` call, so
/// a successful poll REPLACES the published maps. Two behaviours have to survive
/// that: a FAILED fetch must keep the previous maps (one failure now covers the
/// whole fleet, so blanking on it would blank every toolbar at once), and a
/// worktree absent from a SUCCESSFUL response must lose its entry (a detach has
/// to be observed).
@Suite("PR binding refresh")
struct PRBindingRefreshTests {

    // MARK: - The pure transform

    @Test("a reported worktree's bindings become its published entry")
    func reportedBindingsArePublished() {
        let wt = UUID()
        let state = PRBindingRefresh.state(
            from: PRBindingsAllResult(worktrees: [entry(wt, [binding(412, worktreeID: wt)])]))
        #expect(state.bindings[wt]?.map(\.number) == [412])
        #expect(state.detachedCounts[wt] == nil)
    }

    /// The whole point of the count: the live list empties AND the tombstone is
    /// recorded, so the legacy-status fallback stays suppressed.
    @Test("a worktree with only tombstones keeps its count and no bindings")
    func tombstoneOnlyWorktreeKeepsItsCount() {
        let wt = UUID()
        let state = PRBindingRefresh.state(
            from: PRBindingsAllResult(worktrees: [entry(wt, [], detachedCount: 1)]))
        #expect(state.bindings[wt] == nil)
        #expect(state.detachedCounts[wt] == 1)
    }

    /// An older daemon omits the field entirely. `nil` must read as zero — the
    /// pre-existing behaviour — not as "unknown, so suppress".
    @Test("an absent detachedCount reads as zero")
    func absentCountReadsAsZero() {
        let wt = UUID()
        let state = PRBindingRefresh.state(
            from: PRBindingsAllResult(worktrees: [entry(wt, [], detachedCount: nil)]))
        #expect(state.detachedCounts[wt] == nil)
    }

    @Test("several worktrees are all published from the one response")
    func severalWorktreesInOneResponse() {
        let first = UUID()
        let second = UUID()
        let state = PRBindingRefresh.state(from: PRBindingsAllResult(worktrees: [
            entry(first, [binding(1, worktreeID: first)]),
            entry(second, [binding(2, worktreeID: second), binding(3, worktreeID: second)],
                  detachedCount: 2)
        ]))
        #expect(state.bindings[first]?.map(\.number) == [1])
        #expect(state.bindings[second]?.map(\.number) == [2, 3])
        #expect(state.detachedCounts[second] == 2)
    }

    // MARK: - The poll

    @MainActor
    private func withStateAsync(_ body: (AppState) async -> Void) async {
        let defaultsSuite = TestDefaultsSuite("PRBindingRefresh")
        defer { defaultsSuite.tearDown() }
        let defaults = defaultsSuite.defaults
        await body(AppState(userDefaults: defaults))
    }

    /// The regression this batched call exists for.
    ///
    /// A subagent's `gh pr create` binds a PR to a worktree on a branch that
    /// worktree never checked out. Nothing else knows about it: there is no
    /// branch match, so no `prStatuses` entry; no prior binding; no tombstone;
    /// and the user has not selected the worktree. The per-worktree fan-out this
    /// replaced took its target set from exactly those four facts, so it never
    /// asked about this worktree at all and the PR stayed invisible until the
    /// worktree was selected once.
    @MainActor
    @Test("a hook-bound worktree with no status and no selection still gets its bindings")
    func hookBoundUnselectedWorktreeIsRefreshed() async {
        await withStateAsync { state in
            let wt = UUID()
            state.prStatuses = [:]
            state.selectedWorktreeIDs = []
            state.prBindingsFetcher = {
                PRBindingsAllResult(worktrees: [entry(wt, [binding(412, worktreeID: wt)])])
            }

            await state.refreshPRBindings()

            #expect(state.prBindings[wt]?.map(\.number) == [412])
            // …and it reaches the surfaces, which is what the user sees.
            #expect(state.effectivePRBindings(worktreeID: wt).map(\.number) == [412])
        }
    }

    @MainActor
    @Test("a failed fetch keeps the previously published maps")
    func failureKeepsPrevious() async {
        await withStateAsync { state in
            let wt = UUID()
            state.prBindings = [wt: [binding(412, worktreeID: wt)]]
            state.prDetachedCounts = [wt: 2]
            state.prBindingsFetcher = { throw PRBindingRefreshTestError.boom }

            await state.refreshPRBindings()

            #expect(state.prBindings[wt]?.map(\.number) == [412])
            #expect(state.prDetachedCounts[wt] == 2)
        }
    }

    /// One failure now covers the whole fleet, so this is the case the early
    /// return exists for: a hiccup must not blank every worktree's toolbar.
    @MainActor
    @Test("a failed fetch does not blank an entire fleet")
    func failureDoesNotBlankTheFleet() async {
        await withStateAsync { state in
            let ids = (0..<5).map { _ in UUID() }
            state.prBindings = Dictionary(uniqueKeysWithValues: ids.map {
                ($0, [binding(1, worktreeID: $0)])
            })
            state.prBindingsFetcher = { throw PRBindingRefreshTestError.boom }

            await state.refreshPRBindings()

            #expect(state.prBindings.count == 5)
        }
    }

    @MainActor
    @Test("a worktree absent from a successful response loses its entry")
    func absentWorktreeIsDropped() async {
        await withStateAsync { state in
            let detached = UUID()
            let kept = UUID()
            state.prBindings = [detached: [binding(412, worktreeID: detached)],
                                kept: [binding(413, worktreeID: kept)]]
            state.prDetachedCounts = [:]
            // The user detached the only PR on `detached`: the daemon reports it
            // with an empty live list and one tombstone, and `kept` unchanged.
            state.prBindingsFetcher = {
                PRBindingsAllResult(worktrees: [
                    entry(detached, [], detachedCount: 1),
                    entry(kept, [binding(413, worktreeID: kept)])
                ])
            }

            await state.refreshPRBindings()

            #expect(state.prBindings[detached] == nil)
            #expect(state.prDetachedCounts[detached] == 1)
            #expect(state.prBindings[kept]?.map(\.number) == [413])
        }
    }

    /// A worktree that vanishes from the response entirely — archived, or its
    /// last binding hard-deleted by the branch heal — must not linger.
    @MainActor
    @Test("a worktree missing from the response entirely is dropped")
    func missingWorktreeIsDropped() async {
        await withStateAsync { state in
            let gone = UUID()
            state.prBindings = [gone: [binding(412, worktreeID: gone)]]
            state.prDetachedCounts = [gone: 1]
            state.prBindingsFetcher = { PRBindingsAllResult(worktrees: []) }

            await state.refreshPRBindings()

            #expect(state.prBindings.isEmpty)
            #expect(state.prDetachedCounts.isEmpty)
        }
    }

    /// The seam `detachPR` judges its outcome through. The published maps are
    /// whole-fleet, so a refresh already in flight can land afterwards and
    /// publish its older snapshot over the top — returning what THIS call
    /// fetched is what makes an outcome check immune to that.
    @MainActor
    @Test("refreshPRBindings returns the state it fetched, and nil when it failed")
    func refreshReportsWhatItFetched() async {
        await withStateAsync { state in
            let wt = UUID()
            state.prBindingsFetcher = {
                PRBindingsAllResult(worktrees: [entry(wt, [binding(412, worktreeID: wt)])])
            }
            let fetched = await state.refreshPRBindings()
            #expect(fetched?.bindings[wt]?.map(\.number) == [412])

            state.prBindingsFetcher = { throw PRBindingRefreshTestError.boom }
            #expect(await state.refreshPRBindings() == nil)
            // …and the published map is untouched by the failure.
            #expect(state.prBindings[wt]?.map(\.number) == [412])
        }
    }

    /// The stale-poll race the sequence guard exists for, driven for real:
    /// two overlapping refreshes that resolve OUT OF ORDER.
    ///
    /// A background poll (A) is already in flight, holding a snapshot that
    /// still shows #412, when the user untracks it. The untrack's own refresh
    /// (B) starts later, resolves first, and correctly publishes the chip as
    /// gone. Then A finally lands. Without the guard A republishes its older
    /// whole-fleet snapshot over the top and the chip the user just dismissed
    /// comes back on screen.
    ///
    /// Every other poll test here awaits one refresh before starting the next,
    /// so this is the only case that reaches the `seq == prBindingsRefreshSeq`
    /// branch at all.
    @MainActor
    @Test("a stale refresh landing last does not resurrect an untracked chip")
    func staleRefreshDoesNotResurrectAnUntrackedChip() async {
        await withStateAsync { state in
            let wt = UUID()
            // The chip is on screen when the poll goes out.
            state.prBindings = [wt: [binding(412, worktreeID: wt)]]

            let gate = RefreshGate()
            state.prBindingsFetcher = {
                gate.calls += 1
                if gate.calls == 1 {
                    // A: issued before the untrack, so it still sees #412 —
                    // and it is held open until B has published.
                    while !gate.open { try? await Task.sleep(for: .milliseconds(1)) }
                    return PRBindingsAllResult(
                        worktrees: [entry(wt, [binding(412, worktreeID: wt)])])
                }
                // B: issued after the untrack landed, so #412 is tombstoned.
                return PRBindingsAllResult(worktrees: [entry(wt, [], detachedCount: 1)])
            }

            // A starts first and must stamp its sequence number and enter its
            // fetch before B starts — otherwise B's own await hands the actor
            // back to A and the stamps invert.
            let taskA = Task { await state.refreshPRBindings() }
            let entered = await waitUntil { gate.calls == 1 }
            #expect(entered)

            // B supersedes A: it resolves immediately and publishes the detach.
            await state.refreshPRBindings()
            #expect(state.prBindings[wt] == nil)
            #expect(state.prDetachedCounts[wt] == 1)

            // Now let A's stale snapshot resolve. It still REPORTS what it
            // fetched to its own caller — that is the return contract — but it
            // must not put #412 back on screen.
            gate.open = true
            let late = await taskA.value
            #expect(late?.bindings[wt]?.map(\.number) == [412])
            #expect(state.prBindings[wt] == nil)
            #expect(state.prDetachedCounts[wt] == 1)
        }
    }

    /// The other interleaving of the same two calls, and the reason the guard
    /// counts PUBLISHES rather than starts.
    ///
    /// A poll (A) is in flight when a second refresh (B) starts and fails
    /// outright — an RPC hiccup, which publishes nothing and leaves the maps
    /// holding their pre-call values. A then resolves with perfectly good data.
    /// Nothing newer has reached the screen, so A must publish: a guard that
    /// asked only whether a later call had STARTED would withhold A's fleet on
    /// account of a call that never put anything anywhere, and every toolbar
    /// would sit on stale bindings until the next poll.
    @MainActor
    @Test("a later refresh that failed cannot suppress an earlier one that succeeded")
    func failedLaterRefreshDoesNotSuppressAnEarlierSuccess() async {
        await withStateAsync { state in
            let wt = UUID()
            let gate = RefreshGate()
            state.prBindingsFetcher = {
                gate.calls += 1
                if gate.calls == 1 {
                    // A: held open until B has failed.
                    while !gate.open { try? await Task.sleep(for: .milliseconds(1)) }
                    return PRBindingsAllResult(
                        worktrees: [entry(wt, [binding(412, worktreeID: wt)], detachedCount: 1)])
                }
                // B: starts later, publishes nothing at all.
                throw PRBindingRefreshTestError.boom
            }

            let taskA = Task { await state.refreshPRBindings() }
            let entered = await waitUntil { gate.calls == 1 }
            #expect(entered)

            // B takes the later ticket and then fails.
            #expect(await state.refreshPRBindings() == nil)
            #expect(state.prBindings.isEmpty)

            // A resolves last, and its data is still the newest anyone has —
            // so it reaches the screen, not just its own caller.
            gate.open = true
            let late = await taskA.value
            #expect(late?.bindings[wt]?.map(\.number) == [412])
            #expect(state.prBindings[wt]?.map(\.number) == [412])
            #expect(state.prDetachedCounts[wt] == 1)
        }
    }

    // MARK: - The untrack gesture

    /// `detachPR` judges its outcome by re-reading the bindings rather than by
    /// trusting `detached`, because false covers both "already tombstoned" and
    /// "the daemon declined". Each of the three ways out gets a case.

    @MainActor
    @Test("a detach whose chip is gone afterwards says nothing")
    func detachThatLandedIsSilent() async {
        await withStateAsync { state in
            let wt = UUID()
            state.prBindings = [wt: [binding(412, worktreeID: wt)]]
            state.prDetacher = { _, _, _ in PRDetachResult(detached: true) }
            state.prBindingsFetcher = {
                PRBindingsAllResult(worktrees: [entry(wt, [], detachedCount: 1)])
            }

            await state.detachPR(worktreeID: wt, url: nil, number: 412)

            #expect(state.prBindings[wt] == nil)
            #expect(state.activeToast == nil)
        }
    }

    /// `detached: false` is not itself a failure — a second click on the same
    /// xmark reports it — so what matters is whether the chip survived.
    @MainActor
    @Test("a detach whose chip survives is reported, even when the RPC did not throw")
    func detachThatDeclinedIsReported() async {
        await withStateAsync { state in
            let wt = UUID()
            state.prBindings = [wt: [binding(412, worktreeID: wt)]]
            // The daemon declined: nothing was written, so the refresh returns
            // the binding unchanged.
            state.prDetacher = { _, _, _ in PRDetachResult(detached: false) }
            state.prBindingsFetcher = {
                PRBindingsAllResult(worktrees: [entry(wt, [binding(412, worktreeID: wt)])])
            }

            await state.detachPR(worktreeID: wt, url: nil, number: 412)

            #expect(state.prBindings[wt]?.map(\.number) == [412])
            #expect(state.activeToast?.style == .error)
            #expect(state.activeToast?.message == "PR #412 is still tracked here")
        }
    }

    /// The trap the outcome check has to avoid: a refresh that never landed
    /// leaves the maps holding their pre-call values, which read exactly like a
    /// detach that did nothing. Reporting a landed detach as a failure is its
    /// own kind of lie.
    @MainActor
    @Test("a detach followed by a failed refresh is not reported as a failure")
    func detachWithAFailedRefreshIsSilent() async {
        await withStateAsync { state in
            let wt = UUID()
            state.prBindings = [wt: [binding(412, worktreeID: wt)]]
            state.prDetacher = { _, _, _ in PRDetachResult(detached: true) }
            state.prBindingsFetcher = { throw PRBindingRefreshTestError.boom }

            await state.detachPR(worktreeID: wt, url: nil, number: 412)

            // The stale map still shows the chip, and that is precisely why it
            // is not evidence.
            #expect(state.prBindings[wt]?.map(\.number) == [412])
            #expect(state.activeToast == nil)
        }
    }

    @MainActor
    @Test("a thrown detach toasts and never reaches the outcome check")
    func detachThatThrewIsReported() async {
        await withStateAsync { state in
            let wt = UUID()
            state.prBindings = [wt: [binding(412, worktreeID: wt)]]
            state.prDetacher = { _, _, _ in throw PRBindingRefreshTestError.boom }
            state.prBindingsFetcher = {
                Issue.record("a failed detach must not refresh")
                return PRBindingsAllResult(worktrees: [])
            }

            await state.detachPR(worktreeID: wt, url: nil, number: 412)

            #expect(state.activeToast?.style == .error)
            #expect(state.activeToast?.message == "Could not stop tracking PR #412")
        }
    }
}

private enum PRBindingRefreshTestError: Error { case boom }

/// Call counter + release latch for the overlapping-refresh test, so the two
/// fetches resolve out of order by construction rather than by racing sleeps.
@MainActor
private final class RefreshGate {
    var calls = 0
    var open = false
}

/// Poll `cond` on the main actor until true or the deadline. Returns success.
@MainActor
private func waitUntil(
    deadline: Duration = .seconds(15), _ cond: @MainActor () -> Bool
) async -> Bool {
    let clock = ContinuousClock()
    let start = clock.now
    while !cond() {
        if clock.now - start > deadline { return false }
        try? await Task.sleep(for: .milliseconds(2))
    }
    return true
}

private func binding(_ number: Int, worktreeID: UUID) -> PRBinding {
    let url = "https://github.com/acme/acme-prod/pull/\(number)"
    return PRBinding(
        worktreeID: worktreeID, owner: "acme", repo: "acme-prod",
        number: number, url: url,
        status: PRStatus(number: number, url: url, state: .mergeable),
        source: .hook)
}

private func entry(_ worktreeID: UUID, _ bindings: [PRBinding],
                   detachedCount: Int? = 0) -> PRBindingsAllEntry {
    PRBindingsAllEntry(worktreeID: worktreeID, bindings: bindings,
                       detachedCount: detachedCount)
}
