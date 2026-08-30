import SwiftUI
import TBDShared

/// A simple text editor pane for freeform notes.
struct NotePaneView: View {
    let noteID: UUID
    let worktreeID: UUID
    @Environment(AppState.self) var appState
    @State private var text: String = ""
    @State private var loaded = false
    @State private var saveTask: Task<Void, Never>?
    /// Which note `saveTask` is saving. One pane can host two notes in
    /// succession (see `.task(id: noteID)` below), and a pending save must
    /// never be cancelled by whoever came after it — see `debounceSave`.
    @State private var saveTaskNoteID: UUID?

    /// Metadata only — `appState.notes` is polled from `note.list`, which
    /// carries no content. Used here for the title; the editor's text is read
    /// off disk once on appear (see `.task(id: noteID)` below).
    private var note: NoteSummary? {
        appState.notes[worktreeID]?.first { $0.id == noteID }
    }

    /// Where this note's content lives on disk. Written by THIS app now (the
    /// daemon is out of the content path); the file exists only once the note
    /// has non-empty content, but the would-be path is shown regardless —
    /// file-backed settings convention, see `RepoHooksSettingsView`. Resolved
    /// through `noteContentPathResolver` so the advertised path is by
    /// construction the one that gets read and written.
    private var contentFilePath: String {
        appState.noteContentPathResolver(worktreeID, noteID)
    }

    var body: some View {
        VStack(spacing: 0) {
            editor
            footer
        }
        .background(Color(nsColor: .textBackgroundColor))
    }

    private var footer: some View {
        HStack(spacing: 4) {
            Text(contentFilePath.replacingOccurrences(of: NSHomeDirectory(), with: "~"))
                .font(.caption.monospaced())
                .foregroundStyle(.tertiary)
                .lineLimit(1)
                .truncationMode(.middle)
            Button {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(contentFilePath, forType: .string)
            } label: {
                Image(systemName: "doc.on.doc")
                    .font(.caption)
            }
            .buttonStyle(.borderless)
            .foregroundStyle(.secondary)
            .help("Copy full path")
            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.bottom, 6)
    }

    private var editor: some View {
        TextEditor(text: $text)
            .font(.system(.body, design: .monospaced))
            .padding(12)
            .scrollContentBackground(.hidden)
            .onChange(of: text) { _, newValue in
                guard loaded else { return }
                debounceSave(content: newValue)
            }
            .task(id: noteID) {
                // Content is read off disk when the pane appears — one read
                // per pane the user opens, instead of the daemon reading every
                // note on the machine on every two-second poll.
                //
                // Reset BOTH, because this pane is REUSED when its slot is
                // swapped from one note to another (`navigateHistory` keeps
                // the pane UUID, and `NotePaneView` is not `.id`-keyed):
                // leaving `text` alone would show the previous note's words
                // under the new note's title for as long as the load takes,
                // or forever if it fails.
                //
                // A failed load then leaves the editor empty and `loaded`
                // FALSE on purpose. `loaded` gates both the debounced autosave
                // and the onDisappear flush below, so without that guard a
                // failed load would save an empty note on the next keystroke
                // or tab switch — deleting the content file on disk.
                loaded = false
                text = ""
                guard let content = await appState.noteContent(
                    noteID: noteID, worktreeID: worktreeID
                ) else { return }
                // This task may no longer be the authoritative one. `.task(id:)`
                // cancels the outgoing task when `noteID` changes, but
                // cancellation is cooperative and the read above does not
                // throw — so a slow load started for the PREVIOUS note keeps
                // running and would otherwise assign its text here, over a new
                // note that has already loaded, and set `loaded` on it. The
                // next keystroke or tab switch would then write the old note's
                // words into the new note's file. `loaded` cannot catch this:
                // the stale task is what sets it.
                guard !Task.isCancelled else { return }
                text = content
                loaded = true
            }
            .onDisappear {
                // Same rule as `debounceSave`: only cancel a save that is
                // this note's. Dropping the reference does not cancel it, so
                // an outgoing note's pending save still lands.
                if saveTaskNoteID == noteID {
                    saveTask?.cancel()
                }
                saveTask = nil
                saveTaskNoteID = nil
                // Flush an immediate save so content isn't lost on tab switch.
                if loaded {
                    Task {
                        await appState.saveNoteContent(
                            noteID: noteID, worktreeID: worktreeID, content: text)
                    }
                }
            }
    }

    private func debounceSave(content: String) {
        // Cancel only a pending save for THIS note. `saveTask` is one @State
        // slot, and the pane survives a swap from one note to another, so an
        // unconditional cancel here discards the previous note's unsaved edit
        // on the first keystroke in the new one — with no `onDisappear` to
        // catch it, because the pane was reused rather than torn down. Leaving
        // the other note's task uncancelled lets it complete: it captured this
        // view's value, so it writes the right text to the right path.
        if saveTaskNoteID == noteID {
            saveTask?.cancel()
        }
        saveTaskNoteID = noteID
        saveTask = Task {
            // swiftlint:disable:next no_raw_task_sleep - legacy sleep, see docs/specs/2026-07-24-test-hardening-design.md
            try? await Task.sleep(for: .milliseconds(500))
            guard !Task.isCancelled else { return }
            await appState.saveNoteContent(
                noteID: noteID, worktreeID: worktreeID, content: content)
        }
    }
}
