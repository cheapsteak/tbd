import SwiftUI
import TBDShared

/// Standalone popover wrapper around `BranchListView`. Retained as a named
/// view type for any future call site that wants the branch list as its own
/// popover; branch selection itself lives in `BranchListView` so there is a
/// single source of truth (also embedded as page 2 of
/// `WorktreeProfilePickerView`).
struct BranchPickerView: View {
    let repoID: UUID

    var body: some View {
        BranchListView(repoID: repoID)
            .frame(width: 300, height: 400)
    }
}

/// Searchable local + `origin/*` branch list. Selecting a branch creates a
/// worktree from that existing branch (default model resolution — no profile
/// override) and dismisses the enclosing popover. Frameless on purpose so
/// hosts control sizing: `BranchPickerView` gives it a fixed popover frame,
/// while `WorktreeProfilePickerView`'s branch page lets it fill the space left
/// under the back bar.
struct BranchListView: View {
    let repoID: UUID
    /// Forwarded so a branch chosen from a nested `+` creates a child worktree.
    var parentWorktreeID: UUID? = nil
    /// Explicit close hook for the `FloatingPanel` presentation (no
    /// `@Environment(\.dismiss)` there); forwarded from
    /// `WorktreeProfilePickerView`. The standalone `BranchPickerView` wrapper
    /// is currently unused, so its default empty closure is harmless.
    var onClose: () -> Void = {}
    @EnvironmentObject var appState: AppState
    @Environment(\.dismiss) private var dismiss

    @State private var branches: [BranchInfo] = []
    @State private var openPRs: [OpenPRInfo] = []
    @State private var query: String = ""
    @State private var isLoading: Bool = true
    @State private var loadError: Bool = false
    /// True while the open-PR query is in flight (two-phase load). Branches
    /// render immediately; PR rows pop in when this clears.
    @State private var prsLoading: Bool = false
    @FocusState private var searchFocused: Bool

    private var filteredItems: [PickerItem] {
        mergePickerItems(branches: branches, prs: openPRs)
            .filter { matchesFilter($0, query: query) }
    }

    var body: some View {
        VStack(spacing: 0) {
            TextField("Filter branches & PRs", text: $query)
                .textFieldStyle(.roundedBorder)
                .focused($searchFocused)
                .onSubmit { selectFirstMatch() }
                .padding(8)

            Divider()

            if isLoading {
                HStack {
                    Spacer()
                    ProgressView()
                        .controlSize(.small)
                    Spacer()
                }
                .padding(16)
            } else if filteredItems.isEmpty && !prsLoading {
                Text(emptyStateMessage)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(16)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        if prsLoading {
                            PRLoadingPlaceholderRow()
                        }
                        ForEach(filteredItems) { item in
                            BranchPickerRow(item: item) {
                                pick(item)
                            }
                        }
                    }
                }
            }
            Spacer(minLength: 0)
        }
        .task {
            isLoading = true
            loadError = false
            do {
                branches = try await appState.listBranches(repoID: repoID)
            } catch {
                loadError = true
            }
            isLoading = false
            searchFocused = true
            // Phase two: PR rows pop in after branches render. A PR-list
            // failure never blocks or errors the branch list (branches-only).
            prsLoading = true
            openPRs = (try? await appState.listOpenPRs(repoID: repoID)) ?? []
            prsLoading = false
        }
    }

    /// Distinguish "we tried and failed to load" from a query-filtered empty
    /// state or a genuinely empty repo, so the user can tell a load failure
    /// apart from "no matching branches".
    private var emptyStateMessage: String {
        if !branches.isEmpty || !openPRs.isEmpty { return "No matches" }
        if loadError { return "Failed to load branches" }
        return "No branches found"
    }

    private func pick(_ item: PickerItem) {
        dismiss()
        onClose()
        // Branch selection always uses the default model (no profile override).
        if let branch = item.branch {
            // Plain branch row, or a same-repo PR decorating an existing branch:
            // check out the branch exactly as today; stamp the PR number (if any)
            // for status tracking only — no pull-ref fetch (checkoutPRHead false).
            appState.createWorktree(
                repoID: repoID, parentWorktreeID: parentWorktreeID,
                existingBranch: branch, prNumber: item.pr?.number)
        } else if let pr = item.pr {
            // PR-only row (fork PR, or a same-repo PR whose head is unfetched):
            // fetch refs/pull/<n>/head into a fresh local branch.
            let branch = BranchInfo(name: pr.headRefName, localName: pr.headRefName, isRemote: false)
            appState.createWorktree(
                repoID: repoID, parentWorktreeID: parentWorktreeID,
                existingBranch: branch, prNumber: pr.number, checkoutPRHead: true,
                displayName: "#\(pr.number) \(pr.title)")
        }
    }

    private func selectFirstMatch() {
        if let first = filteredItems.first {
            pick(first)
        }
    }
}

/// Non-interactive row shown at the top of the list while the open-PR fetch
/// (`prsLoading`) is in flight. PR rows float to the top once loaded (see
/// 20c8fbfb), so the placeholder occupies that same slot.
private struct PRLoadingPlaceholderRow: View {
    var body: some View {
        HStack(spacing: 6) {
            ProgressView()
                .controlSize(.small)
            Text("Loading pull requests…")
                .font(.system(size: 12))
        }
        .foregroundStyle(.secondary)
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct BranchPickerRow: View {
    let item: PickerItem
    let onSelect: () -> Void

    @State private var isHovered = false

    /// Row title: the branch name, or (PR-only rows) the PR head branch name.
    private var title: String {
        item.branch?.name ?? item.pr?.headRefName ?? ""
    }
    private var isRemote: Bool { item.branch?.isRemote ?? false }
    /// Remote rows use a cloud; everything else (local branch or PR-only) uses
    /// the branch glyph. PR-ness is conveyed by the pill, not the icon.
    private var iconName: String {
        isRemote ? "cloud" : "arrow.triangle.branch"
    }

    var body: some View {
        Button(action: onSelect) {
            HStack(spacing: 6) {
                Image(systemName: iconName)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .frame(width: 14)
                VStack(alignment: .leading, spacing: 1) {
                    Text(title)
                        .font(.system(size: 12))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    // Fork PR-only rows show the PR title as a secondary subtitle.
                    if item.branch == nil, let pr = item.pr {
                        Text(pr.title)
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }
                }
                Spacer(minLength: 4)
                if let pr = item.pr {
                    prPill(pr)
                } else if isRemote {
                    pill("remote")
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 4)
                    .fill(isHovered ? Color.accentColor.opacity(0.15) : Color.clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
    }

    /// `PR #454` for same-repo, `zionts · PR #454` for fork PRs; dimmed for drafts.
    private func prPill(_ pr: OpenPRInfo) -> some View {
        let label = pr.isCrossRepository && !pr.headOwner.isEmpty
            ? "\(pr.headOwner) · PR #\(pr.number)"
            : "PR #\(pr.number)"
        return pill(label).opacity(pr.isDraft ? 0.5 : 1.0)
    }

    private func pill(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 10))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 4)
            .padding(.vertical, 1)
            .background(
                RoundedRectangle(cornerRadius: 3)
                    .fill(Color.secondary.opacity(0.10))
            )
    }
}
