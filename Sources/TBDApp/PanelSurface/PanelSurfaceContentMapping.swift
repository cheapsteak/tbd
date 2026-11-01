import Foundation
import TBDShared

// Content-only bridges from the daemon surface's model to the legacy
// `PaneContent` that the shared leaf view, `PanePlaceholder`, renders (panel
// tabs spec, "The leaf seam"). They map one leaf's content and nothing else:
// nothing here rebuilds a `LayoutNode`, and none of it is used to.

extension PanelContent {
    /// This panel content as the leaf view renders it. The panel's own ID is
    /// the legacy pane identity of the file, web and transcript cases. A note
    /// keeps its note ID, because that is what the note case carries — so a
    /// leaf's `content.paneID` is not its panel ID, and the daemon action set
    /// is handed the panel ID separately. Nil for the Changes list, which has
    /// no leaf form: the side region draws it itself.
    func paneContent(panelID: PanelID) -> PaneContent? {
        switch self {
        case .file(let reference):
            return .codeViewer(id: panelID, path: reference.path)
        case .web(let url):
            return .webview(id: panelID, url: url)
        case .transcript(let terminalID):
            return .liveTranscript(id: panelID, terminalID: terminalID)
        case .note(let noteID):
            return .note(noteID: noteID)
        case .changes:
            return nil
        }
    }
}

extension MRUHistory where Element == PanelContent {
    /// A panel's history as the leaf's chevrons and history palette show it.
    /// Order and cursor are kept, so an index the palette picks is the index
    /// the daemon's `jump` takes. Nil when an entry has no leaf form, which
    /// only Changes content has and no tab's own panel holds
    /// (`PanelSurfaceValidator`).
    func paneHistory(panelID: PanelID) -> PaneHistory? {
        let mapped = map { $0.paneContent(panelID: panelID) }
        guard !mapped.entries.contains(nil) else { return nil }
        return mapped.map { $0! }
    }
}
