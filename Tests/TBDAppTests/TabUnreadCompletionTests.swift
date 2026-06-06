import Foundation
import Testing
@testable import TBDApp
import TBDShared

/// Tests for the background-tab unread-completion bold feature. A
/// `.responseComplete` notification for a terminal whose tab is NOT the
/// currently-active tab of the focused worktree records the terminal in
/// `unreadTerminals` (driving the bold tab label). Activating the tab or
/// focusing the worktree on that tab clears it.
///
/// Every test constructs `AppState(userDefaults:)` against a unique throwaway
/// suite — TBDApp ships as an unbundled SPM executable, so `UserDefaults.standard`
/// is the running developer's real `TBDApp.plist`. Using it from tests would
/// clobber live UI preferences.
@MainActor
@Suite("Tab unread completion")
struct TabUnreadCompletionTests {

    private func withState(_ body: (AppState) -> Void) {
        let suiteName = "TBDAppTests.TabUnreadCompletion.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        body(AppState(userDefaults: defaults))
    }

    private func makeDelta(
        worktreeID: UUID,
        terminalID: UUID?,
        type: NotificationType = .responseComplete
    ) -> StateDelta {
        .notificationReceived(NotificationDelta(
            notificationID: UUID(),
            worktreeID: worktreeID,
            type: type,
            message: nil,
            terminalID: terminalID
        ))
    }

    @Test func responseComplete_forBackgroundTab_recordsUnread() {
        withState { state in
            let worktreeID = UUID()
            let activeTerminal = UUID()
            let backgroundTerminal = UUID()
            state.tabs = [
                worktreeID: [
                    Tab(id: activeTerminal, content: .terminal(terminalID: activeTerminal), label: nil),
                    Tab(id: backgroundTerminal, content: .terminal(terminalID: backgroundTerminal), label: nil),
                ]
            ]
            state.activeTabIndices = [worktreeID: 0]
            state.selectedWorktreeIDs = [worktreeID]

            state.handleDelta(makeDelta(worktreeID: worktreeID, terminalID: backgroundTerminal))

            #expect(state.unreadTerminals.contains(backgroundTerminal))
        }
    }

    @Test func responseComplete_forActiveTab_doesNotRecordUnread() {
        withState { state in
            let worktreeID = UUID()
            let activeTerminal = UUID()
            state.tabs = [
                worktreeID: [
                    Tab(id: activeTerminal, content: .terminal(terminalID: activeTerminal), label: nil),
                ]
            ]
            state.activeTabIndices = [worktreeID: 0]
            state.selectedWorktreeIDs = [worktreeID]

            state.handleDelta(makeDelta(worktreeID: worktreeID, terminalID: activeTerminal))

            #expect(!state.unreadTerminals.contains(activeTerminal))
        }
    }

    @Test func responseComplete_forLiveTranscriptActiveTab_doesNotRecordUnread() {
        withState { state in
            let worktreeID = UUID()
            let terminalID = UUID()
            state.tabs = [
                worktreeID: [
                    Tab(id: UUID(), content: .liveTranscript(id: UUID(), terminalID: terminalID), label: nil),
                ]
            ]
            state.activeTabIndices = [worktreeID: 0]
            state.selectedWorktreeIDs = [worktreeID]

            state.handleDelta(makeDelta(worktreeID: worktreeID, terminalID: terminalID))

            #expect(!state.unreadTerminals.contains(terminalID))
        }
    }

    /// Bolding is generalized to ANY terminal-stamped delta (not just
    /// `.responseComplete`): a background-tab `.error` records unread so its tab
    /// label bolds, matching the focus-push behavior.
    @Test func nonResponseComplete_forBackgroundTab_recordsUnread() {
        withState { state in
            let worktreeID = UUID()
            let backgroundTerminal = UUID()
            state.tabs = [
                worktreeID: [
                    Tab(id: UUID(), content: .terminal(terminalID: UUID()), label: nil),
                    Tab(id: backgroundTerminal, content: .terminal(terminalID: backgroundTerminal), label: nil),
                ]
            ]
            state.activeTabIndices = [worktreeID: 0]
            state.selectedWorktreeIDs = [worktreeID]

            state.handleDelta(makeDelta(worktreeID: worktreeID, terminalID: backgroundTerminal, type: .error))

            #expect(state.unreadTerminals.contains(backgroundTerminal))
        }
    }

    /// A `.responseComplete` whose delta carries no terminalID must be a no-op:
    /// the recording branch is gated on `notification.terminalID` so nothing is
    /// inserted (and nothing crashes).
    @Test func responseComplete_withNilTerminalID_isNoOp() {
        withState { state in
            let worktreeID = UUID()
            state.tabs = [
                worktreeID: [
                    Tab(id: UUID(), content: .terminal(terminalID: UUID()), label: nil),
                ]
            ]
            state.activeTabIndices = [worktreeID: 0]
            state.selectedWorktreeIDs = [worktreeID]

            state.handleDelta(makeDelta(worktreeID: worktreeID, terminalID: nil))

            #expect(state.unreadTerminals.isEmpty)
        }
    }

    @Test func activatingTab_clearsUnread() {
        withState { state in
            let worktreeID = UUID()
            let activeTerminal = UUID()
            let backgroundTerminal = UUID()
            state.tabs = [
                worktreeID: [
                    Tab(id: activeTerminal, content: .terminal(terminalID: activeTerminal), label: nil),
                    Tab(id: backgroundTerminal, content: .terminal(terminalID: backgroundTerminal), label: nil),
                ]
            ]
            state.activeTabIndices = [worktreeID: 0]
            state.unreadTerminals = [backgroundTerminal]

            state.setActiveTab(worktreeID: worktreeID, tabIndex: 1)

            #expect(!state.unreadTerminals.contains(backgroundTerminal))
        }
    }

    @Test func focusingWorktree_clearsActiveTabUnread() {
        withState { state in
            let worktreeID = UUID()
            let activeTerminal = UUID()
            state.tabs = [
                worktreeID: [
                    Tab(id: activeTerminal, content: .terminal(terminalID: activeTerminal), label: nil),
                ]
            ]
            state.activeTabIndices = [worktreeID: 0]
            state.unreadTerminals = [activeTerminal]

            // Focusing the worktree (single selection) clears its active tab's unread.
            state.selectedWorktreeIDs = [worktreeID]

            #expect(!state.unreadTerminals.contains(activeTerminal))
        }
    }

    @Test func focusingWorktree_keepsBackgroundTabUnread() {
        withState { state in
            let worktreeID = UUID()
            let activeTerminal = UUID()
            let backgroundTerminal = UUID()
            state.tabs = [
                worktreeID: [
                    Tab(id: activeTerminal, content: .terminal(terminalID: activeTerminal), label: nil),
                    Tab(id: backgroundTerminal, content: .terminal(terminalID: backgroundTerminal), label: nil),
                ]
            ]
            state.activeTabIndices = [worktreeID: 0]
            state.unreadTerminals = [backgroundTerminal]

            state.selectedWorktreeIDs = [worktreeID]

            // Background tab's unread survives focusing the worktree.
            #expect(state.unreadTerminals.contains(backgroundTerminal))
        }
    }

    // MARK: - Record-before-early-return ordering

    /// The recording branch in `handleNotificationDelta` runs BEFORE the
    /// visible-worktree early-return, so a completion on a background tab of a
    /// worktree that IS focused/visible still bolds. This pins that load-bearing
    /// ordering: the worktree is in `visibleWorktreeIDs`, yet the background
    /// tab's terminal is still recorded.
    @Test func responseComplete_recordsEvenWhenWorktreeVisible() {
        withState { state in
            let worktreeID = UUID()
            let activeTerminal = UUID()
            let backgroundTerminal = UUID()
            state.tabs = [
                worktreeID: [
                    Tab(id: activeTerminal, content: .terminal(terminalID: activeTerminal), label: nil),
                    Tab(id: backgroundTerminal, content: .terminal(terminalID: backgroundTerminal), label: nil),
                ]
            ]
            state.activeTabIndices = [worktreeID: 0]
            // Single-selecting makes the worktree visible (in visibleWorktreeIDs).
            state.selectedWorktreeIDs = [worktreeID]
            #expect(state.visibleWorktreeIDs.contains(worktreeID))

            state.handleDelta(makeDelta(worktreeID: worktreeID, terminalID: backgroundTerminal))

            #expect(state.unreadTerminals.contains(backgroundTerminal))
        }
    }

    // MARK: - Tab close cleanup (finding #1)

    /// Closing a background tab that has a pending unread-completion bold must
    /// remove that tab's terminal from `unreadTerminals` — otherwise the UUID
    /// leaks forever once the tab (and its terminal) are gone.
    @Test func closingBackgroundTabWithUnread_removesFromUnreadTerminals() {
        withState { state in
            let worktreeID = UUID()
            let activeTerminal = UUID()
            let backgroundTerminal = UUID()
            state.tabs = [
                worktreeID: [
                    Tab(id: activeTerminal, content: .terminal(terminalID: activeTerminal), label: nil),
                    Tab(id: backgroundTerminal, content: .terminal(terminalID: backgroundTerminal), label: nil),
                ]
            ]
            state.activeTabIndices = [worktreeID: 0]
            state.unreadTerminals = [backgroundTerminal]

            state.closeTab(worktreeID: worktreeID, index: 1)

            #expect(!state.unreadTerminals.contains(backgroundTerminal))
        }
    }

    /// Closing a split-layout tab clears unread for ALL of its panes, not just
    /// the primary `tab.content` terminal.
    @Test func closingSplitTab_removesAllPaneUnread() {
        withState { state in
            let worktreeID = UUID()
            let tabID = UUID()
            let primaryTerminal = UUID()
            let secondaryTerminal = UUID()
            state.tabs = [
                worktreeID: [
                    Tab(id: tabID, content: .terminal(terminalID: primaryTerminal), label: nil),
                ]
            ]
            state.layouts = [
                tabID: .split(
                    direction: .horizontal,
                    children: [
                        .pane(.terminal(terminalID: primaryTerminal)),
                        .pane(.terminal(terminalID: secondaryTerminal)),
                    ],
                    ratios: [0.5, 0.5]
                )
            ]
            state.activeTabIndices = [worktreeID: 0]
            state.unreadTerminals = [primaryTerminal, secondaryTerminal]

            state.closeTab(worktreeID: worktreeID, index: 0)

            #expect(!state.unreadTerminals.contains(primaryTerminal))
            #expect(!state.unreadTerminals.contains(secondaryTerminal))
        }
    }

    // MARK: - Split-layout active tab (finding #2)

    /// A `.responseComplete` for a SECONDARY pane of the *active* split tab must
    /// NOT record unread — the user is looking at that split, so no pane of it
    /// should bold. Before the fix, `isActiveTabTerminal` only consulted
    /// `tab.content`, missing the secondary pane and wrongly bolding.
    @Test func responseComplete_forSecondaryPaneOfActiveSplitTab_doesNotRecordUnread() {
        withState { state in
            let worktreeID = UUID()
            let tabID = UUID()
            let primaryTerminal = UUID()
            let secondaryTerminal = UUID()
            state.tabs = [
                worktreeID: [
                    Tab(id: tabID, content: .terminal(terminalID: primaryTerminal), label: nil),
                ]
            ]
            state.layouts = [
                tabID: .split(
                    direction: .horizontal,
                    children: [
                        .pane(.terminal(terminalID: primaryTerminal)),
                        .pane(.terminal(terminalID: secondaryTerminal)),
                    ],
                    ratios: [0.5, 0.5]
                )
            ]
            state.activeTabIndices = [worktreeID: 0]
            state.selectedWorktreeIDs = [worktreeID]

            state.handleDelta(makeDelta(worktreeID: worktreeID, terminalID: secondaryTerminal))

            #expect(!state.unreadTerminals.contains(secondaryTerminal))
        }
    }

    /// Activating a split tab clears unread for ALL its panes, including the
    /// secondary one.
    @Test func activatingSplitTab_clearsAllPaneUnread() {
        withState { state in
            let worktreeID = UUID()
            let plainTabID = UUID()
            let plainTerminal = UUID()
            let splitTabID = UUID()
            let primaryTerminal = UUID()
            let secondaryTerminal = UUID()
            state.tabs = [
                worktreeID: [
                    Tab(id: plainTabID, content: .terminal(terminalID: plainTerminal), label: nil),
                    Tab(id: splitTabID, content: .terminal(terminalID: primaryTerminal), label: nil),
                ]
            ]
            state.layouts = [
                splitTabID: .split(
                    direction: .horizontal,
                    children: [
                        .pane(.terminal(terminalID: primaryTerminal)),
                        .pane(.terminal(terminalID: secondaryTerminal)),
                    ],
                    ratios: [0.5, 0.5]
                )
            ]
            state.activeTabIndices = [worktreeID: 0]
            state.unreadTerminals = [primaryTerminal, secondaryTerminal]

            state.setActiveTab(worktreeID: worktreeID, tabIndex: 1)

            #expect(!state.unreadTerminals.contains(primaryTerminal))
            #expect(!state.unreadTerminals.contains(secondaryTerminal))
        }
    }
}
