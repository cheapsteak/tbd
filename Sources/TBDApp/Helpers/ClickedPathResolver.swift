import Foundation

/// Turns a clicked token into an absolute path to an existing file, or nil.
///
/// Pure and AppKit-free so both click surfaces share one definition of "this
/// text names a file": the terminal's cmd+click (`TBDTerminalView`) and the
/// transcript's link pass (`TranscriptLinkPass`). Keeping the rules in one
/// place is the point — two implementations drifted apart is exactly the bug
/// this replaces.
enum ClickedPathResolver {
    /// Characters that may appear inside a clicked path token.
    ///
    /// Referenced by the terminal's `extractFilePath` widener and by
    /// `TranscriptLinkScanner` — never copied into either. Two surfaces that
    /// share a resolver but duplicate the tokenizer are still free to disagree
    /// about where a path begins and ends, which is the same drift the shared
    /// resolver exists to prevent, one layer down.
    static let pathTokenCharacters = CharacterSet.alphanumerics
        .union(CharacterSet(charactersIn: "/._-~"))

    /// Resolves `token` against `worktreePath`.
    ///
    /// Accepted forms, in order: `file://` URLs (including the `file://~` form,
    /// where `URL.path` would otherwise swallow the tilde as a host), `~`-rooted
    /// paths, absolute paths, and paths relative to the worktree root. A
    /// trailing `:line` or `:line:col` is stripped before the existence check.
    ///
    /// Returns nil unless the result names an existing file that is not a
    /// directory — the rule that keeps `/foo/bar`-shaped prose from becoming a
    /// field of dead links.
    static func resolve(
        _ token: String,
        worktreePath: String,
        isReadableFile: (String) -> Bool
    ) -> String? {
        let candidate: String
        if token.hasPrefix("file://~") {
            candidate = NSString(string: String(token.dropFirst("file://".count)))
                .expandingTildeInPath
        } else if token.hasPrefix("file://") {
            guard let path = URL(string: token)?.path, !path.isEmpty else { return nil }
            candidate = path
        } else if token.hasPrefix("~") {
            candidate = NSString(string: token).expandingTildeInPath
        } else if token.hasPrefix("/") {
            candidate = token
        } else if !token.contains("://"), !worktreePath.isEmpty {
            candidate = URL(fileURLWithPath: worktreePath).appendingPathComponent(token).path
        } else {
            return nil
        }

        let pathOnly = strippingLineSuffix(candidate)
        guard isReadableFile(pathOnly) else { return nil }
        return pathOnly
    }

    /// Convenience overload querying the real filesystem. A directory is not a
    /// readable file for this purpose — the viewer opens files.
    static func resolve(_ token: String, worktreePath: String) -> String? {
        resolve(token, worktreePath: worktreePath) { path in
            var isDir: ObjCBool = false
            let exists = FileManager.default.fileExists(atPath: path, isDirectory: &isDir)
            return exists && !isDir.boolValue
        }
    }

    /// Drops a trailing `:line` or `:line:col`. The viewer takes no line
    /// argument, so the suffix only ever obstructs the existence check.
    static func strippingLineSuffix(_ path: String) -> String {
        guard let range = path.range(of: ":\\d+(:\\d+)?$", options: .regularExpression) else {
            return path
        }
        return String(path[..<range.lowerBound])
    }
}
