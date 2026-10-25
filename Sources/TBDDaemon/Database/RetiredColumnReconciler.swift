import Foundation
import GRDB
import os
import TBDShared

/// The app bundle `tbd update` kept for rollback, as far as dropping a column
/// is concerned: where it is, and which schema epoch it was built at.
struct KeptBundle: Equatable, Sendable {
    /// The bundle directory, named in the log when it holds a drop.
    let path: String
    /// The `schemaEpoch` its build identity records. Nil when the identity
    /// records none — a build from before the epoch existed — or when the
    /// identity file is missing or unreadable. Nil reads as epoch 0 and holds
    /// every drop.
    let schemaEpoch: Int?

    /// The epoch the bundle counts as: what it records, else 0.
    var effectiveEpoch: Int { schemaEpoch ?? 0 }

    /// Read the kept bundle at `bundlePath`.
    ///
    /// - Returns: nil only when nothing exists at `bundlePath`, which leaves
    ///   nothing to protect. Anything else there counts as a kept bundle, and
    ///   one whose presence cannot be checked counts as one with no epoch, so
    ///   every uncertain answer holds.
    static func read(atPath bundlePath: String) -> KeptBundle? {
        var info = stat()
        if lstat(bundlePath, &info) != 0 {
            let code = errno
            if code == ENOENT || code == ENOTDIR { return nil }
            return KeptBundle(path: bundlePath, schemaEpoch: nil)
        }
        let identityFile = TBDConstants.buildIdentityFile(
            inAppBundle: URL(fileURLWithPath: bundlePath))
        guard let data = FileManager.default.contents(atPath: identityFile.path),
              let identity = try? JSONDecoder().decode(BuildIdentity.self, from: data)
        else {
            return KeptBundle(path: bundlePath, schemaEpoch: nil)
        }
        return KeptBundle(path: bundlePath, schemaEpoch: identity.schemaEpoch)
    }
}

/// Drops each column in `RetiredColumns.all` once the app bundle kept for
/// rollback no longer uses it.
///
/// Dropping a column is the one schema change an older build cannot tolerate:
/// a GRDB record writes every property it declares, so a build that still
/// declares the column fails every insert and update into its table once the
/// column is gone. `tbd update` keeps the bundle it replaces at
/// `~/tbd/updates/previous/TBD.app` and restores it when the new daemon cannot
/// come up, so a column drops only when that bundle's recorded schema epoch is
/// at least the column's retirement epoch, or when there is no kept bundle.
///
/// Runs once per daemon start, after migrations and before the RPC server or
/// any background sweep. For each entry it:
///
/// 1. skips it when the table has no such column — already dropped, the
///    common case, and not logged;
/// 2. holds it, and logs why, when the kept bundle's epoch is below the
///    entry's;
/// 3. otherwise drops it with `ALTER TABLE … DROP COLUMN`.
///
/// Before the first drop of a run it copies the database to
/// `<database>.pre-column-drop.<UTC-timestamp>` with `VACUUM INTO`, the way
/// back for data someone still needed. When that copy fails it drops nothing
/// in the run. A drop that fails — SQLite refuses a column in a key, a
/// constraint, an index, a view or a trigger — is logged and skipped, and the
/// run carries on. A run in which nothing failed ends by pruning the
/// pre-column-drop copies to the newest `DatabaseSnapshotPruner.keepPerKind`,
/// never deleting the one it just wrote; a run with any failure prunes
/// nothing. Nothing here throws: startup continues whatever happens.
///
/// Drops happen only here; the `.sql` migration allowlist refuses
/// `DROP COLUMN`. Design: `docs/specs/2026-10-24-column-retirement-design.md`.
struct RetiredColumnReconciler: Sendable {
    enum Decision: Equatable, Sendable {
        case drop
        case hold
    }

    /// What one run did with one entry.
    enum Outcome: Equatable, Sendable {
        /// The table has no such column.
        case absent
        /// The kept bundle's epoch, carried here, is below the entry's.
        case held(keptEpoch: Int)
        /// Dropped in this run.
        case dropped
        /// Due to drop, but the pre-drop snapshot failed, so the run dropped
        /// nothing.
        case snapshotFailed
        /// Checking for the column, or dropping it, failed with this error.
        case failed(String)

        /// Whether this entry failed in the run. A run with any failure
        /// prunes no copies.
        var isFailure: Bool {
            switch self {
            case .absent, .held, .dropped: return false
            case .snapshotFailed, .failed: return true
            }
        }
    }

    struct Report: Equatable, Sendable {
        var outcomes: [RetiredColumn: Outcome] = [:]
        /// The snapshot this run wrote before its first drop, if it wrote one.
        var snapshotPath: String?
    }

    private static let logger = Logger(subsystem: "com.tbd.daemon", category: "migrations")

    let columns: [RetiredColumn]
    /// The database file. The pre-drop snapshot is written beside it.
    let databasePath: String
    /// The kept rollback bundle's directory,
    /// `TBDConstants.keptAppBundle()` in production.
    let keptBundlePath: String

    init(
        databasePath: String,
        keptBundlePath: String,
        columns: [RetiredColumn] = RetiredColumns.all
    ) {
        self.databasePath = databasePath
        self.keptBundlePath = keptBundlePath
        self.columns = columns
    }

    /// Whether `entry` may drop, given the kept bundle. No kept bundle leaves
    /// nothing to protect. A bundle that records no epoch predates them and
    /// holds every drop. Otherwise the bundle must be at or past the entry's
    /// epoch, which means it was built from a tree that had already retired the
    /// column.
    static func decision(for entry: RetiredColumn, keptBundle: KeptBundle?) -> Decision {
        guard let keptBundle else { return .drop }
        guard let epoch = keptBundle.schemaEpoch else { return .hold }
        return epoch >= entry.epoch ? .drop : .hold
    }

    /// The snapshot `run` writes before its first drop at `date`.
    func snapshotPath(at date: Date) -> String {
        "\(databasePath).pre-column-drop.\(TBDDatabase.snapshotTimestamp(for: date))"
    }

    /// Reconcile every entry against `writer`. `date` names the snapshot.
    func run(writer: any DatabaseWriter, at date: Date = Date()) async -> Report {
        var report = Report()
        var keptBundle: KeptBundle?
        var keptBundleRead = false
        var due: [RetiredColumn] = []

        for entry in columns {
            let present: Bool
            do {
                present = try await writer.read { db in
                    try SQLMigrationLoader.columnExists(entry.column, in: entry.table, db: db)
                }
            } catch {
                Self.logger.error(
                    "Retired column \(entry.description, privacy: .public): could not check whether it exists, leaving it: \(String(describing: error), privacy: .public)")
                report.outcomes[entry] = .failed(String(describing: error))
                continue
            }
            guard present else {
                report.outcomes[entry] = .absent
                continue
            }

            // Read once, and only when some column is still there to drop.
            if !keptBundleRead {
                keptBundle = KeptBundle.read(atPath: keptBundlePath)
                keptBundleRead = true
            }
            switch Self.decision(for: entry, keptBundle: keptBundle) {
            case .drop:
                due.append(entry)
            case .hold:
                let keptEpoch = keptBundle?.effectiveEpoch ?? 0
                let recorded: String
                if let epoch = keptBundle?.schemaEpoch {
                    recorded = "schema epoch \(epoch)"
                } else {
                    recorded = "no schema epoch, read as 0"
                }
                let bundlePath = keptBundlePath
                Self.logger.notice(
                    "Retired column \(entry.description, privacy: .public) (retired at schema epoch \(entry.epoch, privacy: .public)) is held: the kept bundle at \(bundlePath, privacy: .public) records \(recorded, privacy: .public)")
                report.outcomes[entry] = .held(keptEpoch: keptEpoch)
            }
        }

        if !due.isEmpty {
            // VACUUM INTO cannot run inside a transaction, hence
            // writeWithoutTransaction, as for the pre-migration snapshot.
            let snapshot = snapshotPath(at: date)
            do {
                try await writer.writeWithoutTransaction { db in
                    try db.execute(sql: "VACUUM INTO ?", arguments: [snapshot])
                }
                Self.logger.notice(
                    "Pre-column-drop snapshot written to \(snapshot, privacy: .public)")
                report.snapshotPath = snapshot
            } catch {
                Self.logger.error(
                    "Pre-column-drop snapshot failed at \(snapshot, privacy: .public), so no retired column is dropped this run: \(String(describing: error), privacy: .public)")
                for entry in due { report.outcomes[entry] = .snapshotFailed }
                return report
            }

            for entry in due {
                let sql = "ALTER TABLE \(entry.table.quotedDatabaseIdentifier) DROP COLUMN \(entry.column.quotedDatabaseIdentifier)"
                do {
                    try await writer.write { db in try db.execute(sql: sql) }
                    Self.logger.notice(
                        "Dropped retired column \(entry.description, privacy: .public) (retired at schema epoch \(entry.epoch, privacy: .public))")
                    report.outcomes[entry] = .dropped
                } catch {
                    Self.logger.error(
                        "Could not drop retired column \(entry.description, privacy: .public), leaving it: \(String(describing: error), privacy: .public)")
                    report.outcomes[entry] = .failed(String(describing: error))
                }
            }
        }

        // Only after a run in which nothing failed. A drop that fails at
        // every start writes a fresh copy each time, and pruning then would
        // push out the copy that still holds a column an earlier run dropped.
        // Every such run prunes, whether or not it wrote a copy, so a backlog
        // clears at once. The copy this run wrote is never deleted.
        if !report.outcomes.values.contains(where: \.isFailure) {
            DatabaseSnapshotPruner.prune(
                databasePath: databasePath,
                kinds: [.preColumnDrop],
                protecting: Set([report.snapshotPath].compactMap { $0 }))
        }
        return report
    }
}
