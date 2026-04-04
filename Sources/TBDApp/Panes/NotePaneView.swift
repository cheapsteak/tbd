import SwiftUI
import TBDShared

/// A simple text editor pane for freeform notes.
struct NotePaneView: View {
    let noteID: UUID
    let worktreeID: UUID
    @EnvironmentObject var appState: AppState
    @State private var text: String = ""
    @State private var loaded = false
    @State private var saveTask: Task<Void, Never>?

    private var note: Note? {
        appState.notes[worktreeID]?.first { $0.id == noteID }
    }

    var body: some View {
        TextEditor(text: $text)
            .font(.system(.body, design: .monospaced))
            .padding(12)
            .scrollContentBackground(.hidden)
            .background(Color(nsColor: .textBackgroundColor))
            .onChange(of: text) { _, newValue in
                guard loaded else { return }
                debounceSave(content: newValue)
            }
            .onChange(of: note?.content) { _, newContent in
                // Load content when note data arrives from polling
                guard !loaded, let newContent else { return }
                text = newContent
                loaded = true
            }
            .task(id: noteID) {
                if let note {
                    text = note.content
                    loaded = true
                }
            }
            .onDisappear {
                saveTask?.cancel()
                saveTask = nil
                // Flush an immediate save so content isn't lost on tab switch.
                // If the note was deleted, updateNote gets "Note not found"
                // which handleConnectionError already absorbs silently.
                if loaded {
                    Task { await appState.updateNote(noteID: noteID, worktreeID: worktreeID, content: text) }
                }
            }
    }

    private func debounceSave(content: String) {
        saveTask?.cancel()
        saveTask = Task {
            try? await Task.sleep(for: .milliseconds(500))
            guard !Task.isCancelled else { return }
            await appState.updateNote(noteID: noteID, worktreeID: worktreeID, content: content)
        }
    }
}
