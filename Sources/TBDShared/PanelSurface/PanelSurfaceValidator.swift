import Foundation

public enum PanelSurfaceViolation: Equatable, Sendable {
    case primaryCount(Int)
    case duplicatePanelID(PanelID)
    case duplicateSplitID(SplitID)
    case degenerateSplit(SplitID)
    case ratioCountMismatch(SplitID)
    case ratioBelowMinimum(SplitID)
    case ratioSumInvalid(SplitID)
    case malformedHistory(PanelID)
    case historyContentMismatch(PanelID)
}

/// Structural invariants from Spec C §5.5. Resource-existence checks
/// (notes/terminals belong to an allowed worktree) need daemon context and
/// live in the Phase 2 coordinator, not here.
public enum PanelSurfaceValidator {
    public static let minShare = 0.1
    private static let ratioSumTolerance = 0.001

    public static func violations(in surface: WorkspaceTabSurface) -> [PanelSurfaceViolation] {
        var found: [PanelSurfaceViolation] = []

        let primaries = surface.layout.primaryCount
        if primaries != 1 { found.append(.primaryCount(primaries)) }

        var seenPanels = Set<PanelID>()
        for id in surface.layout.allPanelIDs where !seenPanels.insert(id).inserted {
            found.append(.duplicatePanelID(id))
        }
        var seenSplits = Set<SplitID>()
        for id in surface.layout.allSplitIDs where !seenSplits.insert(id).inserted {
            found.append(.duplicateSplitID(id))
        }

        appendSplitViolations(of: surface.layout, to: &found)
        return found
    }

    public static func violations(in state: PanelSurfaceState) -> [PanelSurfaceViolation] {
        var found = violations(in: state.surface)
        for (panelID, history) in state.histories {
            if !history.isWellFormed {
                found.append(.malformedHistory(panelID))
                continue
            }
            if let slot = state.surface.layout.panelSlot(id: panelID),
               !history.entries.isEmpty,
               history.entries[history.cursor] != slot.content {
                found.append(.historyContentMismatch(panelID))
            }
        }
        return found
    }

    private static func appendSplitViolations(
        of node: PanelLayoutNode, to found: inout [PanelSurfaceViolation]
    ) {
        guard case .split(let split) = node else { return }
        if split.children.count < 2 {
            found.append(.degenerateSplit(split.id))
        }
        if split.ratios.count != split.children.count {
            found.append(.ratioCountMismatch(split.id))
        } else if split.children.count >= 2 {
            if split.ratios.contains(where: { $0 < minShare - ratioSumTolerance }) {
                found.append(.ratioBelowMinimum(split.id))
            }
            if abs(split.ratios.reduce(0, +) - 1.0) > ratioSumTolerance {
                found.append(.ratioSumInvalid(split.id))
            }
        }
        for child in split.children {
            appendSplitViolations(of: child, to: &found)
        }
    }
}
