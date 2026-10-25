import Foundation

/// The CLI's half of `--plugin-dir`. The daemon stores each path for later
/// starts and runs in a different folder from the shell that typed it, so a
/// relative path is made absolute here, against the shell's current folder,
/// before it is sent; the daemon refuses one that arrives relative.
enum CLIPluginDirs {
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
