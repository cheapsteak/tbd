import AppKit
import TBDShared

// MARK: - A panel toggle's decision

/// What a panel toggle sends on the daemon path: the transcript button,
/// which sits at the trailing end of the workspace tab bar while a Claude
/// terminal's tab is selected and the transcript view setting is on (panel
/// tabs spec, "The transcript button"), and ⌘⇧E for the Changes list (side
/// panel notes and Changes spec, "⌘⇧E").
enum PanelToggleDecision: Equatable {
    /// No panel shows the content: open one.
    case open
    /// The panel exists but another panel is in front, or the region is
    /// collapsed: bring it to the front, which also expands the region.
    case select(PanelID)
    /// The panel is in front and visible: close it.
    case close(PanelID)

    /// The operation the decision sends, where `content` is what an `open`
    /// shows.
    func operation(opening content: PanelContent) -> PanelOperation {
        switch self {
        case .open:
            return .open(content: content, newPanel: false)
        case .select(let panelID):
            return .select(panelID: panelID)
        case .close(let panelID):
            return .close(panelID: panelID)
        }
    }
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
    static func transcriptToggleDecision(side: SideRegion, terminalID: UUID) -> PanelToggleDecision {
        let transcript = PanelContent.transcript(terminalID: terminalID)
        guard let panel = side.panels.first(where: { $0.content == transcript }) else { return .open }
        return side.activePanelID == panel.id && side.isVisible ? .close(panel.id) : .select(panel.id)
    }

    /// ⌘⇧E's operation for one workspace tab on the daemon path, decided from
    /// the app's copy of its surface as `transcriptToggleDecision` is: open
    /// when the worktree has no Changes panel, or when `surface` is nil — a
    /// tab the copy holds no surface for yet, where ◫ opens Changes too;
    /// close when the Changes panel is in front of a visible region;
    /// otherwise select it, which also expands a collapsed region. Visibility
    /// counts the worktree's panels (`isSideVisible`), because the Changes
    /// panel is one of them. A tab that renders legacy never reaches this
    /// (`AppState.toggleChangesPanel`).
    static func changesToggleDecision(surface: WorkspaceTabSurface?) -> PanelToggleDecision {
        guard let surface, let panel = surface.worktreePanel(showing: .changes) else { return .open }
        return surface.side.activePanelID == panel.id && surface.isSideVisible
            ? .close(panel.id) : .select(panel.id)
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
                let decision = PaneActions.transcriptToggleDecision(side: currentSide(), terminalID: terminalID)
                send(decision.operation(opening: .transcript(terminalID: terminalID)))
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
