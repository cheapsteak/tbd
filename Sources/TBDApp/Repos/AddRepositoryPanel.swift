import AppKit

/// Adding a repository from a folder on disk: an open panel that picks one
/// directory, then `AppState.addRepo(path:)` with it. The sidebar's Add
/// Repository row, its Local Folder… item, the TBD menu's Add Local
/// Repository… and the empty start screen's Add Repository all run it.
@MainActor
enum AddRepositoryPanel {
    static let title = "Select a Git Repository"

    /// The open panel, configured to choose one existing directory.
    static func make() -> NSOpenPanel {
        let panel = NSOpenPanel()
        panel.title = title
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = false
        return panel
    }

    /// Runs the panel modally and adds the chosen folder as a repository.
    static func run(appState: AppState) {
        run(add: { path in await appState.addRepo(path: path) })
    }

    /// `run(appState:)` with its two effects handed in.
    /// - Parameters:
    ///   - choose: shows the panel and answers the folder picked, or nil when
    ///     it was cancelled. Tests answer without showing it.
    ///   - add: adds the folder at a path.
    /// - Returns: the task adding the chosen folder, or nil when none was
    ///   chosen.
    @discardableResult
    static func run(
        choose: @MainActor (NSOpenPanel) -> URL? = { $0.runModal() == .OK ? $0.url : nil },
        add: @escaping @MainActor @Sendable (String) async -> Void
    ) -> Task<Void, Never>? {
        guard let url = choose(make()) else { return nil }
        let path = url.path
        return Task { await add(path) }
    }
}
