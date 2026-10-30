import Foundation
import Testing
@testable import TBDApp
import TBDShared
import TestSupport

/// One banner the handler asked `postNotificationBanner` to post.
private struct BannerPost: Equatable {
    let worktreeID: UUID
    let message: String?
    let worktreeName: String?
    let type: NotificationType
    let terminalID: UUID?
}

/// Replaces `AppState.postNotificationBanner` and records every call, so a
/// test can see which arrivals post — `MacNotificationManager.postIfEnabled`
/// itself returns early on the unbundled test executable.
@MainActor
private final class BannerRecorder {
    private(set) var posts: [BannerPost] = []

    func install(on state: AppState) {
        state.postNotificationBanner = { [self] notification, worktreeName in
            self.posts.append(BannerPost(
                worktreeID: notification.worktreeID,
                message: notification.message,
                worktreeName: worktreeName,
                type: notification.type,
                terminalID: notification.terminalID
            ))
        }
    }
}

/// Tier 1. A selected or pinned worktree suppresses its banner and its unread
/// mark only while TBD is the frontmost app: `attendedWorktreeIDs`, not
/// `visibleWorktreeIDs`, gates `handleNotificationDelta`. While TBD is in the
/// background an agent finishing in a visible worktree must still post a
/// banner and stay unread, because nobody is looking at it.
///
/// Every test sets `isAppActive` explicitly — the default reads `NSApp`, which
/// is never active under `swift test` — and replaces the banner seam with a
/// `BannerRecorder`.
@MainActor
@Suite("Notification app activity")
struct NotificationAppActivityTests {

    private func withState(active: Bool, _ body: (AppState, BannerRecorder) throws -> Void) rethrows {
        let suite = TestDefaultsSuite("TBDAppTests.NotificationAppActivity")
        let defaults = suite.defaults
        defer { suite.tearDown() }
        let state = AppState(userDefaults: defaults)
        state.isAppActive = { active }
        let recorder = BannerRecorder()
        recorder.install(on: state)
        try body(state, recorder)
    }

    private func makeWorktree(id: UUID, repoID: UUID, displayName: String = "Acme") -> Worktree {
        Worktree(id: id, repoID: repoID, name: "acme", displayName: displayName,
                 branch: "tbd/acme", path: "/tmp/acme", tmuxServer: "tbd-acme")
    }

    private func pinnedTerminal(worktreeID: UUID) -> TBDShared.Terminal {
        TBDShared.Terminal(
            id: UUID(),
            worktreeID: worktreeID,
            tmuxWindowID: "@1",
            tmuxPaneID: "%1",
            label: "Claude",
            pinnedAt: Date(),
            kind: .claude
        )
    }

    private func notificationDelta(
        worktreeID: UUID,
        terminalID: UUID?,
        type: NotificationType = .responseComplete,
        message: String? = "done",
        activate: Bool = false
    ) -> StateDelta {
        .notificationReceived(NotificationDelta(
            notificationID: UUID(),
            worktreeID: worktreeID,
            type: type,
            message: message,
            terminalID: terminalID,
            activate: activate
        ))
    }

    // MARK: - Selected worktree

    @Test func activeApp_selectedWorktree_suppressesBannerAndSummary() {
        withState(active: true) { state, recorder in
            let repoID = UUID()
            let worktreeID = UUID()
            state.worktrees = [repoID: [makeWorktree(id: worktreeID, repoID: repoID)]]
            state.selectedWorktreeIDs = [worktreeID]

            state.handleDelta(notificationDelta(worktreeID: worktreeID, terminalID: UUID()))

            #expect(recorder.posts.isEmpty)
            #expect(state.unreadByWorktree[worktreeID] == nil)
        }
    }

    /// The bug: a selected worktree dropped its banner while the user was in
    /// another app.
    @Test func inactiveApp_selectedWorktree_postsBannerAndKeepsUnread() throws {
        try withState(active: false) { state, recorder in
            let repoID = UUID()
            let worktreeID = UUID()
            let terminalID = UUID()
            state.worktrees = [repoID: [makeWorktree(id: worktreeID, repoID: repoID, displayName: "Acme")]]
            state.selectedWorktreeIDs = [worktreeID]

            state.handleDelta(notificationDelta(
                worktreeID: worktreeID, terminalID: terminalID, type: .responseComplete, message: "done"))

            #expect(recorder.posts.count == 1)
            let post = try #require(recorder.posts.first)
            #expect(post == BannerPost(
                worktreeID: worktreeID,
                message: "done",
                worktreeName: "Acme",
                type: .responseComplete,
                terminalID: terminalID
            ))
            #expect(state.unreadByWorktree[worktreeID]?.type == .responseComplete)
        }
    }

    // MARK: - Pinned-only worktree

    @Test func activeApp_pinnedOnlyWorktree_suppressesBanner() {
        withState(active: true) { state, recorder in
            let worktreeID = UUID()
            state.terminals = [worktreeID: [pinnedTerminal(worktreeID: worktreeID)]]
            state.selectedWorktreeIDs = []
            #expect(state.visibleWorktreeIDs.contains(worktreeID))

            state.handleDelta(notificationDelta(worktreeID: worktreeID, terminalID: nil))

            #expect(recorder.posts.isEmpty)
            #expect(state.unreadByWorktree[worktreeID] == nil)
        }
    }

    @Test func inactiveApp_pinnedOnlyWorktree_postsBanner() {
        withState(active: false) { state, recorder in
            let worktreeID = UUID()
            state.terminals = [worktreeID: [pinnedTerminal(worktreeID: worktreeID)]]
            state.selectedWorktreeIDs = []
            #expect(state.visibleWorktreeIDs.contains(worktreeID))

            state.handleDelta(notificationDelta(worktreeID: worktreeID, terminalID: nil))

            #expect(recorder.posts.map(\.worktreeID) == [worktreeID])
            #expect(state.unreadByWorktree[worktreeID]?.type == .responseComplete)
        }
    }

    // MARK: - Worktree not visible

    @Test(arguments: [true, false])
    func notVisibleWorktree_postsBannerAndSetsUnread(active: Bool) {
        withState(active: active) { state, recorder in
            let other = UUID()
            let worktreeID = UUID()
            let terminalID = UUID()
            state.selectedWorktreeIDs = [other]
            #expect(!state.visibleWorktreeIDs.contains(worktreeID))

            state.handleDelta(notificationDelta(worktreeID: worktreeID, terminalID: terminalID, type: .error))

            #expect(recorder.posts.map(\.worktreeID) == [worktreeID])
            #expect(recorder.posts.first?.type == .error)
            #expect(recorder.posts.first?.terminalID == terminalID)
            #expect(state.unreadByWorktree[worktreeID]?.type == .error)
        }
    }

    // MARK: - Loud focus push

    /// `activate: true` navigates and returns before any banner or summary,
    /// whether or not TBD is active.
    @Test(arguments: [true, false])
    func activateFocus_navigatesWithoutBannerOrSummary(active: Bool) {
        withState(active: active) { state, recorder in
            state.isInitialStateLoaded = true
            let repoID = UUID()
            let worktreeID = UUID()
            let targetTerminal = UUID()
            state.worktrees = [repoID: [makeWorktree(id: worktreeID, repoID: repoID)]]
            state.tabs = [worktreeID: [
                Tab(id: UUID(), content: .terminal(terminalID: UUID()), label: nil),
                Tab(id: targetTerminal, content: .terminal(terminalID: targetTerminal), label: nil),
            ]]
            state.activeTabIndices = [worktreeID: 0]
            state.selectedWorktreeIDs = []

            state.handleDelta(notificationDelta(
                worktreeID: worktreeID, terminalID: targetTerminal,
                type: .focusRequest, message: "look", activate: true))

            #expect(state.selectedWorktreeIDs == [worktreeID])
            #expect(state.activeTabIndices[worktreeID] == 1)
            #expect(recorder.posts.isEmpty)
            #expect(state.unreadByWorktree[worktreeID] == nil)
        }
    }

    // MARK: - Background-tab bolding

    /// Bolding ignores app activity: while TBD is inactive a background-tab
    /// arrival in the selected worktree still bolds and the active tab's does
    /// not — and both now post a banner, since nobody is looking.
    @Test func inactiveApp_backgroundTabBoldingIsUnchanged() {
        withState(active: false) { state, recorder in
            let worktreeID = UUID()
            let activeTerminal = UUID()
            let backgroundTerminal = UUID()
            state.tabs = [worktreeID: [
                Tab(id: activeTerminal, content: .terminal(terminalID: activeTerminal), label: nil),
                Tab(id: backgroundTerminal, content: .terminal(terminalID: backgroundTerminal), label: nil),
            ]]
            state.activeTabIndices = [worktreeID: 0]
            state.selectedWorktreeIDs = [worktreeID]

            state.handleDelta(notificationDelta(worktreeID: worktreeID, terminalID: backgroundTerminal))
            state.handleDelta(notificationDelta(worktreeID: worktreeID, terminalID: activeTerminal))

            #expect(state.unreadTerminals.contains(backgroundTerminal))
            #expect(!state.unreadTerminals.contains(activeTerminal))
            #expect(recorder.posts.map(\.terminalID) == [backgroundTerminal, activeTerminal])
        }
    }

    // MARK: - Severity merge

    @Test func inactiveApp_visibleWorktree_doesNotDowngradeSeverity() {
        withState(active: false) { state, recorder in
            let worktreeID = UUID()
            state.selectedWorktreeIDs = [worktreeID]
            state.unreadByWorktree = [
                worktreeID: UnreadSummary(type: .error, mostRecentAt: Date(timeIntervalSince1970: 0)),
            ]

            state.handleDelta(notificationDelta(worktreeID: worktreeID, terminalID: nil, type: .responseComplete))

            #expect(state.unreadByWorktree[worktreeID]?.type == .error)
            #expect(recorder.posts.map(\.type) == [.responseComplete])
        }
    }

    // MARK: - Attended set

    /// `attendedWorktreeIDs` is also what `refreshNotifications` auto-marks
    /// read and filters out of `unreadByWorktree`; that path fetches over a
    /// concrete `DaemonClient` with no seam, so its input is pinned here.
    @Test func attendedWorktreeIDs_isVisibleSetWhileActive() {
        withState(active: true) { state, _ in
            let selected = UUID()
            let pinned = UUID()
            state.terminals = [pinned: [pinnedTerminal(worktreeID: pinned)]]
            state.selectedWorktreeIDs = [selected]

            #expect(state.visibleWorktreeIDs == [selected, pinned])
            #expect(state.attendedWorktreeIDs == state.visibleWorktreeIDs)
        }
    }

    @Test func attendedWorktreeIDs_isEmptyWhileInactive() {
        withState(active: false) { state, _ in
            let selected = UUID()
            let pinned = UUID()
            state.terminals = [pinned: [pinnedTerminal(worktreeID: pinned)]]
            state.selectedWorktreeIDs = [selected]

            #expect(state.visibleWorktreeIDs == [selected, pinned])
            #expect(state.attendedWorktreeIDs.isEmpty)
        }
    }
}
