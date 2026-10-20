import Foundation
import os

private let logger = Logger(subsystem: "com.tbd.daemon", category: "gc")

/// Removes the two directories the transcript-streaming model proxy left under
/// the TBD home: `proxy` (its pid file, lock, log and route files) and
/// `streams` (its per-terminal stream files). The proxy no longer exists, so
/// nothing writes either directory again and nothing reads them
/// (`docs/specs/2026-10-20-transcript-stream-mod-design.md`, "Leftovers on
/// disk").
///
/// Run once at daemon start, off the path to the socket bind. A directory that
/// is absent is skipped; a removal that fails is logged and left for the next
/// start. Nothing else under the base directory is touched.
struct ProxyLeftoverCleanup: Sendable {
    /// The old feature's leftovers, relative to the TBD home. Named here
    /// rather than in `TBDConstants` because nothing creates them any more.
    static let leftoverDirectoryNames = ["proxy", "streams"]

    /// The TBD home: `TBDConstants.configDir` in production, a temporary
    /// directory in tests.
    let baseDirectory: URL

    /// Removes each leftover directory that exists, and returns the ones it
    /// removed.
    @discardableResult
    func run(fileManager: FileManager = .default) -> [URL] {
        var removed: [URL] = []
        for name in Self.leftoverDirectoryNames {
            let url = baseDirectory.appendingPathComponent(name, isDirectory: true)
            guard fileManager.fileExists(atPath: url.path) else { continue }
            do {
                try fileManager.removeItem(at: url)
                removed.append(url)
                logger.notice(
                    "removed the retired model proxy's leftover directory \(url.path, privacy: .public)")
            } catch {
                logger.error("""
                    could not remove the retired model proxy's leftover directory \
                    \(url.path, privacy: .public): \(error.localizedDescription, privacy: .public)
                    """)
            }
        }
        return removed
    }
}
