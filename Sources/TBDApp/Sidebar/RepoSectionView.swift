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

    @State private var isExpanded = true
    @State private var isEditing = false
    @State private var isHeaderHovered = false
    @State private var isSectionHovered = false
    @State private var hoverDebounceTask: Task<Void, Error>?
    @State private var emojiPickerSelectedIndex = 0

    private var showEmojiPicker: Bool {
        appState.activeEmojiPickerRepoID == repo.id
    }

    private static func startsWithEmoji(_ name: String) -> Bool {
        guard let first = name.first else { return false }
        return first.unicodeScalars.contains { $0.properties.isEmoji && $0.value > 0x7F }
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

    var body: some View {
        HStack(spacing: 4) {
            if !Self.startsWithEmoji(repo.displayName) {
                let repoID = repo.id
                Button {
                    if appState.activeEmojiPickerRepoID == repoID {
                        appState.activeEmojiPickerRepoID = nil
                    } else {
                        appState.activeEmojiPickerRepoID = repoID
                    }
                } label: {
                    Image(systemName: "folder")
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
                .help("Pick emoji")
                .background(
                    EmojiPanelAnchor(
                        isPresented: showEmojiPicker,
                        query: "",
                        selectedIndex: $emojiPickerSelectedIndex,
                        onSelect: { emoji in
                            let newName = "\(emoji) \(repo.displayName)"
                            Task {
                                await appState.renameRepo(id: repo.id, displayName: newName)
                            }
                            appState.activeEmojiPickerRepoID = nil
                            emojiPickerSelectedIndex = 0
                        },
                        onOutsideClick: { [weak appState] in
                            appState?.activeEmojiPickerRepoID = nil
                        }
                    )
                )
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
                if isHeaderHovered {
                    Button(action: { isExpanded.toggle() }) {
                        Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                            .font(.caption)
                            .frame(width: 20, height: 20)
                    }
                    .buttonStyle(HoverPressButtonStyle())
                    .help(isExpanded ? "Collapse" : "Expand")
                } else {
                    Color.clear
                }
            }
            .frame(width: 20, height: 20)
        }
        .frame(height: 22, alignment: .bottom)
        .contentShape(Rectangle())
        .onTapGesture {
            appState.selectRepo(id: repo.id)
        }
        .onHover { hovering in
            isHeaderHovered = hovering
            onSectionHoverChange(hovering)
        }
        .contextMenu {
            Button("Rename...") {
                isEditing = true
            }
        }
        .listRowInsets(EdgeInsets(top: 0, leading: 0, bottom: 0, trailing: 0))
        .listRowSeparator(.hidden)
        .listRowBackground(Color.clear)
        .tag(repo.id)

        if isExpanded {
            if let main = mainWorktree {
                HStack(spacing: 0) {
                    WorktreeRowView(worktree: main, isMain: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
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
                .onHover { onSectionHoverChange($0) }
                .listRowInsets(EdgeInsets(top: 0, leading: 12, bottom: 0, trailing: 0))
                .listRowSeparator(.hidden)
                .listRowBackground(Color.clear)
                .tag(main.id)
            }
            ForEach(worktrees) { worktree in
                WorktreeRowView(worktree: worktree)
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
