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
    @EnvironmentObject var appState: AppState
    @Environment(\.dismiss) private var dismiss

    @State private var branches: [BranchInfo] = []
    @State private var query: String = ""
    @State private var isLoading: Bool = true
    @State private var loadError: Bool = false
    @FocusState private var searchFocused: Bool

    private var filteredBranches: [BranchInfo] {
        let trimmed = query.trimmingCharacters(in: .whitespaces).lowercased()
        if trimmed.isEmpty { return branches }
        return branches.filter { branch in
            branch.name.lowercased().contains(trimmed) ||
                branch.localName.lowercased().contains(trimmed)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            TextField("Filter branches", text: $query)
                .textFieldStyle(.roundedBorder)
                .focused($searchFocused)
                .padding(8)
                .onSubmit { selectFirstMatch() }

            Divider()

            if isLoading {
                HStack {
                    Spacer()
                    ProgressView()
                        .controlSize(.small)
                    Spacer()
                }
                .padding(16)
            } else if filteredBranches.isEmpty {
                Text(emptyStateMessage)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(16)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(filteredBranches) { branch in
                            BranchPickerRow(branch: branch) {
                                pick(branch)
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
        }
    }

    /// Distinguish "we tried and failed to load" from a query-filtered empty
    /// state or a genuinely empty repo, so the user can tell a load failure
    /// apart from "no matching branches".
    private var emptyStateMessage: String {
        if !branches.isEmpty { return "No matches" }
        if loadError { return "Failed to load branches" }
        return "No branches found"
    }

    private func pick(_ branch: BranchInfo) {
        dismiss()
        // Branch selection always uses the default model (no profile override).
        appState.createWorktree(repoID: repoID, parentWorktreeID: parentWorktreeID, existingBranch: branch)
    }

    private func selectFirstMatch() {
        if let first = filteredBranches.first {
            pick(first)
        }
    }
}

struct BranchPickerRow: View {
    let branch: BranchInfo
    let onSelect: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: onSelect) {
            HStack(spacing: 6) {
                Image(systemName: branch.isRemote ? "cloud" : "arrow.triangle.branch")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .frame(width: 14)
                Text(branch.name)
                    .font(.system(size: 12))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 4)
                if branch.isRemote {
                    Text("remote")
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
}
