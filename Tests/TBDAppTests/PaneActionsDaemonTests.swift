import Foundation
import Testing
import TBDShared
@testable import TBDApp

// Tier 1: deterministic, in-process state only (see `PanelTabsTestSupport`).
// Every action is sent through the stubbed `panel.apply` seam; no socket opens.

/// `PaneActions.daemon` (panel tabs spec, "The leaf seam" and "The transcript
/// button"): each leaf gesture becomes one panel operation, the two queries
/// read the app's copy, and the transcript button decides from that copy.
@Suite("PaneActions daemon")
@MainActor
struct PaneActionsDaemonTests {
    private typealias Fixture = PanelTabsFixture

    // MARK: - Fixtures

    private static func side(
        _ panels: [ViewerPanel], active: PanelID?, collapsed: Bool = false
    ) -> SideRegion {
        SideRegion(
            panels: panels, activePanelID: active, recency: panels.map(\.id), collapsed: collapsed)
    }

    /// Seeds the copy with one workspace tab whose primary is `terminalID`.
    private static func seed(
        _ state: AppState, terminalID: UUID = UUID(), side: SideRegion = .empty
    ) -> WorkspaceTabSurface {
        let worktreeID = UUID()
        let tabID = UUID()
        let surface = WorkspaceTabSurface(
            id: tabID, worktreeID: worktreeID,
            primary: .terminal(terminalID: terminalID), side: side, revision: 1)
        state.panelSurfaces = [worktreeID: [tabID: surface]]
        return surface
    }

    private static func actions(
        _ state: AppState, on surface: WorkspaceTabSurface, panelID: PanelID?,
        newPanel: Bool = false
    ) -> PaneActions {
        .daemon(
            appState: state, worktreeID: surface.worktreeID, tabID: surface.id,
            panelID: panelID, newPanelModifier: { newPanel })
    }

    private static func fileOpen(_ path: String, newPanel: Bool) -> PanelOperation {
        .open(content: .file(FileReference(path: path)), newPanel: newPanel)
    }

    // MARK: - The transcript button's decision

    @Test("no transcript panel for the terminal: open")
    func noPanelOpens() {
        let terminalID = UUID()
        #expect(PaneActions.transcriptToggleDecision(side: .empty, terminalID: terminalID) == .open)

        // Another terminal's transcript, and a file, are not this terminal's.
        let other = ViewerPanel(id: UUID(), content: .transcript(terminalID: UUID()))
        let file = ViewerPanel(id: UUID(), content: .file(FileReference(path: "/w/a.md")))
        let region = Self.side([other, file], active: other.id)
        #expect(PaneActions.transcriptToggleDecision(side: region, terminalID: terminalID) == .open)
    }

    @Test("the transcript panel behind another panel: select it")
    func hiddenBehindAnotherSelects() {
        let terminalID = UUID()
        let transcript = ViewerPanel(id: UUID(), content: .transcript(terminalID: terminalID))
        let file = ViewerPanel(id: UUID(), content: .file(FileReference(path: "/w/a.md")))
        let region = Self.side([transcript, file], active: file.id)
        #expect(PaneActions.transcriptToggleDecision(side: region, terminalID: terminalID)
            == .select(transcript.id))
    }

    @Test("the transcript panel in front of a collapsed region: select it")
    func collapsedSelects() {
        let terminalID = UUID()
        let transcript = ViewerPanel(id: UUID(), content: .transcript(terminalID: terminalID))
        let region = Self.side([transcript], active: transcript.id, collapsed: true)
        #expect(PaneActions.transcriptToggleDecision(side: region, terminalID: terminalID)
            == .select(transcript.id))
    }

    @Test("the transcript panel in front and visible: close it")
    func frontAndVisibleCloses() {
        let terminalID = UUID()
        let transcript = ViewerPanel(id: UUID(), content: .transcript(terminalID: terminalID))
        let file = ViewerPanel(id: UUID(), content: .file(FileReference(path: "/w/a.md")))
        let region = Self.side([file, transcript], active: transcript.id)
        #expect(PaneActions.transcriptToggleDecision(side: region, terminalID: terminalID)
            == .close(transcript.id))
    }

    // MARK: - Each action emits its operation

    @Test("history steps send history for the leaf's own panel")
    func historyStepSendsHistory() async {
        await Fixture.withState(panelTabs: true) { state in
            let file = ViewerPanel(id: UUID(), content: .file(FileReference(path: "/w/a.md")))
            let surface = Self.seed(state, side: Self.side([file], active: file.id))
            let envelopes = Fixture.collectEnvelopes(state, replying: surface)
            let actions = Self.actions(state, on: surface, panelID: file.id)
            let content = PaneContent.codeViewer(id: file.id, path: "/w/a.md")

            actions.historyStep(content, .back)
            actions.historyStep(content, .forward)
            actions.historyStep(content, .jump(2))
            await Fixture.drainMainActor()

            let expected: [PanelOperation] = [
                .history(panelID: file.id, action: .back),
                .history(panelID: file.id, action: .forward),
                .history(panelID: file.id, action: .jump(index: 2)),
            ]
            #expect(envelopes.envelopes.map(\.operation) == expected)
            #expect(envelopes.envelopes.allSatisfy { $0.worktreeID == surface.worktreeID })
            #expect(envelopes.envelopes.allSatisfy { $0.tabID == surface.id })
        }
    }

    @Test("a link inside a side panel's document navigates that panel")
    func navigateInPaneSendsNavigate() async {
        await Fixture.withState(panelTabs: true) { state in
            let file = ViewerPanel(id: UUID(), content: .file(FileReference(path: "/w/a.md")))
            let surface = Self.seed(state, side: Self.side([file], active: file.id))
            let envelopes = Fixture.collectEnvelopes(state, replying: surface)

            Self.actions(state, on: surface, panelID: file.id)
                .navigateInPane(.codeViewer(id: file.id, path: "/w/a.md"), "/w/b.md")
            await Fixture.drainMainActor()

            let expected: [PanelOperation] = [
                .navigate(panelID: file.id, destination: .file(FileReference(path: "/w/b.md"))),
            ]
            #expect(envelopes.envelopes.map(\.operation) == expected)
        }
    }

    @Test("a link inside the primary's document opens in the side region")
    func navigateInPrimaryOpensInTheSide() async {
        await Fixture.withState(panelTabs: true) { state in
            let surface = Self.seed(state)
            let envelopes = Fixture.collectEnvelopes(state, replying: surface)

            Self.actions(state, on: surface, panelID: nil)
                .navigateInPane(.codeViewer(id: surface.id, path: "/w/a.md"), "/w/b.md")
            await Fixture.drainMainActor()

            let expected: [PanelOperation] = [Self.fileOpen("/w/b.md", newPanel: false)]
            #expect(envelopes.envelopes.map(\.operation) == expected)
        }
    }

    @Test("every file-opening action sends one open, reusing a panel without the modifier")
    func fileOpeningActionsSendOpen() async {
        await Fixture.withState(panelTabs: true) { state in
            let terminalID = UUID()
            let surface = Self.seed(state, terminalID: terminalID)
            let envelopes = Fixture.collectEnvelopes(state, replying: surface)
            let actions = Self.actions(state, on: surface, panelID: nil, newPanel: false)
            let primary = PaneContent.terminal(terminalID: terminalID)

            actions.routeTerminalFile(terminalID, "/w/a.swift")
            actions.openFilePreview(primary, "/w/b.swift")
            actions.openTranscriptLink(primary, terminalID, .file("/w/c.swift"))
            await Fixture.drainMainActor()

            let expected: [PanelOperation] = [
                Self.fileOpen("/w/a.swift", newPanel: false),
                Self.fileOpen("/w/b.swift", newPanel: false),
                Self.fileOpen("/w/c.swift", newPanel: false),
            ]
            #expect(envelopes.envelopes.map(\.operation) == expected)
        }
    }

    @Test("holding the new-panel modifier asks every file-opening action for a new panel")
    func newPanelModifierAsksForANewPanel() async {
        await Fixture.withState(panelTabs: true) { state in
            let terminalID = UUID()
            let surface = Self.seed(state, terminalID: terminalID)
            let envelopes = Fixture.collectEnvelopes(state, replying: surface)
            let actions = Self.actions(state, on: surface, panelID: nil, newPanel: true)
            let primary = PaneContent.terminal(terminalID: terminalID)

            actions.routeTerminalFile(terminalID, "/w/a.swift")
            actions.openFilePreview(primary, "/w/b.swift")
            actions.openTranscriptLink(primary, terminalID, .file("/w/c.swift"))
            actions.navigateInPane(primary, "/w/d.swift")
            await Fixture.drainMainActor()

            let expected: [PanelOperation] = [
                Self.fileOpen("/w/a.swift", newPanel: true),
                Self.fileOpen("/w/b.swift", newPanel: true),
                Self.fileOpen("/w/c.swift", newPanel: true),
                Self.fileOpen("/w/d.swift", newPanel: true),
            ]
            #expect(envelopes.envelopes.map(\.operation) == expected)
        }
    }

    @Test("close sends close for the leaf's own panel")
    func closeSendsClose() async {
        await Fixture.withState(panelTabs: true) { state in
            let file = ViewerPanel(id: UUID(), content: .file(FileReference(path: "/w/a.md")))
            let surface = Self.seed(state, side: Self.side([file], active: file.id))
            let envelopes = Fixture.collectEnvelopes(state, replying: surface)
            let actions = Self.actions(state, on: surface, panelID: file.id)
            let content = PaneContent.codeViewer(id: file.id, path: "/w/a.md")

            #expect(actions.canClose(content))
            actions.close(content)
            await Fixture.drainMainActor()

            let expected: [PanelOperation] = [.close(panelID: file.id)]
            #expect(envelopes.envelopes.map(\.operation) == expected)
        }
    }

    @Test("a note panel's actions name its panel ID, not the note ID its content carries")
    func notePanelActionsCarryThePanelID() async {
        await Fixture.withState(panelTabs: true) { state in
            let noteID = UUID()
            let note = ViewerPanel(id: UUID(), content: .note(noteID: noteID))
            let surface = Self.seed(state, side: Self.side([note], active: note.id))
            let envelopes = Fixture.collectEnvelopes(state, replying: surface)
            let actions = Self.actions(state, on: surface, panelID: note.id)
            // The leaf's content: its `paneID` is the note's ID.
            let content = PaneContent.note(noteID: noteID)
            #expect(content.paneID == noteID, "precondition: a note's pane ID is the note's own ID")

            actions.historyStep(content, .back)
            actions.close(content)
            await Fixture.drainMainActor()

            let expected: [PanelOperation] = [
                .history(panelID: note.id, action: .back),
                .close(panelID: note.id),
            ]
            #expect(envelopes.envelopes.map(\.operation) == expected)
            #expect(actions.history(content) == note.history.paneHistory(panelID: note.id))
        }
    }

    @Test("the primary cannot close, has no history, and sends nothing for either")
    func primaryCannotClose() async {
        await Fixture.withState(panelTabs: true) { state in
            let terminalID = UUID()
            let surface = Self.seed(state, terminalID: terminalID)
            let envelopes = Fixture.collectEnvelopes(state, replying: surface)
            let actions = Self.actions(state, on: surface, panelID: nil)
            let primary = PaneContent.terminal(terminalID: terminalID)

            #expect(!actions.canClose(primary))
            #expect(actions.history(primary) == nil)
            actions.close(primary)
            actions.historyStep(primary, .back)
            await Fixture.drainMainActor()

            #expect(envelopes.envelopes.isEmpty, "observed \(envelopes.envelopes.map(\.operation))")
        }
    }

    @Test("a side panel's history is its own, read from the copy")
    func historyComesFromTheCopy() async {
        await Fixture.withState(panelTabs: true) { state in
            let first = PanelContent.file(FileReference(path: "/w/a.md"))
            let second = PanelContent.file(FileReference(path: "/w/b.md"))
            let history: PanelHistory = {
                var built = PanelHistory.seeded(with: first)
                built.recordReplacement(outgoing: first, incoming: second)
                return built
            }()
            let file = ViewerPanel(id: UUID(), history: history)
            let surface = Self.seed(state, side: Self.side([file], active: file.id))
            let content = PaneContent.codeViewer(id: file.id, path: "/w/b.md")

            let shown = Self.actions(state, on: surface, panelID: file.id).history(content)
            #expect(shown == history.paneHistory(panelID: file.id))
            #expect(shown?.entries.count == 2)
            #expect(shown?.canGoBack == true)

            // A panel the copy no longer holds has nothing to show.
            #expect(Self.actions(state, on: surface, panelID: UUID()).history(content) == nil)
        }
    }

    @Test("the transcript button is on whenever the terminal's transcript panel exists")
    func isTranscriptOpenReadsTheCopy() async {
        await Fixture.withState(panelTabs: true) { state in
            let terminalID = UUID()
            let transcript = ViewerPanel(id: UUID(), content: .transcript(terminalID: terminalID))
            let file = ViewerPanel(id: UUID(), content: .file(FileReference(path: "/w/a.md")))
            // Behind another panel, in a collapsed region: still on.
            let surface = Self.seed(
                state, terminalID: terminalID,
                side: Self.side([transcript, file], active: file.id, collapsed: true))
            let actions = Self.actions(state, on: surface, panelID: nil)

            #expect(actions.isTranscriptOpen(terminalID))
            #expect(!actions.isTranscriptOpen(UUID()))
        }
    }

    @Test("the transcript button on a hidden transcript sends select")
    func toggleOnAHiddenTranscriptSendsSelect() async {
        await Fixture.withState(panelTabs: true) { state in
            let terminalID = UUID()
            let transcript = ViewerPanel(id: UUID(), content: .transcript(terminalID: terminalID))
            let file = ViewerPanel(id: UUID(), content: .file(FileReference(path: "/w/a.md")))
            let surface = Self.seed(
                state, terminalID: terminalID, side: Self.side([transcript, file], active: file.id))
            let envelopes = Fixture.collectEnvelopes(state, replying: surface)

            Self.actions(state, on: surface, panelID: nil)
                .toggleTranscript(.terminal(terminalID: terminalID), terminalID)
            await Fixture.drainMainActor()

            let expected: [PanelOperation] = [.select(panelID: transcript.id)]
            #expect(envelopes.envelopes.map(\.operation) == expected)
        }
    }

    // MARK: - The transcript button across a round trip

    @Test("two toggles before any reply is adopted send two opens; the reducer keeps one panel")
    func toggleBeforeReplyAdoptedSendsOpenTwice() async {
        await Fixture.withState(panelTabs: true) { state in
            let terminalID = UUID()
            let surface = Self.seed(state, terminalID: terminalID)
            let envelopes = Fixture.collectEnvelopes(state, replying: surface)
            let actions = Self.actions(state, on: surface, panelID: nil)
            let primary = PaneContent.terminal(terminalID: terminalID)

            // Both clicks read the copy before either apply has run.
            actions.toggleTranscript(primary, terminalID)
            actions.toggleTranscript(primary, terminalID)
            await Fixture.drainMainActor()

            let open = PanelOperation.open(content: .transcript(terminalID: terminalID), newPanel: false)
            let expected: [PanelOperation] = [open, open]
            #expect(envelopes.envelopes.map(\.operation) == expected)
        }
    }

    @Test("once the open reply is adopted, the next toggle closes the transcript")
    func toggleAfterOpenAdoptedCloses() async {
        await Fixture.withState(panelTabs: true) { state in
            let terminalID = UUID()
            let surface = Self.seed(state, terminalID: terminalID)
            let transcriptPanelID = UUID()
            let opened = WorkspaceTabSurface(
                id: surface.id, worktreeID: surface.worktreeID,
                primary: .terminal(terminalID: terminalID),
                side: Self.side(
                    [ViewerPanel(id: transcriptPanelID, content: .transcript(terminalID: terminalID))],
                    active: transcriptPanelID),
                revision: 2)
            let envelopes = Fixture.collectEnvelopes(state, replying: opened)
            let actions = Self.actions(state, on: surface, panelID: nil)
            let primary = PaneContent.terminal(terminalID: terminalID)

            actions.toggleTranscript(primary, terminalID)
            await Fixture.drainMainActor()
            #expect(state.panelSurface(worktreeID: surface.worktreeID, tabID: surface.id) == opened,
                    "precondition: the open reply was adopted")
            #expect(actions.isTranscriptOpen(terminalID))

            actions.toggleTranscript(primary, terminalID)
            await Fixture.drainMainActor()

            let expected: [PanelOperation] = [
                .open(content: .transcript(terminalID: terminalID), newPanel: false),
                .close(panelID: transcriptPanelID),
            ]
            #expect(envelopes.envelopes.map(\.operation) == expected)
        }
    }
}
