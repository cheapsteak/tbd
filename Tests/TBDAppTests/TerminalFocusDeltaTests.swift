import Foundation
import Testing
@testable import TBDApp
import TBDShared

@MainActor
@Suite("Focus-push delta handling")
struct TerminalFocusDeltaTests {

    private func withState(_ body: (AppState) -> Void) {
        let suiteName = "TBDAppTests.FocusDelta.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        body(AppState(userDefaults: defaults))
    }

    private func focusDelta(worktreeID: UUID, terminalID: UUID, activate: Bool) -> StateDelta {
        .notificationReceived(NotificationDelta(
            notificationID: UUID(), worktreeID: worktreeID,
            type: .focusRequest, message: "look", terminalID: terminalID, activate: activate
        ))
    }

    @Test func softFocus_forBackgroundTab_recordsUnread_doesNotNavigate() {
        withState { state in
            state.isInitialStateLoaded = true
            let other = UUID()
            let worktreeID = UUID()
            let activeTerminal = UUID()
            let backgroundTerminal = UUID()
            state.tabs = [worktreeID: [
                Tab(id: activeTerminal, content: .terminal(terminalID: activeTerminal), label: nil),
                Tab(id: backgroundTerminal, content: .terminal(terminalID: backgroundTerminal), label: nil),
            ]]
            state.activeTabIndices = [worktreeID: 0]
            // Focus is on a different worktree, so worktreeID is NOT visible.
            state.selectedWorktreeIDs = [other]

            state.handleDelta(focusDelta(worktreeID: worktreeID, terminalID: backgroundTerminal, activate: false))

            #expect(state.unreadTerminals.contains(backgroundTerminal))
            #expect(state.selectedWorktreeIDs == [other])   // no navigation
        }
    }

    @Test func softFocus_forActiveTab_doesNotBold() {
        withState { state in
            state.isInitialStateLoaded = true
            let worktreeID = UUID()
            let activeTerminal = UUID()
            state.tabs = [worktreeID: [
                Tab(id: activeTerminal, content: .terminal(terminalID: activeTerminal), label: nil),
            ]]
            state.activeTabIndices = [worktreeID: 0]
            state.selectedWorktreeIDs = [worktreeID]

            state.handleDelta(focusDelta(worktreeID: worktreeID, terminalID: activeTerminal, activate: false))

            #expect(!state.unreadTerminals.contains(activeTerminal))
        }
    }

    @Test func activateFocus_navigatesToWorktreeAndTab() {
        withState { state in
            state.isInitialStateLoaded = true
            let repoID = UUID()
            let worktreeID = UUID()
            let targetTerminal = UUID()
            state.worktrees = [repoID: [
                Worktree(id: worktreeID, repoID: repoID, name: "x", displayName: "X",
                         branch: "tbd/x", path: "/tmp/x", tmuxServer: "tbd-x"),
            ]]
            state.tabs = [worktreeID: [
                Tab(id: UUID(), content: .terminal(terminalID: UUID()), label: nil),
                Tab(id: targetTerminal, content: .terminal(terminalID: targetTerminal), label: nil),
            ]]
            state.activeTabIndices = [worktreeID: 0]
            state.selectedWorktreeIDs = []

            state.handleDelta(focusDelta(worktreeID: worktreeID, terminalID: targetTerminal, activate: true))

            #expect(state.selectedWorktreeIDs == [worktreeID])
            #expect(state.activeTabIndices[worktreeID] == 1)   // switched to the target tab
        }
    }
}
