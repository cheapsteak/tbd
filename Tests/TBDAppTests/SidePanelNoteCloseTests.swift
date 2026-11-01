import Foundation
import Testing
import TBDShared
@testable import TBDApp
import TestSupport

// Tier 2: in-process, with a real scratch directory holding the note content
// file `noteHasContent` stats. Every daemon hop goes through an injected seam
// (`PanelTabsFixture`), so no socket opens, and no confirmation alert runs.

/// Closing a note's side-region tab (panel tabs spec, "The renderer"):
/// `AppState.closeSidePanel` asks first when the note has content — whether or
/// not `notes` holds its summary yet, and counting an edit an open editor
/// still holds on its save debounce — then closes the panel and deletes the
/// note, and deletes nothing when the user declines or the daemon refuses the
/// close. The `close` operation itself keeps the note, so the daemon action
/// set's close never deletes one.
@Suite("Side-region note close")
@MainActor
struct SidePanelNoteCloseTests {
    private typealias Fixture = PanelTabsFixture

    // MARK: - Fixtures

    /// A workspace tab in the copy whose side region holds one panel.
    private struct Seeded {
        let surface: WorkspaceTabSurface
        let panelID: PanelID
        var worktreeID: UUID { surface.worktreeID }
        var tabID: UUID { surface.id }
    }

    /// Seeds the copy with one tab whose side region shows `content`, and,
    /// for a note, the note's summary unless `withSummary` is false — the
    /// note an agent opened before the notes refresh landed.
    private static func seed(
        _ state: AppState, content: PanelContent, withSummary: Bool = true
    ) -> Seeded {
        let worktreeID = UUID()
        let tabID = UUID()
        let panel = ViewerPanel(id: UUID(), content: content)
        let surface = WorkspaceTabSurface(
            id: tabID, worktreeID: worktreeID, primary: .terminal(terminalID: tabID),
            side: SideRegion(panels: [panel], activePanelID: panel.id, recency: [panel.id]),
            revision: 1)
        state.panelSurfaces = [worktreeID: [tabID: surface]]
        if case .note(let noteID) = content, withSummary {
            state.notes = [worktreeID: [NoteSummary(id: noteID, worktreeID: worktreeID, title: "Plan")]]
        }
        return Seeded(surface: surface, panelID: panel.id)
    }

    /// The daemon's tab once the close has applied: the side region empty.
    private static func closed(_ seeded: Seeded) -> WorkspaceTabSurface {
        var reply = seeded.surface
        reply.side = .empty
        reply.revision += 1
        return reply
    }

    /// Points the note content resolver at a fresh scratch directory, which
    /// the caller removes. Nothing is in it until `writeContent`.
    private static func useScratchNoteFiles(_ state: AppState) -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("tbd-side-note-close-\(UUID().uuidString)")
        state.noteContentPathResolver = { worktreeID, noteID in
            root.appendingPathComponent(worktreeID.uuidString)
                .appendingPathComponent("\(noteID.uuidString).md").path
        }
        return root
    }

    /// Writes the note's content file where the resolver says it lives.
    private static func writeContent(
        _ text: String, state: AppState, worktreeID: UUID, noteID: UUID
    ) throws {
        let url = URL(fileURLWithPath: state.noteContentPathResolver(worktreeID, noteID))
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: url, atomically: true, encoding: .utf8)
    }

    /// Stubs the confirmation to answer `answer`, and the delete to succeed,
    /// recording both.
    private static func stubNoteSeams(_ state: AppState, confirming answer: Bool) -> NoteSeamRecorder {
        let recorder = NoteSeamRecorder()
        state.noteCloseConfirmer = { note, _ in recorder.confirm(note, answer: answer) }
        state.noteDeleter = { @MainActor noteID in recorder.delete(noteID) }
        return recorder
    }

    // MARK: - Notes

    @Test("closing a side-region note with content asks, then closes the panel and deletes the note")
    func noteWithContentAsksThenClosesAndDeletes() async throws {
        try await Fixture.withState { state in
            let noteID = UUID()
            let seeded = Self.seed(state, content: .note(noteID: noteID))
            let root = Self.useScratchNoteFiles(state)
            defer { try? FileManager.default.removeItem(at: root) }
            try Self.writeContent("- ship it\n", state: state, worktreeID: seeded.worktreeID, noteID: noteID)
            #expect(state.noteHasContent(worktreeID: seeded.worktreeID, noteID: noteID),
                    "precondition: the content file makes the note non-empty")
            let envelopes = Fixture.collectEnvelopes(state, replying: Self.closed(seeded))
            let notes = Self.stubNoteSeams(state, confirming: true)

            await state.closeSidePanel(
                worktreeID: seeded.worktreeID, tabID: seeded.tabID,
                panelID: seeded.panelID, content: .note(noteID: noteID))

            let applied = envelopes.envelopes.map(\.operation)
            let expectedApplied: [PanelOperation] = [.close(panelID: seeded.panelID)]
            #expect(applied == expectedApplied)
            #expect(notes.confirmations == 1)
            let expectedDeleted: [UUID] = [noteID]
            #expect(notes.deleted == expectedDeleted)
            #expect(state.notes[seeded.worktreeID]?.isEmpty == true, "the deleted note leaves `notes`")
        }
    }

    @Test("closing an empty side-region note closes and deletes without asking")
    func emptyNoteClosesAndDeletesWithoutAsking() async {
        await Fixture.withState { state in
            let noteID = UUID()
            let seeded = Self.seed(state, content: .note(noteID: noteID))
            let root = Self.useScratchNoteFiles(state)
            defer { try? FileManager.default.removeItem(at: root) }
            #expect(!state.noteHasContent(worktreeID: seeded.worktreeID, noteID: noteID),
                    "precondition: no content file and no legacy content")
            let envelopes = Fixture.collectEnvelopes(state, replying: Self.closed(seeded))
            // Declining would block the close, so a prompt cannot go unnoticed.
            let notes = Self.stubNoteSeams(state, confirming: false)

            await state.closeSidePanel(
                worktreeID: seeded.worktreeID, tabID: seeded.tabID,
                panelID: seeded.panelID, content: .note(noteID: noteID))

            let applied = envelopes.envelopes.map(\.operation)
            let expectedApplied: [PanelOperation] = [.close(panelID: seeded.panelID)]
            #expect(applied == expectedApplied)
            #expect(notes.confirmations == 0)
            let expectedDeleted: [UUID] = [noteID]
            #expect(notes.deleted == expectedDeleted)
        }
    }

    @Test("a declined confirmation changes nothing")
    func declinedConfirmationChangesNothing() async throws {
        try await Fixture.withState { state in
            let noteID = UUID()
            let seeded = Self.seed(state, content: .note(noteID: noteID))
            let root = Self.useScratchNoteFiles(state)
            defer { try? FileManager.default.removeItem(at: root) }
            try Self.writeContent("- ship it\n", state: state, worktreeID: seeded.worktreeID, noteID: noteID)
            let envelopes = Fixture.collectEnvelopes(state, replying: Self.closed(seeded))
            let notes = Self.stubNoteSeams(state, confirming: false)

            await state.closeSidePanel(
                worktreeID: seeded.worktreeID, tabID: seeded.tabID,
                panelID: seeded.panelID, content: .note(noteID: noteID))

            #expect(notes.confirmations == 1)
            #expect(envelopes.envelopes.isEmpty, "a declined close sends nothing")
            #expect(notes.deleted.isEmpty)
            #expect(state.panelSurface(worktreeID: seeded.worktreeID, tabID: seeded.tabID) == seeded.surface)
            #expect(state.notes[seeded.worktreeID]?.count == 1, "the note stays in `notes`")
        }
    }

    @Test("a close the daemon refuses deletes nothing")
    func refusedCloseDeletesNothing() async throws {
        try await Fixture.withState { state in
            let noteID = UUID()
            let seeded = Self.seed(state, content: .note(noteID: noteID))
            let root = Self.useScratchNoteFiles(state)
            defer { try? FileManager.default.removeItem(at: root) }
            try Self.writeContent("- ship it\n", state: state, worktreeID: seeded.worktreeID, noteID: noteID)
            let refused = PanelEnvelopeCollector()
            state.panelApplyTrigger = { @MainActor envelope in
                refused.record(envelope)
                throw PanelTabsFixture.Rejected(message: "No panel with that ID")
            }
            // A failed apply refetches the worktree; the daemon still holds the panel.
            let truth = seeded.surface
            _ = Fixture.collectGets(state) { _ in PanelGetResult(tabs: [truth], activeTabID: nil) }
            let notes = Self.stubNoteSeams(state, confirming: true)

            await state.closeSidePanel(
                worktreeID: seeded.worktreeID, tabID: seeded.tabID,
                panelID: seeded.panelID, content: .note(noteID: noteID))

            let applied = refused.envelopes.map(\.operation)
            let expectedApplied: [PanelOperation] = [.close(panelID: seeded.panelID)]
            #expect(applied == expectedApplied, "the close was sent once")
            #expect(notes.confirmations == 1)
            #expect(notes.deleted.isEmpty, "a refused close must not delete the note")
            #expect(state.notes[seeded.worktreeID]?.count == 1)
            state.dismissToast()
        }
    }

    // MARK: - An edit still on the editor's debounce

    @Test("closing a side-region note with an edit still pending asks, and declining closes and deletes nothing", .fastPassBounded)
    func pendingEditAsksAndDeclineChangesNothing() async {
        await Fixture.withState { state in
            let noteID = UUID()
            let seeded = Self.seed(state, content: .note(noteID: noteID))
            let root = NoteEditorFixture.useScratchNoteFiles(state)
            defer { try? FileManager.default.removeItem(at: root) }
            let editor = await NoteEditorFixture.open(state, noteID: noteID, worktreeID: seeded.worktreeID)
            let typed = "typed inside the debounce window"
            NoteEditorFixture.type(typed, into: editor, state: state)
            #expect(!state.noteHasContent(worktreeID: seeded.worktreeID, noteID: noteID),
                    "precondition: the content file still reads as empty")
            let envelopes = Fixture.collectEnvelopes(state, replying: Self.closed(seeded))
            let notes = Self.stubNoteSeams(state, confirming: false)

            await state.closeSidePanel(
                worktreeID: seeded.worktreeID, tabID: seeded.tabID,
                panelID: seeded.panelID, content: .note(noteID: noteID))

            #expect(notes.confirmations == 1, "the pending edit makes the note non-empty, so × asks")
            #expect(envelopes.envelopes.isEmpty, "a declined close sends nothing")
            #expect(notes.deleted.isEmpty)
            #expect(state.panelSurface(worktreeID: seeded.worktreeID, tabID: seeded.tabID) == seeded.surface)
            let onDisk = NoteEditorFixture.onDisk(state, worktreeID: seeded.worktreeID, noteID: noteID)
            #expect(onDisk == typed, "the edit landed in the content file before the check")
        }
    }

    @Test("closing an empty side-region note whose open editor holds nothing closes and deletes without asking", .fastPassBounded)
    func emptyNoteWithEditorClosesAndDeletesWithoutAsking() async {
        await Fixture.withState { state in
            let noteID = UUID()
            let seeded = Self.seed(state, content: .note(noteID: noteID))
            let root = NoteEditorFixture.useScratchNoteFiles(state)
            defer { try? FileManager.default.removeItem(at: root) }
            let editor = await NoteEditorFixture.open(state, noteID: noteID, worktreeID: seeded.worktreeID)
            #expect(editor.loaded, "precondition: the editor loaded the note")
            #expect(state.hasNoteSaveFlusher(noteID: noteID), "precondition: the editor registered")
            let envelopes = Fixture.collectEnvelopes(state, replying: Self.closed(seeded))
            // Declining would block the close, so a prompt cannot go unnoticed.
            let notes = Self.stubNoteSeams(state, confirming: false)

            await state.closeSidePanel(
                worktreeID: seeded.worktreeID, tabID: seeded.tabID,
                panelID: seeded.panelID, content: .note(noteID: noteID))

            let applied = envelopes.envelopes.map(\.operation)
            let expectedApplied: [PanelOperation] = [.close(panelID: seeded.panelID)]
            #expect(applied == expectedApplied)
            #expect(notes.confirmations == 0)
            let expectedDeleted: [UUID] = [noteID]
            #expect(notes.deleted == expectedDeleted)
        }
    }

    // MARK: - A note whose summary has not loaded

    @Test("a side-region note whose summary has not loaded still asks when it has content, then closes and deletes")
    func unloadedNoteWithContentAsksThenClosesAndDeletes() async throws {
        try await Fixture.withState { state in
            let noteID = UUID()
            let seeded = Self.seed(state, content: .note(noteID: noteID), withSummary: false)
            let root = Self.useScratchNoteFiles(state)
            defer { try? FileManager.default.removeItem(at: root) }
            try Self.writeContent("- ship it\n", state: state, worktreeID: seeded.worktreeID, noteID: noteID)
            try #require(state.notes[seeded.worktreeID] == nil, "precondition: no summary for the note")
            let envelopes = Fixture.collectEnvelopes(state, replying: Self.closed(seeded))
            let notes = Self.stubNoteSeams(state, confirming: true)

            await state.closeSidePanel(
                worktreeID: seeded.worktreeID, tabID: seeded.tabID,
                panelID: seeded.panelID, content: .note(noteID: noteID))

            let asked = try Fixture.single(notes.confirmedNotes)
            #expect(asked.id == noteID, "the confirmation names the note being closed")
            #expect(asked.worktreeID == seeded.worktreeID)
            #expect(asked.title == "Note", "a note with no summary is asked about as \"Note\"")
            let applied = envelopes.envelopes.map(\.operation)
            let expectedApplied: [PanelOperation] = [.close(panelID: seeded.panelID)]
            #expect(applied == expectedApplied)
            let expectedDeleted: [UUID] = [noteID]
            #expect(notes.deleted == expectedDeleted)
        }
    }

    @Test("a declined confirmation for a side-region note whose summary has not loaded changes nothing")
    func unloadedNoteDeclinedChangesNothing() async throws {
        try await Fixture.withState { state in
            let noteID = UUID()
            let seeded = Self.seed(state, content: .note(noteID: noteID), withSummary: false)
            let root = Self.useScratchNoteFiles(state)
            defer { try? FileManager.default.removeItem(at: root) }
            try Self.writeContent("- ship it\n", state: state, worktreeID: seeded.worktreeID, noteID: noteID)
            let envelopes = Fixture.collectEnvelopes(state, replying: Self.closed(seeded))
            let notes = Self.stubNoteSeams(state, confirming: false)

            await state.closeSidePanel(
                worktreeID: seeded.worktreeID, tabID: seeded.tabID,
                panelID: seeded.panelID, content: .note(noteID: noteID))

            #expect(notes.confirmations == 1)
            #expect(envelopes.envelopes.isEmpty, "a declined close sends nothing")
            #expect(notes.deleted.isEmpty)
            #expect(state.panelSurface(worktreeID: seeded.worktreeID, tabID: seeded.tabID) == seeded.surface)
        }
    }

    @Test("an empty side-region note whose summary has not loaded closes and deletes without asking")
    func unloadedEmptyNoteClosesAndDeletesWithoutAsking() async {
        await Fixture.withState { state in
            let noteID = UUID()
            let seeded = Self.seed(state, content: .note(noteID: noteID), withSummary: false)
            let root = Self.useScratchNoteFiles(state)
            defer { try? FileManager.default.removeItem(at: root) }
            #expect(!state.noteHasContent(worktreeID: seeded.worktreeID, noteID: noteID),
                    "precondition: no content file and no legacy content")
            let envelopes = Fixture.collectEnvelopes(state, replying: Self.closed(seeded))
            // Declining would block the close, so a prompt cannot go unnoticed.
            let notes = Self.stubNoteSeams(state, confirming: false)

            await state.closeSidePanel(
                worktreeID: seeded.worktreeID, tabID: seeded.tabID,
                panelID: seeded.panelID, content: .note(noteID: noteID))

            let applied = envelopes.envelopes.map(\.operation)
            let expectedApplied: [PanelOperation] = [.close(panelID: seeded.panelID)]
            #expect(applied == expectedApplied)
            #expect(notes.confirmations == 0)
            let expectedDeleted: [UUID] = [noteID]
            #expect(notes.deleted == expectedDeleted)
        }
    }

    // MARK: - Other panels and the operation alone

    @Test("closing a side-region file panel only closes it")
    func filePanelOnlyCloses() async {
        await Fixture.withState { state in
            let seeded = Self.seed(state, content: .file(FileReference(path: "/w/a.md")))
            let envelopes = Fixture.collectEnvelopes(state, replying: Self.closed(seeded))
            let notes = Self.stubNoteSeams(state, confirming: true)

            await state.closeSidePanel(
                worktreeID: seeded.worktreeID, tabID: seeded.tabID,
                panelID: seeded.panelID, content: .file(FileReference(path: "/w/a.md")))

            let applied = envelopes.envelopes.map(\.operation)
            let expectedApplied: [PanelOperation] = [.close(panelID: seeded.panelID)]
            #expect(applied == expectedApplied)
            #expect(notes.confirmations == 0)
            #expect(notes.deleted.isEmpty)
        }
    }

    @Test("the close operation alone keeps the note")
    func closeOperationKeepsTheNote() async throws {
        try await Fixture.withState { state in
            let noteID = UUID()
            let seeded = Self.seed(state, content: .note(noteID: noteID))
            let root = Self.useScratchNoteFiles(state)
            defer { try? FileManager.default.removeItem(at: root) }
            try Self.writeContent("- ship it\n", state: state, worktreeID: seeded.worktreeID, noteID: noteID)
            let envelopes = Fixture.collectEnvelopes(state, replying: Self.closed(seeded))
            let notes = Self.stubNoteSeams(state, confirming: true)
            let actions = PaneActions.daemon(
                appState: state, worktreeID: seeded.worktreeID, tabID: seeded.tabID,
                panelID: seeded.panelID, newPanelModifier: { false })

            actions.close(.note(noteID: noteID))
            await Fixture.drainMainActor()

            let applied = envelopes.envelopes.map(\.operation)
            let expectedApplied: [PanelOperation] = [.close(panelID: seeded.panelID)]
            #expect(applied == expectedApplied)
            #expect(notes.confirmations == 0)
            #expect(notes.deleted.isEmpty)
            #expect(state.notes[seeded.worktreeID]?.count == 1)
        }
    }
}

/// The note confirmations asked and the notes deleted, in order.
@MainActor
private final class NoteSeamRecorder {
    /// The note each confirmation named.
    private(set) var confirmedNotes: [NoteSummary] = []
    private(set) var deleted: [UUID] = []

    var confirmations: Int { confirmedNotes.count }

    func confirm(_ note: NoteSummary, answer: Bool) -> Bool {
        confirmedNotes.append(note)
        return answer
    }

    func delete(_ noteID: UUID) {
        deleted.append(noteID)
    }
}
