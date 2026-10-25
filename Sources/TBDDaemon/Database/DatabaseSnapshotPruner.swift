import Foundation
import os

/// Keeps the newest `keepPerKind` copies of each kind TBD writes beside the
/// database and deletes the rest.
///
/// The two kinds are `<name>.pre-migration.<UTC stamp>` (written by
/// `TBDDatabase.takePreMigrationSnapshot`) and `<name>.pre-column-drop.<UTC
/// stamp>` (written by `RetiredColumnReconciler`), where `<name>` is the
/// database file's own name. A file counts as a copy only when its whole name
/// matches; anything else in the directory is never touched. Newest is read
/// from the name's timestamp, not the file date. A failed delete is logged and
/// skipped. Design: `docs/specs/2026-10-25-state-db-retention-design.md`.
enum DatabaseSnapshotPruner {
    /// How many copies of each kind survive a prune.
    static let keepPerKind = 3

    private static let logger = Logger(subsystem: "com.tbd.daemon", category: "migrations")

    /// Prune the copies beside `databasePath`.
    /// - Returns: the number of files deleted.
    @discardableResult
    static func prune(databasePath: String, fileManager: FileManager = .default) -> Int {
        let url = URL(fileURLWithPath: databasePath)
        let directory = url.deletingLastPathComponent().path
        let name = NSRegularExpression.escapedPattern(for: url.lastPathComponent)

        let names: [String]
        do {
            names = try fileManager.contentsOfDirectory(atPath: directory)
        } catch {
            logger.error(
                "Could not list \(directory, privacy: .public) to prune database copies: \(String(describing: error), privacy: .public)")
            return 0
        }

        var deleted = 0
        for kind in ["pre-migration", "pre-column-drop"] {
            guard let regex = try? NSRegularExpression(
                pattern: "^\(name)\\.\(kind)\\.(\\d{8}T\\d{6}Z)$") else { continue }
            var copies: [(file: String, stamp: String)] = []
            for file in names {
                let range = NSRange(file.startIndex..., in: file)
                guard let match = regex.firstMatch(in: file, range: range),
                      let stampRange = Range(match.range(at: 1), in: file)
                else { continue }
                copies.append((file, String(file[stampRange])))
            }
            // The fixed-width stamp sorts chronologically as text; newest first.
            copies.sort { $0.stamp > $1.stamp }
            for copy in copies.dropFirst(keepPerKind) {
                let path = (directory as NSString).appendingPathComponent(copy.file)
                do {
                    try fileManager.removeItem(atPath: path)
                    deleted += 1
                    logger.info("Pruned old database copy \(path, privacy: .public)")
                } catch {
                    logger.error(
                        "Could not prune database copy \(path, privacy: .public): \(String(describing: error), privacy: .public)")
                }
            }
        }
        return deleted
    }
}
