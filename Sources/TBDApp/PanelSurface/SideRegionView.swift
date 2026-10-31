import SwiftUI
import TBDShared

// MARK: - Strip model

/// One tab in the side region's strip, decided from the surface as a value so
/// the strip can be asserted without standing up a view.
struct SideRegionTab: Equatable, Identifiable {
    let id: PanelID
    /// The panel's current content: its history's cursor entry.
    let content: PanelContent
    let title: String
    let isActive: Bool
    /// The session `.jsonl` a transcript tab's file menu acts on. Nil for the
    /// other kinds, and until the terminal's row carries one.
    let transcriptPath: String?

    /// The content as the leaf view, and the file menu, take it.
    var paneContent: PaneContent { content.paneContent(panelID: id) }

    /// The symbol the workspace tab bar shows for the same kind.
    var systemImage: String { content.kind.tabSystemImage }
}

enum SideRegionStrip {
    /// The strip's tabs, in the region's order. A panel with no current
    /// content — only malformed decoded data can produce one — is left out
    /// rather than drawn blank.
    static func tabs(
        for side: SideRegion,
        noteTitle: (UUID) -> String?,
        transcriptPath: (UUID) -> String?
    ) -> [SideRegionTab] {
        side.panels.compactMap { panel in
            guard let content = panel.content else { return nil }
            var path: String?
            if case .transcript(let terminalID) = content,
               let resolved = transcriptPath(terminalID), !resolved.isEmpty {
                path = resolved
            }
            return SideRegionTab(
                id: panel.id,
                content: content,
                title: title(for: content, noteTitle: noteTitle),
                isActive: panel.id == side.activePanelID,
                transcriptPath: path)
        }
    }

    /// The title the workspace tab bar gives the same content
    /// (`PanelContent.tabTitle`), except that a note with no title shows
    /// "Note": a side-region tab has no position number to give it.
    static func title(for content: PanelContent, noteTitle: (UUID) -> String?) -> String {
        content.tabTitle(noteTitle: noteTitle, untitledNote: "Note")
    }
}

// MARK: - SideRegionView

/// The side region of a daemon-rendered workspace tab (panel tabs spec, "The
/// renderer"): a strip with a tab per panel and a collapse button, and below
/// it the active panel through the shared leaf view, which keeps its history
/// chevrons and actions. The leaf's own title is hidden, because the tab
/// names it; the file menu that hung on that title moves to the tab.
struct SideRegionView: View {
    let surface: WorkspaceTabSurface
    let worktree: LocalWorktree
    @Environment(AppState.self) var appState

    var body: some View {
        let tabs = SideRegionStrip.tabs(
            for: surface.side,
            noteTitle: { noteID in
                appState.notes[worktree.id]?.first(where: { $0.id == noteID })?.title
            },
            transcriptPath: { terminalID in
                appState.terminal(id: terminalID, in: worktree.id)?.transcriptPath
            })

        VStack(spacing: 0) {
            strip(tabs: tabs)

            Divider()

            if let active = tabs.first(where: \.isActive) {
                PanePlaceholder(
                    content: active.paneContent,
                    worktree: worktree,
                    tabID: surface.id,
                    actions: .daemon(
                        appState: appState, worktreeID: surface.worktreeID, tabID: surface.id,
                        panelID: active.id),
                    showsPaneLabel: false
                )
                .id(active.id)
            } else {
                Color.clear
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    // MARK: - Strip

    private func strip(tabs: [SideRegionTab]) -> some View {
        HStack(spacing: 0) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 0) {
                    ForEach(tabs) { tab in
                        tabItem(tab)
                    }
                }
            }

            collapseButton
        }
        .frame(height: 28)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    /// A tab: a select button over the icon and title, and a close button
    /// beside it — siblings, not nested, so each takes its own clicks. A
    /// right-click offers the file menu for file and transcript tabs.
    private func tabItem(_ tab: SideRegionTab) -> some View {
        HStack(spacing: 0) {
            Button {
                send(.select(panelID: tab.id))
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: tab.systemImage)
                        .font(.system(size: 10))
                        .foregroundStyle(tab.isActive ? .primary : .tertiary)
                    Text(tab.title)
                        .font(.system(size: 11))
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .frame(maxWidth: 180, alignment: .leading)
                        .foregroundStyle(tab.isActive ? .primary : .secondary)
                }
                .padding(.leading, 8)
                .frame(maxHeight: .infinity)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(tab.title)

            Button {
                send(.close(panelID: tab.id))
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(.secondary)
                    .frame(width: 18, height: 18)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 2)
            .help("Close panel")
        }
        .frame(maxHeight: .infinity)
        .background(tab.isActive ? Color(nsColor: .controlBackgroundColor) : Color.clear)
        .overlay(alignment: .bottom) {
            if tab.isActive {
                Rectangle()
                    .fill(Color(nsColor: .separatorColor))
                    .frame(height: 2)
            }
        }
        .headerFileContextMenu(for: tab.paneContent, transcriptPath: tab.transcriptPath)
    }

    private var collapseButton: some View {
        Button {
            send(.setCollapsed(true))
        } label: {
            Image(systemName: "sidebar.right")
                .font(.system(size: 11))
                .frame(width: 24, height: 24)
                .contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        .keyboardShortcut("\\", modifiers: .command)
        .help("Hide the side panel (⌘\\)")
        .padding(.horizontal, 4)
    }

    private func send(_ operation: PanelOperation) {
        appState.sendPanelOperation(worktreeID: surface.worktreeID, tabID: surface.id, operation)
    }
}
