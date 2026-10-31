import Foundation

public enum PanelSurfaceViolation: Equatable, Sendable {
    /// Two panels in the side region share this ID.
    case duplicatePanelID(PanelID)
    /// `activePanelID` names no panel in a region that has panels.
    case activePanelMissing(PanelID)
    /// The region has no panels but names an active one.
    case activePanelWithoutPanels
    /// The region has panels but none is active.
    case noActivePanel
    /// `recency` is not a permutation of the panel IDs.
    case recencyMismatch
    /// The panel's history is empty or its cursor is out of range.
    case malformedHistory(PanelID)
    /// The panel's history holds more than `MRUHistory.maxEntries` entries.
    case historyOverCap(PanelID)
    /// The panel's history holds content of more than one kind.
    case historyMixesKinds(PanelID)
    /// More than one panel currently shows this terminal's transcript.
    case duplicateTranscriptView(terminalID: UUID)
    /// `width` is not finite or lies outside `SideRegion.widthRange`.
    case widthOutOfRange(Double)
}

/// Structural invariants from the panel tabs spec ("The model"). Resource
/// checks (a note or terminal belongs to an allowed worktree) need daemon
/// context and live in the coordinator, not here.
public enum PanelSurfaceValidator {
    public static func violations(in surface: WorkspaceTabSurface) -> [PanelSurfaceViolation] {
        let side = surface.side
        let panelIDs = side.panels.map(\.id)
        var found: [PanelSurfaceViolation] = []

        var seenPanels = Set<PanelID>()
        for id in panelIDs where !seenPanels.insert(id).inserted {
            found.append(.duplicatePanelID(id))
        }

        if let active = side.activePanelID {
            if side.panels.isEmpty {
                found.append(.activePanelWithoutPanels)
            } else if side.panel(id: active) == nil {
                found.append(.activePanelMissing(active))
            }
        } else if !side.panels.isEmpty {
            found.append(.noActivePanel)
        }

        // A multiset comparison, so duplicate panel IDs are reported once, as
        // duplicates, and not again as a recency mismatch.
        if occurrences(of: side.recency) != occurrences(of: panelIDs) {
            found.append(.recencyMismatch)
        }

        for panel in side.panels {
            let history = panel.history
            guard history.isWellFormed, !history.entries.isEmpty else {
                found.append(.malformedHistory(panel.id))
                continue
            }
            if history.entries.count > PanelHistory.maxEntries {
                found.append(.historyOverCap(panel.id))
            }
            if Set(history.entries.map(\.kind)).count > 1 {
                found.append(.historyMixesKinds(panel.id))
            }
        }

        // Views are what panels show now; a transcript held only further back
        // in a history is not a view.
        var shownTranscripts = Set<UUID>()
        for panel in side.panels {
            guard case .transcript(let terminalID)? = panel.content else { continue }
            if !shownTranscripts.insert(terminalID).inserted {
                found.append(.duplicateTranscriptView(terminalID: terminalID))
            }
        }

        if !(side.width.isFinite && SideRegion.widthRange.contains(side.width)) {
            found.append(.widthOutOfRange(side.width))
        }

        return found
    }

    private static func occurrences(of ids: [PanelID]) -> [PanelID: Int] {
        ids.reduce(into: [:]) { counts, id in counts[id, default: 0] += 1 }
    }
}
