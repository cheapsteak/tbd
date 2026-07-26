import AppKit
import SwiftUI
import TBDShared

struct HoverPressButtonStyle: ButtonStyle {
    @State private var isHovering = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(.secondary)
            .background(
                RoundedRectangle(cornerRadius: 4)
                    .fill(configuration.isPressed
                          ? Color.primary.opacity(0.15)
                          : isHovering ? Color.primary.opacity(0.08) : Color.clear)
            )
            .scaleEffect(configuration.isPressed ? 0.9 : 1.0)
            .padding(6)
            .contentShape(Rectangle())
            .padding(-6)
            .onHover { hovering in
                isHovering = hovering
            }
    }
}

struct RepoSectionView: View {
    let repo: Repo
    @EnvironmentObject var appState: AppState

    @State private var isEditing = false
    @State private var isSectionHovered = false
    @State private var isChevronHovered = false
    @State private var hoverDebounceTask: Task<Void, Error>?
    @State private var showRemoveConfirm = false
    // Hover the `+` (or ⌥-click it) to open the model-profile picker; a plain
    // click still creates a worktree with the default profile.
    @StateObject private var newWorktreeMenu = HoverMenuModel()

    private func onSectionHoverChange(_ hovering: Bool) {
        if hovering {
            hoverDebounceTask?.cancel()
            hoverDebounceTask = nil
            if !isSectionHovered {
                isSectionHovered = true
            }
        } else {
            hoverDebounceTask?.cancel()
            hoverDebounceTask = Task { @MainActor in
                try await Task.sleep(nanoseconds: 80_000_000)
                isSectionHovered = false
            }
        }
    }

    var mainWorktree: Worktree? {
        (appState.worktrees[repo.id] ?? [])
            .first { $0.status == .main }
    }

    var topLevelWorktrees: [Worktree] {
        (appState.worktrees[repo.id] ?? [])
            .filter { ($0.status == .active || $0.status == .creating) && $0.parentWorktreeID == nil }
            .sorted { $0.sortOrder < $1.sortOrder }
    }

    /// Remote sessions resolved to this repo (`RemoteSessionInfo.resolvedRepoID
    /// == repo.id`), rendered after every local worktree. See
    /// `RepoSectionView.matchedRemoteSessions` for the filter/sort rule.
    var matchedRemoteSessions: [RemoteSessionInfo] {
        RepoSectionView.matchedRemoteSessions(appState.remoteSessions, repoID: repo.id)
    }

    private var activeWorktreeCount: Int {
        (appState.worktrees[repo.id] ?? [])
            .filter { $0.status == .active || $0.status == .creating }
            .count
    }

    private var removeButtonLabel: String {
        activeWorktreeCount > 0 ? "Archive Worktrees & Remove" : "Remove"
    }

    private var removeConfirmMessage: String {
        let base = "This unregisters the repo from TBD. Your git repository and files on disk are not touched."
        if activeWorktreeCount > 0 {
            let plural = activeWorktreeCount == 1 ? "worktree" : "worktrees"
            return "\(activeWorktreeCount) active \(plural) will be archived first.\n\n\(base)"
        }
        return base
    }

    var body: some View {
        HStack(spacing: 4) {
            Button {
                Task { await appState.setRepoExpanded(id: repo.id, expanded: !repo.expanded) }
            } label: {
                Image(systemName: repo.expanded ? "chevron.down" : "chevron.right")
                    .font(.system(size: 11))
                    .foregroundStyle(
                        repo.status == .missing
                            ? AnyShapeStyle(Color.secondary.opacity(0.5))
                            : AnyShapeStyle(HierarchicalShapeStyle.secondary)
                    )
                    .frame(width: 18, height: 18)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .onHover { isChevronHovered = $0 }
            .help(repo.expanded ? "Collapse" : "Expand")
            RenameableLabel(
                text: repo.displayName,
                isEditing: $isEditing,
                onCommit: { newName in
                    Task {
                        await appState.renameRepo(id: repo.id, displayName: newName)
                    }
                }
            ) {
                Text(repo.displayName)
                    .font(.system(size: 12, weight: .semibold))
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .foregroundStyle(
                        repo.status == .missing
                            ? AnyShapeStyle(Color.secondary.opacity(0.5))
                            : AnyShapeStyle(appState.selectedRepoID == repo.id ? HierarchicalShapeStyle.primary : HierarchicalShapeStyle.secondary)
                    )
            }
            .padding(.leading, -2)

            if repo.status == .missing {
                Text("[missing]")
                    .font(.caption)
                    .foregroundStyle(.red.opacity(0.7))
                Button("Locate…") {
                    locateRepo()
                }
                .buttonStyle(.link)
                .font(.caption)
            }

            Spacer()

            Group {
                if HoverMenuModel.shouldShowPlus(hovered: isSectionHovered, menuOpen: newWorktreeMenu.isOpen) {
                    // Hover opens the unified profile picker; its "Choose a
                    // branch…" row drills into the branch list. ⌥-click opens
                    // it immediately. No tooltip — it would render on top of
                    // the hover menu.
                    SectionHeaderPlusButton(action: handlePlusButton)
                    .accessibilityLabel("New worktree")
                    .disabled(repo.status == .missing)
                    // `.disabled` blocks the click path but NOT `.onHover`
                    // tracking-area events, so gate the hover-open explicitly —
                    // a missing repo must never open the picker.
                    .onHover { if repo.status != .missing { newWorktreeMenu.triggerHover($0) } }
                    .background(
                        FloatingMenuAnchor(
                            isPresented: newWorktreeMenu.isOpen,
                            content: WorktreeProfilePickerView(
                                repoID: repo.id,
                                highlightDefaultProfile: newWorktreeMenu.isTriggerHovered,
                                onClose: { newWorktreeMenu.closeNow() }
                            )
                            .environmentObject(appState)
                            .background(.ultraThickMaterial)
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                            .onHover { newWorktreeMenu.menuHover($0) }
                        )
                    )
                } else {
                    Color.clear
                }
            }
            .frame(width: 20, height: 20)
        }
        .frame(height: 22, alignment: .bottom)
        .background(Color.white.opacity(0.0001))
        .contentShape(Rectangle())
        .onTapGesture {
            appState.selectRepo(id: repo.id)
        }
        .onHover { hovering in
            onSectionHoverChange(hovering)
        }
        .contextMenu {
            Button(repo.expanded ? "Collapse" : "Expand") {
                Task { await appState.setRepoExpanded(id: repo.id, expanded: !repo.expanded) }
            }
            Button("Rename...") {
                isEditing = true
            }
            Button(repo.hidden ? "Unhide" : "Hide") {
                Task { await appState.setRepoHidden(id: repo.id, hidden: !repo.hidden) }
            }
            Divider()
            Button("Remove from List...", role: .destructive) {
                showRemoveConfirm = true
            }
        }
        .confirmationDialog(
            "Remove \(repo.displayName) from list?",
            isPresented: $showRemoveConfirm,
            titleVisibility: .visible
        ) {
            Button(removeButtonLabel, role: .destructive) {
                Task { await appState.removeRepo(repoID: repo.id, force: activeWorktreeCount > 0) }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(removeConfirmMessage)
        }
        .listRowInsets(EdgeInsets(top: 0, leading: -2, bottom: 0, trailing: 0))
        .listRowSeparator(.hidden)
        .listRowBackground(Color.clear)
        .tag(repo.id)

        if repo.expanded {
            if let main = mainWorktree {
                WorktreeRowView(worktree: main, isMain: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.white.opacity(0.0001))
                    .opacity(isChevronHovered ? 0.7 : 1.0)
                    .onHover { onSectionHoverChange($0) }
                    .listRowInsets(EdgeInsets(top: 0, leading: 12, bottom: 0, trailing: 0))
                    .listRowSeparator(.hidden)
                    .listRowBackground(Color.clear)
                    .tag(main.id)
            }
            ForEach(topLevelWorktrees) { wt in
                WorktreeSubtreeView(worktree: wt, depth: 0, sectionRepoID: repo.id)
                    .opacity(isChevronHovered ? 0.7 : 1.0)
                    .onHover { onSectionHoverChange($0) }
            }
            .onMove { source, destination in
                appState.reorderTopLevelWorktrees(
                    repoID: repo.id,
                    fromOffsets: source,
                    toOffset: destination
                )
            }
            // Matched remote sessions render AFTER local worktrees, never
            // interleaved: local worktrees have a user-controlled sort order
            // (`sortOrder`/drag reorder above) and remote ones have nothing
            // comparable, so appending is predictable while interleaving
            // would look arbitrary relative to a manual reorder the user set
            // up on purpose.
            ForEach(matchedRemoteSessions) { session in
                RemoteSessionRowView(session: session)
                    .opacity(isChevronHovered ? 0.7 : 1.0)
                    .onHover { onSectionHoverChange($0) }
                    .listRowInsets(EdgeInsets(top: 0, leading: 12, bottom: 0, trailing: 0))
                    .listRowSeparator(.hidden)
                    .listRowBackground(Color.clear)
                    .tag(session.id)
            }
        }
    }

    /// Sessions resolved to `repoID`, dismissed tombstones excluded, sorted
    /// oldest-first by reported creation time. Pure — split out from the
    /// computed `matchedRemoteSessions` property so it's directly testable
    /// without an `AppState`/view hierarchy. `nonisolated` for the same
    /// reason as `RemoteSectionView`'s pure helpers (see its doc comment).
    nonisolated static func matchedRemoteSessions(_ all: [RemoteSessionInfo], repoID: UUID) -> [RemoteSessionInfo] {
        all.filter { $0.resolvedRepoID == repoID && !$0.dismissed }
            .sorted(by: RepoSectionView.isOrderedByCreation)
    }

    /// Ascending creation-time ordering for two remote sessions. A session
    /// with a missing/unparseable `created_at` (allowed by the contract —
    /// `docs/remote-provider-contract.md` doesn't require it) sorts after
    /// every dated session; any remaining tie (including two undated
    /// sessions) breaks on the row's own stable `id` so ordering is fully
    /// deterministic across renders regardless of source-array order.
    nonisolated static func isOrderedByCreation(_ a: RemoteSessionInfo, _ b: RemoteSessionInfo) -> Bool {
        let da = RepoSectionView.parsedCreatedAt(a.payload.createdAt)
        let db = RepoSectionView.parsedCreatedAt(b.payload.createdAt)
        switch (da, db) {
        case let (x?, y?) where x != y: return x < y
        case (nil, .some): return false
        case (.some, nil): return true
        default: return a.id.uuidString < b.id.uuidString
        }
    }

    nonisolated static func parsedCreatedAt(_ raw: String?) -> Date? {
        guard let raw else { return nil }
        // A fresh formatter per call (rather than a cached `static let`)
        // sidesteps `RepoSectionView`'s inferred `@MainActor` isolation
        // (from being a `View`) so this stays callable from a plain
        // `nonisolated` test context — session counts are small enough that
        // the allocation cost here is a non-issue.
        //
        // `docs/remote-provider-contract.md` shows a whole-second
        // `created_at` example but never pins a profile, so a conforming
        // provider can legally emit fractional seconds
        // (`2026-07-24T18:02:11.123Z`) — a default-options formatter rejects
        // those outright, sorting every such row as undated. Try
        // `.withFractionalSeconds` first, then fall back to the plain
        // whole-second profile — `ISO8601DateFormatter` does not accept both
        // in one `formatOptions` value.
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractional.date(from: raw) { return date }
        return ISO8601DateFormatter().date(from: raw)
    }

    private func handlePlusButton() {
        guard repo.status != .missing else { return }
        switch HoverMenuModel.plusOutcome(optionHeld: NSEvent.modifierFlags.contains(.option)) {
        case .openMenu:
            newWorktreeMenu.openImmediately()
        case .createDefault:
            // A plain click short-circuits any hover-opened menu to the fast
            // default-create path.
            newWorktreeMenu.closeNow()
            createWorktree()
        }
    }

    private func createWorktree() {
        appState.createWorktree(repoID: repo.id)
    }

    private func locateRepo() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.message = "Select the new location of \(repo.displayName)"
        panel.prompt = "Relocate"
        if panel.runModal() == .OK, let url = panel.url {
            Task {
                await appState.relocateRepo(id: repo.id, newPath: url.path)
            }
        }
    }
}
