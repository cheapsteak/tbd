import Foundation

// Spec C §7.3 — wire vocabulary uses user-facing edges; split direction is
// derived by the reducer.
public enum PanelEdge: String, Codable, Sendable {
    case left, right, above, below
}

public enum PanelAnchor: Codable, Sendable, Equatable {
    case primary
    case panel(PanelID)
}

/// Placement intent. `.automatic` contract: the pure reducer resolves it
/// deterministically (first viewer panel in pre-order → replace; otherwise
/// split right of the primary anchor at the default share). Recency-based
/// reuse (§6.1 rule 1) is the coordinator's job — it rewrites `.automatic`
/// to `.replace(panelID:)` from `panel_history.updated_at` BEFORE invoking
/// the reducer, keeping the reducer clock-free and pure.
public enum PanelPlacement: Codable, Sendable, Equatable {
    case automatic
    case replace(panelID: PanelID)
    case beside(target: PanelAnchor, edge: PanelEdge, share: Double?)
}

public enum PanelHistoryAction: Codable, Sendable, Equatable {
    case back
    case forward
    case jump(index: Int)
}

public enum PanelOperation: Codable, Sendable, Equatable {
    case open(content: PanelContent, placement: PanelPlacement)
    case close(panelID: PanelID)
    case move(panelID: PanelID, placement: PanelPlacement)
    case resize(splitID: SplitID, ratios: [Double])
    case navigate(panelID: PanelID, destination: PanelContent)
    case history(panelID: PanelID, action: PanelHistoryAction)
    case selectTab(tabID: WorkspaceTabID)
}

/// Not a security credential — supports feature gating and diagnostics (§7.2).
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
