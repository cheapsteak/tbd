import SwiftUI
import TBDShared

struct ArchivedWorktreesView: View {
    let repoID: UUID
    @EnvironmentObject var appState: AppState

    @State private var listWidth: CGFloat = 280
    @State private var dragStartWidth: CGFloat? = nil
    @AppStorage("archived.hideEmpty") private var hideEmpty: Bool = true

    /// All archived rows for this repo (∪ lingering revive snapshots), unfiltered.
    /// Used for the unfiltered count and to back the filter visibility decision.
    private var allRows: [ArchivedRow] {
        let archived = (appState.archivedWorktrees[repoID] ?? [])
        let lingering = appState.revivingArchived
            .compactMap { (_, state) -> Worktree? in
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

    /// Visible rows after applying the current filter. Lingering revives
    /// always pass through so a just-revived row doesn't vanish mid-flight.
    private var rows: [ArchivedRow] {
        guard hideEmpty else { return allRows }
        return allRows.filter { row in
            row.reviveState != nil
                || row.worktree.archivedClaudeSessions?.isEmpty == false
        }
    }

    private var selectedID: UUID? {
        appState.selectedArchivedWorktreeIDs[repoID]
    }

    var body: some View {
        if allRows.isEmpty {
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
            HStack(spacing: 8) {
                Text("Archived")
                    .font(.title3)
                    .fontWeight(.medium)
                Spacer()
                if hideEmpty && rows.count < allRows.count {
                    Text("\(rows.count) of \(allRows.count)")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                } else {
                    Text("\(rows.count)")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                Menu {
                    Toggle("Hide worktrees with no conversations", isOn: $hideEmpty)
                } label: {
                    Image(systemName: hideEmpty
                          ? "line.3.horizontal.decrease.circle.fill"
                          : "line.3.horizontal.decrease.circle")
                        .foregroundStyle(hideEmpty ? Color.accentColor : .secondary)
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .help("Filter")
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)

            Divider()

            ScrollViewReader { proxy in
                if rows.isEmpty {
                    VStack(spacing: 8) {
                        Image(systemName: "line.3.horizontal.decrease.circle")
                            .font(.system(size: 28))
                            .foregroundStyle(.tertiary)
                        Text("No matches")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                        Button("Show all") { hideEmpty = false }
                            .buttonStyle(.link)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
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
        }
        .onAppear { reconcileSelection() }
        .onChange(of: hideEmpty) { _, _ in reconcileSelection() }
    }

    /// Make sure `selectedArchivedWorktreeIDs[repoID]` points to a row that
    /// is currently visible. Picks the first non-lingering visible row when
    /// unset or stale; clears when nothing is visible. Triggers a session
    /// fetch for any newly-selected row.
    private func reconcileSelection() {
        let visibleIDs = Set(rows.map(\.id))
        if let current = selectedID, visibleIDs.contains(current) { return }
        if let first = rows.first(where: { $0.reviveState == nil })?.worktree {
            appState.selectedArchivedWorktreeIDs[repoID] = first.id
            Task { await appState.fetchSessions(worktreeID: first.id) }
        } else {
            appState.selectedArchivedWorktreeIDs.removeValue(forKey: repoID)
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
