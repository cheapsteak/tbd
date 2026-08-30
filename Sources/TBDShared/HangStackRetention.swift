import Foundation

/// The retention policy for the hang-stack diagnostics directory
/// (`~/Library/Logs/TBD/hang-stacks/`), and the single place it is written
/// down. Design: `docs/specs/2026-08-29-hang-stack-reclaimer-design.md`.
///
/// These constants live in `TBDShared` rather than beside either user because
/// **two processes act on the same directory**: `HangStackWriter` in the app
/// writes one file per hang event and trims to `maxFiles` right after, and
/// `HangStackCollector` in the daemon runs the hourly sweep that enforces
/// `maxAge` as well. If each side carried its own copy of the cap, the file
/// naming shape, or the directory path, the two bounds could drift and each
/// would be enforcing a policy the other did not know about — the write-side
/// cap could keep more files than the sweep's cap, or the sweep could look in a
/// directory nothing writes to. Sharing the constants makes that drift
/// impossible rather than merely unlikely.
public enum HangStackRetention {
    /// Never keep more than this many hang-stack files. The bound `maxAge`
    /// cannot give: a hang *storm* writes files far faster than they age out,
    /// which is exactly how the directory this policy was written against
    /// reached 25,799 files. At the observed ~11.6 KB per file this is roughly
    /// 12 MB.
    public static let maxFiles = 1000

    /// Delete hang-stack files older than this. Fourteen days spans a
    /// days-long performance soak plus the weekend on either side, which is
    /// the longest window anyone has plausibly needed to reach back through.
    public static let maxAge: TimeInterval = 14 * 24 * 3600

    /// Filename prefix `HangStackWriter` gives every file it creates.
    public static let filenamePrefix = "hang-"

    /// Filename suffix `HangStackWriter` gives every file it creates.
    public static let filenameSuffix = ".txt"

    /// Whether `name` has the shape the writer produces
    /// (`hang-<timestamp>-<pid>.txt`).
    ///
    /// A **whitelist**, never a blacklist: the hang-stacks directory is not
    /// TBD's to empty, and anything the writer did not produce — a user's
    /// notes, a copied sample, a subdirectory — must never be a candidate for
    /// deletion.
    public static func isHangStackFilename(_ name: String) -> Bool {
        name.hasPrefix(filenamePrefix) && name.hasSuffix(filenameSuffix)
    }

    /// Whether `url` names an immediate child of `directory` — the anchor check
    /// every deletion in this policy is guarded by.
    ///
    /// Both sides are normalized (symlinks resolved, path standardized, any
    /// trailing slash dropped) before they are compared, because the two
    /// spellings of one directory reach this check from different places: a
    /// base handed in by a caller, and a URL produced by directory
    /// enumeration. On darwin those differ routinely — `/var/folders/…` against
    /// `/private/var/folders/…`, or a directory URL that carries a trailing
    /// slash — and a naive prefix test on the raw strings then reads a
    /// perfectly anchored file as unanchored and silently refuses to reclaim
    /// anything at all.
    ///
    /// Deliberately stricter than a prefix test: only a direct child qualifies,
    /// which is exactly the invariant the enumeration already produces, and a
    /// prefix test would also accept a sibling directory whose name merely
    /// starts with the base's.
    public static func isImmediateChild(_ url: URL, of directory: URL) -> Bool {
        let name = url.lastPathComponent
        guard !name.isEmpty, name != "/", name != ".", name != ".." else { return false }
        return normalizedPath(url.deletingLastPathComponent()) == normalizedPath(directory)
    }

    /// The spelling of a directory that everything enumerating or comparing it
    /// should use: symlinks resolved, path standardized.
    ///
    /// Enumeration is the reason this is not merely tidiness.
    /// `FileManager.contentsOfDirectory(at:)` yields **nothing** for a URL that
    /// is itself a symlink to a directory, so a base handed in through a
    /// symlinked path makes the sweep and the write-side trim silently reclaim
    /// nothing — the failure looks exactly like an empty directory, which is
    /// also what "working correctly" looks like. Resolving the base once, at
    /// the boundary, is what makes that unrepresentable rather than a bug
    /// waiting for the right filesystem layout.
    public static func resolvedDirectory(_ url: URL) -> URL {
        url.resolvingSymlinksInPath().standardizedFileURL
    }

    private static func normalizedPath(_ url: URL) -> String {
        var path = url.resolvingSymlinksInPath().standardizedFileURL.path
        while path.count > 1, path.hasSuffix("/") { path.removeLast() }
        return path
    }

    /// The hang-stacks directory under an explicitly given home directory.
    /// Used by the zero-argument default below, and directly by anything that
    /// needs the path for a home other than this process's.
    public static func baseDirectory(homeDirectory: String) -> URL {
        URL(fileURLWithPath: homeDirectory, isDirectory: true)
            .appendingPathComponent("Library/Logs/TBD/hang-stacks", isDirectory: true)
    }

    /// The production directory: `~/Library/Logs/TBD/hang-stacks`.
    ///
    /// Resolved exactly the way `HangStackWriter` resolved it before this type
    /// existed — the user-domain library directory, falling back to
    /// `NSHomeDirectory()/Library` when that lookup returns nothing — so
    /// consolidating the two callers changed no production behaviour.
    public static var defaultBaseDirectory: URL {
        let library = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
                .appendingPathComponent("Library", isDirectory: true)
        return library.appendingPathComponent("Logs/TBD/hang-stacks", isDirectory: true)
    }
}
