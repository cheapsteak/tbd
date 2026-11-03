import SwiftUI
import TBDShared

/// Replaces the static "TBD" window title in the toolbar. Left-to-right:
/// notes button, repo name (11 pt) as a dropdown to the repo's detail tabs, and
/// the worktree display name (14 pt) as a dropdown reusing the sidebar row
/// action menu (Rename, Archive, …).
///
/// `appState`/`worktree`/`repoName` are passed in (not read from the
/// environment) so this view has no `@Environment` dependency inside the
/// toolbar's title item.
struct WorktreeTitleView: View {
    let appState: AppState
    let worktree: Worktree
    let repoName: String?

    var body: some View {
        HStack(alignment: .center, spacing: 6) {
            WorktreeNotesButton(worktree: worktree)
            if let repoName {
                WorktreeTitleMenus.repoMenu(appState: appState, worktree: worktree) {
                    Text(repoName)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                .fixedSize()
            }
            WorktreeTitleMenus.worktreeMenu(appState: appState, worktree: worktree) {
                Text(worktree.displayName)
                    .font(.system(size: 14, weight: .semibold))
                    .lineLimit(1)
            }
            .fixedSize()
        }
    }
}

/// The worktree's title set over its project name, the way macOS sets a
/// window's subtitle under its title, for the main pane's top row with the
/// Tabs in the toolbar setting on: the title in 13 pt semibold, and under it
/// the notes button and the project name in 11 pt, secondary. Each line keeps
/// the menu `WorktreeTitleView` gives it. A worktree with no project, a
/// scratch space, shows the title alone, which the row centres on its
/// midline, and the notes button leads that line instead.
///
/// The notes button, sized to the line it leads, never shrinks. Neither text
/// holds its ideal width: offered less, the title truncates in the middle and
/// the project name at the end, and hovering the title shows it whole.
/// `MainTabRowWidths` decides how much the column gets.
struct WorktreeTitleColumn: View {
    let appState: AppState
    let worktree: Worktree
    let repoName: String?

    /// The line the notes button leads.
    enum NotesLine: Equatable {
        /// The project name's line, under the title.
        case project
        /// The title's own line, the only one.
        case title

        /// The point size of the line's text, which the button's symbol
        /// takes.
        var fontSize: CGFloat {
            switch self {
            case .project: MainTabRowMetrics.projectFontSize
            case .title: MainTabRowMetrics.titleFontSize
            }
        }
    }

    /// The project name's line when there is a project, else the title's.
    static func notesLine(repoName: String?) -> NotesLine {
        repoName == nil ? .title : .project
    }

    var body: some View {
        if Self.notesLine(repoName: repoName) == .project, let repoName {
            VStack(alignment: .leading, spacing: MainTabRowMetrics.titleLineSpacing) {
                titleMenu
                HStack(spacing: MainTabRowMetrics.notesToProjectSpacing) {
                    notesButton(.project)
                    WorktreeTitleMenus.repoMenu(appState: appState, worktree: worktree) {
                        Text(repoName)
                            .font(.system(size: MainTabRowMetrics.projectFontSize))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }
                }
            }
        } else {
            HStack(spacing: MainTabRowMetrics.notesToProjectSpacing) {
                notesButton(.title)
                titleMenu
            }
        }
    }

    private var titleMenu: some View {
        WorktreeTitleMenus.worktreeMenu(appState: appState, worktree: worktree) {
            Text(worktree.displayName)
                .font(.system(size: MainTabRowMetrics.titleFontSize, weight: .semibold))
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .help(worktree.displayName)
    }

    private func notesButton(_ line: NotesLine) -> some View {
        WorktreeNotesButton(worktree: worktree, style: .inline(fontSize: line.fontSize))
            .fixedSize()
    }
}

/// The worktree's notes button, with its popover and its hover label. In
/// either style it draws the tab rows' hover square
/// (`RowIconButtonStyle`) at its small size: a square
/// `MainTabRowMetrics.notesHitOutset` past its symbol on each side, which is
/// its hit area too and leaves the button's size, and the layout around it,
/// as they are. A full 28 pt square would dwarf the line of text it leads.
/// The style draws its symbol in the secondary colour too.
struct WorktreeNotesButton: View {
    /// How the button draws.
    enum Style: Equatable {
        /// The toolbar's inline cluster: the symbol at the default size, with
        /// a hover label drawn under it.
        case toolbar
        /// Leading a line of text in the main row's title column: the symbol
        /// at the line's point size, in the secondary colour, and its help tag
        /// as its hover label.
        case inline(fontSize: CGFloat)
    }

    /// The hover square both styles draw.
    private static let squareStyle = RowIconButtonStyle(.outset(MainTabRowMetrics.notesHitOutset))

    let worktree: Worktree
    let style: Style
    @State private var showNotes = false
    @State private var hoveringNotes = false

    init(worktree: Worktree, style: Style = .toolbar) {
        self.worktree = worktree
        self.style = style
    }

    private var notesTooltip: String {
        worktree.isScratch ? "Worktree notes" : "Repo notes"
    }

    var body: some View {
        button
            .popover(isPresented: $showNotes, arrowEdge: .bottom) {
                NotepadPopoverView(scope: NotesScope.resolve(for: worktree))
                    // The main row's icon-button style stops at the popover.
                    .buttonStyle(.automatic)
            }
    }

    @ViewBuilder
    private var button: some View {
        switch style {
        case .toolbar:
            Button {
                showNotes.toggle()
            } label: {
                Image(systemName: "square.and.pencil")
            }
            .buttonStyle(Self.squareStyle)
            .onHover { hoveringNotes = $0 }
            .overlay(alignment: .top) {
                if hoveringNotes && !showNotes {
                    Text(notesTooltip)
                        .font(.caption)
                        .fixedSize()
                        .padding(.horizontal, 6)
                        .padding(.vertical, 3)
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 5))
                        .overlay(RoundedRectangle(cornerRadius: 5).stroke(.separator))
                        .offset(y: 26)
                        .allowsHitTesting(false)
                }
            }
        case .inline(let fontSize):
            Button {
                showNotes.toggle()
            } label: {
                // In the style's own secondary colour.
                Image(systemName: "square.and.pencil")
                    .font(.system(size: fontSize))
            }
            .buttonStyle(Self.squareStyle)
            .help(notesTooltip)
        }
    }
}

/// The title's two menus, shared by the toolbar's inline cluster and the
/// main row's title column, which differ only in their labels.
@MainActor
enum WorktreeTitleMenus {
    /// The repo name's menu: links to the repo's detail tabs, and New
    /// Worktree.
    static func repoMenu<Label: View>(
        appState: AppState, worktree: Worktree, @ViewBuilder label: () -> Label
    ) -> some View {
        let labelView = label()
        return Menu {
            if let repoID = worktree.repoID {
                Button("Archived Worktrees") { openRepoTab(appState, repoID, .archived) }
                Button("Default Prompts") { openRepoTab(appState, repoID, .instructions) }
                Button("Hooks & Settings") { openRepoTab(appState, repoID, .settings) }
                Divider()
                Button("New Worktree") { appState.createWorktree(repoID: repoID) }
                    .keyboardShortcut("n", modifiers: .command)
            }
        } label: {
            labelView
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
    }

    /// The worktree name's menu: the sidebar row's action menu.
    static func worktreeMenu<Label: View>(
        appState: AppState, worktree: Worktree, @ViewBuilder label: () -> Label
    ) -> some View {
        let labelView = label()
        return Menu {
            RowActionMenuItemsView(
                actions: RowActionMenuActions(
                    appState: appState,
                    worktree: worktree,
                    onRename: { appState.editingWorktreeID = worktree.id }
                )
            )
        } label: {
            labelView
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
    }

    private static func openRepoTab(_ appState: AppState, _ repoID: UUID, _ tab: RepoDetailTab) {
        appState.pendingRepoDetailTab = tab
        appState.selectRepo(id: repoID)
    }
}
