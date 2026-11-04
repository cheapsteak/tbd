import SwiftUI
import TBDShared

/// The sizes of the worktree's title line, which the toolbar's title item
/// (`WorktreeTitleView`) and the main row's title column
/// (`WorktreeTitleColumn`) both draw from, so the two read the same.
enum WorktreeTitleMetrics {
    /// The worktree title's point size, at semibold weight (`titleFont`).
    static let titleFontSize: CGFloat = 14
    /// The project name's point size, in the secondary colour
    /// (`projectFont`).
    static let projectFontSize: CGFloat = 11
    /// Between the notes button, the project name and the title.
    static let spacing: CGFloat = 6
    /// The notes button's symbol size in the main row's title column. The
    /// toolbar's notes button sets no font, so its symbol takes the default
    /// font of the hosting view the toolbar draws it in
    /// (`MainWindowSplitView.makeTitleView`), the 13 pt body font; the row's
    /// draws at this size to match it.
    static let notesSymbolSize: CGFloat = 13

    /// The worktree title's font.
    static var titleFont: Font { .system(size: titleFontSize, weight: .semibold) }
    /// The project name's font.
    static var projectFont: Font { .system(size: projectFontSize) }
}

/// Replaces the static "TBD" window title in the toolbar. Left-to-right:
/// notes button, repo name (11 pt) as a dropdown to the repo's detail tabs, and
/// the worktree display name (14 pt) as a dropdown reusing the sidebar row
/// action menu (Rename, Archive, …), at the sizes `WorktreeTitleMetrics`
/// names.
///
/// `appState`/`worktree`/`repoName` are passed in (not read from the
/// environment) so this view has no `@Environment` dependency inside the
/// toolbar's title item.
struct WorktreeTitleView: View {
    let appState: AppState
    let worktree: Worktree
    let repoName: String?

    var body: some View {
        HStack(alignment: .center, spacing: WorktreeTitleMetrics.spacing) {
            WorktreeNotesButton(worktree: worktree)
            if let repoName {
                WorktreeTitleMenus.repoMenu(appState: appState, worktree: worktree) {
                    Text(repoName)
                        .font(WorktreeTitleMetrics.projectFont)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                .fixedSize()
            }
            WorktreeTitleMenus.worktreeMenu(appState: appState, worktree: worktree) {
                Text(worktree.displayName)
                    .font(WorktreeTitleMetrics.titleFont)
                    .lineLimit(1)
            }
            .fixedSize()
        }
    }
}

/// The worktree's title line in the main pane's top row, with the Tabs in the
/// toolbar setting on: the line the toolbar's title item draws
/// (`WorktreeTitleView`) on every page without a tab bar, at the same sizes
/// (`WorktreeTitleMetrics`), so the title reads the same in both. Left to
/// right, centred on the row's midline: the notes button, the project name in
/// 11 pt, secondary, and the worktree title in 14 pt semibold, 6 pt apart,
/// each text with the menu `WorktreeTitleView` gives it. A worktree with no
/// project, a scratch space, shows the notes button, then the title.
///
/// The column takes the width `MainTabRowWidths` gives it. The notes button
/// never shrinks. Neither text holds its ideal width: offered less than the
/// line's ideal width, the project name gives way first, truncating at its
/// end, and then the title, truncating in the middle. Hovering the title
/// shows it whole.
///
/// The notes button takes its inline style rather than the toolbar's, whose
/// hover label draws below the button, where the pane would cut it off.
struct WorktreeTitleColumn: View {
    let appState: AppState
    let worktree: Worktree
    let repoName: String?

    var body: some View {
        HStack(alignment: .center, spacing: WorktreeTitleMetrics.spacing) {
            WorktreeNotesButton(worktree: worktree, style: .inline)
                .fixedSize()
            if let repoName {
                WorktreeTitleMenus.repoMenu(appState: appState, worktree: worktree) {
                    Text(repoName)
                        .font(WorktreeTitleMetrics.projectFont)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
            }
            WorktreeTitleMenus.worktreeMenu(appState: appState, worktree: worktree) {
                Text(worktree.displayName)
                    .font(WorktreeTitleMetrics.titleFont)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .help(worktree.displayName)
            // Offered its width before the project name, so the project name
            // gives way first.
            .layoutPriority(1)
        }
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
        /// The toolbar's inline cluster: the symbol at the hosting view's
        /// default font, 13 pt, with a hover label drawn under it.
        case toolbar
        /// Leading the main row's title column: the symbol at
        /// `WorktreeTitleMetrics.notesSymbolSize`, the toolbar style's size,
        /// and its help tag as its hover label, which the pane cannot cut
        /// off.
        case inline
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
                    // No button style around the notes button reaches the
                    // popover.
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
        case .inline:
            Button {
                showNotes.toggle()
            } label: {
                // In the style's own secondary colour.
                Image(systemName: "square.and.pencil")
                    .font(.system(size: WorktreeTitleMetrics.notesSymbolSize))
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
