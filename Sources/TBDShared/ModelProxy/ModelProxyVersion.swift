import Foundation

/// The build identity of a `TBDModelProxy` image, computed the same way on
/// both sides of the comparison that uses it.
///
/// The daemon replaces a running proxy whose version *differs* from its own
/// (spec, "Supervisor") — different rather than older, because `tbd update`
/// keeps the previous app bundle as a rollback route and a rollback must
/// replace the newer image it rolled back from. That rule is only meaningful
/// if the two sides compute the identity identically: the proxy reports the
/// identity of the executable it is running, and the daemon computes the
/// identity of the sibling `TBDModelProxy` it would spawn. One function, in
/// `TBDShared`, so a change to the formula cannot land on one side only.
///
/// **Size and mtime, not a hash.** The daemon computes this on every watch
/// poll for a binary that may sit on a network volume, and the two facts it
/// reads come out of one `stat`. A content hash would be stronger against a
/// deliberate forgery, but nothing here is a security boundary — both files
/// are in a directory the user already owns — and the failure it would prevent
/// (a rebuild that lands on the same size *and* the same whole second) is one
/// SwiftPM cannot produce: a relink writes a fresh mtime.
///
/// **Whole seconds.** APFS keeps nanoseconds, but the two sides read the file
/// through different code paths and a sub-second component is exactly the kind
/// of detail one of them can round. Truncating to the second makes the string
/// stable under any reader that agrees on the second.
public enum ModelProxyVersion {
    /// What a proxy reports when it cannot read its own executable. Two
    /// proxies both reporting this are still *different* from the daemon's own
    /// identity, so an unreadable binary reads as "replace me" rather than as
    /// "adopt me" — the safe direction.
    public static let unknown = "unknown"

    /// `"<size in bytes>-<mtime in whole seconds since the epoch>"`, or nil
    /// when the file cannot be described.
    ///
    /// Symlinks are resolved first: `.build/debug/TBDModelProxy` and the copy
    /// inside an app bundle can be links to one file, and `stat` on the link
    /// itself would describe the link.
    public static func identity(of url: URL, fileManager: FileManager = .default) -> String? {
        let resolved = url.resolvingSymlinksInPath()
        guard let attributes = try? fileManager.attributesOfItem(atPath: resolved.path),
            let size = attributes[.size] as? NSNumber,
            let modified = attributes[.modificationDate] as? Date
        else {
            return nil
        }
        return "\(size.int64Value)-\(Int(modified.timeIntervalSince1970))"
    }

    /// The identity of a running process's own executable, falling back to
    /// `unknown`.
    ///
    /// `Bundle.main.executableURL` is the authority — TBD's executables are
    /// unbundled SPM products, and it resolves to the running image — with
    /// `argv[0]` behind it for the case where the bundle cannot answer.
    public static func currentExecutable(
        bundleExecutable: URL? = Bundle.main.executableURL,
        argumentZero: String = CommandLine.arguments.first ?? "",
        fileManager: FileManager = .default
    ) -> String {
        let candidates = [bundleExecutable, argumentZero.isEmpty ? nil : URL(fileURLWithPath: argumentZero)]
        for candidate in candidates.compactMap({ $0 }) {
            if let identity = identity(of: candidate, fileManager: fileManager) {
                return identity
            }
        }
        return unknown
    }
}
