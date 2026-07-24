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

public struct PanelImportParams: Codable, Sendable, Equatable {
    public let worktreeID: UUID
    public let tabs: [LegacyTabPayload]
    public let tabOrder: [UUID]
    public let activeTabID: UUID?
    /// PR #472's persisted per-slot histories (legacy `PaneContent` MRU),
    /// keyed by legacy slot/pane ID.
    public let paneHistories: [UUID: MRUHistory<PaneContent>]
    public init(worktreeID: UUID, tabs: [LegacyTabPayload], tabOrder: [UUID],
                activeTabID: UUID?, paneHistories: [UUID: MRUHistory<PaneContent>]) {
        self.worktreeID = worktreeID
        self.tabs = tabs
        self.tabOrder = tabOrder
        self.activeTabID = activeTabID
        self.paneHistories = paneHistories
    }
}

public struct PanelImportResult: Codable, Sendable, Equatable {
    public let imported: Bool
    public let tabCount: Int
    public let promotedTerminalTabs: Int
    public let skipped: [String]
    public init(imported: Bool, tabCount: Int, promotedTerminalTabs: Int, skipped: [String]) {
        self.imported = imported
        self.tabCount = tabCount
        self.promotedTerminalTabs = promotedTerminalTabs
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
