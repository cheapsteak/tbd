import Foundation

/// Where to look for a command when the ambient `PATH` cannot be trusted.
///
/// A GUI process does not inherit a login shell's `PATH`. When TBD is launched
/// from a terminal it gets the developer's full path; when LaunchServices
/// relaunches the installed `.app` — at login after a reboot, from Spotlight,
/// via "reopen windows" — it can get launchd's bare
/// `/usr/bin:/bin:/usr/sbin:/sbin` instead, and everything the app spawns
/// inherits that. `scripts/restart.sh` writes the developer's `PATH` into the
/// bundle's `LSEnvironment`, but that is a request LaunchServices does not
/// always honour, so subprocess environments need a floor of their own.
///
/// The floor is **appended**, never prepended: a real launch `PATH` still wins,
/// including a user's deliberate ordering of shims (volta, asdf, a
/// project-local `node_modules/.bin`). These directories only ever answer a
/// lookup that would otherwise have failed.
public enum ExecutableSearchPath {
    /// Common package-manager and system directories, in the order a lookup
    /// should try them. Home-relative entries come first because a
    /// user-installed tool should win over a system copy of the same name.
    public static func fallbackDirectories(
        homeDirectory: String = FileManager.default.homeDirectoryForCurrentUser.path
    ) -> [String] {
        [
            "\(homeDirectory)/.local/bin",
            "\(homeDirectory)/.volta/bin",
            "\(homeDirectory)/.cargo/bin",
            "/opt/homebrew/bin",
            "/opt/homebrew/sbin",
            "/usr/local/bin",
            "/usr/bin",
            "/bin",
            "/usr/sbin",
            "/sbin",
        ]
    }

    /// `path` with every missing fallback directory appended.
    ///
    /// Existing entries keep their order and their precedence; a directory
    /// already present is not repeated, so calling this twice is the same as
    /// calling it once. A nil or empty `path` yields the fallbacks alone.
    public static func augmented(
        _ path: String?,
        homeDirectory: String = FileManager.default.homeDirectoryForCurrentUser.path
    ) -> String {
        let existing = (path ?? "")
            .split(separator: ":", omittingEmptySubsequences: true)
            .map(String.init)

        var seen = Set<String>()
        var ordered: [String] = []
        for directory in existing + fallbackDirectories(homeDirectory: homeDirectory)
        where seen.insert(directory).inserted {
            ordered.append(directory)
        }
        return ordered.joined(separator: ":")
    }
}
