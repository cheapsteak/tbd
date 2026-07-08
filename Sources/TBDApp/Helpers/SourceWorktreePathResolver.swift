import Foundation

/// Resolves the absolute path of the worktree that built this running app.
///
/// Primary source is a sidecar file written into the bundle by `scripts/restart.sh`;
/// falls back to parsing the exec path for legacy in-place `.build/debug/TBD.app` launches.
/// Extracted as a non-actor type so callers from different isolation contexts
/// (main-actor views, background actors like DaemonClient) can use it without
/// isolation violations.
enum SourceWorktreePathResolver {
    /// Resolve the source worktree path from the bundle or exec path.
    ///
    /// Tries the sidecar file (Contents/SourceWorktreePath.txt) written by
    /// `scripts/restart.sh` first; falls back to parsing the executable path
    /// for the legacy in-place `.build/debug/TBD.app` launch shape.
    ///
    /// - Parameters:
    ///   - bundleURL: The URL of the app bundle (typically `Bundle.main.bundleURL`)
    ///   - executablePath: The path to the running app executable
    ///     (typically `Bundle.main.executablePath`)
    ///   - sidecarReader: Injection seam for reading the sidecar file;
    ///     defaults to filesystem read. Tests can provide a custom reader
    ///     to avoid needing a real bundle structure.
    ///
    /// - Returns: The absolute path of the source worktree, or nil if neither
    ///   source is available.
    static func resolve(
        bundleURL: URL,
        executablePath: String?,
        sidecarReader: (URL) -> String? = { try? String(contentsOf: $0, encoding: .utf8) }
    ) -> String? {
        let sidecarURL = bundleURL.appendingPathComponent("Contents/SourceWorktreePath.txt")
        if let raw = sidecarReader(sidecarURL) {
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { return trimmed }
        }
        if let execPath = executablePath,
           let buildRange = execPath.range(of: "/.build/", options: .backwards) {
            return String(execPath[..<buildRange.lowerBound])
        }
        return nil
    }
}
