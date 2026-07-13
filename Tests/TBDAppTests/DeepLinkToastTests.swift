import Foundation
import Testing
@testable import TBDApp
import TBDShared

/// Tests for the deep-link toast state machine (Toast model + AppState+Toast).
///
/// Every test constructs `AppState(userDefaults:)` against a throwaway suite —
/// `UserDefaults.standard` on this unbundled executable is the developer's
/// real `TBDApp.plist`. Countdown ticks are shrunk to 5ms via
/// `toastTickDuration` so no test sleeps for real seconds.
@MainActor
@Suite("Deep-link toast")
struct DeepLinkToastTests {

    private func withState(_ body: (AppState) async -> Void) async {
        let suiteName = "TBDAppTests.DeepLinkToast.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let state = AppState(userDefaults: defaults)
        state.toastTickDuration = .milliseconds(5)
        await body(state)
    }

    private func makeArchived(id: UUID, repoID: UUID?) -> Worktree {
        Worktree(
            id: id,
            repoID: repoID,
            name: "wt-\(id.uuidString.prefix(8))",
            displayName: "Fix Login",
            branch: "fix-login",
            path: "/tmp/test",
            status: .archived,
            tmuxServer: "test-server"
        )
    }

    /// Poll `cond` on the main actor until true or deadline. Returns success.
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

    // MARK: - showToast / dismissToast basics

    @Test func showToast_publishesToast() async {
        await withState { state in
            state.showToast(Toast(id: UUID(), message: "Looking for worktree…", style: .progress))
            #expect(state.activeToast?.message == "Looking for worktree…")
            #expect(state.activeToast?.style == .progress)
        }
    }

    @Test func dismissToast_clearsToastAndCTA() async {
        await withState { state in
            state.showToast(Toast(id: UUID(), message: "m", style: .progress))
            state.toastCTAAction = {}
            state.dismissToast()
            #expect(state.activeToast == nil)
            #expect(state.toastCTAAction == nil)
        }
    }

    // MARK: - Countdown

    @Test func startToastCountdown_beginsAtFullSeconds() async {
        await withState { state in
            state.showToast(Toast(id: UUID(), message: "m", style: .progress))
            state.startToastCountdown(onExpiry: {})
            #expect(state.activeToast?.style == .countdown(secondsRemaining: 5))
        }
    }

    @Test func countdownExpiry_firesOnExpiryOnceAndDismisses() async {
        await withState { state in
            var fired = 0
            state.showToast(Toast(id: UUID(), message: "m", style: .progress))
            state.startToastCountdown(onExpiry: { fired += 1 })
            let expired = await waitUntil { state.activeToast == nil }
            #expect(expired)
            // Drain a few more ticks to prove it fires exactly once.
            try? await Task.sleep(for: .milliseconds(50))
            #expect(fired == 1)
        }
    }

    @Test func hoverDuringCountdown_cancelsPermanentlyAndShowsCTA() async {
        await withState { state in
            var fired = false
            state.showToast(Toast(id: UUID(), message: "m", style: .progress))
            state.startToastCountdown(onExpiry: { fired = true })
            state.toastHoverChanged(true)
            #expect(state.activeToast?.style == .action(ctaLabel: "Go to archive entry"))
            // Mouse leaves — countdown must NOT resume.
            state.toastHoverChanged(false)
            try? await Task.sleep(for: .milliseconds(60))  // > 10 ticks
            #expect(fired == false)
            #expect(state.activeToast != nil)
            // Proves the state machine settled (not just starved by scheduler load).
            #expect(state.activeToast?.style == .action(ctaLabel: "Go to archive entry"))
        }
    }

    @Test func hoverOutsideCountdownState_isIgnored() async {
        await withState { state in
            state.showToast(Toast(id: UUID(), message: "m", style: .progress))
            state.toastHoverChanged(true)
            #expect(state.activeToast?.style == .progress)
        }
    }

    @Test func newToast_replacesOldAndCancelsItsCountdown() async {
        await withState { state in
            var fired = false
            state.showToast(Toast(id: UUID(), message: "old", style: .progress))
            state.startToastCountdown(onExpiry: { fired = true })
            state.showToast(Toast(id: UUID(), message: "new", style: .progress))
            try? await Task.sleep(for: .milliseconds(60))
            #expect(fired == false)
            #expect(state.activeToast?.message == "new")
        }
    }

    // MARK: - Error toast

    @Test func errorToast_autoDismisses() async {
        await withState { state in
            state.showErrorToast("Worktree not found — it may have been deleted.")
            #expect(state.activeToast?.style == .error)
            let dismissed = await waitUntil { state.activeToast == nil }
            #expect(dismissed)
        }
    }

    // MARK: - Deep-link archived flow

    @Test func archivedHit_showsCountdownToastWithDisplayName() async {
        await withState { state in
            let repoID = UUID()
            let id = UUID()
            state.archivedLookupOverride = { [wt = makeArchived(id: id, repoID: repoID)] _ in [wt] }

            await state.navigateToArchivedWorktree(id)

            #expect(state.activeToast?.style == .countdown(secondsRemaining: 5))
            #expect(state.activeToast?.message.contains("Fix Login") == true)
            #expect(state.activeToast?.message.contains("archived") == true)
            // Navigation deferred: nothing selected yet.
            #expect(state.selectedRepoID == nil)
            #expect(state.highlightedArchivedWorktreeID == nil)
        }
    }

    @Test func archivedCountdownExpiry_navigatesToArchiveEntry() async {
        await withState { state in
            let repoID = UUID()
            let id = UUID()
            state.archivedLookupOverride = { [wt = makeArchived(id: id, repoID: repoID)] _ in [wt] }

            await state.navigateToArchivedWorktree(id)

            let navigated = await waitUntil {
                state.highlightedArchivedWorktreeID == id && state.activeToast == nil
            }
            #expect(navigated)
            #expect(state.selectedRepoID == repoID)
            #expect(state.selectedWorktreeIDs.isEmpty)
            #expect(state.archivedWorktrees[repoID]?.map(\.id) == [id])
        }
    }

    @Test func archivedHoverThenCTA_navigatesImmediately() async {
        await withState { state in
            let repoID = UUID()
            let id = UUID()
            state.archivedLookupOverride = { [wt = makeArchived(id: id, repoID: repoID)] _ in [wt] }

            await state.navigateToArchivedWorktree(id)
            state.toastHoverChanged(true)
            #expect(state.activeToast?.style == .action(ctaLabel: "Go to archive entry"))

            state.toastCTAAction?()

            #expect(state.selectedRepoID == repoID)
            #expect(state.highlightedArchivedWorktreeID == id)
            #expect(state.activeToast == nil)
        }
    }

    @Test func archivedHoverThenDismiss_neverNavigates() async {
        await withState { state in
            let repoID = UUID()
            let id = UUID()
            state.archivedLookupOverride = { [wt = makeArchived(id: id, repoID: repoID)] _ in [wt] }

            await state.navigateToArchivedWorktree(id)
            state.toastHoverChanged(true)
            state.dismissToast()
            try? await Task.sleep(for: .milliseconds(60))

            #expect(state.selectedRepoID == nil)
            #expect(state.highlightedArchivedWorktreeID == nil)
            #expect(state.activeToast == nil)
        }
    }

    @Test func unknownWorktree_showsErrorToast() async {
        await withState { state in
            state.archivedLookupOverride = { _ in [] }

            await state.navigateToArchivedWorktree(UUID())

            #expect(state.activeToast?.style == .error)
            #expect(state.activeToast?.message == "Worktree not found — it may have been deleted.")
            let dismissed = await waitUntil { state.activeToast == nil }
            #expect(dismissed)
        }
    }

    @Test func scratchWorktree_dismissesToastWithoutNavigation() async {
        await withState { state in
            let id = UUID()
            state.archivedLookupOverride = { [wt = makeArchived(id: id, repoID: nil)] _ in [wt] }

            await state.navigateToArchivedWorktree(id)

            #expect(state.activeToast == nil)
            #expect(state.selectedRepoID == nil)
        }
    }

    @Test func navigateToWorktreeMiss_showsLookingToast() async {
        await withState { state in
            state.isInitialStateLoaded = true
            // Slow lookup so the progress state is observable.
            state.archivedLookupOverride = { _ in
                try? await Task.sleep(for: .milliseconds(100))
                return []
            }

            state.navigateToWorktree(UUID())

            let looking = await waitUntil { state.activeToast?.style == .progress }
            #expect(looking)
            #expect(state.activeToast?.message == "Looking for worktree…")
        }
    }

    @Test func activeWorktreeHit_showsNoToast() async {
        await withState { state in
            state.isInitialStateLoaded = true
            let repoID = UUID()
            let id = UUID()
            var wt = makeArchived(id: id, repoID: repoID)
            wt.status = .active
            state.worktrees = [repoID: [wt]]

            state.navigateToWorktree(id)

            #expect(state.activeToast == nil)
            #expect(state.selectedWorktreeIDs == [id])
        }
    }

    // MARK: - Request-generation guard (F1/F5)

    /// F5 (spec line ~68): a second deep link mid-countdown restarts the state
    /// machine for the new UUID. The toast retargets to B, and only B's repo is
    /// ever navigated to — A's countdown is cancelled by the replacing toast.
    @Test func secondDeepLinkMidCountdown_restartsForNewUUID() async {
        await withState { state in
            let repoA = UUID(), idA = UUID()
            let repoB = UUID(), idB = UUID()
            let a = makeArchived(id: idA, repoID: repoA)  // displayName "Fix Login"
            var b = makeArchived(id: idB, repoID: repoB)
            b.displayName = "Refactor DB"
            state.archivedLookupOverride = { reqID in
                if reqID == idA { return [a] }
                if reqID == idB { return [b] }
                return []
            }

            await state.navigateToArchivedWorktree(idA)
            #expect(state.activeToast?.message.contains("Fix Login") == true)

            await state.navigateToArchivedWorktree(idB)
            // Toast now names B, countdown restarted.
            #expect(state.activeToast?.message.contains("Refactor DB") == true)
            #expect(state.activeToast?.style == .countdown(secondsRemaining: 5))

            let navigated = await waitUntil {
                state.highlightedArchivedWorktreeID == idB && state.activeToast == nil
            }
            #expect(navigated)
            #expect(state.selectedRepoID == repoB)
            // A must never have been navigated to.
            #expect(state.selectedRepoID != repoA)
        }
    }

    /// F1: two overlapping lookups (A slow, B fast) that resolve out of order.
    /// A's late resolution must be dropped by the request-generation guard so
    /// it can't clobber B's toast/navigation.
    @Test func staleLookupResolution_doesNotClobberNewerRequest() async {
        await withState { state in
            let repoA = UUID(), idA = UUID()
            let repoB = UUID(), idB = UUID()
            let a = makeArchived(id: idA, repoID: repoA)  // displayName "Fix Login"
            var b = makeArchived(id: idB, repoID: repoB)
            b.displayName = "Refactor DB"
            state.archivedLookupOverride = { reqID in
                if reqID == idA {
                    try? await Task.sleep(for: .milliseconds(100))
                    return [a]
                }
                if reqID == idB { return [b] }
                return []
            }

            // A's lookup starts first (production spawns each deep link in its
            // own Task, so requests stamp their generation token in arrival
            // order). Let A stamp its token and enter its slow lookup before B
            // starts — otherwise B's own await would yield the actor back to A,
            // inverting the stamp order this guard depends on.
            let taskA = Task { await state.navigateToArchivedWorktree(idA) }
            try? await Task.sleep(for: .milliseconds(10))
            // B supersedes A (newest request); its lookup resolves immediately.
            await state.navigateToArchivedWorktree(idB)
            #expect(state.activeToast?.message.contains("Refactor DB") == true)

            // Let A's slow lookup resolve — the guard must drop it.
            _ = await taskA.value

            let navigated = await waitUntil {
                state.highlightedArchivedWorktreeID == idB && state.activeToast == nil
            }
            #expect(navigated)
            #expect(state.selectedRepoID == repoB)
            // A's late resolution never navigated to A or showed A's toast.
            #expect(state.highlightedArchivedWorktreeID != idA)
        }
    }

    // MARK: - RPC-failure branch (F4)

    /// F4: a thrown lookup error exercises the same error-toast branch as a real
    /// RPC failure. Previously the seam was non-throwing and this was untestable.
    @Test func lookupThrows_showsErrorToast() async {
        await withState { state in
            struct LookupError: Error {}
            state.archivedLookupOverride = { _ in throw LookupError() }

            await state.navigateToArchivedWorktree(UUID())

            #expect(state.activeToast?.style == .error)
            #expect(state.activeToast?.message.hasPrefix("Couldn't look up the worktree") == true)
            let dismissed = await waitUntil { state.activeToast == nil }
            #expect(dismissed)
        }
    }
}
