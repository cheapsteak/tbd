import AppKit
import SwiftUI
import TBDShared

private struct HoverPressButtonStyle: ButtonStyle {
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
    @State private var hoverDebounceTask: Task<Void, Error>?
    @State private var showRemoveConfirm = false

    private static func startsWithEmoji(_ name: String) -> Bool {
        guard let first = name.first else { return false }
        return first.unicodeScalars.contains { $0.properties.isEmoji && $0.value > 0x7F }
    }

    private static func leadingEmoji(_ name: String) -> String? {
        guard startsWithEmoji(name), let first = name.first else { return nil }
        return String(first)
    }

    private static func nameWithoutLeadingEmoji(_ name: String) -> String {
        guard startsWithEmoji(name) else { return name }
        var rest = name.dropFirst()
        if rest.first == " " { rest = rest.dropFirst() }
        return String(rest)
    }

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

    var worktrees: [Worktree] {
        (appState.worktrees[repo.id] ?? [])
            .filter { $0.status == .active || $0.status == .creating }
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
            if isSectionHovered {
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
                .buttonStyle(HoverPressButtonStyle())
                .help(repo.expanded ? "Collapse" : "Expand")
            } else if let emoji = Self.leadingEmoji(repo.displayName) {
                Text(emoji)
                    .font(.system(size: 12))
                    .frame(width: 18, height: 18)
            } else {
                Image(systemName: "folder")
                    .font(.system(size: 11))
                    .foregroundStyle(
                        repo.status == .missing
                            ? AnyShapeStyle(Color.secondary.opacity(0.5))
                            : AnyShapeStyle(HierarchicalShapeStyle.secondary)
                    )
                    .frame(width: 18, height: 18)
            }
            RenameableLabel(
                text: repo.displayName,
                isEditing: $isEditing,
                onCommit: { newName in
                    Task {
                        await appState.renameRepo(id: repo.id, displayName: newName)
                    }
                }
            ) {
                Text(Self.nameWithoutLeadingEmoji(repo.displayName))
                    .font(.system(size: 12, weight: .semibold))
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .foregroundStyle(
                        repo.status == .missing
                            ? AnyShapeStyle(Color.secondary.opacity(0.5))
                            : AnyShapeStyle(appState.selectedRepoID == repo.id ? HierarchicalShapeStyle.primary : HierarchicalShapeStyle.secondary)
                    )
            }

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
                if isSectionHovered {
                    Button(action: createWorktree) {
                        Image(systemName: "plus")
                            .font(.caption)
                            .frame(width: 20, height: 20)
                    }
                    .buttonStyle(HoverPressButtonStyle())
                    .help("New worktree")
                    .disabled(repo.status == .missing)
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
        .listRowInsets(EdgeInsets(top: 0, leading: 0, bottom: 0, trailing: 0))
        .listRowSeparator(.hidden)
        .listRowBackground(Color.clear)
        .tag(repo.id)

        if repo.expanded {
            if let main = mainWorktree {
                WorktreeRowView(worktree: main, isMain: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.white.opacity(0.0001))
                    .onHover { onSectionHoverChange($0) }
                    .listRowInsets(EdgeInsets(top: 0, leading: 12, bottom: 0, trailing: 0))
                    .listRowSeparator(.hidden)
                    .listRowBackground(Color.clear)
                    .tag(main.id)
            }
            ForEach(worktrees) { worktree in
                WorktreeRowView(worktree: worktree)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.white.opacity(0.0001))
                    .onHover { onSectionHoverChange($0) }
                    .listRowInsets(EdgeInsets(top: 0, leading: 12, bottom: 0, trailing: 0))
                    .listRowSeparator(.hidden)
                .listRowBackground(Color.clear)
                    .tag(worktree.id)
            }
            .onMove { source, destination in
                appState.reorderWorktrees(repoID: repo.id, fromOffsets: source, toOffset: destination)
            }
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
