import Foundation
import os

private let logger = Logger(subsystem: "com.tbd.app", category: "ViewerRouting")

// MARK: - ViewerRouteResult

/// Outcome of a content-navigation gesture (file click, transcript toggle).
///
/// `replaced` is non-nil when the gesture reused an existing viewer-class
/// "slot" pane in place — the call site pushes `outgoing` onto that slot's
/// `PaneHistory`. `removedPaneID` is non-nil when the gesture closed a pane
/// (transcript toggle-off) — the call site prunes that pane's history.
struct ViewerRouteResult: Equatable {
    struct Replacement: Equatable {
        let paneID: UUID
        let outgoing: PaneContent
        let incoming: PaneContent
    }

    let layout: LayoutNode
    var replaced: Replacement? = nil
    var removedPaneID: UUID? = nil
}

// MARK: - routeFileClick

/// Decides where a terminal-link click should land.
///
/// Reuse priority:
/// 1. An existing `.codeViewer` pane — swap its `path`.
/// 2. Any other viewer-class pane (`.liveTranscript`, `.webview`) — replace
///    its content with a code viewer.
/// 3. No viewer-class pane — split horizontally off the clicked terminal.
///
/// In-place replacements preserve the pane's `paneID` so SwiftUI keeps the
/// view identity stable, including any `@StateObject` it owns — notably the
/// `FileWatcher` — and so the slot's `PaneHistory` stays keyed to one UUID.
func routeFileClick(into layout: LayoutNode, terminalID: UUID, path: String) -> ViewerRouteResult {
    let isCodeViewer: (PaneContent) -> Bool = { content in
        if case .codeViewer = content { return true } else { return false }
    }

    if let outgoing = layout.firstPaneContent(where: isCodeViewer)
        ?? layout.firstPaneContent(where: \.isViewerClass)
    {
        let slotID = outgoing.paneID
        let incoming = PaneContent.codeViewer(id: slotID, path: path)
        if let updated = layout.replacingContent(at: slotID, with: incoming) {
            logger.debug("routeFileClick[swap]: slotID=\(slotID, privacy: .public) path=\(path, privacy: .public)")
            return ViewerRouteResult(
                layout: updated,
                replaced: .init(paneID: slotID, outgoing: outgoing, incoming: incoming)
            )
        }
    }

    logger.debug("routeFileClick[split]: terminalID=\(terminalID, privacy: .public) path=\(path, privacy: .public)")
    return ViewerRouteResult(layout: layout.splitPane(
        id: terminalID,
        direction: .horizontal,
        newContent: .codeViewer(id: UUID(), path: path)
    ))
}
