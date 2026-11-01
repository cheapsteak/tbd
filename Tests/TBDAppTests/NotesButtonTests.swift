import Foundation
import Testing
import TBDShared
@testable import TBDApp

// Tier 1: deterministic, in-process state only (see `PanelTabsTestSupport`).
// `note.create`, `note.delete` and `panel.apply` go through injected seams, so
// no socket opens, and every `AppState` is on a throwaway defaults suite.

/// The Notes button at the window's right edge: nothing opens a note panel by
/// itself, so the button shows, brings forward or closes the worktree's first
/// note — the oldest by `createdAt` — with the transcript button's three
/// states, and in a worktree whose notes are listed and empty creates one
/// titled "Notes" and opens it. Before the worktree's notes have loaded it
/// toggles the tab's first note panel, or, with none, is disabled and creates
/// nothing. Its close keeps the note.
@Suite("Notes button")
@MainActor
struct NotesButtonTests {
    private typealias Fixture = PanelTabsFixture

    // MARK: - Fixtures

    private static func surface(
        tabID: UUID = UUID(), worktreeID: UUID = UUID(),
        worktreePanels: [WorktreePanel], active: PanelID?, collapsed: Bool = false
    ) -> WorkspaceTabSurface {
        WorkspaceTabSurface(
            id: tabID, worktreeID: worktreeID,
            primary: .terminal(terminalID: tabID),
            side: SideRegion(panels: [], activePanelID: active, recency: [], collapsed: collapsed),
            worktreePanels: worktreePanels,
            revision: 1)
    }

    /// A note created `seconds` after the epoch.
    private static func note(worktreeID: UUID = UUID(), createdAt seconds: TimeInterval) -> NoteSummary {
        let date = Date(timeIntervalSince1970: seconds)
        return NoteSummary(worktreeID: worktreeID, title: "Note", createdAt: date, updatedAt: date)
    }

    /// Seeds the copy with `surface` and the worktree's `notes` — nil leaves
    /// them not loaded — presses the Notes button on the surface's tab, and
    /// returns every operation it sent.
    private static func press(
        _ state: AppState, surface: WorkspaceTabSurface, notes: [NoteSummary]?
    ) async -> [PanelOperation] {
        state.panelSurfaces = [surface.worktreeID: [surface.id: surface]]
        if let notes {
            state.notes = [surface.worktreeID: notes]
        }
        let envelopes = Fixture.collectEnvelopes(state, replying: surface)
        await state.toggleNotesPanel(worktreeID: surface.worktreeID, tabID: surface.id)
        return envelopes.envelopes.map(\.operation)
    }

    // MARK: - The decision

    @Test("a worktree whose notes are listed and empty creates one when the tab shows no note panel")
    func noNotesCreates() {
        let changes = WorktreePanel(id: UUID(), content: .changes)

        #expect(PaneActions.notesToggleDecision(surface: nil, notes: []) == .create)
        #expect(PaneActions.notesToggleDecision(
            surface: Self.surface(worktreePanels: [changes], active: changes.id), notes: []) == .create)
    }

    @Test("the first note with no worktree panel opens, as it does before the tab's surface loads")
    func firstNoteWithoutPanelOpens() {
        let first = Self.note(createdAt: 1_000)
        let second = Self.note(createdAt: 2_000)
        let secondPanel = WorktreePanel(id: UUID(), content: .note(noteID: second.id))

        #expect(PaneActions.notesToggleDecision(surface: nil, notes: [first, second])
            == .open(noteID: first.id))
        // Another note's panel in front does not stand in for the first note.
        #expect(PaneActions.notesToggleDecision(
            surface: Self.surface(worktreePanels: [secondPanel], active: secondPanel.id),
            notes: [first, second])
            == .open(noteID: first.id))
    }

    @Test("the first note's panel behind another panel is selected")
    func firstNoteBehindSelects() {
        let first = Self.note(createdAt: 1_000)
        let firstPanel = WorktreePanel(id: UUID(), content: .note(noteID: first.id))
        let changes = WorktreePanel(id: UUID(), content: .changes)

        #expect(PaneActions.notesToggleDecision(
            surface: Self.surface(worktreePanels: [firstPanel, changes], active: changes.id),
            notes: [first])
            == .select(firstPanel.id))
    }

    @Test("the first note's panel in front of a collapsed region is selected, which expands it")
    func firstNoteCollapsedSelects() {
        let first = Self.note(createdAt: 1_000)
        let firstPanel = WorktreePanel(id: UUID(), content: .note(noteID: first.id))

        #expect(PaneActions.notesToggleDecision(
            surface: Self.surface(worktreePanels: [firstPanel], active: firstPanel.id, collapsed: true),
            notes: [first])
            == .select(firstPanel.id))
    }

    @Test("the first note's panel in front of a visible region is closed")
    func firstNoteInFrontCloses() {
        let first = Self.note(createdAt: 1_000)
        let firstPanel = WorktreePanel(id: UUID(), content: .note(noteID: first.id))
        let changes = WorktreePanel(id: UUID(), content: .changes)

        #expect(PaneActions.notesToggleDecision(
            surface: Self.surface(worktreePanels: [changes, firstPanel], active: firstPanel.id),
            notes: [first])
            == .close(firstPanel.id))
    }

    @Test("the first note is the oldest by createdAt, not the first in the list")
    func firstNoteIsOldestByCreatedAt() {
        let newer = Self.note(createdAt: 2_000)
        let older = Self.note(createdAt: 1_000)
        let newest = Self.note(createdAt: 3_000)
        let newerPanel = WorktreePanel(id: UUID(), content: .note(noteID: newer.id))
        let olderPanel = WorktreePanel(id: UUID(), content: .note(noteID: older.id))

        #expect(PaneActions.notesToggleDecision(surface: nil, notes: [newer, older, newest])
            == .open(noteID: older.id))
        // The list's first note in front is not the first note in front.
        #expect(PaneActions.notesToggleDecision(
            surface: Self.surface(worktreePanels: [newerPanel, olderPanel], active: newerPanel.id),
            notes: [newer, older, newest])
            == .select(olderPanel.id))
    }

    @Test("before the notes load, a tab with no note panel is unavailable, whatever else it shows")
    func notLoadedWithoutNotePanelIsUnavailable() {
        let changes = WorktreePanel(id: UUID(), content: .changes)

        #expect(PaneActions.notesToggleDecision(surface: nil, notes: nil) == .unavailable)
        #expect(PaneActions.notesToggleDecision(
            surface: Self.surface(worktreePanels: [], active: nil), notes: nil) == .unavailable)
        #expect(PaneActions.notesToggleDecision(
            surface: Self.surface(worktreePanels: [changes], active: changes.id), notes: nil) == .unavailable)
    }

    @Test("before the notes load, the tab's first note panel in strip order stands in for the first note")
    func notLoadedTogglesFirstNotePanel() {
        let changes = WorktreePanel(id: UUID(), content: .changes)
        let firstPanel = WorktreePanel(id: UUID(), content: .note(noteID: UUID()))
        let secondPanel = WorktreePanel(id: UUID(), content: .note(noteID: UUID()))
        let panels: [WorktreePanel] = [changes, firstPanel, secondPanel]

        // Behind another panel, or in front of a collapsed region: select it.
        #expect(PaneActions.notesToggleDecision(
            surface: Self.surface(worktreePanels: panels, active: secondPanel.id), notes: nil)
            == .select(firstPanel.id))
        #expect(PaneActions.notesToggleDecision(
            surface: Self.surface(worktreePanels: panels, active: firstPanel.id, collapsed: true), notes: nil)
            == .select(firstPanel.id))
        // In front of a visible region: close it.
        #expect(PaneActions.notesToggleDecision(
            surface: Self.surface(worktreePanels: panels, active: firstPanel.id), notes: nil)
            == .close(firstPanel.id))
    }

    @Test("notes listed empty while the tab shows a note panel toggle that panel rather than create")
    func listedEmptyWithNotePanelTogglesIt() {
        let notePanel = WorktreePanel(id: UUID(), content: .note(noteID: UUID()))

        #expect(PaneActions.notesToggleDecision(
            surface: Self.surface(worktreePanels: [notePanel], active: notePanel.id), notes: [])
            == .close(notePanel.id))
    }

    @Test("each decision's operation, and the button is on only while a press would close")
    func decisionOperationsAndOnState() {
        let noteID = UUID()
        let panelID = UUID()
        let opensNote: PanelOperation = .open(content: .note(noteID: noteID), newPanel: false)
        let selectsPanel: PanelOperation = .select(panelID: panelID)
        let closesPanel: PanelOperation = .close(panelID: panelID)

        #expect(NotesToggleDecision.create.operation == nil, "a create sends its open once the note exists")
        #expect(NotesToggleDecision.unavailable.operation == nil, "an unavailable button sends nothing")
        #expect(NotesToggleDecision.open(noteID: noteID).operation == opensNote)
        #expect(NotesToggleDecision.select(panelID).operation == selectsPanel)
        #expect(NotesToggleDecision.close(panelID).operation == closesPanel)

        #expect(!NotesToggleDecision.create.isOn)
        #expect(!NotesToggleDecision.open(noteID: noteID).isOn)
        #expect(!NotesToggleDecision.select(panelID).isOn)
        #expect(NotesToggleDecision.close(panelID).isOn)
        #expect(!NotesToggleDecision.unavailable.isOn)

        #expect(!NotesToggleDecision.unavailable.isEnabled)
        #expect(NotesToggleDecision.create.isEnabled)
        #expect(NotesToggleDecision.open(noteID: noteID).isEnabled)
        #expect(NotesToggleDecision.select(panelID).isEnabled)
        #expect(NotesToggleDecision.close(panelID).isEnabled)
    }

    // MARK: - The button

    @Test("the button draws note.text: accent while on, primary while off, secondary and disabled while loading")
    func notesControlAppearance() {
        let on = PaneChromeControl.notes(isOn: true, isEnabled: true)
        let off = PaneChromeControl.notes(isOn: false, isEnabled: true)
        let loading = PaneChromeControl.notes(isOn: false, isEnabled: false)

        #expect(on.systemImage == "note.text")
        #expect(on.systemImage == PanelKind.note.tabSystemImage)
        #expect(on.tint == .accent)
        #expect(on.help == "Hide notes")
        #expect(on.isEnabled)
        #expect(off.systemImage == "note.text")
        #expect(off.tint == .primary)
        #expect(off.help == "Show notes")
        #expect(off.isEnabled)
        #expect(loading.systemImage == "note.text")
        #expect(loading.tint == .secondary)
        #expect(loading.help == "Notes are loading")
        #expect(!loading.isEnabled)
        // The viewer controls can always be pressed, and so can a live
        // transcript button.
        let others: [PaneChromeControl] = [
            .transcript(isOn: true, isEnabled: true), .transcript(isOn: false, isEnabled: true),
            .renderToggle(showingSource: false), .copyAddress(copied: false), .refresh,
        ]
        for control in others {
            #expect(control.isEnabled, "\(control)")
        }
    }

    @Test("the button draws on while the first note is in front, and disabled while it cannot act")
    func workspaceBarNotesControl() {
        let first = Self.note(createdAt: 1_000)
        let firstPanel = WorktreePanel(id: UUID(), content: .note(noteID: first.id))
        let on: PaneChromeControl = .notes(isOn: true, isEnabled: true)
        let off: PaneChromeControl = .notes(isOn: false, isEnabled: true)
        let loading: PaneChromeControl = .notes(isOn: false, isEnabled: false)

        #expect(PanelSurfaceWorkspaceView.notesControl(
            surface: Self.surface(worktreePanels: [firstPanel], active: firstPanel.id), notes: [first])
            == on)
        #expect(PanelSurfaceWorkspaceView.notesControl(
            surface: Self.surface(worktreePanels: [firstPanel], active: firstPanel.id, collapsed: true),
            notes: [first])
            == off)
        #expect(PanelSurfaceWorkspaceView.notesControl(surface: nil, notes: [first]) == off)
        #expect(PanelSurfaceWorkspaceView.notesControl(surface: nil, notes: []) == off)
        // Not loaded: disabled with no note panel, live with one.
        #expect(PanelSurfaceWorkspaceView.notesControl(surface: nil, notes: nil) == loading)
        #expect(PanelSurfaceWorkspaceView.notesControl(
            surface: Self.surface(worktreePanels: [firstPanel], active: firstPanel.id), notes: nil)
            == on)
    }

    @Test("a bar drawn off the daemon path has Session History alone, and no Notes button")
    func noneHasNoNotesButton() {
        let items: [TabBarTrailingItem] = TabBarTrailingItems.none.items
        let expected: [TabBarTrailingItem] = [.sessionHistory]
        #expect(items == expected)
    }

    // MARK: - A press

    @Test("a press opens the first note when it has no panel")
    func pressOpensFirstNote() async {
        await Fixture.withState { state in
            let worktreeID = UUID()
            let first = Self.note(worktreeID: worktreeID, createdAt: 1_000)
            let second = Self.note(worktreeID: worktreeID, createdAt: 2_000)
            let surface = Self.surface(worktreeID: worktreeID, worktreePanels: [], active: nil)

            let sent = await Self.press(state, surface: surface, notes: [second, first])

            let expected: [PanelOperation] = [.open(content: .note(noteID: first.id), newPanel: false)]
            #expect(sent == expected)
        }
    }

    @Test("a press selects the first note's panel when it is behind another")
    func pressSelectsPanelBehind() async {
        await Fixture.withState { state in
            let worktreeID = UUID()
            let first = Self.note(worktreeID: worktreeID, createdAt: 1_000)
            let firstPanel = WorktreePanel(id: UUID(), content: .note(noteID: first.id))
            let changes = WorktreePanel(id: UUID(), content: .changes)
            let surface = Self.surface(
                worktreeID: worktreeID, worktreePanels: [firstPanel, changes], active: changes.id)

            let sent = await Self.press(state, surface: surface, notes: [first])

            let expected: [PanelOperation] = [.select(panelID: firstPanel.id)]
            #expect(sent == expected)
        }
    }

    @Test("a press selects the first note's panel when the region is collapsed")
    func pressSelectsPanelInCollapsedRegion() async {
        await Fixture.withState { state in
            let worktreeID = UUID()
            let first = Self.note(worktreeID: worktreeID, createdAt: 1_000)
            let firstPanel = WorktreePanel(id: UUID(), content: .note(noteID: first.id))
            let surface = Self.surface(
                worktreeID: worktreeID, worktreePanels: [firstPanel], active: firstPanel.id, collapsed: true)

            let sent = await Self.press(state, surface: surface, notes: [first])

            let expected: [PanelOperation] = [.select(panelID: firstPanel.id)]
            #expect(sent == expected)
        }
    }

    @Test("a press closes the first note's panel in front, and keeps the note")
    func pressClosesAndKeepsNote() async {
        await Fixture.withState { state in
            let deletes = PanelEventLog()
            state.noteDeleter = { @MainActor noteID in deletes.record("delete \(noteID)") }
            // The fixture's confirmer records an issue if a close asks.
            let worktreeID = UUID()
            let first = Self.note(worktreeID: worktreeID, createdAt: 1_000)
            let firstPanel = WorktreePanel(id: UUID(), content: .note(noteID: first.id))
            let surface = Self.surface(worktreeID: worktreeID, worktreePanels: [firstPanel], active: firstPanel.id)

            let sent = await Self.press(state, surface: surface, notes: [first])
            await Fixture.drainMainActor()

            let expected: [PanelOperation] = [.close(panelID: firstPanel.id)]
            #expect(sent == expected)
            #expect(deletes.events.isEmpty, "the Notes button's close never deletes the note")
            let listed: [UUID] = state.notes[worktreeID]?.map(\.id) ?? []
            let expectedListed: [UUID] = [first.id]
            #expect(listed == expectedListed)
        }
    }

    @Test("a press in a worktree whose notes are listed and empty creates one titled Notes, then opens it here")
    func pressCreatesThenOpens() async {
        await Fixture.withState { state in
            let worktreeID = UUID()
            let tabID = UUID()
            let surface = Fixture.surface(tabID: tabID, worktreeID: worktreeID, revision: 1)
            state.panelSurfaces = [worktreeID: [tabID: surface]]
            state.adoptNotes([], worktreeIDs: [worktreeID])
            let created = Note(worktreeID: worktreeID, title: "Notes")
            let creates = PanelEventLog()
            state.noteCreator = { @MainActor worktreeID, title in
                creates.record("create \(worktreeID) title \(title ?? "<default>")")
                return created
            }
            let envelopes = Fixture.collectEnvelopes(state, replying: surface)

            await state.toggleNotesPanel(worktreeID: worktreeID, tabID: tabID)

            let expectedCreates: [String] = ["create \(worktreeID) title Notes"]
            #expect(creates.events == expectedCreates)
            let applied: [PanelOperation] = envelopes.envelopes.map(\.operation)
            let expectedApplied: [PanelOperation] = [.open(content: .note(noteID: created.id), newPanel: false)]
            #expect(applied == expectedApplied)
            #expect(envelopes.envelopes.first?.tabID == tabID, "the note opens in the tab whose button was pressed")
            let listed: [UUID] = state.notes[worktreeID]?.map(\.id) ?? []
            let expectedListed: [UUID] = [created.id]
            #expect(listed == expectedListed)
            #expect(state.notesButtonCreatesInFlight.isEmpty)
        }
    }

    @Test("a second press while the create is in flight sends nothing, so a double click makes one note")
    func pressDuringCreateSendsNothing() async throws {
        try await Fixture.withState { state in
            let worktreeID = UUID()
            let tabID = UUID()
            let surface = Fixture.surface(tabID: tabID, worktreeID: worktreeID, revision: 1)
            state.panelSurfaces = [worktreeID: [tabID: surface]]
            state.notes = [worktreeID: []]
            let created = Note(worktreeID: worktreeID, title: "Notes")
            let creates = PanelEventLog()
            let gate = PanelCallGate()
            state.noteCreator = { @MainActor worktreeID, _ in
                creates.record("create \(worktreeID)")
                await gate.wait()
                return created
            }
            let envelopes = Fixture.collectEnvelopes(state, replying: surface)

            let firstPress = Task { @MainActor in
                await state.toggleNotesPanel(worktreeID: worktreeID, tabID: tabID)
            }
            await Fixture.drainMainActor()
            try #require(gate.isHolding, "precondition: the first press's create is in flight")

            await state.toggleNotesPanel(worktreeID: worktreeID, tabID: tabID)
            gate.release()
            await firstPress.value

            let expectedCreates: [String] = ["create \(worktreeID)"]
            #expect(creates.events == expectedCreates)
            let applied: [PanelOperation] = envelopes.envelopes.map(\.operation)
            let expectedApplied: [PanelOperation] = [.open(content: .note(noteID: created.id), newPanel: false)]
            #expect(applied == expectedApplied)
            #expect(state.notesButtonCreatesInFlight.isEmpty)
        }
    }

    @Test("a failed create opens nothing, and the next press tries again")
    func failedCreateLetsNextPressRetry() async {
        await Fixture.withState { state in
            let worktreeID = UUID()
            let tabID = UUID()
            state.notes = [worktreeID: []]
            let creates = PanelEventLog()
            state.noteCreator = { @MainActor worktreeID, _ in
                creates.record("create \(worktreeID)")
                throw PanelTabsFixture.Rejected(message: "note.create refused")
            }
            // The fixture's `panel.apply` records an issue if it is reached.

            await state.toggleNotesPanel(worktreeID: worktreeID, tabID: tabID)
            await state.toggleNotesPanel(worktreeID: worktreeID, tabID: tabID)

            let expectedCreates: [String] = ["create \(worktreeID)", "create \(worktreeID)"]
            #expect(creates.events == expectedCreates)
            #expect(state.notes[worktreeID]?.isEmpty == true)
            #expect(state.notesButtonCreatesInFlight.isEmpty)
            #expect(state.activeToast?.style == .error)
        }
    }

    @Test("a press before the notes load, with no note panel, sends nothing and creates nothing")
    func pressBeforeNotesLoadDoesNothing() async {
        await Fixture.withState { state in
            // The fixture's `note.create` records an issue if it is reached.
            let worktreeID = UUID()
            let surface = Self.surface(worktreeID: worktreeID, worktreePanels: [], active: nil)
            #expect(state.notes[worktreeID] == nil, "precondition: the notes have not loaded")

            let sent = await Self.press(state, surface: surface, notes: nil)

            #expect(sent.isEmpty)
            #expect(state.notes[worktreeID] == nil, "nothing was created")
            #expect(state.notesButtonCreatesInFlight.isEmpty)
        }
    }

    @Test("a press before the notes load toggles the note panel the tab already shows")
    func pressBeforeNotesLoadTogglesNotePanel() async {
        await Fixture.withState { state in
            let worktreeID = UUID()
            let notePanel = WorktreePanel(id: UUID(), content: .note(noteID: UUID()))
            let changes = WorktreePanel(id: UUID(), content: .changes)

            let behind = Self.surface(
                worktreeID: worktreeID, worktreePanels: [changes, notePanel], active: changes.id)
            let selected = await Self.press(state, surface: behind, notes: nil)
            let expectedSelect: [PanelOperation] = [.select(panelID: notePanel.id)]
            #expect(selected == expectedSelect)

            let inFront = Self.surface(
                worktreeID: worktreeID, worktreePanels: [changes, notePanel], active: notePanel.id)
            let closed = await Self.press(state, surface: inFront, notes: nil)
            let expectedClose: [PanelOperation] = [.close(panelID: notePanel.id)]
            #expect(closed == expectedClose)
            #expect(state.notes[worktreeID] == nil, "nothing was created")
        }
    }

    // MARK: - Loading

    @Test("a notes answer stores every worktree it covers, an empty list included, and leaves others unloaded")
    func adoptNotesStoresEmptyLists() async {
        await Fixture.withState { state in
            let empty = UUID()
            let emptied = UUID()
            let listed = UUID()
            let uncovered = UUID()
            let kept = Self.note(worktreeID: listed, createdAt: 1_000)
            state.notes = [emptied: [Self.note(worktreeID: emptied, createdAt: 1_000)]]

            state.adoptNotes([kept], worktreeIDs: [empty, emptied, listed])

            let none: [NoteSummary] = []
            let expectedListed: [NoteSummary] = [kept]
            #expect(state.notes[empty] == none, "an empty answer marks the worktree loaded with no note")
            #expect(state.notes[emptied] == none, "a worktree whose notes are gone is left with none")
            #expect(state.notes[listed] == expectedListed)
            #expect(state.notes[uncovered] == nil, "a worktree the answer did not cover stays unloaded")
        }
    }
}
