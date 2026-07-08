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
    // Long-press or Option-click the `+` opens the model-profile picker; a plain
    // click creates a worktree with the default profile.
    @State private var showProfilePicker = false
    // Set when a long-press opens the profile picker, so the Button's own tap
    // action (which fires on finger-up, after the long-press's onEnded) doesn't
    // ALSO create a default worktree. Reset on the next plain click.
    @State private var longPressTriggered = false

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
                if isSectionHovered || showProfilePicker {
                    SectionHeaderPlusButton(
                        // Long-press or Option-click opens the unified profile
                        // picker; its "Choose a branch…" row drills into the
                        // (former standalone) branch picker.
                        help: "New worktree (long-press or \u{2325}-click to pick a model profile)",
                        action: handlePlusButton
                    )
                    .disabled(repo.status == .missing)
                    // Long-press (~0.3s) opens the profile picker. `.simultaneousGesture`
                    // runs ALONGSIDE the Button's tap recognizer, so a plain click still
                    // fires `handlePlusButton` (create-with-default) and long-press doesn't
                    // swallow it — the guard flag prevents a create on the long-press release.
                    .simultaneousGesture(
                        LongPressGesture(minimumDuration: 0.3)
                            .onEnded { _ in
                                guard repo.status != .missing else { return }
                                longPressTriggered = true
                                showProfilePicker = true
                            }
                    )
                    .popover(isPresented: $showProfilePicker, arrowEdge: .trailing) {
                        WorktreeProfilePickerView(repoID: repo.id)
                            .environmentObject(appState)
                    }
                    // Safety net for the orphaned-flag cases: if the long-press
                    // opened the picker but no follow-up tap on `+` ever cleared
                    // the flag (press released off-button, or picker dismissed /
                    // a profile chosen), clear it when the popover closes so the
                    // next plain click isn't swallowed by the guard.
                    .onChange(of: showProfilePicker) { _, isShown in
                        if !isShown { longPressTriggered = false }
                    }
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
        }
    }

    private func handlePlusButton() {
        // A long-press already handled this interaction (it opened the profile
        // picker and set the flag); the Button's tap fires on finger-up right
        // after, so consume it here instead of creating a default worktree.
        if longPressTriggered {
            longPressTriggered = false
            return
        }
        // Option-click (like long-press) opens the unified model-profile
        // picker; branch selection now lives inside it under "Choose a branch…".
        if NSEvent.modifierFlags.contains(.option) {
            showProfilePicker = true
        } else {
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
