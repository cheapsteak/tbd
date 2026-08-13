import Testing
import Foundation
@testable import TBDApp
import TBDShared

/// Covers `WorktreeRowView.leadingIndicator(worktree:isPending:hasPRStatus:)`
/// — the leading-slot rule for a worktree row now that adopted remote lanes
/// render as ordinary worktree rows. Tier 1: pure, no `AppState`, no view
/// hierarchy, no clock.
@Suite("WorktreeRowView — remote leading indicator")
struct WorktreeRowRemoteIndicatorTests {

    private func worktree(location: WorktreeLocation) -> Worktree {
        Worktree(
            repoID: UUID(), name: "lane", displayName: "lane", branch: "feature",
            path: location.storagePath ?? "/tmp/lane", tmuxServer: "tbd-x",
            location: location)
    }

    private var remote: Worktree {
        worktree(location: .remote(provider: "acme", sessionID: "s1"))
    }

    private var local: Worktree { worktree(location: .local) }

    @Test func remoteRowReportsTheRemoteIndicator() {
        #expect(WorktreeRowView.leadingIndicator(
            worktree: remote, isPending: false, hasPRStatus: false) == .remote)
    }

    /// The local path is unchanged: an idle local row still has no leading
    /// indicator at all.
    @Test func localRowIsUnchanged() {
        #expect(WorktreeRowView.leadingIndicator(
            worktree: local, isPending: false, hasPRStatus: false) == nil)
        #expect(WorktreeRowView.leadingIndicator(
            worktree: local, isPending: true, hasPRStatus: false) == .pending)
        #expect(WorktreeRowView.leadingIndicator(
            worktree: local, isPending: false, hasPRStatus: true) == .prStatus)
    }

    /// `.remote` is the lowest-priority leading indicator, and that is the
    /// whole point of adopting lanes as worktree rows: a remote lane carries
    /// PR badges exactly like a local one, so the badge must win the slot.
    @Test func remoteRowWithAPRStillShowsThePRBadge() {
        #expect(WorktreeRowView.leadingIndicator(
            worktree: remote, isPending: false, hasPRStatus: true) == .prStatus)
    }

    /// End-to-end through the presentation the row actually renders from: a
    /// remote row's `prStatus` produces a presentation (so `hasPRStatus` is
    /// true at the call site), and the slot resolves to the PR badge.
    @Test func remoteRowsPRStatusProducesAPresentationAndWinsTheSlot() {
        let status = PRStatus(number: 42, url: "https://example.test/pr/42", state: .mergeable)
        let presentation = PRStatusPresentation.make(for: status)
        #expect(presentation != nil)
        #expect(WorktreeRowView.leadingIndicator(
            worktree: remote, isPending: false, hasPRStatus: presentation != nil) == .prStatus)
    }

    /// A remote lane still being created shows the pending glyph, same as a
    /// local one — remoteness is the quietest fact in the slot.
    @Test func pendingOutranksRemote() {
        #expect(WorktreeRowView.leadingIndicator(
            worktree: remote, isPending: true, hasPRStatus: false) == .pending)
    }
}
