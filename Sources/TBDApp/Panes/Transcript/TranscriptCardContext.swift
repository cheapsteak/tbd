import SwiftUI

/// Closures + state captured at document-build time and threaded into each
/// embedded card attachment (the cards live inside an NSAttributedString, not
/// the SwiftUI environment tree, so their dependencies must be injected here). (#129)
@MainActor
struct TranscriptCardContext {
    let terminalID: UUID?
    let openTranscriptOverlay: (@MainActor (String) -> Void)?
    let toggleActivityGroup: (@MainActor (String, Bool) -> Void)?
    let appState: AppState?
    /// Resolves a path token against the worktree root. Nil in contexts with no
    /// worktree, where only web URLs become links.
    let linkResolver: TranscriptPathResolver?
    /// Routes a clicked transcript link. Nil leaves links inert.
    let onLinkClicked: ((TranscriptLinkTarget) -> Void)?

    init(
        terminalID: UUID?,
        openTranscriptOverlay: (@MainActor (String) -> Void)?,
        toggleActivityGroup: (@MainActor (String, Bool) -> Void)? = nil,
        appState: AppState?,
        linkResolver: TranscriptPathResolver?,
        onLinkClicked: ((TranscriptLinkTarget) -> Void)?
    ) {
        self.terminalID = terminalID
        self.openTranscriptOverlay = openTranscriptOverlay
        self.toggleActivityGroup = toggleActivityGroup
        self.appState = appState
        self.linkResolver = linkResolver
        self.onLinkClicked = onLinkClicked
    }
}
