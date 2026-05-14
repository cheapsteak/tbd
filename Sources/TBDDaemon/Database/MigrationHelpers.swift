import Foundation
import GRDB
import os

/// Idempotent schema-change helpers for `DatabaseMigrator` bodies.
///
/// Parallel branches sometimes register an additive migration (e.g. `ADD COLUMN`)
/// under different IDs. GRDB tracks applied migrations by string ID, so when the
/// schema already has the column but the *new* ID has not been recorded, GRDB
/// re-runs the body and SQLite throws `duplicate column name`. These helpers
/// make the body a no-op in that case, turning the second crash-causing
/// scenario into a clean skip.
extension GRDB.Database {

    /// Add `column` to `table` if it isn't already present.
    ///
    /// Column-name comparison is case-insensitive — SQLite identifiers are
    /// case-insensitive, so a column declared as `FOO` must be detected by a
    /// lookup of `"foo"`.
    func addColumnIfMissing(
        table: String,
        column: String,
        type: GRDB.Database.ColumnType,
        defaults: (any DatabaseValueConvertible)? = nil
    ) throws {
        let existing = try Row.fetchAll(self, sql: "PRAGMA table_info(\(table))")
            .compactMap { ($0["name"] as String?)?.lowercased() }
        if existing.contains(column.lowercased()) {
            Self.migrationsLogger.debug(
                "addColumnIfMissing: skip \(table, privacy: .public).\(column, privacy: .public) (already present)"
            )
            return
        }
        try alter(table: table) { t in
            let def = t.add(column: column, type)
            if let defaults {
                _ = def.defaults(to: defaults)
            }
        }
        Self.migrationsLogger.debug(
            "addColumnIfMissing: added \(table, privacy: .public).\(column, privacy: .public)"
        )
    }

    /// Create `table` if it doesn't already exist. Wraps GRDB's
    /// `create(table:options:body:)` with `.ifNotExists`.
    func createTableIfNotExists(
        _ table: String,
        body: (TableDefinition) throws -> Void
    ) throws {
        // GRDB short-circuits if the table is already there, but we still log
        // when we skipped vs created so the migration trail is clear.
        let preexisting = try tableExists(table)
        try create(table: table, options: [.ifNotExists], body: body)
        if preexisting {
            Self.migrationsLogger.debug(
                "createTableIfNotExists: skip \(table, privacy: .public) (already present)"
            )
        } else {
            Self.migrationsLogger.debug(
                "createTableIfNotExists: created \(table, privacy: .public)"
            )
        }
    }

    /// Create an index if it doesn't already exist. Supports partial indexes
    /// via the optional `where` clause.
    func addIndexIfMissing(
        _ indexName: String,
        on table: String,
        columns: [String],
        unique: Bool = false,
        where whereClause: String? = nil
    ) throws {
        let uniqueKW = unique ? "UNIQUE " : ""
        let cols = columns.joined(separator: ", ")
        var sql = "CREATE \(uniqueKW)INDEX IF NOT EXISTS \(indexName) ON \(table)(\(cols))"
        if let whereClause, !whereClause.isEmpty {
            sql += " WHERE \(whereClause)"
        }
        let existed = try Bool.fetchOne(
            self,
            sql: "SELECT 1 FROM sqlite_master WHERE type = 'index' AND name = ?",
            arguments: [indexName]
        ) ?? false
        try execute(sql: sql)
        if existed {
            Self.migrationsLogger.debug(
                "addIndexIfMissing: skip \(indexName, privacy: .public) on \(table, privacy: .public) (already present)"
            )
        } else {
            Self.migrationsLogger.debug(
                "addIndexIfMissing: created \(indexName, privacy: .public) on \(table, privacy: .public)"
            )
        }
    }

    fileprivate static let migrationsLogger = Logger(
        subsystem: "com.tbd.daemon",
        category: "migrations"
    )
}
