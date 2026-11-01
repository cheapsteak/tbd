import Foundation

public enum PanelHistoryAction: Codable, Sendable, Equatable {
    case back
    case forward
    case jump(index: Int)
}

/// The operations on one workspace tab's side region (panel tabs spec,
/// "Operations"). The envelope names the tab; every case acts inside it.
public enum PanelOperation: Codable, Sendable, Equatable {
    /// The one entry point for command-clicks, transcript links and
    /// `tbd panel open`: selects a panel already showing `content`, else
    /// reuses a same-kind panel (file, web) unless `newPanel`, else adds a
    /// panel after the active one. Note and Changes content opens a worktree
    /// panel instead, the one already showing it or a new one at the end of
    /// the worktree's list, whatever `newPanel` says.
    case open(content: PanelContent, newPanel: Bool)
    /// Points one panel at new content of its own kind, committing history.
    case navigate(panelID: PanelID, destination: PanelContent)
    /// Moves one panel's history cursor.
    case history(panelID: PanelID, action: PanelHistoryAction)
    /// Brings a panel to the front.
    case select(panelID: PanelID)
    case close(panelID: PanelID)
    /// Hides or shows the region, keeping its panels.
    case setCollapsed(Bool)
    /// Sets the region's share of the workspace tab's width.
    case resize(width: Double)
}

/// Not a security credential — diagnostics only (§7.2).
public enum PanelOperationOrigin: String, Codable, Sendable {
    case appUser, agentCLI, daemonReconcile
}

public struct PanelOperationEnvelope: Codable, Sendable, Equatable {
    public let operationID: PanelOperationID
    public let worktreeID: UUID
    public let tabID: WorkspaceTabID
    public let baseRevision: UInt64?
    public let origin: PanelOperationOrigin
    public let operation: PanelOperation
    public init(operationID: PanelOperationID, worktreeID: UUID, tabID: WorkspaceTabID,
                baseRevision: UInt64?, origin: PanelOperationOrigin, operation: PanelOperation) {
        self.operationID = operationID
        self.worktreeID = worktreeID
        self.tabID = tabID
        self.baseRevision = baseRevision
        self.origin = origin
        self.operation = operation
    }
}
