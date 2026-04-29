import SwiftUI
import TBDShared

struct ArchivedWorktreesView: View {
    let repoID: UUID
    @EnvironmentObject var appState: AppState

    private var repo: Repo? {
        appState.repos.first { $0.id == repoID }
    }

    private var archived: [Worktree] {
        (appState.archivedWorktrees[repoID] ?? [])
            .sorted { ($0.archivedAt ?? .distantPast) > ($1.archivedAt ?? .distantPast) }
    }

    var body: some View {
        if archived.isEmpty {
            VStack(spacing: 12) {
                Image(systemName: "archivebox")
                    .font(.system(size: 36))
                    .foregroundStyle(.secondary)
                Text("No Archived Worktrees")
                    .font(.title3)
                    .fontWeight(.medium)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            VStack(spacing: 0) {
                // Header
                HStack {
                    Text("Archived Worktrees")
                        .font(.title3)
                        .fontWeight(.medium)
                    Spacer()
                    Text("\(archived.count) worktree\(archived.count == 1 ? "" : "s")")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 16)

                Divider()

                // List
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(spacing: 1) {
                            ForEach(archived) { worktree in
                                ArchivedWorktreeRow(worktree: worktree)
                                    .id(worktree.id)
                            }
                        }
                        .padding(.vertical, 8)
                    }
                    .onChange(of: appState.highlightedArchivedWorktreeID) { _, newValue in
                        guard let id = newValue,
                              archived.contains(where: { $0.id == id }) else { return }
                        withAnimation(.easeInOut(duration: 0.3)) {
                            proxy.scrollTo(id, anchor: .center)
                        }
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.9) {
                            if appState.highlightedArchivedWorktreeID == id {
                                appState.highlightedArchivedWorktreeID = nil
                            }
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

private struct ArchivedWorktreeRow: View {
    let worktree: Worktree
    @EnvironmentObject var appState: AppState
    @State private var isReviving = false

    private var hasClaudeSessions: Bool {
        worktree.archivedClaudeSessions?.isEmpty == false
    }

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(worktree.displayName)
                        .fontWeight(.medium)
                    if hasClaudeSessions {
                        let count = worktree.archivedClaudeSessions?.count ?? 0
                        Text("\(count) Claude session\(count == 1 ? "" : "s")")
                            .font(.caption)
                            .foregroundStyle(.orange)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(.orange.opacity(0.1), in: Capsule())
                    }
                }
                HStack(spacing: 8) {
                    Label(worktree.branch, systemImage: "arrow.triangle.branch")
                    if let archivedAt = worktree.archivedAt {
                        Text("archived \(archivedAt, format: .relative(presentation: .named))")
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            Spacer()

            Button {
                isReviving = true
                Task {
                    await appState.reviveWorktree(id: worktree.id)
                    isReviving = false
                }
            } label: {
                if isReviving {
                    ProgressView()
                        .controlSize(.small)
                        .frame(width: 60)
                } else {
                    Text("Revive")
                        .frame(width: 60)
                }
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
            .disabled(isReviving)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 10)
        .background(
            appState.highlightedArchivedWorktreeID == worktree.id
                ? Color.accentColor.opacity(0.25)
                : Color.primary.opacity(0.03)
        )
        .animation(.easeInOut(duration: 0.4),
                   value: appState.highlightedArchivedWorktreeID)
        .cornerRadius(6)
        .padding(.horizontal, 12)
    }
}
