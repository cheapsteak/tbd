import SwiftUI

/// Closures + state captured at document-build time and threaded into each
/// embedded card attachment (the cards live inside an NSAttributedString, not
/// the SwiftUI environment tree, so their dependencies must be injected here). (#129)
@MainActor
struct TranscriptCardContext {
    let terminalID: UUID?
    let openTranscriptOverlay: (@MainActor (String) -> Void)?
    let toggleActivityGroup: (@MainActor (String) -> Void)?
    let appState: AppState?

    init(
        terminalID: UUID?,
        openTranscriptOverlay: (@MainActor (String) -> Void)?,
        toggleActivityGroup: (@MainActor (String) -> Void)? = nil,
        appState: AppState?
    ) {
        self.terminalID = terminalID
        self.openTranscriptOverlay = openTranscriptOverlay
        self.toggleActivityGroup = toggleActivityGroup
        self.appState = appState
    }
}
