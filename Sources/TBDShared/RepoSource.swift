import Foundation

/// What the user typed when adding a repository: a local folder, a git URL to
/// clone, a GitHub `owner/repo` short form, or something unusable.
public enum RepoSource: Equatable, Sendable {
    /// An existing path, as given (trimmed).
    case local(path: String)
    /// A git URL to clone, with the folder name the clone should get.
    case remote(url: String, folderName: String)
    /// `owner/repo` (the repo has no `.git` suffix); the caller resolves the clone URL.
    case githubShortForm(owner: String, repo: String)
    case invalid(reason: String)

    private static let schemes: Set<String> = ["https", "http", "ssh", "git", "file"]
    private static let genericReason = "Enter a git URL or owner/repo."
    private static let noFolderReason = "Can't tell the folder name from this URL."

    /// Classifies `text`. Rules apply in order: an existing path wins over
    /// everything, then `scheme://` URLs, then scp-like `host:path`, then
    /// `[github.com/]owner/repo`. `pathExists` is asked about the trimmed text.
    public static func parse(_ text: String, pathExists: (String) -> Bool) -> RepoSource {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return .invalid(reason: genericReason) }
        if pathExists(trimmed) { return .local(path: trimmed) }

        if let schemeRange = trimmed.range(of: "://") {
            let scheme = String(trimmed[..<schemeRange.lowerBound])
            if isSchemeName(scheme) {
                guard schemes.contains(scheme.lowercased()) else {
                    return .invalid(
                        reason: "Unsupported URL scheme '\(scheme)'. Use https, http, ssh, git or file."
                    )
                }
                // Drop the authority (host) so only the path names the folder.
                let afterScheme = trimmed[schemeRange.upperBound...]
                let path = afterScheme.firstIndex(of: "/").map { String(afterScheme[$0...]) } ?? ""
                return remote(url: trimmed, path: path)
            }
        }

        if let colon = trimmed.firstIndex(of: ":") {
            let host = trimmed[..<colon]
            let path = String(trimmed[trimmed.index(after: colon)...])
            if !host.contains("/"), !host.isEmpty, !path.isEmpty {
                return remote(url: trimmed, path: path)
            }
        }

        return shortForm(trimmed) ?? .invalid(reason: genericReason)
    }

    /// `folderName` for `.remote`, `repo` for `.githubShortForm`, nil otherwise.
    public var cloneFolderName: String? {
        switch self {
        case .remote(_, let folderName): return folderName
        case .githubShortForm(_, let repo): return repo
        case .local, .invalid: return nil
        }
    }

    private static func isSchemeName(_ scheme: String) -> Bool {
        !scheme.isEmpty && scheme.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || "+-.".contains($0)) }
    }

    private static func remote(url: String, path: String) -> RepoSource {
        guard let last = path.split(separator: "/").last else {
            return .invalid(reason: noFolderReason)
        }
        let name = dropGitSuffix(String(last))
        if name.isEmpty || name == "." || name == ".." {
            return .invalid(reason: noFolderReason)
        }
        return .remote(url: url, folderName: name)
    }

    private static func shortForm(_ text: String) -> RepoSource? {
        var rest = text
        let hostPrefix = "github.com/"
        if rest.lowercased().hasPrefix(hostPrefix) { rest = String(rest.dropFirst(hostPrefix.count)) }
        let parts = rest.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard parts.count == 2 else { return nil }
        let owner = parts[0]
        let repo = dropGitSuffix(parts[1])
        let ownerOK = !owner.isEmpty && owner.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") }
        let repoOK = !repo.isEmpty && repo != "." && repo != ".."
            && repo.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || "._-".contains($0)) }
        guard ownerOK, repoOK else { return nil }
        return .githubShortForm(owner: owner, repo: repo)
    }

    private static func dropGitSuffix(_ name: String) -> String {
        name.hasSuffix(".git") ? String(name.dropLast(4)) : name
    }
}
