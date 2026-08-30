import SwiftUI
import TBDShared

/// A simple text editor pane for freeform notes.
///
/// Rendering and gesture wiring only. The load/save sequence — which is where
/// this pane's data-loss risks live, because one pane hosts many notes in
/// succession — belongs to `NotePaneModel`, where it can be tested.
struct NotePaneView: View {
    let noteID: UUID
    let worktreeID: UUID
    @Environment(AppState.self) var appState
    @State private var model = NotePaneModel()

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
        TextEditor(text: $model.text)
            .font(.system(.body, design: .monospaced))
            .padding(12)
            .scrollContentBackground(.hidden)
            .onChange(of: model.text) { _, newValue in
                model.textEdited(newValue, appState: appState)
            }
            .task(id: noteID) {
                // Content is read off disk when the pane appears — one read
                // per pane the user opens, instead of the daemon reading every
                // note on the machine on every two-second poll.
                //
                // This fires on a note SWAP as well as on first appearance:
                // the pane is reused, keeping its SwiftUI identity, so there is
                // no `onDisappear` in between. `load` flushes the outgoing
                // note's pending save before it reads — see `NotePaneModel`.
                await model.load(
                    noteID: noteID, worktreeID: worktreeID, appState: appState)
            }
            .onDisappear {
                model.paneDisappeared(appState: appState)
            }
    }
}
