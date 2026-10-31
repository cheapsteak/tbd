import AppKit
import TBDShared

// MARK: - The transcript button's decision

/// What the transcript button in a primary terminal's header sends on the
/// daemon path (panel tabs spec, "The transcript button").
enum TranscriptToggleDecision: Equatable {
    /// No transcript panel for the terminal: open one.
    case open
    /// The panel exists but another panel is in front, or the region is
    /// collapsed: bring it to the front, which also expands the region.
    case select(PanelID)
    /// The panel is in front and visible: close it.
    case close(PanelID)
}

extension PaneHistoryStep {
    /// The same step in the daemon's operation vocabulary.
    var panelHistoryAction: PanelHistoryAction {
        switch self {
        case .back: return .back
        case .forward: return .forward
        case .jump(let index): return .jump(index: index)
        }
    }
}

// MARK: - Daemon action set

extension PaneActions {
    /// The transcript button's operation, decided from the app's copy of the
    /// side region. Acting on the copy means an agent mutation landing between
    /// the read and the click can make one click act on a stale picture; the
    /// reply corrects the copy, and the next click acts on the truth.
    static func transcriptToggleDecision(side: SideRegion, terminalID: UUID) -> TranscriptToggleDecision {
        let transcript = PanelContent.transcript(terminalID: terminalID)
        guard let panel = side.panels.first(where: { $0.content == transcript }) else { return .open }
        return side.activePanelID == panel.id && side.isVisible ? .close(panel.id) : .select(panel.id)
    }

    /// The daemon-owned surface: every structural change a leaf asks for
    /// becomes one `PanelOperation` through `AppState.applyPanelOperation`, and
    /// the leaf's two questions (is a transcript open, which history to show)
    /// are answered from the app's copy as it is when they are asked.
    ///
    /// Built per leaf. `panelID` is the leaf's side-region panel, or nil for
    /// the workspace tab's primary. It is passed in, never read back from the
    /// leaf's content: a note's `content.paneID` is the note's own ID, not its
    /// panel's, so every closure ignores the content it is handed where a
    /// panel ID is needed.
    ///
    /// - Opening a file — a command-click in a terminal, a preview raised from
    ///   a transcript, a file link in a transcript — is one `open`, placed by
    ///   the daemon's reuse rule. `newPanelModifier` is read as the action
    ///   runs; holding it asks for a new panel instead of reusing one.
    /// - A link inside a rendered document navigates its own panel. The
    ///   primary has no operation that repoints it, so a link inside a
    ///   primary document opens in the side region instead.
    /// - The primary has no history and cannot be closed. Closing a note
    ///   panel closes the panel and keeps the note.
    /// - Choosing the entry already shown in a history palette sends nothing,
    ///   as the legacy path does nothing: the reducer refuses a jump to the
    ///   cursor. Back and forward at the ends need no such check, because
    ///   their chevrons are disabled there.
    @MainActor
    static func daemon(
        appState: AppState,
        worktreeID: UUID,
        tabID: UUID,
        panelID: PanelID?,
        newPanelModifier: @escaping @MainActor () -> Bool = { NSEvent.modifierFlags.contains(.shift) }
    ) -> PaneActions {
        let send: @MainActor (PanelOperation) -> Void = { operation in
            appState.sendPanelOperation(worktreeID: worktreeID, tabID: tabID, operation)
        }
        let currentSide: @MainActor () -> SideRegion = {
            appState.panelSurface(worktreeID: worktreeID, tabID: tabID)?.side ?? .empty
        }
        let openFileInSide: @MainActor (String) -> Void = { path in
            send(.open(content: .file(FileReference(path: path)), newPanel: newPanelModifier()))
        }
        return PaneActions(
            historyStep: { _, step in
                guard let panelID else { return }
                if case .jump(let index) = step,
                   index == currentSide().panel(id: panelID)?.history.cursor {
                    return
                }
                send(.history(panelID: panelID, action: step.panelHistoryAction))
            },
            navigateInPane: { _, path in
                guard let panelID else {
                    openFileInSide(path)
                    return
                }
                send(.navigate(panelID: panelID, destination: .file(FileReference(path: path))))
            },
            routeTerminalFile: { _, path in
                openFileInSide(path)
            },
            openFilePreview: { _, path in
                openFileInSide(path)
            },
            openTranscriptLink: { _, _, target in
                switch TranscriptLinkDestination.daemon(target, newPanel: newPanelModifier()) {
                case .apply(let operation):
                    send(operation)
                case .openInBrowser(let url):
                    NSWorkspace.shared.open(url)
                }
            },
            close: { _ in
                guard let panelID else { return }
                send(.close(panelID: panelID))
            },
            toggleTranscript: { _, terminalID in
                switch PaneActions.transcriptToggleDecision(side: currentSide(), terminalID: terminalID) {
                case .open:
                    send(.open(content: .transcript(terminalID: terminalID), newPanel: false))
                case .select(let transcriptPanelID):
                    send(.select(panelID: transcriptPanelID))
                case .close(let transcriptPanelID):
                    send(.close(panelID: transcriptPanelID))
                }
            },
            isTranscriptOpen: { terminalID in
                let transcript = PanelContent.transcript(terminalID: terminalID)
                return currentSide().panels.contains { $0.content == transcript }
            },
            history: { _ in
                guard let panelID else { return nil }
                return currentSide().panel(id: panelID)?.history.paneHistory(panelID: panelID)
            },
            canClose: { _ in
                panelID != nil
            }
        )
    }
}
