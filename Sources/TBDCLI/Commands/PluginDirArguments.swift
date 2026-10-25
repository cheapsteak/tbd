import ArgumentParser
import Foundation

/// The CLI's half of `--plugin-dir`. The daemon stores each path for later
/// starts and runs in a different folder from the shell that typed it, so a
/// relative path is made absolute here, against the shell's current folder,
/// before it is sent; the daemon refuses one that arrives relative.
enum CLIPluginDirs {
    static let blankValueMessage = "--plugin-dir must not be empty."

    /// Refuses a blank or whitespace-only value. Resolved against the current
    /// folder, a blank path names that folder, which exists, so the daemon
    /// would load the current folder as a plugin folder.
    static func validateNotBlank(_ paths: [String]) throws {
        if paths.contains(where: { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) {
            throw ValidationError(blankValueMessage)
        }
    }

    /// `paths` in order, each relative one resolved against `cwd` and
    /// standardized. A path starting with `/` or `~/` is sent unchanged: the
    /// daemon expands `~/` itself.
    static func absolute(_ paths: [String], cwd: String) -> [String] {
        paths.map { path in
            path.hasPrefix("/") || path.hasPrefix("~/")
                ? path
                : resolvePath(path, relativeTo: cwd)
        }
    }
}
