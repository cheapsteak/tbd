import SwiftUI
import TBDShared

struct ArchivedWorktreesView: View {
    let repoID: UUID
    @EnvironmentObject var appState: AppState

    @State private var listWidth: CGFloat = 280
    @State private var dragStartWidth: CGFloat? = nil

    /// Display rows = archived worktrees ∪ lingering revive snapshots,
    /// deduped by id, sorted by archivedAt desc.
    private var rows: [ArchivedRow] {
        let archived = (appState.archivedWorktrees[repoID] ?? [])
        let lingering = appState.revivingArchived
            .compactMap { (id, state) -> Worktree? in
                guard state.snapshot.repoID == repoID else { return nil }
                return state.snapshot
            }
        var byID: [UUID: Worktree] = [:]
        for wt in archived { byID[wt.id] = wt }
        for wt in lingering where byID[wt.id] == nil { byID[wt.id] = wt }
        return byID.values
            .sorted { ($0.archivedAt ?? .distantPast) > ($1.archivedAt ?? .distantPast) }
            .map { wt in
                ArchivedRow(worktree: wt, reviveState: appState.revivingArchived[wt.id])
            }
    }

    private var selectedID: UUID? {
        appState.selectedArchivedWorktreeIDs[repoID]
    }

    var body: some View {
        if rows.isEmpty {
            emptyState
        } else {
            HStack(spacing: 0) {
                leftRail
                    .frame(width: listWidth)
                divider
                rightPane
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    // MARK: - Left rail

    private var leftRail: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Archived")
                    .font(.title3)
                    .fontWeight(.medium)
                Spacer()
                Text("\(rows.count)")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)

            Divider()

            ScrollViewReader { proxy in
                List(rows) { row in
                    ArchivedWorktreeRow(
                        row: row,
                        isSelected: selectedID == row.id
                    )
                    .id(row.id)
                    .contentShape(Rectangle())
                    .onTapGesture { select(row) }
                    .listRowInsets(EdgeInsets(top: 6, leading: 12, bottom: 6, trailing: 12))
                    .listRowBackground(rowBackground(for: row))
                    .listRowSeparator(.hidden)
                    .contextMenu {
                        if row.reviveState == nil {
                            Button("Revive") {
                                Task { await appState.reviveWorktree(id: row.worktree.id) }
                            }
                        }
                    }
                }
                .listStyle(.plain)
                .onChange(of: appState.highlightedArchivedWorktreeID, initial: true) { _, newValue in
                    guard let id = newValue, rows.contains(where: { $0.id == id }) else { return }
                    withAnimation(.easeInOut(duration: 0.3)) {
                        proxy.scrollTo(id, anchor: .center)
                    }
                    Task { @MainActor in
                        try? await Task.sleep(for: .milliseconds(900))
                        if appState.highlightedArchivedWorktreeID == id {
                            appState.highlightedArchivedWorktreeID = nil
                        }
                    }
                }
            }
        }
        .onAppear {
            // Trigger initial selection if nothing is set yet. The async refresh
            // path also calls into `ensureArchivedSelectionValid`, but on
            // re-appearances (cached `archivedWorktrees`) we still need this.
            if selectedID == nil,
               let first = rows.first(where: { $0.reviveState == nil })?.worktree {
                appState.selectedArchivedWorktreeIDs[repoID] = first.id
                Task { await appState.fetchSessions(worktreeID: first.id) }
            }
        }
    }

    private var divider: some View {
        Rectangle()
            .fill(Color(nsColor: .separatorColor))
            .frame(width: 1)
            .contentShape(Rectangle().inset(by: -3))
            .cursor(.resizeLeftRight)
            .gesture(
                DragGesture()
                    .onChanged { value in
                        if dragStartWidth == nil { dragStartWidth = listWidth }
                        let newWidth = (dragStartWidth ?? listWidth) + value.translation.width
                        listWidth = max(220, min(400, newWidth))
                    }
                    .onEnded { _ in dragStartWidth = nil }
            )
    }

    // MARK: - Right pane

    @ViewBuilder
    private var rightPane: some View {
        if let id = selectedID,
           let row = rows.first(where: { $0.id == id }) {
            if (row.worktree.archivedClaudeSessions ?? []).isEmpty {
                noSessionsState(for: row.worktree)
            } else {
                HistoryPaneView(worktreeID: id, transcriptAction: .reviveWithSession)
            }
        } else {
            VStack(spacing: 8) {
                Text("Select a worktree")
                    .foregroundStyle(.secondary)
                    .font(.callout)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func noSessionsState(for worktree: Worktree) -> some View {
        VStack(spacing: 12) {
            Image(systemName: "bubble.left.and.bubble.right")
                .font(.system(size: 32))
                .foregroundStyle(.tertiary)
            Text("No archived sessions")
                .foregroundStyle(.secondary)
                .font(.callout)
            Button("Revive") {
                Task { await appState.reviveWorktree(id: worktree.id) }
            }
            .buttonStyle(.borderedProminent)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Empty list state

    private var emptyState: some View {
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
    }

    // MARK: - Actions

    private func select(_ row: ArchivedRow) {
        // In-flight or done revives are non-selectable.
        guard row.reviveState == nil else { return }
        appState.selectedArchivedWorktreeIDs[repoID] = row.id
        Task { await appState.fetchSessions(worktreeID: row.id) }
    }

    private func rowBackground(for row: ArchivedRow) -> Color {
        if appState.highlightedArchivedWorktreeID == row.id {
            return Color.accentColor.opacity(0.25)
        }
        if selectedID == row.id {
            return Color.accentColor.opacity(0.15)
        }
        return Color.clear
    }
}

// MARK: - Row model

private struct ArchivedRow: Identifiable {
    let worktree: Worktree
    let reviveState: ReviveState?
    var id: UUID { worktree.id }
}

// MARK: - Row view

private struct ArchivedWorktreeRow: View {
    let row: ArchivedRow
    let isSelected: Bool

    private var hasClaudeSessions: Bool {
        row.worktree.archivedClaudeSessions?.isEmpty == false
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Text(row.worktree.displayName)
                    .font(.callout)
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                statusPill
            }
            HStack(spacing: 4) {
                Text(row.worktree.branch)
                    .lineLimit(1)
                if let archivedAt = row.worktree.archivedAt, row.reviveState == nil {
                    separator
                    Text(archivedAt, format: .relative(presentation: .named))
                }
                if hasClaudeSessions, row.reviveState == nil {
                    let count = row.worktree.archivedClaudeSessions?.count ?? 0
                    separator
                    Text("\(count) session\(count == 1 ? "" : "s")")
                }
            }
            .font(.caption2)
            .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 3)
    }

    private var separator: some View {
        Text("·").foregroundStyle(.quaternary).font(.caption2)
    }

    @ViewBuilder
    private var statusPill: some View {
        switch row.reviveState {
        case .inFlight:
            HStack(spacing: 4) {
                ProgressView().controlSize(.mini)
                Text("Reviving…")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        case .done:
            Text("Revived ✓")
                .font(.caption)
                .foregroundStyle(.green)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(.green.opacity(0.12), in: Capsule())
        case .none:
            EmptyView()
        }
    }

}
