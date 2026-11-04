import Foundation
import TBDShared

/// The repo filter menu: "All Repos" plus each repo, and the current choice,
/// then the Show Hidden Repos toggle and its state.
struct RepoFilterPresentation: Equatable {
    struct Option: Equatable {
        var id: UUID?
        var title: String
    }

    var options: [Option]
    var selected: UUID?
    /// False when `selected` names a repo that is not in `options`.
    var selectedIsKnown: Bool
    /// How many repos are hidden: the count the Show Hidden Repos row names.
    var hiddenRepoCount: Int
    /// Whether hidden repos' sections show while no repo is chosen
    /// (`SidebarBuildOptions.showHiddenReposKey`), which checks the Show
    /// Hidden Repos row. It does not make the filter active: only a chosen
    /// repo tints the button.
    var showsHiddenRepos: Bool

    /// The first option's title, which chooses no repo.
    static let allReposTitle = "All Repos"
    /// The filter button's tool tip while no repo filter is set.
    static let inactiveHelp = "Filter sidebar by repository"
    /// The Show Hidden Repos row's title, before any count.
    static let showHiddenReposTitle = "Show Hidden Repos"

    /// Whether a repo filter is set: `selected` names a repo, known or gone.
    /// A filter naming a repo that is gone still filters the sidebar, to no
    /// repo at all.
    var isActive: Bool { selected != nil }

    /// The Show Hidden Repos row's title: the hidden repos' count follows in
    /// parentheses while there are any.
    var showHiddenReposRowTitle: String {
        guard hiddenRepoCount > 0 else { return Self.showHiddenReposTitle }
        return "\(Self.showHiddenReposTitle) (\(hiddenRepoCount))"
    }

    /// The title of the option `selected` names: "All Repos" when it names
    /// none, the repo's name, or `nil` when it names a repo that is gone.
    var selectedTitle: String? {
        guard selectedIsKnown else { return nil }
        return options.first { $0.id == selected }?.title
    }

    /// The filter button's tool tip: what the button does while no filter is
    /// set, and which repo it filters by while one is.
    var help: String {
        guard isActive else { return Self.inactiveHelp }
        guard let selectedTitle else { return "Filtering by a removed repository" }
        return "Filtering by \(selectedTitle)"
    }

    /// The filter button's accessibility value: "All Repos", the repo it
    /// filters by, or "Removed repository" when that repo is gone.
    var accessibilityValue: String {
        selectedTitle ?? "Removed repository"
    }
}

/// The selected remote session's toolbar buttons.
/// Its actions read the selected session when they are clicked, so it carries
/// no selection of its own.
struct RemotePresentation: Equatable {
    /// The Transcript toggle is offered: only while the session is attached.
    var showsTranscript: Bool
    var showsReconnect: Bool
    var showsStop: Bool
    /// The detail pane shows the transcript, so the toggle reads "Hide".
    var transcriptShown: Bool

    var transcriptSymbolName: String { transcriptShown ? "bubble.fill" : "bubble" }
    var transcriptHelp: String { transcriptShown ? "Hide transcript" : "Show transcript" }
}

/// Everything the AppKit main toolbar reads from `AppState`, and from its
/// defaults store for the filter's Show Hidden Repos row, as plain values.
/// Each apply makes one. The controller compares it with the one it last
/// applied only to skip an apply an observed change asked for when nothing
/// the toolbar shows changed, since making it reads more than it shows, such
/// as every worktree, which `findWorktree` searches for the selected one. An
/// apply that runs diffs the items against the layout, then sets each item
/// property only when it differs from what the item shows
/// (`MainToolbarController.updateContent`).
struct MainToolbarSnapshot: Equatable {
    var canGoBack: Bool
    var canGoForward: Bool
    var filter: RepoFilterPresentation
    var remote: RemotePresentation?
    /// The title cluster's main title (`ToolbarTitleCluster.mainTitle(in:)`),
    /// which the title item's overflow row shows. `nil` with nothing selected.
    var title: String?
    /// Whether the detail area shows a worktree's tab bar
    /// (`AppState.showsWorktreeTabBar`, from `MainDetailContent`).
    var showsWorktreeTabBar: Bool = false

    /// The layout's inputs: the panes draw the top row while a worktree's tab
    /// bar shows.
    func layoutState(sidebarCollapsed: Bool) -> MainToolbarLayoutState {
        MainToolbarLayoutState(
            sidebarCollapsed: sidebarCollapsed,
            showsTranscript: remote?.showsTranscript ?? false,
            showsReconnect: remote?.showsReconnect ?? false,
            showsStop: remote?.showsStop ?? false,
            panesDrawTopRow: showsWorktreeTabBar)
    }

    @MainActor
    static func make(from appState: AppState) -> MainToolbarSnapshot {
        var options = [RepoFilterPresentation.Option(id: nil, title: RepoFilterPresentation.allReposTitle)]
        options += appState.repos.map { RepoFilterPresentation.Option(id: $0.id, title: $0.displayName) }
        let selected = appState.repoFilter
        // The defaults key is not tracked by Observation: the controller's
        // watch on `appState.userDefaults` asks for the apply that reads it.
        let filter = RepoFilterPresentation(
            options: options,
            selected: selected,
            selectedIsKnown: selected == nil || appState.repos.contains { $0.id == selected },
            hiddenRepoCount: appState.repos.filter { $0.hidden }.count,
            showsHiddenRepos: SidebarBuildOptions.storedShowHiddenRepos(appState.userDefaults))

        var remote: RemotePresentation?
        if let selection = appState.selectedRemoteSession {
            // One read of the attach state for Transcript and Reconnect, as
            // `ContentView` does.
            let transcript = appState.remoteTranscriptPresentation(for: selection)
            let showsReconnect = transcript.attached
            let showsStop = appState.remoteSessionShowsStop(selection)
            let showsTranscript = transcript.showsToggle
            if showsReconnect || showsStop || showsTranscript {
                remote = RemotePresentation(
                    showsTranscript: showsTranscript,
                    showsReconnect: showsReconnect,
                    showsStop: showsStop,
                    transcriptShown: transcript.showsPane)
            }
        }

        return MainToolbarSnapshot(
            canGoBack: appState.canGoBack,
            canGoForward: appState.canGoForward,
            filter: filter,
            remote: remote,
            title: ToolbarTitleCluster.mainTitle(in: appState),
            showsWorktreeTabBar: appState.showsWorktreeTabBar)
    }
}
