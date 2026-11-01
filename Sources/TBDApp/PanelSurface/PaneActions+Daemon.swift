import AppKit
import TBDShared

// MARK: - A panel toggle's decision

/// What a panel toggle sends on the daemon path: the transcript button,
/// which sits at the window's right edge while the transcript view setting is
/// on and acts while a Claude terminal's tab is selected (panel tabs spec,
/// "The transcript button"), and ⌘⇧E for the Changes list (side panel notes
/// and Changes spec, "⌘⇧E").
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

// MARK: - The Notes button's decision

/// What the Notes button sends, for the worktree's first note: the oldest
/// by `createdAt` (`PaneActions.notesToggleDecision`). The button sits at the
/// window's right edge, after the transcript button, on every tab that
/// renders on the daemon path, and follows the transcript button's three
/// states. Nothing opens a note panel by itself.
enum NotesToggleDecision: Equatable {
    /// The worktree's notes are listed and there are none, and the tab shows
    /// no note panel: create one titled `createdNoteTitle`, then open it.
    case create
    /// The worktree's notes have not loaded yet and the tab shows no note
    /// panel: the button draws disabled and a press sends nothing, so it
    /// never creates a note beside one the app has not listed yet.
    case unavailable
    /// The first note has no worktree panel: open one, which comes to the
    /// front in this tab and expands its region.
    case open(noteID: UUID)
    /// The first note's panel exists but another panel is in front, or the
    /// region is collapsed: bring it to the front, which also expands the
    /// region.
    case select(PanelID)
    /// The first note's panel is in front and visible: close it. The close
    /// keeps the note.
    case close(PanelID)

    /// The title of the note the button creates in a worktree with none.
    static let createdNoteTitle = "Notes"

    /// The operation the decision sends; nil for `create`, which sends its
    /// `open` once the note exists (`AppState.createNote`), and for
    /// `unavailable`, which sends nothing.
    var operation: PanelOperation? {
        switch self {
        case .create, .unavailable:
            return nil
        case .open(let noteID):
            return .open(content: .note(noteID: noteID), newPanel: false)
        case .select(let panelID):
            return .select(panelID: panelID)
        case .close(let panelID):
            return .close(panelID: panelID)
        }
    }

    /// Whether the button draws on: the first note is in front of a visible
    /// region, so a press closes it.
    var isOn: Bool {
        if case .close = self { return true }
        return false
    }

    /// Whether a press can act: false only while the button is
    /// `unavailable`.
    var isEnabled: Bool { self != .unavailable }
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
    /// tab the copy holds no surface for yet; close when the Changes panel is
    /// in front of a visible region; otherwise select it, which also expands
    /// a collapsed region. Visibility
    /// counts the worktree's panels (`isSideVisible`), because the Changes
    /// panel is one of them. A tab that renders legacy never reaches this
    /// (`AppState.toggleChangesPanel`).
    static func changesToggleDecision(surface: WorkspaceTabSurface?) -> PanelToggleDecision {
        guard let surface, let panel = surface.worktreePanel(showing: .changes) else { return .open }
        return surface.side.activePanelID == panel.id && surface.isSideVisible
            ? .close(panel.id) : .select(panel.id)
    }

    /// The Notes button's operation for one workspace tab on the daemon path,
    /// decided from the app's copy as `changesToggleDecision` is, for the
    /// worktree's first note. `notes` is the worktree's entry in
    /// `AppState.notes`: nil until its first `note.list` answer has landed,
    /// then the listed notes, empty included.
    ///
    /// With notes listed, the first note is the oldest by `createdAt`,
    /// whatever order the list is in. Open it when it has no worktree panel,
    /// or when `surface` is nil — a tab the copy holds no surface for yet;
    /// close its panel when that is in front of a visible region; otherwise
    /// select it, which also expands a collapsed region.
    ///
    /// With no note listed — none loaded yet, or none at all — the tab's
    /// first note panel in strip order stands in for the first note, and is
    /// selected or closed the same way: a note the tab already shows is a
    /// note the worktree has. Without one, a worktree whose notes are listed
    /// and empty creates a note, and one whose notes have not loaded is
    /// `unavailable`, so a press before the first notes poll never creates a
    /// second note beside one not yet listed.
    ///
    /// One pass over the worktree's notes (`min(by:)`, no sort), so it is
    /// cheap enough for the tab bar to decide the button's state as it draws.
    static func notesToggleDecision(
        surface: WorkspaceTabSurface?, notes: [NoteSummary]?
    ) -> NotesToggleDecision {
        if let first = notes?.min(by: { $0.createdAt < $1.createdAt }) {
            guard let surface, let panel = surface.worktreePanel(showing: .note(noteID: first.id)) else {
                return .open(noteID: first.id)
            }
            return notesToggle(panel, in: surface)
        }
        let firstNotePanel = surface?.worktreePanels.first { panel in
            if case .note = panel.content { return true }
            return false
        }
        if let surface, let firstNotePanel {
            return notesToggle(firstNotePanel, in: surface)
        }
        return notes == nil ? .unavailable : .create
    }

    /// Closes `panel` when it is in front of a visible region, and selects
    /// it otherwise.
    private static func notesToggle(
        _ panel: WorktreePanel, in surface: WorkspaceTabSurface
    ) -> NotesToggleDecision {
        surface.side.activePanelID == panel.id && surface.isSideVisible
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
