import Foundation
import Testing
import TestSupport
@testable import TBDApp
import TBDShared

/// Tests for the deep-link toast state machine (Toast model + AppState+Toast).
///
/// Every test constructs `AppState(userDefaults:)` against a throwaway suite —
/// `UserDefaults.standard` on this unbundled executable is the developer's
/// real `TBDApp.plist`. Auto-dismiss ticks are shrunk to 5ms via
/// `toastTickDuration` so no test sleeps for real seconds.
@MainActor
@Suite("Deep-link toast")
struct DeepLinkToastTests {

    private func withState(_ body: (AppState) async -> Void) async {
        let suite = TestDefaultsSuite("TBDAppTests.DeepLinkToast")
        let defaults = suite.defaults
        defer { suite.tearDown() }
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

    // MARK: - showToast / dismissToast basics

    @Test func showToast_publishesToast() async {
        await withState { state in
            state.showToast(Toast(id: UUID(), message: "Looking for worktree…", style: .progress))
            #expect(state.activeToast?.message == "Looking for worktree…")
            #expect(state.activeToast?.style == .progress)
        }
    }

    @Test func dismissToast_clearsToast() async {
        await withState { state in
            state.showToast(Toast(id: UUID(), message: "m", style: .progress))
            state.dismissToast()
            #expect(state.activeToast == nil)
        }
    }

    @Test func newToast_replacesOldAndCancelsItsDismissTask() async {
        await withState { state in
            // The old transient toast schedules an auto-dismiss ~4 ticks out.
            state.showTransientToast("old", style: .notice)
            // Replacing it must cancel that task so it can't clear the new one.
            state.showToast(Toast(id: UUID(), message: "new", style: .progress))
            try? await Task.sleep(for: .milliseconds(60))  // > old's ~4-tick deadline
            #expect(state.activeToast?.message == "new")
        }
    }

    // MARK: - Transient (notice / error) toast auto-dismiss

    @Test func errorToast_autoDismisses() async {
        await withState { state in
            state.showErrorToast("Worktree not found — it may have been deleted.")
            #expect(state.activeToast?.style == .error)
            #expect(state.toastDismissTask != nil)
            await state.toastDismissTask?.value
            #expect(state.activeToast == nil)
        }
    }

    @Test func noticeToast_autoDismisses() async {
        await withState { state in
            state.showTransientToast("heads up", style: .notice)
            #expect(state.activeToast?.style == .notice)
            #expect(state.toastDismissTask != nil)
            await state.toastDismissTask?.value
            #expect(state.activeToast == nil)
        }
    }

    // MARK: - Deep-link archived flow

    @Test func archivedHit_navigatesImmediatelyWithNoticeToast() async {
        await withState { state in
            let repoID = UUID()
            let id = UUID()
            state.archivedLookupOverride = { [wt = makeArchived(id: id, repoID: repoID)] _ in [wt] }

            await state.navigateToArchivedWorktree(id)

            // Navigation is immediate — no countdown, no deferral.
            #expect(state.selectedRepoID == repoID)
            #expect(state.highlightedArchivedWorktreeID == id)
            #expect(state.selectedWorktreeIDs.isEmpty)
            #expect(state.archivedWorktrees[repoID]?.map(\.id) == [id])
            // And a brief notice explains the archive landing.
            #expect(state.activeToast?.style == .notice)
            #expect(state.activeToast?.message.contains("Fix Login") == true)
            #expect(state.activeToast?.message.contains("archived") == true)
            // The notice auto-dismisses.
            #expect(state.toastDismissTask != nil)
            await state.toastDismissTask?.value
            #expect(state.activeToast == nil)
        }
    }

    @Test func unknownWorktree_showsErrorToast() async {
        await withState { state in
            state.archivedLookupOverride = { _ in [] }

            await state.navigateToArchivedWorktree(UUID())

            #expect(state.activeToast?.style == .error)
            #expect(state.activeToast?.message == "Worktree not found — it may have been deleted.")
            #expect(state.toastDismissTask != nil)
            await state.toastDismissTask?.value
            #expect(state.activeToast == nil)
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

            // A hang guard on a main-queue delivery, so the saturated-pass
            // budget (`Tests/CLAUDE.md`, "Population is the scheduler").
            let looking = await pollUntilTrue(timeout: TestDeadlines.saturatedPass) { @Sendable in
                await MainActor.run { state.activeToast?.style == .progress }
            }
            #expect(looking != .timedOut, "the lookup's progress toast never showed")
            guard looking == .satisfied else { return }
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

    /// F5: a second deep link supersedes the first. With auto-navigation each
    /// link navigates immediately, so B's navigation simply wins — only B's
    /// repo is ever selected.
    @Test func secondDeepLink_navigatesToNewUUID() async {
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
            #expect(state.selectedRepoID == repoA)

            await state.navigateToArchivedWorktree(idB)
            // B navigated last; its repo is selected and its notice shown.
            #expect(state.selectedRepoID == repoB)
            #expect(state.highlightedArchivedWorktreeID == idB)
            #expect(state.activeToast?.message.contains("Refactor DB") == true)
            #expect(state.activeToast?.style == .notice)
        }
    }

    /// F1: two overlapping lookups (A slow, B fast) that resolve out of order.
    /// A's late resolution must be dropped by the request-generation guard so
    /// it can't clobber B's navigation — no navigation to A, no A toast.
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
            // B supersedes A (newest request); its lookup resolves immediately
            // and navigates right away.
            await state.navigateToArchivedWorktree(idB)
            #expect(state.selectedRepoID == repoB)
            #expect(state.highlightedArchivedWorktreeID == idB)
            #expect(state.activeToast?.message.contains("Refactor DB") == true)

            // Let A's slow lookup resolve — the guard must drop it.
            _ = await taskA.value

            // A's late resolution never navigated to A nor showed A's toast.
            #expect(state.selectedRepoID == repoB)
            #expect(state.highlightedArchivedWorktreeID == idB)
            #expect(state.activeToast?.message.contains("Fix Login") != true)
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
            #expect(state.toastDismissTask != nil)
            await state.toastDismissTask?.value
            #expect(state.activeToast == nil)
        }
    }

    // MARK: - A newer navigation supersedes an archived lookup in flight

    private func remoteSession(_ sessionID: String) -> RemoteSessionInfo {
        RemoteSessionInfo(
            provider: "acme", payload: RemoteSessionPayload(id: sessionID, state: .running),
            gone: false, dismissed: false, lastSeen: Date())
    }

    /// Follows a deep link to an archived worktree whose lookup `gate` holds
    /// open, and returns once that lookup is in flight with its progress
    /// toast up. Returns the archived worktree's repo.
    private func startHeldArchivedLookup(_ state: AppState, gate: LookupGate) async -> UUID {
        state.isInitialStateLoaded = true
        state.reposLoaded = true
        state.worktreesLoaded = true
        let repoID = UUID()
        let id = UUID()
        state.archivedLookupOverride = { [wt = makeArchived(id: id, repoID: repoID)] _ in
            await gate.hold()
            return [wt]
        }
        state.navigateToWorktree(id)
        let inFlight = await pollUntilTrue(timeout: TestDeadlines.saturatedPass) { @Sendable in
            await MainActor.run { gate.isHolding }
        }
        #expect(inFlight != .timedOut, "the archived lookup never reached its gate")
        #expect(state.activeToast?.style == .progress)
        return repoID
    }

    /// Control: with nothing newer, the held lookup still lands on the
    /// archive view once it resolves.
    @Test func heldArchivedLookup_navigatesWhenNothingSupersedesIt() async {
        await withState { state in
            let gate = LookupGate()
            let repoID = await startHeldArchivedLookup(state, gate: gate)

            gate.release()
            await state.archivedLookupTask?.value

            #expect(state.selectedRepoID == repoID)
            #expect(state.highlightedArchivedWorktreeID != nil)
            #expect(state.activeToast?.style != .progress)
        }
    }

    @Test func archivedLookupInFlight_doesNotOverrideALaterRemoteBannerClick() async {
        await withState { state in
            let gate = LookupGate()
            let repoID = await startHeldArchivedLookup(state, gate: gate)
            state.remoteMirrorLoaded = true
            state.remoteSessions = [remoteSession("s1")]
            let expected = RemoteSessionSelection(provider: "acme", sessionID: "s1")

            state.macNotificationManager.handleClick(identifier: "remote:acme:s1")
            #expect(state.selectedRemoteSession == expected)
            // The click took over, so the lookup's progress toast is gone.
            #expect(state.activeToast == nil)

            gate.release()
            await state.archivedLookupTask?.value

            #expect(state.selectedRemoteSession == expected)
            #expect(state.selectedRepoID == nil)
            #expect(state.highlightedArchivedWorktreeID == nil)
            #expect(state.archivedWorktrees[repoID] == nil)
            #expect(state.activeToast == nil)
        }
    }

    @Test func archivedLookupInFlight_doesNotReplaceALaterRemoteClicksNotFoundAnswer() async {
        await withState { state in
            let gate = LookupGate()
            let repoID = await startHeldArchivedLookup(state, gate: gate)
            state.remoteMirrorLoaded = true

            state.macNotificationManager.handleClick(identifier: "remote:acme:missing")
            #expect(state.activeToast?.message == "Remote session not found — it may have ended.")

            gate.release()
            await state.archivedLookupTask?.value

            #expect(state.selectedRepoID == nil)
            #expect(state.highlightedArchivedWorktreeID == nil)
            #expect(state.archivedWorktrees[repoID] == nil)
            #expect(state.activeToast?.style != .notice)
        }
    }

    @Test func archivedLookupInFlight_doesNotOverrideALaterActiveWorktreeLink() async {
        await withState { state in
            let gate = LookupGate()
            let archivedRepoID = await startHeldArchivedLookup(state, gate: gate)
            let activeRepoID = UUID()
            let activeID = UUID()
            var active = makeArchived(id: activeID, repoID: activeRepoID)
            active.status = .active
            state.worktrees = [activeRepoID: [active]]

            state.navigateToWorktree(activeID)
            #expect(state.selectedWorktreeIDs == [activeID])
            #expect(state.activeToast == nil)

            gate.release()
            await state.archivedLookupTask?.value

            #expect(state.selectedWorktreeIDs == [activeID])
            #expect(state.selectedRepoID == nil)
            #expect(state.highlightedArchivedWorktreeID == nil)
            #expect(state.archivedWorktrees[archivedRepoID] == nil)
            #expect(state.activeToast == nil)
        }
    }

    /// A row the user selects in the sidebar is a later navigation than the
    /// link, so it supersedes the lookup: the lookup's progress toast goes at
    /// once, and its late answer is dropped. The row is selected through the
    /// outline's own selection handler, as a click selects it.
    @Test func archivedLookupInFlight_isSupersededByALaterSidebarSelection() async throws {
        let h = OutlineHarness("DeepLinkToast.sidebarSelection")
        defer { h.tearDown() }
        let state = h.state
        state.toastTickDuration = .milliseconds(5)
        let repo = Repo(path: "/tmp/acme", displayName: "acme")
        let active = SidebarGroupFixtures.row("active", repoID: repo.id)
        state.repos = [repo]
        state.worktrees = [repo.id: [active]]
        h.mount()
        let gate = LookupGate()
        let archivedRepoID = await startHeldArchivedLookup(state, gate: gate)
        let activeRow = h.row(.worktree(active.id))
        try #require(activeRow >= 0)

        h.outline.selectRowIndexes(IndexSet(integer: activeRow), byExtendingSelection: false)
        #expect(state.selectedWorktreeIDs == [active.id])
        #expect(state.activeToast == nil)

        gate.release()
        await state.archivedLookupTask?.value

        #expect(state.selectedWorktreeIDs == [active.id])
        #expect(state.selectedRepoID == nil)
        #expect(state.highlightedArchivedWorktreeID == nil)
        #expect(state.archivedWorktrees[archivedRepoID] == nil)
        #expect(state.activeToast == nil)
    }

    /// A create that finishes while the lookup is in flight swaps its
    /// placeholder for the real row and selects it. The app made that change,
    /// not the user, so it supersedes nothing: the lookup still lands. The
    /// create starts before the link is followed, so only its swap falls
    /// inside the lookup.
    @Test func archivedLookupInFlight_landsAfterACreatesPlaceholderSwap() async {
        await withState { state in
            let createRepoID = UUID()
            var draft = makeArchived(id: UUID(), repoID: createRepoID)
            draft.status = .active
            let created = draft
            let createGate = LookupGate()
            state.worktreeCreator = { @MainActor _ in
                await createGate.hold()
                return created
            }
            state.createWorktree(repoID: createRepoID)
            let creating = await pollUntilTrue(timeout: TestDeadlines.saturatedPass) { @Sendable in
                await MainActor.run { createGate.isHolding }
            }
            #expect(creating != .timedOut, "the create never reached its gate")

            let lookupGate = LookupGate()
            let archivedRepoID = await startHeldArchivedLookup(state, gate: lookupGate)

            createGate.release()
            let swapped = await pollUntilTrue(timeout: TestDeadlines.saturatedPass) { @Sendable [createdID = created.id] in
                await MainActor.run { state.selectedWorktreeIDs == [createdID] }
            }
            #expect(swapped != .timedOut, "the create never swapped its placeholder")
            // The swap left the lookup's progress toast up.
            #expect(state.activeToast?.style == .progress)

            lookupGate.release()
            await state.archivedLookupTask?.value

            #expect(state.selectedRepoID == archivedRepoID)
            #expect(state.highlightedArchivedWorktreeID != nil)
            #expect(state.activeToast?.style != .progress)
        }
    }

    @Test func archivedLookupInFlight_isSupersededByALaterRemoteSessionSelection() async {
        await withState { state in
            let gate = LookupGate()
            let repoID = await startHeldArchivedLookup(state, gate: gate)
            let expected = RemoteSessionSelection(provider: "acme", sessionID: "s1")

            state.selectRemoteSession(provider: "acme", sessionID: "s1")
            #expect(state.activeToast == nil)

            gate.release()
            await state.archivedLookupTask?.value

            #expect(state.selectedRemoteSession == expected)
            #expect(state.selectedRepoID == nil)
            #expect(state.highlightedArchivedWorktreeID == nil)
            #expect(state.archivedWorktrees[repoID] == nil)
            #expect(state.activeToast == nil)
        }
    }

    /// A click held for the remote mirror has not navigated, so the lookup
    /// keeps its navigation. The lookup lands a link followed before the
    /// click, so the click, the later action, stays held through it and is
    /// replayed once the remote list loads.
    @Test func archivedLookupInFlight_isNotSupersededByAClickThatIsOnlyHeld() async {
        await withState { state in
            let gate = LookupGate()
            let repoID = await startHeldArchivedLookup(state, gate: gate)
            let held = RemoteSessionSelection(provider: "acme", sessionID: "s1")

            // `remoteMirrorLoaded` is false: the click is held, not answered.
            state.macNotificationManager.handleClick(identifier: "remote:acme:s1")
            #expect(state.pendingRemoteSessionLink == held)
            #expect(state.activeToast?.style == .progress)

            gate.release()
            await state.archivedLookupTask?.value

            #expect(state.selectedRepoID == repoID)
            #expect(state.pendingRemoteSessionLink == held)

            state.remoteProvidersFetcher = { RemoteProvidersResult(providers: []) }
            state.remoteSessionsFetcher = { [session = remoteSession("s1")] in
                RemoteSessionsResult(sessions: [session])
            }
            state.retainedTranscriptsFetcher = { [] }
            await state.refreshRemote()

            #expect(state.selectedRemoteSession == held)
            #expect(state.selectedRepoID == nil)
            #expect(state.pendingRemoteSessionLink == nil)
        }
    }

    /// The lookup is superseded even when the newer click lands before the
    /// lookup's task has started: its token is stamped when the link is
    /// followed, not when the task runs.
    @Test func archivedLookupNotYetStarted_isSupersededByALaterRemoteBannerClick() async {
        await withState { state in
            state.isInitialStateLoaded = true
            state.reposLoaded = true
            state.worktreesLoaded = true
            state.remoteMirrorLoaded = true
            state.remoteSessions = [remoteSession("s1")]
            let repoID = UUID()
            let id = UUID()
            state.archivedLookupOverride = { [wt = makeArchived(id: id, repoID: repoID)] _ in [wt] }

            // One main-actor turn, so the lookup's task cannot start between them.
            state.navigateToWorktree(id)
            state.macNotificationManager.handleClick(identifier: "remote:acme:s1")
            await state.archivedLookupTask?.value

            #expect(state.selectedRemoteSession == RemoteSessionSelection(provider: "acme", sessionID: "s1"))
            #expect(state.selectedRepoID == nil)
            #expect(state.archivedWorktrees[repoID] == nil)
        }
    }
}

/// Holds an archived lookup, or a create, open until the test lets it
/// resolve. A main-actor class because the stub is an escaping closure: it
/// parks its continuation here, not in a captured local `var`.
@MainActor
private final class LookupGate {
    private(set) var isHolding = false
    private var released = false
    private var held: CheckedContinuation<Void, Never>?

    /// Called from the lookup; returns once `release()` has been called.
    func hold() async {
        guard !released else { return }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            held = continuation
            isHolding = true
        }
    }

    func release() {
        released = true
        isHolding = false
        held?.resume()
        held = nil
    }
}
