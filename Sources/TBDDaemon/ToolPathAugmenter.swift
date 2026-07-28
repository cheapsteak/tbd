import Foundation

/// Augments PATH with standard macOS tool directories when the daemon is spawned
/// from the GUI app with a minimal LaunchServices PATH.
///
/// When TBDApp launches TBDDaemon directly, the daemon inherits the app's environment,
/// which on macOS is `/usr/bin:/bin:/usr/sbin:/sbin` — a minimal set that excludes
/// Homebrew tools. This causes git subprocesses to fail when they try to invoke
/// `git-lfs` (and other tools only present in `/opt/homebrew/bin`), because git's
/// `filter.<driver>.process` hook cannot find the executable.
///
/// This helper prepends the standard macOS tool directories in a deterministic order,
/// preserving any existing PATH entries and avoiding duplicates.
public struct ToolPathAugmenter {
    /// Prepends standard macOS tool directories to the PATH.
    ///
    /// - Parameter currentPath: The current PATH string, or nil/empty to start fresh.
    ///   Existing entries are preserved and their order is maintained.
    /// - Returns: An augmented PATH string with Homebrew and standard directories
    ///   prepended, or the input unchanged if it already contains all required dirs.
    ///
    /// Directories prepended (in order): `/opt/homebrew/bin`, `/opt/homebrew/sbin`,
    /// `/usr/local/bin`, `/usr/local/sbin`. None are prepended if already present.
    nonisolated public static func augmentPath(_ currentPath: String?) -> String {
        let dirsToPrepend = [
            "/opt/homebrew/bin",
            "/opt/homebrew/sbin",
            "/usr/local/bin",
            "/usr/local/sbin"
        ]

        let existingParts = (currentPath ?? "")
            .split(separator: ":", omittingEmptySubsequences: false)
            .map { String($0) }

        var toAdd: [String] = []
        for dir in dirsToPrepend {
            if !existingParts.contains(dir) {
                toAdd.append(dir)
            }
        }

        if toAdd.isEmpty {
            return currentPath ?? ""
        }

        let newParts = toAdd + existingParts
        return newParts.joined(separator: ":")
    }
}
