import Foundation

/// TBD's own ⌘-click matcher: what a ⌘-click on one terminal row opens, before the engine's link
/// detection looks. It finds a file path around the clicked column, then a `PR #123` anywhere on
/// the row; a URL, or a path soft-wrapped across rows, is left to the detection after it.
///
/// Both engines call it, so a ⌘-click opens the same thing whichever draws the terminal.
/// `TBDTerminalView` hands it a row of SwiftTerm's buffer and `GhosttyEngine` a row the libghostty
/// view read at the press, each as SwiftTerm's `BufferLine.translateToString()` gives a row: one
/// `Character` per column, `"\0"` for a cell with no text.
///
/// It runs only on a panel's terminal, which resolves paths against a worktree: each engine calls
/// it only while click routing is on.
enum TerminalCommandClick {
    enum Target: Equatable {
        /// An existing file, as an absolute path.
        case file(String)
        /// A link for the browser.
        case url(URL)
    }

    /// What a ⌘-click at `column` of `row` opens, or nil when TBD's matcher finds nothing there.
    static func target(
        row: String,
        column: Int,
        worktreePath: String,
        remoteURL: String?,
        isReadableFile: (String) -> Bool = ClickedPathResolver.isReadableFile
    ) -> Target? {
        if let path = filePath(in: row, column: column, worktreePath: worktreePath, isReadableFile: isReadableFile) {
            return .file(path)
        }
        guard let link = pullRequestLink(in: row, remoteURL: remoteURL) else { return nil }
        if let path = ClickedPathResolver.resolve(link, worktreePath: worktreePath, isReadableFile: isReadableFile) {
            return .file(path)
        }
        guard link.contains("://"), let url = URL(string: link) else { return nil }
        return .url(url)
    }

    /// The existing file named by the path-shaped token around `column`: the run of
    /// `ClickedPathResolver.pathTokenCharacters` holding it, so a `:line` suffix, quotes, brackets
    /// and spaces all end the path. Trailing full stops are dropped, since a sentence can end in
    /// one ("see design.md."); the resolver expands `~` and resolves a relative path against
    /// `worktreePath`.
    private static func filePath(
        in row: String,
        column: Int,
        worktreePath: String,
        isReadableFile: (String) -> Bool
    ) -> String? {
        let characters = Array(row)
        guard characters.indices.contains(column) else { return nil }
        // Whole characters, so a character of several scalars (a decomposed accent) keeps the
        // token's columns where the row's are.
        let pathCharacters = ClickedPathResolver.pathTokenCharacters
        func isPathCharacter(_ character: Character) -> Bool {
            character.unicodeScalars.allSatisfy { pathCharacters.contains($0) }
        }
        var start = column
        var end = column
        while start > 0, isPathCharacter(characters[start - 1]) { start -= 1 }
        while end + 1 < characters.count, isPathCharacter(characters[end + 1]) { end += 1 }
        var candidate = String(characters[start...end])
        while candidate.hasSuffix(".") { candidate.removeLast() }
        guard !candidate.isEmpty else { return nil }
        return ClickedPathResolver.resolve(candidate, worktreePath: worktreePath, isReadableFile: isReadableFile)
    }

    /// The pull request a `PR #123` anywhere on `row` links to, on the repository at `remoteURL`.
    /// Anywhere, not at the click: wide characters (`▶▶`) put a row's text and its columns out of
    /// step, so the click's column cannot be trusted to find the number.
    static func pullRequestLink(in row: String, remoteURL: String?) -> String? {
        let text = String(row.map { $0 == "\0" ? " " : $0 })
        guard let match = prPattern.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let number = Range(match.range(at: 1), in: text),
              let repository = browserURL(ofRemote: remoteURL) else { return nil }
        return "\(repository)/pull/\(text[number])"
    }

    private static let prPattern = try! NSRegularExpression(pattern: "PR\\s+#(\\d+)")

    /// The repository's page for a remote: `.git` dropped, and GitHub's SSH form rewritten as its
    /// HTTPS one.
    private static func browserURL(ofRemote remoteURL: String?) -> String? {
        guard var remote = remoteURL, !remote.isEmpty else { return nil }
        if remote.hasSuffix(".git") { remote = String(remote.dropLast(4)) }
        if remote.hasPrefix("git@github.com:") {
            remote = "https://github.com/" + remote.dropFirst("git@github.com:".count)
        }
        return remote
    }
}
