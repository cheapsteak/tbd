import Foundation

// Spec C §10.1 wire surface. Full affected-tab snapshots, never structural
// diffs — trees are small, IDs are stable, full payloads are self-healing.

public struct PanelGetParams: Codable, Sendable, Equatable {
    public let worktreeID: UUID
    public let tabID: UUID?
    public init(worktreeID: UUID, tabID: UUID? = nil) {
        self.worktreeID = worktreeID
        self.tabID = tabID
    }
}

public struct PanelGetResult: Codable, Sendable, Equatable {
    public let tabs: [WorkspaceTabSurface]
    public let activeTabID: UUID?
    public init(tabs: [WorkspaceTabSurface], activeTabID: UUID?) {
        self.tabs = tabs
        self.activeTabID = activeTabID
    }
}

public struct PanelApplyParams: Codable, Sendable, Equatable {
    public let envelope: PanelOperationEnvelope
    public init(envelope: PanelOperationEnvelope) { self.envelope = envelope }
}

public struct PanelApplyResult: Codable, Sendable, Equatable {
    public let tab: WorkspaceTabSurface
    /// True when this operationID had already committed — the stored result
    /// is being replayed (§7.4 idempotency), nothing was re-applied.
    public let replayed: Bool
    public init(tab: WorkspaceTabSurface, replayed: Bool) {
        self.tab = tab
        self.replayed = replayed
    }
}

/// One legacy tab as the app knows it today: `Tab.content` (primary seed)
/// plus the tab's `LayoutNode` tree when one exists in the layouts blob.
public struct LegacyTabPayload: Codable, Sendable, Equatable {
    public let tabID: UUID
    public let label: String?
    public let content: PaneContent
    public let layout: LayoutNode?
    public init(tabID: UUID, label: String?, content: PaneContent, layout: LayoutNode?) {
        self.tabID = tabID
        self.label = label
        self.content = content
        self.layout = layout
    }
}

/// `panel.syncTabs` (panel tabs spec, "Tab sync"): every workspace tab of one
/// worktree as the app knows it. The daemon imports each listed tab that has
/// no surface through `LegacyTabConverter`, never overwrites one that has a
/// surface, re-parents a listed tab's surface held under another worktree,
/// updates position, label and primary on existing surfaces, and deletes this
/// worktree's surfaces for tabs not listed.
public struct PanelSyncTabsParams: Codable, Sendable, Equatable {
    public let worktreeID: UUID
    /// Every workspace tab, in tab-bar order.
    public let tabs: [LegacyTabPayload]
    /// PR #472's persisted per-pane histories (legacy `PaneContent` MRU),
    /// keyed by legacy pane ID; read when a tab is imported.
    public let paneHistories: [UUID: MRUHistory<PaneContent>]
    public init(worktreeID: UUID, tabs: [LegacyTabPayload],
                paneHistories: [UUID: MRUHistory<PaneContent>]) {
        self.worktreeID = worktreeID
        self.tabs = tabs
        self.paneHistories = paneHistories
    }
}

public struct PanelSyncTabsResult: Codable, Sendable, Equatable {
    /// Listed tabs that had no surface and now have one.
    public let importedTabIDs: [UUID]
    /// Listed tabs whose surface moved here from another worktree.
    public let reparentedTabIDs: [UUID]
    /// This worktree's surfaces deleted because their tab was not listed.
    public let removedTabIDs: [UUID]
    /// Listed tabs the daemon could not import, which the sync left without a
    /// surface: they render legacy. A tab that already has a surface is never
    /// named, whatever its legacy layout holds.
    public let skippedTabIDs: [UUID]
    /// The reason for each of `skippedTabIDs`, in the same order.
    public let skipped: [String]
    public init(importedTabIDs: [UUID], reparentedTabIDs: [UUID],
                removedTabIDs: [UUID], skippedTabIDs: [UUID], skipped: [String]) {
        self.importedTabIDs = importedTabIDs
        self.reparentedTabIDs = reparentedTabIDs
        self.removedTabIDs = removedTabIDs
        self.skippedTabIDs = skippedTabIDs
        self.skipped = skipped
    }
}

public struct PanelSurfaceDelta: Codable, Sendable, Equatable {
    public let worktreeID: UUID
    public let tabs: [WorkspaceTabSurface]
    public let removedTabIDs: [UUID]
    public let activeTabID: UUID?
    public let originOperationID: UUID?
    public init(worktreeID: UUID, tabs: [WorkspaceTabSurface], removedTabIDs: [UUID],
                activeTabID: UUID?, originOperationID: UUID?) {
        self.worktreeID = worktreeID
        self.tabs = tabs
        self.removedTabIDs = removedTabIDs
        self.activeTabID = activeTabID
        self.originOperationID = originOperationID
    }
}
