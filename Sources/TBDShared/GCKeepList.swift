import Darwin
import Foundation

/// Command-line patterns the orphan-process sweep must never reclaim.
///
/// **A file, not a compiled list.** Which long-lived daemons a machine runs
/// outside any worktree (an agent daemon, a key agent) differs per user, and
/// a wrong guess either kills something that mattered or leaks something that
/// did not. So the shipped list is only the default: a user's file replaces it
/// wholesale, and TBD never rewrites that file. A missing file means the
/// shipped defaults; an empty file means an empty list; a file that cannot be
/// read means the sweep must not run (see `Loaded.unreadable`), because
/// falling back to defaults would silently drop the user's own protections.
public struct GCKeepList: Sendable, Equatable {
    public let patterns: [String]

    public init(patterns: [String]) {
        self.patterns = patterns
    }

    /// The patterns TBD ships, in a fixed order.
    public static let shippedPatterns: [String] = [
        "claude daemon run", "--bg-pty-host", "gpg-agent", "dirmngr", "keyboxd", "codex app-server",
    ]

    public static var shipped: GCKeepList { GCKeepList(patterns: shippedPatterns) }

    /// One pattern per line. Lines are trimmed (so CRLF endings and trailing
    /// spaces never end up inside a pattern); blank lines and lines starting
    /// with `#` are dropped.
    public static func parse(_ text: String) -> GCKeepList {
        let patterns = text.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.hasPrefix("#") }
        return GCKeepList(patterns: patterns)
    }

    /// Whether `command` contains any pattern as a substring. An empty pattern
    /// matches nothing: it would otherwise protect every process.
    public func matches(_ command: String) -> Bool {
        patterns.contains { !$0.isEmpty && command.contains($0) }
    }

    /// The text `customize` writes: a comment header, then `patterns`.
    public static func fileContents(patterns: [String] = shippedPatterns) -> String {
        let header = [
            "# One pattern per line.",
            "# A process whose command line contains a pattern is never reclaimed by the",
            "# orphan-process sweep, nor is anything beneath it.",
            "# Lines starting with # are ignored.",
            "# TBD never rewrites this file.",
        ]
        return (header + patterns).joined(separator: "\n") + "\n"
    }

    public enum Source: String, Sendable, Equatable { case shippedDefaults, file }

    public enum Loaded: Sendable, Equatable {
        case list(GCKeepList, Source)
        /// The file exists but cannot be read as UTF-8 text.
        case unreadable(reason: String)
    }

    /// Load the list at `path`. Absent (`ENOENT`) means the shipped defaults;
    /// a readable UTF-8 file replaces them; anything else is `.unreadable`.
    public static func load(path: String) -> Loaded {
        var info = stat()
        if lstat(path, &info) != 0 {
            let code = errno
            if code == ENOENT { return .list(.shipped, .shippedDefaults) }
            return .unreadable(reason: String(cString: strerror(code)))
        }
        do {
            let data = try Data(contentsOf: URL(fileURLWithPath: path))
            guard let text = String(data: data, encoding: .utf8) else {
                return .unreadable(reason: "not valid UTF-8")
            }
            return .list(parse(text), .file)
        } catch {
            return .unreadable(reason: error.localizedDescription)
        }
    }

    /// Write the shipped defaults to `path` for the user to edit. Never
    /// overwrites: returns false, touching nothing, when the file exists.
    @discardableResult
    public static func customize(path: String) throws -> Bool {
        let url = URL(fileURLWithPath: path)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        var existing = stat()
        do {
            try Data(fileContents().utf8).write(to: url, options: .withoutOverwriting)
            return true
        } catch {
            // `withoutOverwriting` reports an existing file as an error; the
            // file being there is the answer, not a failure.
            if lstat(path, &existing) == 0 { return false }
            throw error
        }
    }
}
