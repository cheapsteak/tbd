import Foundation

/// Directory listing that survives a directory URL which IS a symlink.
///
/// `FileManager.contentsOfDirectory(at:)` does not follow a symlinked
/// directory URL: it returns an EMPTY array — not an error — so every caller
/// that treats "no entries" as "nothing there" degrades silently.
///
/// TBD hits this on every profile-bound Claude session. Model-profile config
/// dirs mirror the host store by symlinking their slots:
///
///     ~/tbd/profiles/<profile-id>/claude/projects -> ~/.claude/projects
///
/// Enumerating that profile projects root therefore saw zero project dirs
/// while the ambient root saw hundreds, which silently turned every
/// by-session-ID transcript lookup (archived-session revive, hibernation wake,
/// fresh-branch conversation revive) into "start a fresh conversation".
///
/// Only ENUMERATION is affected. Paths *through* a symlink — `fileExists`,
/// `createDirectory`, `copyItem` — follow it normally, so those call sites
/// need no change.
enum SymlinkedDirectoryListing {
    /// Entries of `directory`, resolving the URL first so a symlinked
    /// directory lists its target's contents. Returns `nil` when the directory
    /// cannot be listed (missing, or not a directory), matching
    /// `try? FileManager.contentsOfDirectory(at:)`.
    static func entries(
        of directory: URL,
        includingPropertiesForKeys keys: [URLResourceKey]? = nil
    ) -> [URL]? {
        try? FileManager.default.contentsOfDirectory(
            at: directory.resolvingSymlinksInPath(),
            includingPropertiesForKeys: keys
        )
    }
}
