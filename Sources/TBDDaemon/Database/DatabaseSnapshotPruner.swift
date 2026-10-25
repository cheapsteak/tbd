import Foundation
import os

/// Keeps the newest `keepPerKind` copies of each kind TBD writes beside the
/// database and deletes the rest.
///
/// The two kinds are `<name>.pre-migration.<UTC stamp>` (written by
/// `TBDDatabase.takePreMigrationSnapshot`) and `<name>.pre-column-drop.<UTC
/// stamp>` (written by `RetiredColumnReconciler`), where `<name>` is the
/// database file's own name. Each writer prunes its own kind, and only once
/// its step has succeeded: `TBDDatabase.init(path:)` after migrations, the
/// reconciler after a run in which nothing failed.
///
/// A file counts as a copy only when its whole name matches, with an ASCII
/// stamp; anything else in the directory is never touched. Newest is read
/// from the name's timestamp, not the file date. A copy named in `protecting`
/// — the one the caller just wrote — is never deleted and takes one of the
/// kept places, so a clock running behind an older stamp cannot delete the
/// newest copy of the database. A failed delete is logged and skipped.
/// Design: `docs/specs/2026-10-25-state-db-retention-design.md`.
enum DatabaseSnapshotPruner {
    /// The kinds of copy, by the word their names carry.
    enum Kind: String, CaseIterable, Sendable {
        case preMigration = "pre-migration"
        case preColumnDrop = "pre-column-drop"
    }

    /// How many copies of each kind survive a prune.
    static let keepPerKind = 3

    private static let logger = Logger(subsystem: "com.tbd.daemon", category: "migrations")

    /// Prune the copies of `kinds` beside `databasePath`.
    /// - Parameter protected: paths of copies that must survive, compared by
    ///   file name. Each one found counts against `keepPerKind`.
    /// - Returns: the number of files deleted.
    @discardableResult
    static func prune(
        databasePath: String,
        kinds: [Kind] = Kind.allCases,
        protecting protected: Set<String> = [],
        fileManager: FileManager = .default
    ) -> Int {
        let url = URL(fileURLWithPath: databasePath)
        let directory = url.deletingLastPathComponent().path
        let name = NSRegularExpression.escapedPattern(for: url.lastPathComponent)
        let protectedNames = Set(protected.map { URL(fileURLWithPath: $0).lastPathComponent })

        let names: [String]
        do {
            names = try fileManager.contentsOfDirectory(atPath: directory)
        } catch {
            logger.error(
                "Could not list \(directory, privacy: .public) to prune database copies: \(String(describing: error), privacy: .public)")
            return 0
        }

        var deleted = 0
        for kind in kinds {
            // \A and \z anchor the whole name: `$` would also match before a
            // trailing newline, and `\d` matches any Unicode digit.
            let pattern = #"\A"# + name + #"\."#
                + NSRegularExpression.escapedPattern(for: kind.rawValue)
                + #"\.([0-9]{8}T[0-9]{6}Z)\z"#
            let regex: NSRegularExpression
            do {
                regex = try NSRegularExpression(pattern: pattern)
            } catch {
                logger.error(
                    "Could not build the pattern for \(kind.rawValue, privacy: .public) copies of \(databasePath, privacy: .public), so none are pruned: \(String(describing: error), privacy: .public)")
                continue
            }
            var protectedCount = 0
            var candidates: [(file: String, stamp: String)] = []
            for file in names {
                let range = NSRange(file.startIndex..., in: file)
                guard let match = regex.firstMatch(in: file, range: range),
                      let stampRange = Range(match.range(at: 1), in: file)
                else { continue }
                if protectedNames.contains(file) {
                    protectedCount += 1
                } else {
                    candidates.append((file, String(file[stampRange])))
                }
            }
            // The fixed-width stamp sorts chronologically as text; newest first.
            candidates.sort { $0.stamp > $1.stamp }
            for copy in candidates.dropFirst(max(0, keepPerKind - protectedCount)) {
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
