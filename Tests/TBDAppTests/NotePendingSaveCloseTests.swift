import Foundation
import Testing
import TBDShared
@testable import TBDApp
import TestSupport

// Tier 2: in-process, with a real scratch directory holding the note content
// files the closes stat and the editor writes. Every daemon hop goes through
// an injected seam (`PanelTabsFixture`), the editor's debounce runs on an
// `EventDrivenTestClock` nobody advances, and no confirmation alert runs.

/// Opens real `NotePaneModel` editors whose debounce never fires on its own,
/// so an edit stays pending until something flushes it.
@MainActor
enum NoteEditorFixture {
    /// An editor showing `noteID`, loaded as its pane's `.task(id:)` loads it.
    static func open(_ state: AppState, noteID: UUID, worktreeID: UUID) async -> NotePaneModel {
        let model = NotePaneModel(debounceInterval: .milliseconds(500), clock: EventDrivenTestClock())
        await model.load(noteID: noteID, worktreeID: worktreeID, appState: state)
        return model
    }

    /// What the view's two-way binding plus `onChange` do for one keystroke.
    static func type(_ text: String, into model: NotePaneModel, state: AppState) {
        model.text = text
        model.textEdited(text, appState: state)
    }

    /// Points the note content resolver at a fresh scratch directory, which
    /// the caller removes.
    static func useScratchNoteFiles(_ state: AppState) -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("tbd-note-pending-save-\(UUID().uuidString)")
        state.noteContentPathResolver = { worktreeID, noteID in
            root.appendingPathComponent(worktreeID.uuidString)
                .appendingPathComponent("\(noteID.uuidString).md").path
        }
        return root
    }

    /// The note's text as it sits on disk, or nil when it has no file.
    static func onDisk(_ state: AppState, worktreeID: UUID, noteID: UUID) -> String? {
        try? String(contentsOfFile: state.noteContentPathResolver(worktreeID, noteID), encoding: .utf8)
    }
}

/// × on a note decides whether to ask from the note's content file
/// (`noteHasContent`), and the editor writes that file on a 500 ms debounce.
/// So a close first lands every save an open editor still holds
/// (`AppState.flushPendingNoteSave`, through the registry each
/// `NotePaneModel` joins when it loads a note); otherwise a note typed into
/// and closed inside the window reads as empty, closes without asking, and
/// takes the typed text with it. These cases drive the registry and the
/// workspace tab's `closeTab`; the side tab's `closeSidePanel` is in
/// `SidePanelNoteCloseTests`.
@Suite("Note close flushes the pending save", .clockDriven)
@MainActor
struct NotePendingSaveCloseTests {
    private typealias Fixture = PanelTabsFixture
    private typealias Editor = NoteEditorFixture

    private static let typed = "typed inside the debounce window"

    /// A worktree whose one tab is an empty note (no content file, no legacy
    /// content), with the note's summary in `notes`.
    private static func seedNoteTab(_ state: AppState) -> (worktreeID: UUID, noteID: UUID) {
        let worktreeID = UUID()
        let note = NoteSummary(worktreeID: worktreeID, title: "Notes")
        state.notes = [worktreeID: [note]]
        state.tabs = [worktreeID: [noteTab(note.id)]]
        return (worktreeID, note.id)
    }

    private static func noteTab(_ noteID: UUID) -> TBDShared.Tab {
        TBDShared.Tab(id: noteID, content: .note(noteID: noteID), label: nil)
    }

    /// Stubs the confirmation to answer `answer`, and the delete to succeed,
    /// recording both.
    private static func stubNoteSeams(_ state: AppState, confirming answer: Bool) -> NoteCloseRecorder {
        let recorder = NoteCloseRecorder()
        state.noteCloseConfirmer = { _, _ in recorder.confirm(answer: answer) }
        state.noteDeleter = { @MainActor noteID in recorder.delete(noteID) }
        return recorder
    }

    private static func tabIDs(_ state: AppState, _ worktreeID: UUID) -> [UUID] {
        state.tabs[worktreeID]?.map(\.id) ?? []
    }

    // MARK: - The registry

    @Test("a flush lands an open editor's pending edit in the content file before it returns")
    func flushLandsThePendingEditOnDisk() async {
        await Fixture.withState { state in
            let root = Editor.useScratchNoteFiles(state)
            defer { try? FileManager.default.removeItem(at: root) }
            let (worktreeID, noteID) = Self.seedNoteTab(state)
            let editor = await Editor.open(state, noteID: noteID, worktreeID: worktreeID)
            #expect(editor.loaded, "precondition: the editor loaded the note")
            Editor.type(Self.typed, into: editor, state: state)
            #expect(Editor.onDisk(state, worktreeID: worktreeID, noteID: noteID) == nil,
                    "precondition: the edit is still on the debounce")
            #expect(!state.noteHasContent(worktreeID: worktreeID, noteID: noteID),
                    "precondition: the file reads as empty")

            await state.flushPendingNoteSave(noteID: noteID)

            #expect(Editor.onDisk(state, worktreeID: worktreeID, noteID: noteID) == Self.typed)
            #expect(state.noteHasContent(worktreeID: worktreeID, noteID: noteID))
            #expect(editor.pendingSaveTask == nil, "the debounce was resolved, not left armed")
        }
    }

    @Test("a flush awaits every editor of the note, and a stale unregister removes no newer registration")
    func flushAwaitsEveryEditorAndStaleUnregisterKeepsNewer() async {
        await Fixture.withState { state in
            let noteID = UUID()
            let log = PanelEventLog()
            let first = state.registerNoteSaveFlusher(noteID: noteID) { log.record("first") }
            state.unregisterNoteSaveFlusher(first)
            let second = state.registerNoteSaveFlusher(noteID: noteID) { log.record("second") }
            let third = state.registerNoteSaveFlusher(noteID: noteID) { log.record("third") }

            // `first` again: a late unregister of a registration already gone.
            state.unregisterNoteSaveFlusher(first)
            await state.flushPendingNoteSave(noteID: noteID)

            let flushed = Set(log.events)
            let expectedFlushed: Set<String> = ["second", "third"]
            #expect(flushed == expectedFlushed)
            #expect(log.events.count == 2)

            state.unregisterNoteSaveFlusher(second)
            state.unregisterNoteSaveFlusher(third)
            #expect(!state.hasNoteSaveFlusher(noteID: noteID))
            await state.flushPendingNoteSave(noteID: noteID)
            #expect(log.events.count == 2, "a note no editor has open flushed something")
        }
    }

    /// The pane's `onDisappear` flush unregisters the editor once its write
    /// lands — unless the pane has reappeared and its `load` registered the
    /// editor again meanwhile, which a late unregister must not undo.
    @Test("a pane that reappears before its disappearing flush ends stays registered; one that does not is unregistered")
    func disappearingFlushUnregistersOnlyItsOwnRegistration() async {
        await Fixture.withState { state in
            let root = Editor.useScratchNoteFiles(state)
            defer { try? FileManager.default.removeItem(at: root) }
            let (worktreeID, noteID) = Self.seedNoteTab(state)
            let editor = await Editor.open(state, noteID: noteID, worktreeID: worktreeID)
            let before = editor.saveFlusherRegistration
            #expect(before != nil, "precondition: loading registered the editor")

            let disappearing = editor.paneDisappeared(appState: state)
            await editor.load(noteID: noteID, worktreeID: worktreeID, appState: state)
            await disappearing.value

            #expect(state.hasNoteSaveFlusher(noteID: noteID),
                    "the disappearing flush removed the reappeared pane's registration")
            #expect(editor.saveFlusherRegistration != nil)
            #expect(editor.saveFlusherRegistration != before, "each load registers afresh")

            await editor.paneDisappeared(appState: state).value

            #expect(!state.hasNoteSaveFlusher(noteID: noteID), "a pane gone for good stays registered")
            #expect(editor.saveFlusherRegistration == nil)
        }
    }

    @Test("the registry does not keep a released editor alive, and its registration then writes nothing")
    func releasedEditorIsNotKeptAlive() async {
        await Fixture.withState { state in
            let root = Editor.useScratchNoteFiles(state)
            defer { try? FileManager.default.removeItem(at: root) }
            let (worktreeID, noteID) = Self.seedNoteTab(state)
            var editor: NotePaneModel? = await Editor.open(state, noteID: noteID, worktreeID: worktreeID)
            weak var released = editor
            #expect(state.hasNoteSaveFlusher(noteID: noteID), "precondition: the editor registered")

            editor = nil

            let wasReleased = released == nil
            #expect(wasReleased, "the registry kept the editor alive")
            await state.flushPendingNoteSave(noteID: noteID)
            #expect(Editor.onDisk(state, worktreeID: worktreeID, noteID: noteID) == nil,
                    "a released editor's registration wrote to the note")
        }
    }

    // MARK: - × on the workspace tab

    @Test("× on a note tab with an edit still pending asks, and declining keeps the tab and the note")
    func closeTabWithPendingEditAsksAndDeclineKeepsAll() async throws {
        try await Fixture.withState { state in
            let root = Editor.useScratchNoteFiles(state)
            defer { try? FileManager.default.removeItem(at: root) }
            let (worktreeID, noteID) = Self.seedNoteTab(state)
            let editor = await Editor.open(state, noteID: noteID, worktreeID: worktreeID)
            Editor.type(Self.typed, into: editor, state: state)
            let notes = Self.stubNoteSeams(state, confirming: false)

            let started = state.closeTab(worktreeID: worktreeID, index: 0)
            let closing = try #require(started, "a note an editor has open closes on a task")
            await closing.value
            await Fixture.drainMainActor()

            #expect(notes.confirmations == 1, "the pending edit makes the note non-empty, so × asks")
            let expectedTabs: [UUID] = [noteID]
            #expect(Self.tabIDs(state, worktreeID) == expectedTabs, "declining keeps the tab")
            #expect(notes.deleted.isEmpty, "declining deletes nothing")
            #expect(Editor.onDisk(state, worktreeID: worktreeID, noteID: noteID) == Self.typed)
        }
    }

    @Test("× on a note tab with an edit still pending, confirmed, closes and deletes the note with the text on disk")
    func closeTabWithPendingEditConfirmedKeepsTextOnDisk() async throws {
        try await Fixture.withState { state in
            let root = Editor.useScratchNoteFiles(state)
            defer { try? FileManager.default.removeItem(at: root) }
            let (worktreeID, noteID) = Self.seedNoteTab(state)
            let editor = await Editor.open(state, noteID: noteID, worktreeID: worktreeID)
            Editor.type(Self.typed, into: editor, state: state)
            let notes = Self.stubNoteSeams(state, confirming: true)

            let started = state.closeTab(worktreeID: worktreeID, index: 0)
            let closing = try #require(started, "a note an editor has open closes on a task")
            await closing.value
            await Fixture.drainMainActor()

            #expect(notes.confirmations == 1)
            #expect(Self.tabIDs(state, worktreeID).isEmpty)
            let expectedDeleted: [UUID] = [noteID]
            #expect(notes.deleted == expectedDeleted)
            #expect(Editor.onDisk(state, worktreeID: worktreeID, noteID: noteID) == Self.typed,
                    "the typed text is in the file the delete keeps")
        }
    }

    @Test("× on an empty note tab whose open editor holds nothing closes and deletes it without asking")
    func closeTabOfEmptyNoteWithEditorClosesWithoutAsking() async throws {
        try await Fixture.withState { state in
            let root = Editor.useScratchNoteFiles(state)
            defer { try? FileManager.default.removeItem(at: root) }
            let (worktreeID, noteID) = Self.seedNoteTab(state)
            let editor = await Editor.open(state, noteID: noteID, worktreeID: worktreeID)
            #expect(editor.loaded, "precondition: the editor loaded the note")
            // Declining would keep the tab, so a prompt cannot go unnoticed.
            let notes = Self.stubNoteSeams(state, confirming: false)

            let started = state.closeTab(worktreeID: worktreeID, index: 0)
            let closing = try #require(started, "a note an editor has open closes on a task")
            await closing.value
            await Fixture.drainMainActor()

            #expect(notes.confirmations == 0)
            #expect(Self.tabIDs(state, worktreeID).isEmpty)
            let expectedDeleted: [UUID] = [noteID]
            #expect(notes.deleted == expectedDeleted)
        }
    }

    @Test("× on a note tab no editor has open closes it before returning")
    func closeTabOfNoteWithoutEditorClosesAtOnce() async {
        await Fixture.withState { state in
            let root = Editor.useScratchNoteFiles(state)
            defer { try? FileManager.default.removeItem(at: root) }
            let (worktreeID, noteID) = Self.seedNoteTab(state)
            let notes = Self.stubNoteSeams(state, confirming: false)

            let closing = state.closeTab(worktreeID: worktreeID, index: 0)

            let closedOnATask = closing != nil
            #expect(!closedOnATask, "nothing to flush, so no task")
            #expect(Self.tabIDs(state, worktreeID).isEmpty, "the tab closed before closeTab returned")
            await Fixture.drainMainActor()
            #expect(notes.confirmations == 0)
            let expectedDeleted: [UUID] = [noteID]
            #expect(notes.deleted == expectedDeleted)
        }
    }

    @Test("a note tab that moves while its save lands is the tab closed")
    func closeTabFindsTheNoteTabAgainAfterTheFlush() async throws {
        try await Fixture.withState { state in
            let root = Editor.useScratchNoteFiles(state)
            defer { try? FileManager.default.removeItem(at: root) }
            let (worktreeID, noteID) = Self.seedNoteTab(state)
            let other = Fixture.terminalTab(label: "shell")
            let inserted = Fixture.terminalTab(label: "inserted")
            state.tabs[worktreeID]?.append(other)
            _ = state.registerNoteSaveFlusher(noteID: noteID) { [weak state] in
                state?.tabs[worktreeID]?.insert(inserted, at: 0)
            }
            let notes = Self.stubNoteSeams(state, confirming: false)

            let started = state.closeTab(worktreeID: worktreeID, index: 0)
            let closing = try #require(started, "a note an editor has open closes on a task")
            await closing.value
            await Fixture.drainMainActor()

            let expectedTabs: [UUID] = [inserted.id, other.id]
            #expect(Self.tabIDs(state, worktreeID) == expectedTabs, "the note tab, now second, closed")
            let expectedDeleted: [UUID] = [noteID]
            #expect(notes.deleted == expectedDeleted)
        }
    }

    @Test("a note tab that closes while its save lands closes nothing else")
    func closeTabOfNoteGoneAfterTheFlushClosesNothing() async throws {
        try await Fixture.withState { state in
            let root = Editor.useScratchNoteFiles(state)
            defer { try? FileManager.default.removeItem(at: root) }
            let (worktreeID, noteID) = Self.seedNoteTab(state)
            let other = Fixture.terminalTab(label: "shell")
            state.tabs[worktreeID]?.append(other)
            _ = state.registerNoteSaveFlusher(noteID: noteID) { [weak state] in
                state?.tabs[worktreeID]?.removeAll { $0.id == noteID }
            }
            let notes = Self.stubNoteSeams(state, confirming: false)

            let started = state.closeTab(worktreeID: worktreeID, index: 0)
            let closing = try #require(started, "a note an editor has open closes on a task")
            await closing.value
            await Fixture.drainMainActor()

            let expectedTabs: [UUID] = [other.id]
            #expect(Self.tabIDs(state, worktreeID) == expectedTabs, "the tab now at the old index stays")
            #expect(notes.confirmations == 0)
            #expect(notes.deleted.isEmpty)
        }
    }
}

/// Every confirmation asked and every note deleted, in order.
@MainActor
final class NoteCloseRecorder {
    private(set) var confirmations = 0
    private(set) var deleted: [UUID] = []

    func confirm(answer: Bool) -> Bool {
        confirmations += 1
        return answer
    }

    func delete(_ noteID: UUID) {
        deleted.append(noteID)
    }
}
