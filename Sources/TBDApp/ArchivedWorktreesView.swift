import SwiftUI
import TBDShared

/// Pure substring match behind the archived list's search field: folder `name`
/// OR `displayName`, case-insensitive, no fuzzy matching. A blank query matches
/// everything.
///
/// This is also the documented semantics of the daemon-side filter
/// (`WorktreeStore.list(nameQuery:)`, SQL `LIKE '%q%'` over the same two
/// columns) — the two are kept deliberately identical so the client-side
/// preview shown during the debounce window is a subset of the daemon's answer
/// rather than a different question. Extracted from the view so it is
/// unit-testable without SwiftUI (same pattern as `PaneHistoryPaletteFilter`).
enum ArchivedWorktreeSearchFilter {
    static func matches(name: String, displayName: String, query: String) -> Bool {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !needle.isEmpty else { return true }
        return name.lowercased().contains(needle)
            || displayName.lowercased().contains(needle)
    }

    static func matches(_ worktree: Worktree, query: String) -> Bool {
        matches(name: worktree.name, displayName: worktree.displayName, query: query)
    }
}

/// One repo's archived-search answer: the rows the daemon returned, the query
/// they answer, and whether more pages of matches exist — held as ONE value so
/// the rows and their query can never disagree.
///
/// They did disagree when these were separate `AppState` dicts: the in-flight
/// query was stamped *before* the await while the rows were replaced *after*
/// it, so for the whole in-flight window the view saw "stored query == typed
/// query" and rendered the PREVIOUS query's rows as a settled answer. Since
/// daemon results are deliberately not re-filtered client-side (they arrive
/// pre-filtered), that showed rows which do not match what the user typed — a
/// superset of the true answer, i.e. exactly the failure the client-side
/// preview exists to prevent. Typing appeared not to narrow the list.
struct ArchivedSearchResults {
    /// The trimmed query these rows answer.
    let query: String
    let worktrees: [Worktree]
    /// Whether more pages of matches exist beyond `worktrees`.
    let hasMore: Bool
}

/// Page-preserving refetch arithmetic, shared by the unsearched archived
/// refresh and the search refresh so the invariant lives in one place.
///
/// The invariant (PR #236): a refresh must not collapse pages the user already
/// pulled in with "Load More", so it re-fetches `max(currentCount, pageSize)`
/// rows rather than one page. `knownExhausted` is the other half — a partial
/// last page proves the server has nothing more, and without it the larger
/// refetch (which returns fewer rows than it asked for) would keep re-arming
/// "Load More" forever.
struct ArchivedRefreshPlan {
    let fetchCount: Int
    let knownExhausted: Bool

    init(currentCount: Int, pageSize: Int) {
        fetchCount = max(currentCount, pageSize)
        knownExhausted = currentCount > 0 && currentCount % pageSize != 0
    }

    func hasMore(fetched: Int) -> Bool {
        knownExhausted ? false : fetched >= fetchCount
    }
}

/// Which row set the archived list should show, given the query in the field
/// and the query the results in hand actually answer. Pure and total, so the
/// stale-results branch is directly testable without a daemon seam.
enum ArchivedSearchDisplay {
    enum Decision: Equatable {
        /// No query: show every loaded archived row.
        case unfiltered
        /// The results in hand answer exactly this query, so they ARE the row
        /// set — they span archives beyond the locally loaded pages.
        case daemonResults
        /// No answer for *this* query yet: debounce window, in-flight RPC,
        /// results left over from an earlier query, or a failed search. Filter
        /// the loaded rows client-side instead.
        case clientPreview
    }

    /// - Parameter resultsQuery: the query carried by the stored
    ///   `ArchivedSearchResults`, or nil when none have landed. Never the
    ///   in-flight query — see `AppState.archivedSearchQuery`.
    static func decide(query: String, resultsQuery: String?) -> Decision {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .unfiltered }
        guard resultsQuery == trimmed else { return .clientPreview }
        return .daemonResults
    }
}

struct ArchivedWorktreesView: View {
    let repoID: UUID
    @EnvironmentObject var appState: AppState

    @State private var listWidth: CGFloat = 280
    @State private var dragStartWidth: CGFloat? = nil
    @AppStorage("archived.hideEmpty") private var hideEmpty: Bool = true

    /// Raw text in the search field. This view is NOT `.id(repoID)`-keyed by
    /// `RepoDetailView`, so its `@State` survives a repo switch — hence the
    /// explicit reset in `.onChange(of: repoID)` below.
    @State private var searchQuery: String = ""
    /// Keystrokes must not each become an RPC. Trailing-edge, clock-injected;
    /// see `SearchQueryDebouncer`.
    @State private var searchDebouncer = SearchQueryDebouncer()

    private var trimmedQuery: String {
        searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var isSearching: Bool { !trimmedQuery.isEmpty }

    /// What to render for the query currently in the field. Compares against
    /// the query the stored results ACTUALLY answer — never the in-flight one,
    /// which is stamped before its response lands.
    private var displayDecision: ArchivedSearchDisplay.Decision {
        ArchivedSearchDisplay.decide(
            query: searchQuery,
            resultsQuery: appState.archivedSearchResults[repoID]?.query
        )
    }

    /// Daemon-side results for *exactly* the query currently in the field, or
    /// nil while that answer hasn't landed (debounce window, in-flight RPC,
    /// leftovers from an earlier query, or a failed search).
    private var settledSearchResults: ArchivedSearchResults? {
        guard displayDecision == .daemonResults else { return nil }
        return appState.archivedSearchResults[repoID]
    }

    /// True when the search RPC for the current query failed and the list is
    /// therefore showing the client-side preview of loaded rows only.
    private var searchFailed: Bool {
        isSearching && appState.archivedSearchFailed[repoID] == true
    }

    /// Merge a worktree list with this repo's lingering revive snapshots (so a
    /// just-revived row doesn't vanish mid-flight), sort `archivedAt` desc, and
    /// wrap in rows. `lingeringQuery` non-nil additionally requires those
    /// snapshots to match it — daemon results arrive already filtered, local
    /// snapshots don't.
    private func makeRows(_ worktrees: [Worktree], lingeringQuery: String?) -> [ArchivedRow] {
        var byID: [UUID: Worktree] = [:]
        for wt in worktrees { byID[wt.id] = wt }
        for (_, state) in appState.revivingArchived {
            let wt = state.snapshot
            guard wt.repoID == repoID, byID[wt.id] == nil else { continue }
            if let lingeringQuery,
               !ArchivedWorktreeSearchFilter.matches(wt, query: lingeringQuery) { continue }
            byID[wt.id] = wt
        }
        return byID.values
            .sorted { ($0.archivedAt ?? .distantPast) > ($1.archivedAt ?? .distantPast) }
            .map { wt in
                ArchivedRow(worktree: wt, reviveState: appState.revivingArchived[wt.id])
            }
    }

    /// All *loaded* archived rows for this repo (∪ lingering revive snapshots),
    /// ignoring both filters. Backs the "this repo has no archives at all"
    /// empty state.
    private var allRows: [ArchivedRow] {
        makeRows(appState.archivedWorktrees[repoID] ?? [], lingeringQuery: nil)
    }

    /// Rows after the search filter (before `hideEmpty`).
    ///
    /// While the daemon's answer for the current query hasn't arrived, this
    /// falls back to filtering the already-loaded rows client-side rather than
    /// showing an empty list or stale unfiltered rows. That preview is a close
    /// approximation, not a guaranteed subset. For the *archived* rows it is
    /// one: they are the newest N of the archived set in the same
    /// `archivedAt desc` order the daemon returns, so the daemon's answer only
    /// ever extends them. But `allRows` also unions in every lingering
    /// `revivingArchived` snapshot — including `.done` ones whose worktree is
    /// no longer archived server-side — so the preview can briefly show a row
    /// the daemon would not return. That is the same deliberate "don't yank a
    /// just-revived row out from under the user" behaviour the unsearched list
    /// already has, not a search-specific inconsistency.
    private var searchedRows: [ArchivedRow] {
        switch displayDecision {
        case .unfiltered:
            return allRows
        case .daemonResults:
            guard let results = settledSearchResults else { return allRows }
            return makeRows(results.worktrees, lingeringQuery: results.query)
        case .clientPreview:
            return allRows.filter {
                ArchivedWorktreeSearchFilter.matches($0.worktree, query: trimmedQuery)
            }
        }
    }

    /// Visible rows after applying every filter. Lingering revives always pass
    /// the `hideEmpty` filter so a just-revived row doesn't vanish mid-flight.
    private var rows: [ArchivedRow] {
        guard hideEmpty else { return searchedRows }
        return searchedRows.filter { row in
            row.reviveState != nil || row.effectiveSessionCount > 0
        }
    }

    private var selectedID: UUID? {
        appState.selectedArchivedWorktreeIDs[repoID]
    }

    /// "Reclaimed" section selection, mutually exclusive with `selectedID`
    /// (see `AppState.selectArchivedWorktree(_:repoID:)` /
    /// `selectReapRecord(_:repoID:)`).
    private var selectedReapID: UUID? {
        appState.selectedReapRecordIDs[repoID]
    }

    /// Whether the *currently displayed* set has more pages. While a search is
    /// active but unsettled we have no verified answer for the matching set, so
    /// no "Load More" is offered.
    private var hasMore: Bool {
        if isSearching {
            guard let settled = settledSearchResults else { return false }
            return settled.hasMore
        }
        return appState.archivedWorktreesHasMore[repoID] == true
    }

    var body: some View {
        // "No archives at all" and "the search found nothing" are distinct: the
        // latter must keep the rail (and its search field) on screen.
        if allRows.isEmpty && !isSearching {
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
                // Counts describe the *searched* set when a query is active,
                // the whole loaded set otherwise (identical when not searching).
                if hideEmpty && rows.count < searchedRows.count {
                    Text("\(rows.count) of \(searchedRows.count)\(hasMore ? "+" : "")")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                } else if hasMore {
                    Text("\(rows.count)+")
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
            .padding(.top, 12)
            .padding(.bottom, 8)

            searchField

            // A failed search silently degrades to the client-side preview,
            // which is a partial answer over the loaded pages only — say so
            // rather than letting it pass as the real result set.
            if searchFailed {
                Text("Search failed — showing loaded results only")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 16)
                    .padding(.bottom, 8)
            }

            Divider()

            ScrollViewReader { proxy in
                if rows.isEmpty {
                    noMatchesState
                } else {
                    List {
                        ForEach(rows) { row in
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
                        if hasMore {
                            let isLoading = isSearching
                                ? appState.isLoadingMoreArchivedSearch[repoID] == true
                                : appState.isLoadingMoreArchived[repoID] == true
                            Button {
                                Task { await loadMore() }
                            } label: {
                                Text(isLoading ? "Loading…" : "Load More…")
                                    .font(.callout)
                                    .foregroundStyle(.secondary)
                                    .frame(maxWidth: .infinity)
                                    .padding(.vertical, 8)
                            }
                            .buttonStyle(.plain)
                            .disabled(isLoading)
                            .listRowInsets(EdgeInsets(top: 2, leading: 12, bottom: 2, trailing: 12))
                            .listRowSeparator(.hidden)
                            .listRowBackground(Color.clear)
                        }
                    }
                    .listStyle(.plain)
                    .onChange(of: appState.highlightedArchivedWorktreeID, initial: true) { _, newValue in
                        guard let id = newValue, rows.contains(where: { $0.id == id }) else { return }
                        withAnimation(.easeInOut(duration: 0.3)) {
                            proxy.scrollTo(id, anchor: .center)
                        }
                        Task { @MainActor in
                            // swiftlint:disable:next no_raw_task_sleep - legacy sleep, see docs/specs/2026-07-24-test-hardening-design.md
                            try? await Task.sleep(for: .milliseconds(900))
                            if appState.highlightedArchivedWorktreeID == id {
                                appState.highlightedArchivedWorktreeID = nil
                            }
                        }
                    }
                }
            }

            if appState.reapRecords[repoID]?.isEmpty == false {
                ReclaimedSectionView(repoID: repoID)
            }
        }
        .onAppear {
            // A fresh mount (tab switch away and back) starts with an empty
            // field, so drop any search state left behind — otherwise the list
            // and the field disagree, and every refresh re-runs a search the
            // user can no longer see.
            if trimmedQuery.isEmpty { appState.clearArchivedSearch(repoID: repoID) }
            reconcileSelection()
        }
        // Any change to the VISIBLE row set — `hideEmpty`, a landed search
        // result, a revive — can strand a selection the list no longer shows.
        // Keyed on the ids rather than on the raw query text so the reconcile
        // happens when the list actually changes, not one keystroke early.
        .onChange(of: rows.map(\.id)) { _, _ in reconcileSelection() }
        .onChange(of: searchQuery) { _, newValue in searchQueryChanged(newValue) }
        // This view is reused across repos (not `.id(repoID)`-keyed), so the
        // field would otherwise carry one repo's query into the next.
        .onChange(of: repoID) { oldValue, _ in
            searchDebouncer.cancel()
            appState.clearArchivedSearch(repoID: oldValue)
            searchQuery = ""
        }
    }

    // MARK: - Search

    private var searchField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.caption)
                .foregroundStyle(.secondary)
            TextField("Search by name", text: $searchQuery)
                .textFieldStyle(.plain)
                .font(.callout)
            if !searchQuery.isEmpty {
                Button {
                    clearSearch()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
                .help("Clear search")
            }
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 10)
    }

    /// Debounced query handling. An emptied field takes effect immediately —
    /// there is nothing to fetch, and waiting would leave a filtered list up
    /// after the user cleared it.
    private func searchQueryChanged(_ newValue: String) {
        let trimmed = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            searchDebouncer.cancel()
            appState.clearArchivedSearch(repoID: repoID)
            return
        }
        searchDebouncer.schedule(trimmed) { [appState, repoID] query in
            Task { await appState.searchArchivedWorktrees(repoID: repoID, query: query) }
        }
    }

    private func clearSearch() {
        searchQuery = ""
        searchDebouncer.cancel()
        appState.clearArchivedSearch(repoID: repoID)
    }

    private func loadMore() async {
        if isSearching {
            await appState.loadMoreArchivedSearchResults(repoID: repoID)
        } else {
            await appState.loadMoreArchivedWorktrees(repoID: repoID)
        }
    }

    /// Nothing visible, but the repo does have archives — offer whichever
    /// filter(s) are responsible for the miss.
    private var noMatchesState: some View {
        VStack(spacing: 8) {
            Image(systemName: isSearching ? "magnifyingglass" : "line.3.horizontal.decrease.circle")
                .font(.system(size: 28))
                .foregroundStyle(.tertiary)
            Text("No matches")
                .font(.callout)
                .foregroundStyle(.secondary)
            if isSearching {
                Button("Clear search") { clearSearch() }
                    .buttonStyle(.link)
            }
            // `searchedRows` non-empty means rows survived the search and only
            // `hideEmpty` is hiding them, so "Show all" is a real remedy.
            if hideEmpty && !searchedRows.isEmpty {
                Button("Show all") { hideEmpty = false }
                    .buttonStyle(.link)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// Make sure `selectedArchivedWorktreeIDs[repoID]` points to a row that
    /// is currently visible. Picks the first non-lingering visible row when
    /// unset or stale; clears when nothing is visible. Triggers a session
    /// fetch for any newly-selected row.
    private func reconcileSelection() {
        // A deliberate Reclaimed-row selection must not be stolen by the
        // archived auto-select (mutual exclusivity with selectedReapID).
        if selectedReapID != nil { return }
        let visibleIDs = Set(rows.map(\.id))
        if let current = selectedID, visibleIDs.contains(current) { return }
        if let first = rows.first(where: { $0.reviveState == nil })?.worktree {
            appState.selectArchivedWorktree(first.id, repoID: repoID)
            Task { await appState.fetchSessions(worktreeID: first.id) }
        } else {
            appState.selectArchivedWorktree(nil, repoID: repoID)
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
        if let reapID = selectedReapID,
           let record = (appState.reapRecords[repoID] ?? []).first(where: { $0.id == reapID }) {
            ReclaimedDetailView(record: record, repoID: repoID)
        } else if let id = selectedID,
           let row = rows.first(where: { $0.id == id }) {
            if row.effectiveSessionCount == 0 {
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
        // In-flight revives are non-selectable; .done rows are fine to browse.
        if case .inFlight = row.reviveState { return }
        appState.selectArchivedWorktree(row.id, repoID: repoID)
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

    /// Best available count of conversations for this worktree:
    /// the daemon-supplied live file count when present, falling back to
    /// the stored `archivedClaudeSessions` length (older archives or when
    /// the daemon couldn't scan).
    var effectiveSessionCount: Int {
        worktree.liveClaudeSessionCount ?? worktree.archivedClaudeSessions?.count ?? 0
    }
}

// MARK: - Row view

private struct ArchivedWorktreeRow: View {
    let row: ArchivedRow
    let isSelected: Bool

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
                if row.effectiveSessionCount > 0, row.reviveState == nil {
                    separator
                    Text("\(row.effectiveSessionCount) session\(row.effectiveSessionCount == 1 ? "" : "s")")
                }
                Spacer(minLength: 6)
                if let archivedAt = row.worktree.archivedAt, row.reviveState == nil {
                    Text(archivedAt, format: .relative(presentation: .named))
                        .lineLimit(1)
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
