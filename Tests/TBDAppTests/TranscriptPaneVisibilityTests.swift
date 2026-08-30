import Foundation
import Testing
@testable import TBDApp

/// The pane→scheduler tier wiring.
///
/// `TranscriptPollPolicyTests` asserts what each tier *costs*; these assert
/// that a pane ever declares the cheaper one. That is a separate claim, and it
/// is the one that was false: the pane hardcoded `.foreground`, so every
/// mounted-but-off-screen session polled at 100ms and `.background` was
/// unreachable in production no matter how correct the policy function was.
@MainActor
@Suite("Transcript pane poll tier")
struct TranscriptPaneVisibilityTests {

    @Test("the pane of a selected worktree is on screen, so it is foreground")
    func selectedIsForeground() {
        let visible = UUID()
        #expect(TranscriptPaneVisibility.tier(
            worktreeID: visible, selectedWorktreeIDs: [visible]) == .foreground)
    }

    @Test("a pane the keep-alive LRU holds off screen is background")
    func mountedButUnselectedIsBackground() {
        let selected = UUID()
        let warm = UUID()
        #expect(TranscriptPaneVisibility.tier(
            worktreeID: warm, selectedWorktreeIDs: [selected]) == .background,
                "a mounted pane whose worktree is not selected is not on screen")
    }

    @Test("multi-select renders every selected worktree, so all of them are foreground")
    func everyMultiSelectedWorktreeIsForeground() {
        let first = UUID()
        let second = UUID()
        let selection: Set<UUID> = [first, second]
        #expect(TranscriptPaneVisibility.tier(
            worktreeID: first, selectedWorktreeIDs: selection) == .foreground)
        #expect(TranscriptPaneVisibility.tier(
            worktreeID: second, selectedWorktreeIDs: selection) == .foreground)
    }

    @Test("with nothing selected every mounted pane is on the background cadence")
    func emptySelectionIsAllBackground() {
        #expect(TranscriptPaneVisibility.tier(
            worktreeID: UUID(), selectedWorktreeIDs: []) == .background)
    }

    /// The exact shape the finding named: the pager mounts the whole keep-alive
    /// set, and only its selected member is on screen. Composed from the real
    /// `AppState.keepAliveWorktreeIDs` policy rather than a hand-written list,
    /// so the two cannot drift apart on what "mounted" means.
    @Test("across a real keep-alive set exactly the selected pane is foreground")
    func onlyTheSelectedMemberOfTheKeepAliveSetIsForeground() {
        let selected = UUID()
        let warm = (0..<5).map { _ in UUID() }
        let mounted = AppState.keepAliveWorktreeIDs(
            recentlyVisited: [selected] + warm,
            protected: [selected],
            limit: 8)
        #expect(mounted.count == 6, "the LRU keeps the warm worktrees mounted alongside the selection")

        let tiers = mounted.map {
            TranscriptPaneVisibility.tier(worktreeID: $0, selectedWorktreeIDs: [selected])
        }
        #expect(tiers.filter { $0 == .foreground }.count == 1,
                "only the on-screen pane may hold the 100ms cadence")
        #expect(tiers.filter { $0 == .background }.count == 5,
                "the five panes the LRU is merely holding must poll at 2s")
    }

    @Test("the declared tier is the one the scheduler actually records")
    func declaredTierReachesTheScheduler() async {
        let scheduler = TranscriptPollScheduler(source: TranscriptSource())
        let worktree = UUID()
        await TranscriptPaneRegistration.apply(
            enabled: true, sessionID: "s1", path: "/tmp/tbd-tier-test-s1.jsonl",
            tier: TranscriptPaneVisibility.tier(
                worktreeID: worktree, selectedWorktreeIDs: [UUID()]),
            scheduler: scheduler)
        #expect(await scheduler.registeredTier(sessionID: "s1") == .background)
        await scheduler.deregister(sessionID: "s1")
    }

    /// Losing the selection must re-tier a live registration in place — the
    /// pane is not torn down when the viewer slot keeps it mounted, so nothing
    /// else would move it off the 100ms cadence.
    @Test("a visibility change moves a live registration to the other cadence")
    func visibilityChangeReTiersInPlace() async {
        let scheduler = TranscriptPollScheduler(source: TranscriptSource())
        let worktree = UUID()
        let path = "/tmp/tbd-tier-test-s2.jsonl"

        await TranscriptPaneRegistration.apply(
            enabled: true, sessionID: "s2", path: path,
            tier: TranscriptPaneVisibility.tier(
                worktreeID: worktree, selectedWorktreeIDs: [worktree]),
            scheduler: scheduler)
        #expect(await scheduler.registeredTier(sessionID: "s2") == .foreground)

        // Selection moves to another worktree; this pane stays mounted.
        await TranscriptPaneRegistration.apply(
            enabled: true, sessionID: "s2", path: path,
            tier: TranscriptPaneVisibility.tier(
                worktreeID: worktree, selectedWorktreeIDs: [UUID()]),
            scheduler: scheduler)
        #expect(await scheduler.registeredSessionIDs == ["s2"],
                "re-declaring a tier must replace the registration, not duplicate it")
        #expect(await scheduler.registeredTier(sessionID: "s2") == .background)

        // And back again when the pane returns to screen.
        await TranscriptPaneRegistration.apply(
            enabled: true, sessionID: "s2", path: path,
            tier: TranscriptPaneVisibility.tier(
                worktreeID: worktree, selectedWorktreeIDs: [worktree]),
            scheduler: scheduler)
        #expect(await scheduler.registeredTier(sessionID: "s2") == .foreground)
        await scheduler.deregister(sessionID: "s2")
    }
}
