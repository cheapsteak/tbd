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
    /// The on-disk path that `content`/`loadedContent` were loaded from, so a
    /// flush always writes back to the file the edit belongs to — even if
    /// `scope` has since changed to a different worktree/repo.
    @State private var loadedPath: String = ""
    @State private var saveTask: Task<Void, Never>?
    @FocusState private var editorFocused: Bool
    /// Dismisses the containing popover after an open-in-app action, so the
    /// notepad doesn't keep showing content that goes stale while the file is
    /// edited externally (it re-reads from disk on the next presentation).
    @Environment(\.dismiss) private var dismiss

    private var placeholder: String {
        switch scope {
        case .repo: return "Notes for this repo — shared across all its worktrees"
        case .worktree: return "Notes for this worktree"
        }
    }

    /// Matches the notes button tooltip wording in `WorktreeTitleView`.
    private var title: String {
        switch scope {
        case .repo: return "Repo notes"
        case .worktree: return "Worktree notes"
        }
    }

    /// MRU key for the open-in control: the repo when repo-scoped, else nil
    /// (scratch worktrees fall back to the shared "scratch" MRU key).
    private var openInRepoID: UUID? {
        if case .repo(let id) = scope { return id }
        return nil
    }

    var body: some View {
        VStack(spacing: 4) {
            HStack {
                Text(title)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                OpenInEditorButton(path: scope.notesPath, repoID: openInRepoID, beforeOpen: {
                    // Flush any pending debounced edit, then make sure the
                    // file exists on disk (it won't yet when the notepad is
                    // empty — `write` deletes empty files) so the editor
                    // opens the real path.
                    saveTask?.cancel()
                    saveTask = nil
                    flushSave()
                    store.ensureFileExists(at: scope.notesPath)
                }, afterOpen: {
                    dismiss()
                })
            }

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
        }
        .frame(width: 360, height: 308)
        .padding(10)
        .defaultFocus($editorFocused, true)
        .onChange(of: content) { _, newValue in
            guard didLoad else { return }
            debounceSave(newValue)
        }
        .task(id: scope.notesPath) {
            // Flush any pending edit for the previously-loaded scope before
            // we overwrite `content` with the new scope's file. Without this,
            // a scope change mid-debounce (e.g. Cmd+[ / Cmd+] while the
            // popover is open) silently drops the unsaved edit.
            saveTask?.cancel()
            saveTask = nil
            flushSave()

            let path = scope.notesPath
            let disk = store.read(at: path)
            content = disk
            loadedContent = disk
            loadedPath = path
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

    /// Writes only when the user has actually modified the loaded content, and
    /// always to the path that content came from (`loadedPath`).
    private func flushSave() {
        guard didLoad, !loadedPath.isEmpty, content != loadedContent else { return }
        store.write(content, to: loadedPath)
        loadedContent = content
    }
}
