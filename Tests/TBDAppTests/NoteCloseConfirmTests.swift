import Foundation
import TestSupport
import Testing
@testable import TBDApp
import TBDShared

/// Closing a note tab hard-deletes the note row, so `closeTab` asks for
/// confirmation when the note has content (empty notes close silently).
/// The confirmer is injectable (`AppState.noteCloseConfirmer`) so both
/// branches run without a real modal NSAlert.
///
/// Constructs `AppState(userDefaults:)` against a throwaway suite —
/// `UserDefaults.standard` on this unbundled executable is the developer's
/// real TBDApp.plist (see TabUnreadCompletionTests).
@MainActor
@Suite("Note close confirmation")
struct NoteCloseConfirmTests {

    private func withState(_ body: (AppState) -> Void) {
        let defaultsSuite = TestDefaultsSuite("NoteCloseConfirm")
        defer { defaultsSuite.tearDown() }
        let defaults = defaultsSuite.defaults
        body(AppState(userDefaults: defaults))
    }

    private func makeNoteTab(
        state: AppState, worktreeID: UUID, content: String
    ) -> Note {
        let note = Note(worktreeID: worktreeID, title: "Notes", content: content)
        state.notes = [worktreeID: [note]]
        state.tabs = [worktreeID: [
            Tab(id: note.id, content: .note(noteID: note.id), label: nil)
        ]]
        return note
    }

    @Test func nonEmptyNoteDeclinedKeepsTab() {
        withState { state in
            let worktreeID = UUID()
            let note = makeNoteTab(state: state, worktreeID: worktreeID, content: "important")
            var asked = false
            state.noteCloseConfirmer = { _ in
                asked = true
                return false
            }

            state.closeTab(worktreeID: worktreeID, index: 0)

            #expect(asked, "a non-empty note must prompt before closing")
            #expect(state.tabs[worktreeID]?.contains { $0.id == note.id } == true,
                    "declining the prompt must keep the tab")
        }
    }

    @Test func nonEmptyNoteConfirmedClosesTab() {
        withState { state in
            let worktreeID = UUID()
            let note = makeNoteTab(state: state, worktreeID: worktreeID, content: "important")
            state.noteCloseConfirmer = { _ in true }

            state.closeTab(worktreeID: worktreeID, index: 0)

            #expect(state.tabs[worktreeID]?.contains { $0.id == note.id } != true,
                    "confirming the prompt must close the tab")
        }
    }

    @Test func emptyNoteClosesSilently() {
        withState { state in
            let worktreeID = UUID()
            let note = makeNoteTab(state: state, worktreeID: worktreeID, content: "  \n")
            var asked = false
            state.noteCloseConfirmer = { _ in
                asked = true
                return false
            }

            state.closeTab(worktreeID: worktreeID, index: 0)

            #expect(!asked, "an empty (whitespace-only) note must not prompt")
            #expect(state.tabs[worktreeID]?.contains { $0.id == note.id } != true,
                    "an empty note tab must close silently as before")
        }
    }
}
