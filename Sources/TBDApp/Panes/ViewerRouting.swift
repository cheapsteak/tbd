import Foundation

/// Decides where a terminal-link click should land.
///
/// If the tab's layout already contains a `.codeViewer` pane, this returns
/// the layout with that pane's `path` swapped (preserving the pane's `paneID`
/// so SwiftUI keeps the view identity stable, including any `@StateObject`
/// it owns — notably the `FileWatcher`).
///
/// Otherwise it falls back to splitting horizontally from the clicked terminal,
/// matching the original behavior at `PanePlaceholder.swift:243-245`.
func routeFileClick(into layout: LayoutNode, terminalID: UUID, path: String) -> LayoutNode {
    let isViewer: (PaneContent) -> Bool = { content in
        if case .codeViewer = content { return true } else { return false }
    }

    if let viewerID = layout.firstPaneID(where: isViewer),
       let updated = layout.replacingContent(
           at: viewerID,
           with: .codeViewer(id: viewerID, path: path)
       )
    {
        return updated
    }

    return layout.splitPane(
        id: terminalID,
        direction: .horizontal,
        newContent: .codeViewer(id: UUID(), path: path)
    )
}
