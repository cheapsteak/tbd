import Foundation

public enum PanelSurfaceViolation: Equatable, Sendable {
    /// Two panels share this ID: two of the tab's own, two worktree panels,
    /// or one of each.
    case duplicatePanelID(PanelID)
    /// `activePanelID` names neither one of the tab's own panels nor a
    /// worktree panel, while there is a panel.
    case activePanelMissing(PanelID)
    /// There is no panel of either kind, but one is named active.
    case activePanelWithoutPanels
    /// There is a panel of either kind, but none is active.
    case noActivePanel
    /// `recency` is not a permutation of the tab's own panel IDs.
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
    /// One of the tab's own panels holds note or Changes content in its
    /// history, which only a worktree panel may show.
    case tabPanelShowsWorktreeContent(PanelID)
    /// More than one worktree panel shows this note.
    case duplicateNotePanel(noteID: UUID)
    /// More than one worktree panel shows the Changes list.
    case duplicateChangesPanel
}

/// Structural invariants from the panel tabs spec ("The model") and the side
/// panel notes spec ("The model"). Resource checks (a note or terminal
/// belongs to an allowed worktree) need daemon context and live in the
/// coordinator, not here.
public enum PanelSurfaceValidator {
    public static func violations(in surface: WorkspaceTabSurface) -> [PanelSurfaceViolation] {
        let side = surface.side
        let panelIDs = side.panels.map(\.id)
        let worktreePanelIDs = surface.worktreePanels.map(\.id)
        var found: [PanelSurfaceViolation] = []

        var seenPanels = Set<PanelID>()
        for id in panelIDs + worktreePanelIDs where !seenPanels.insert(id).inserted {
            found.append(.duplicatePanelID(id))
        }

        if let active = side.activePanelID {
            if !surface.hasPanels {
                found.append(.activePanelWithoutPanels)
            } else if side.panel(id: active) == nil, surface.worktreePanel(id: active) == nil {
                found.append(.activePanelMissing(active))
            }
        } else if surface.hasPanels {
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
            if history.entries.contains(where: { WorktreePanelContent($0) != nil }) {
                found.append(.tabPanelShowsWorktreeContent(panel.id))
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

        var shownNotes = Set<UUID>()
        var showsChanges = false
        for panel in surface.worktreePanels {
            switch panel.content {
            case .note(let noteID):
                if !shownNotes.insert(noteID).inserted {
                    found.append(.duplicateNotePanel(noteID: noteID))
                }
            case .changes:
                if showsChanges {
                    found.append(.duplicateChangesPanel)
                }
                showsChanges = true
            }
        }

        return found
    }

    private static func occurrences(of ids: [PanelID]) -> [PanelID: Int] {
        ids.reduce(into: [:]) { counts, id in counts[id, default: 0] += 1 }
    }
}
