import SwiftUI
import TBDShared

/// Archived tab for `ScratchDetailView`: a plain list of archived scratch
/// spaces. Deliberately NOT `ArchivedWorktreesView` (the rich master-detail
/// session-history browser built for repo worktrees) — scratch archive
/// (Stage 2) tears down terminals fully at archive time, exactly like
/// `scratch.delete`, so there are no Claude sessions to browse. No split
/// pane, no pagination — scratch archive volume is expected to be low.
struct ScratchArchivedView: View {
    @EnvironmentObject var appState: AppState
    @State private var pendingDeleteID: UUID?

    private var rows: [Worktree] {
        appState.archivedScratchWorktrees.sorted {
            ($0.archivedAt ?? .distantPast) > ($1.archivedAt ?? .distantPast)
        }
    }

    var body: some View {
        Group {
            if rows.isEmpty {
                emptyState
            } else {
                List(rows) { worktree in
                    row(for: worktree)
                }
                .listStyle(.inset)
            }
        }
        .task {
            await appState.refreshArchivedScratch()
        }
        .confirmationDialog(
            "Delete this scratch space?",
            isPresented: Binding(
                get: { pendingDeleteID != nil },
                set: { if !$0 { pendingDeleteID = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) {
                if let id = pendingDeleteID {
                    Task { await appState.deleteScratch(id: id) }
                }
                pendingDeleteID = nil
            }
            Button("Cancel", role: .cancel) { pendingDeleteID = nil }
        } message: {
            Text("This moves the scratch space's folder to Trash. This cannot be undone.")
        }
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "archivebox")
                .font(.system(size: 36))
                .foregroundStyle(.secondary)
            Text("No Archived Scratch Spaces")
                .font(.title3)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func row(for worktree: Worktree) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(worktree.displayName)
                    .font(.body)
                if let archivedAt = worktree.archivedAt {
                    Text(archivedAt, format: .relative(presentation: .named))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    Text(worktree.path)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            Spacer()
            Button("Revive") {
                Task { await appState.reviveScratch(id: worktree.id) }
            }
            .buttonStyle(.bordered)
            Button("Delete", role: .destructive) {
                pendingDeleteID = worktree.id
            }
            .buttonStyle(.bordered)
        }
        .padding(.vertical, 4)
        .contextMenu {
            Button("Revive") {
                Task { await appState.reviveScratch(id: worktree.id) }
            }
            Button("Delete", role: .destructive) {
                pendingDeleteID = worktree.id
            }
        }
    }
}
