import Foundation
import TBDShared

/// The repo filter menu: "All Repos" plus each repo, and the current choice.
struct RepoFilterPresentation: Equatable {
    struct Option: Equatable {
        var id: UUID?
        var title: String
    }

    var options: [Option]
    var selected: UUID?
    /// False when `selected` names a repo that is not in `options`.
    var selectedIsKnown: Bool
}

/// The Servers button for the one selected worktree.
struct ServersPresentation: Equatable {
    var title: String
    var isRunning: Bool
    var primaryURL: String?
    var help: String
    var accessibilityLabel: String
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

    var transcriptSymbolName: String { transcriptShown ? "text.bubble.fill" : "text.bubble" }
    var transcriptHelp: String { transcriptShown ? "Hide transcript" : "Show transcript" }
}

/// Everything the AppKit main toolbar reads from `AppState`, as plain values.
/// Each apply makes one. The controller compares it with the one it last
/// applied only to skip an apply an observed change asked for when nothing
/// the toolbar shows changed, since making it reads more than it shows, such
/// as every worktree's dev-server list. An apply that runs diffs the items
/// against the layout, then sets each item property only when it differs from
/// what the item shows (`MainToolbarController.updateContent`). The rules
/// mirror the SwiftUI toolbar in `ContentView`.
struct MainToolbarSnapshot: Equatable {
    var canGoBack: Bool
    var canGoForward: Bool
    var filter: RepoFilterPresentation
    var servers: ServersPresentation?
    var remote: RemotePresentation?
    /// The title cluster's main title (`ToolbarTitleCluster.mainTitle(in:)`),
    /// which the title item's overflow row shows. `nil` with nothing selected.
    var title: String?

    func layoutState(sidebarCollapsed: Bool) -> MainToolbarLayoutState {
        MainToolbarLayoutState(
            sidebarCollapsed: sidebarCollapsed,
            showsServers: servers != nil,
            showsTranscript: remote?.showsTranscript ?? false,
            showsReconnect: remote?.showsReconnect ?? false,
            showsStop: remote?.showsStop ?? false)
    }

    @MainActor
    static func make(from appState: AppState) -> MainToolbarSnapshot {
        var options = [RepoFilterPresentation.Option(id: nil, title: "All Repos")]
        options += appState.repos.map { RepoFilterPresentation.Option(id: $0.id, title: $0.displayName) }
        let selected = appState.repoFilter
        let filter = RepoFilterPresentation(
            options: options,
            selected: selected,
            selectedIsKnown: selected == nil || appState.repos.contains { $0.id == selected })

        var servers: ServersPresentation?
        if appState.selectedWorktreeIDs.count == 1,
           let worktreeID = appState.selectedWorktreeIDs.first,
           let list = appState.devServerLists[worktreeID],
           AppState.showsServersButton(list) {
            let runningCount = ServersButtonLabel.runningCount(list)
            let primaryURL = AppState.primaryDevServerURL(list)
            servers = ServersPresentation(
                title: ServersButtonLabel.title(runningCount: runningCount),
                isRunning: runningCount > 0,
                primaryURL: primaryURL,
                help: primaryURL.map { "Open \($0) · more options" } ?? "Dev servers",
                accessibilityLabel: ServersButtonLabel.accessibilityLabel(runningCount: runningCount))
        }

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
            servers: servers,
            remote: remote,
            title: ToolbarTitleCluster.mainTitle(in: appState))
    }
}
