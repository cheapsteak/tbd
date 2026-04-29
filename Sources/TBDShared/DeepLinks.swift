import Foundation

/// Shared format for `tbd://` deep-link URLs used by both the app and the CLI.
public enum DeepLink {
    public static let scheme = "tbd"
    public static let openHost = "open"

    /// Build a `tbd://open?worktree=<uuid>` URL for the given worktree.
    public static func makeOpenWorktreeURL(_ id: UUID) -> URL {
        var components = URLComponents()
        components.scheme = scheme
        components.host = openHost
        components.queryItems = [URLQueryItem(name: "worktree", value: id.uuidString)]
        guard let url = components.url else {
            preconditionFailure("DeepLink components produced an invalid URL")
        }
        return url
    }

    /// Parse a `tbd://open?worktree=<uuid>` URL. Returns the worktree UUID on
    /// success, or `nil` if the URL doesn't match the expected shape. Does NOT
    /// validate that the worktree exists.
    public static func parseOpenURL(_ url: URL) -> UUID? {
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
        return id
    }
}
