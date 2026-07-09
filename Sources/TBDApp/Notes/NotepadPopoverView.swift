import SwiftUI
import TBDShared

/// Free-text notepad shown in a popover from the nav-header notes button.
/// Content is stored on disk (`NotesFileStore`), shared across all worktrees
/// of a repo, or scoped to the worktree for scratch worktrees.
///
/// Read-on-open + dirty-tracking: the editor re-reads the file every time it
/// appears and only writes back when the user has actually changed the text,
/// so an untouched open never clobbers an edit made outside TBD.
struct NotepadPopoverView: View {
    let scope: NotesScope

    private let store = NotesFileStore()
    @State private var content: String = ""
    @State private var loadedContent: String = ""
    @State private var didLoad = false
    @State private var saveTask: Task<Void, Never>?
    @FocusState private var editorFocused: Bool

    private var placeholder: String {
        switch scope {
        case .repo: return "Notes for this repo — shared across all its worktrees"
        case .worktree: return "Notes for this worktree"
        }
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            TextEditor(text: $content)
                .font(.body)
                .scrollContentBackground(.hidden)
                .focused($editorFocused)

            if content.isEmpty {
                Text(placeholder)
                    .font(.body)
                    .foregroundStyle(.tertiary)
                    .padding(.leading, 5)
                    .allowsHitTesting(false)
            }
        }
        .frame(width: 360, height: 280)
        .padding(10)
        .defaultFocus($editorFocused, true)
        .onChange(of: content) { _, newValue in
            guard didLoad else { return }
            debounceSave(newValue)
        }
        .task(id: scope.notesPath) {
            let disk = store.read(at: scope.notesPath)
            content = disk
            loadedContent = disk
            didLoad = true
            try? await Task.sleep(for: .milliseconds(200))
            editorFocused = true
        }
        .onDisappear {
            saveTask?.cancel()
            saveTask = nil
            flushSave()
        }
    }

    private func debounceSave(_ newValue: String) {
        saveTask?.cancel()
        saveTask = Task {
            try? await Task.sleep(for: .milliseconds(500))
            guard !Task.isCancelled else { return }
            flushSave()
        }
    }

    /// Writes only when the user has actually modified the loaded content.
    private func flushSave() {
        guard didLoad, content != loadedContent else { return }
        store.write(content, to: scope.notesPath)
        loadedContent = content
    }
}
