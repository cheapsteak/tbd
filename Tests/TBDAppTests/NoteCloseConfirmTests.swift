import Foundation
import Testing
@testable import TBDApp
import TBDShared

/// Closing a note tab hard-deletes the note row, so `closeTab` asks for
/// confirmation when the note has content (empty notes close silently).
/// The branch is driven by `AppState.noteHasContent`, the union of the polled
/// summary's `hasLegacyContent` and a single stat of the content file — the
/// daemon does no filesystem work for `note.list`, so `closeTab` cannot
/// inspect the text and does not need to. These cases drive the legacy leg;
/// the file leg needs no note row of its own, since a fresh UUID has no file.
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
        let suiteName = "TBDAppTests.NoteCloseConfirm.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("tbd-note-close-\(UUID().uuidString)")
        defer {
            defaults.removePersistentDomain(forName: suiteName)
            try? FileManager.default.removeItem(at: dir)
        }
        let state = AppState(userDefaults: defaults)
        // Point the file leg of `noteHasContent` at an empty temp directory,
        // so these cases exercise the legacy leg alone and never depend on the
        // process-global TBD_HOME (see NoteContentFileAccessTests).
        state.noteContentPathResolver = { worktreeID, noteID in
            dir.appendingPathComponent(worktreeID.uuidString)
                .appendingPathComponent("\(noteID.uuidString).md").path
        }
        body(state)
    }

    private func makeNoteTab(
        state: AppState, worktreeID: UUID, hasLegacyContent: Bool
    ) -> NoteSummary {
        let note = NoteSummary(worktreeID: worktreeID, title: "Notes",
                               hasLegacyContent: hasLegacyContent)
        state.notes = [worktreeID: [note]]
        state.tabs = [worktreeID: [
            Tab(id: note.id, content: .note(noteID: note.id), label: nil)
        ]]
        return note
    }

    @Test func nonEmptyNoteDeclinedKeepsTab() {
        withState { state in
            let worktreeID = UUID()
            let note = makeNoteTab(state: state, worktreeID: worktreeID, hasLegacyContent: true)
            var asked = false
            state.noteCloseConfirmer = { _, _ in
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
            let note = makeNoteTab(state: state, worktreeID: worktreeID, hasLegacyContent: true)
            state.noteCloseConfirmer = { _, _ in true }

            state.closeTab(worktreeID: worktreeID, index: 0)

            #expect(state.tabs[worktreeID]?.contains { $0.id == note.id } != true,
                    "confirming the prompt must close the tab")
        }
    }

    @Test func emptyNoteClosesSilently() {
        withState { state in
            let worktreeID = UUID()
            let note = makeNoteTab(state: state, worktreeID: worktreeID, hasLegacyContent: false)
            var asked = false
            state.noteCloseConfirmer = { _, _ in
                asked = true
                return false
            }

            state.closeTab(worktreeID: worktreeID, index: 0)

            #expect(!asked, "a note with no content must not prompt")
            #expect(state.tabs[worktreeID]?.contains { $0.id == note.id } != true,
                    "a contentless note tab must close silently as before")
        }
    }
}
