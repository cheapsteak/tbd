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

    /// Where this note's content lives on disk (daemon-written; the file
    /// exists only once the note has non-empty content, but the would-be
    /// path is shown regardless — file-backed settings convention, see
    /// `RepoHooksSettingsView`).
    private var contentFilePath: String {
        TBDConstants.noteContentPath(worktreeID: worktreeID, noteID: noteID)
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
            // swiftlint:disable:next no_raw_task_sleep - legacy sleep, see docs/specs/2026-07-24-test-hardening-design.md
            try? await Task.sleep(for: .milliseconds(500))
            guard !Task.isCancelled else { return }
            await appState.updateNote(noteID: noteID, worktreeID: worktreeID, content: content)
        }
    }
}
