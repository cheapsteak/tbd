import Foundation
import Testing
@testable import TBDApp
import TBDShared

// Tier 1: pure mapping, no AppState and no AppKit.

/// `SidebarSelectionBridge` in both directions, with mixed local and remote
/// selections. Spec: docs/specs/2026-10-31-native-sidebar-design.md,
/// "Selection".
@Suite("Sidebar selection bridge")
struct SidebarSelectionBridgeTests {
    /// The `List` tags worktree rows with the worktree's ID and remote session
    /// rows with the session's ID, and nothing else; the outline writes the
    /// same set for the same rows.
    @Test func outlineSelectionWritesSameIDsListTagsWould() {
        let repo = UUID()
        let worktree = UUID()
        let lane = RemoteSessionIdentity.uuid(provider: "acme", sessionID: "lane")
        let selected: [SidebarNodeID] = [
            .repoHeader(repo), .worktree(worktree), .remoteSession(lane), .scratchHeader, .scratchPrompt,
            .providerHeader("acme"), .group(SidebarGroupID(owner: .repository(repo), kind: .remote)),
        ]
        #expect(SidebarSelectionBridge.appStateIDs(for: selected) == [worktree, lane])
        #expect(SidebarSelectionBridge.appStateIDs(for: [.worktree(worktree)]) == [worktree])
        #expect(SidebarSelectionBridge.appStateIDs(for: [.remoteSession(lane)]) == [lane])
        #expect(SidebarSelectionBridge.appStateIDs(for: [.repoHeader(repo), .scratchHeader]).isEmpty,
                "A header never reaches the selection")
        #expect(SidebarSelectionBridge.appStateIDs(for: []).isEmpty)
    }

    @Test func outlineIDsMirrorAppStateSelection() {
        let first = UUID()
        let second = UUID()
        let lane = RemoteSessionIdentity.uuid(provider: "acme", sessionID: "lane")
        #expect(SidebarSelectionBridge.outlineIDs(selectedWorktreeIDs: [first, second], selectedRemoteSession: nil)
                == [.worktree(first), .worktree(second)])
        // A pure remote selection rests in `selectedRemoteSession`, not the set.
        #expect(SidebarSelectionBridge.outlineIDs(selectedWorktreeIDs: [], selectedRemoteSession: lane)
                == [.remoteSession(lane)])
        #expect(SidebarSelectionBridge.outlineIDs(selectedWorktreeIDs: [first], selectedRemoteSession: lane)
                == [.worktree(first), .remoteSession(lane)])
        #expect(SidebarSelectionBridge.outlineIDs(selectedWorktreeIDs: [], selectedRemoteSession: nil).isEmpty)

        // Round trip: what the outline shows writes back the same IDs.
        let shown = SidebarSelectionBridge.outlineIDs(selectedWorktreeIDs: [first], selectedRemoteSession: lane)
        #expect(SidebarSelectionBridge.appStateIDs(for: Array(shown)) == [first, lane])
    }

    @Test func onlyRowsAreSelectable() {
        let repo = UUID()
        #expect(SidebarSelectionBridge.isSelectable(.worktree(UUID())))
        #expect(SidebarSelectionBridge.isSelectable(.remoteSession(UUID())))
        #expect(!SidebarSelectionBridge.isSelectable(.repoHeader(repo)))
        #expect(!SidebarSelectionBridge.isSelectable(.scratchHeader))
        #expect(!SidebarSelectionBridge.isSelectable(.scratchPrompt))
        #expect(!SidebarSelectionBridge.isSelectable(.providerHeader("acme")))
        #expect(!SidebarSelectionBridge.isSelectable(.group(SidebarGroupID(owner: .scratch, kind: .hibernated))))
    }
}
