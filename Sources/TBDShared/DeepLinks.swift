import Foundation

/// Shared format for `tbd://` deep-link URLs used by both the app and the CLI.
public enum DeepLink {
    public static let scheme = "tbd"
    public static let openHost = "open"
    /// GitHub Pages redirector that forwards its query onto `tbd://open` —
    /// the shareable https form of a deep link (works in chat apps and
    /// browsers that won't linkify a custom scheme).
    public static let redirectorBase = "https://cheapsteak.github.io/tbd/open/"

    /// Build a `tbd://open?worktree=<uuid>[&terminal=<uuid>]` URL for the
    /// given worktree, optionally anchored to a specific terminal's tab.
    public static func makeOpenWorktreeURL(_ id: UUID, terminalID: UUID? = nil) -> URL {
        var components = URLComponents()
        components.scheme = scheme
        components.host = openHost
        components.queryItems = queryItems(worktreeID: id, terminalID: terminalID)
        guard let url = components.url else {
            preconditionFailure("DeepLink components produced an invalid URL")
        }
        return url
    }

    /// Build the shareable https form:
    /// `https://cheapsteak.github.io/tbd/open/?worktree=<uuid>[&terminal=<uuid>]`.
    /// The redirector page forwards both params onto the `tbd://` scheme.
    public static func makeShareableOpenURL(_ id: UUID, terminalID: UUID? = nil) -> URL {
        guard var components = URLComponents(string: redirectorBase) else {
            preconditionFailure("DeepLink redirector base is an invalid URL")
        }
        components.queryItems = queryItems(worktreeID: id, terminalID: terminalID)
        guard let url = components.url else {
            preconditionFailure("DeepLink components produced an invalid URL")
        }
        return url
    }

    private static func queryItems(worktreeID: UUID, terminalID: UUID?) -> [URLQueryItem] {
        var items = [URLQueryItem(name: "worktree", value: worktreeID.uuidString)]
        if let terminalID {
            items.append(URLQueryItem(name: "terminal", value: terminalID.uuidString))
        }
        return items
    }

    /// Parse a `tbd://open?worktree=<uuid>[&terminal=<uuid>]` URL. Returns the
    /// worktree UUID (and the terminal UUID when present) on success, or `nil`
    /// if the URL doesn't match the expected shape. A missing or malformed
    /// `terminal` param never rejects the URL — the worktree still parses with
    /// a nil terminal, so older or hand-edited links degrade gracefully. Does
    /// NOT validate that the worktree or terminal exists.
    public static func parseOpenURL(_ url: URL) -> (worktree: UUID, terminal: UUID?)? {
        guard
            let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
            components.scheme == scheme,
            components.host == openHost,
            let items = components.queryItems,
            let worktreeValue = items.first(where: { $0.name == "worktree" })?.value,
            let id = UUID(uuidString: worktreeValue)
        else {
            return nil
        }
        let terminal = items.first(where: { $0.name == "terminal" })?.value
            .flatMap(UUID.init(uuidString:))
        return (worktree: id, terminal: terminal)
    }
}
