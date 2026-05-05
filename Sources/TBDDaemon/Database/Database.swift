import Foundation
import GRDB
import TBDShared

/// Central database class that manages the SQLite connection and exposes store accessors.
public final class TBDDatabase: Sendable {
    private let writer: any DatabaseWriter

    /// Test-only accessor exposing the underlying writer for migration / schema tests.
    internal var writerForTests: any DatabaseWriter { writer }

    public let repos: RepoStore
    public let worktrees: WorktreeStore
    public let terminals: TerminalStore
    public let notifications: NotificationStore
    public let notes: NoteStore
    public let conductors: ConductorStore
    public let modelProfiles: ModelProfileStore
    public let modelProfileUsage: ModelProfileUsageStore
    public let config: ConfigStore
    public let meta: TBDMetaStore

    /// Create a production database at the given file path with WAL mode and a DatabasePool.
    public init(path: String) throws {
        var config = Configuration()
        #if DEBUG
        config.prepareDatabase { db in
            db.trace { print($0) }
        }
        #endif
        let pool = try DatabasePool(path: path, configuration: config)
        self.writer = pool
        self.repos = RepoStore(writer: pool)
        self.worktrees = WorktreeStore(writer: pool)
        self.terminals = TerminalStore(writer: pool)
        self.notifications = NotificationStore(writer: pool)
        self.notes = NoteStore(writer: pool)
        self.conductors = ConductorStore(writer: pool)
        self.modelProfiles = ModelProfileStore(writer: pool)
        self.modelProfileUsage = ModelProfileUsageStore(writer: pool)
        self.config = ConfigStore(writer: pool)
        self.meta = TBDMetaStore(writer: pool)
        try Self.migrate(writer: pool)
    }

    /// Create an in-memory database for testing using DatabaseQueue.
    public init(inMemory: Bool) throws {
        precondition(inMemory, "Use init(path:) for file-backed databases")
        let queue = try DatabaseQueue()
        self.writer = queue
        self.repos = RepoStore(writer: queue)
        self.worktrees = WorktreeStore(writer: queue)
        self.terminals = TerminalStore(writer: queue)
        self.notifications = NotificationStore(writer: queue)
        self.notes = NoteStore(writer: queue)
        self.conductors = ConductorStore(writer: queue)
        self.modelProfiles = ModelProfileStore(writer: queue)
        self.modelProfileUsage = ModelProfileUsageStore(writer: queue)
        self.config = ConfigStore(writer: queue)
        self.meta = TBDMetaStore(writer: queue)
        try Self.migrate(writer: queue)
    }

    private static func migrate(writer: any DatabaseWriter) throws {
        var migrator = DatabaseMigrator()

        migrator.registerMigration("v1") { db in
            try db.create(table: "repo") { t in
                t.primaryKey("id", .text).notNull()
                t.column("path", .text).notNull().unique()
                t.column("remoteURL", .text)
                t.column("displayName", .text).notNull()
                t.column("defaultBranch", .text).notNull()
                t.column("createdAt", .datetime).notNull()
            }

            try db.create(table: "worktree") { t in
                t.primaryKey("id", .text).notNull()
                t.column("repoID", .text).notNull()
                    .references("repo", onDelete: .cascade)
                t.column("name", .text).notNull()
                t.column("displayName", .text).notNull()
                t.column("branch", .text).notNull()
                t.column("path", .text).notNull().unique()
                t.column("status", .text).notNull().defaults(to: "active")
                t.column("createdAt", .datetime).notNull()
                t.column("archivedAt", .datetime)
                t.column("tmuxServer", .text).notNull()
            }

            try db.create(table: "terminal") { t in
                t.primaryKey("id", .text).notNull()
                t.column("worktreeID", .text).notNull()
                    .references("worktree", onDelete: .cascade)
                t.column("tmuxWindowID", .text).notNull()
                t.column("tmuxPaneID", .text).notNull()
                t.column("label", .text)
                t.column("createdAt", .datetime).notNull()
            }

            try db.create(table: "notification") { t in
                t.primaryKey("id", .text).notNull()
                t.column("worktreeID", .text).notNull()
                    .references("worktree", onDelete: .cascade)
                t.column("type", .text).notNull()
                t.column("message", .text)
                t.column("read", .boolean).notNull().defaults(to: false)
                t.column("createdAt", .datetime).notNull()
            }
        }

        migrator.registerMigration("v2") { db in
            try db.alter(table: "worktree") { t in
                t.add(column: "gitStatus", .text).notNull().defaults(to: "current")
            }
        }

        migrator.registerMigration("v3") { db in
            try db.alter(table: "worktree") { t in
                t.add(column: "hasConflicts", .boolean).notNull().defaults(to: false)
            }
            // Migrate existing conflict data
            try db.execute(sql: "UPDATE worktree SET hasConflicts = (gitStatus = 'conflicts')")
        }

        migrator.registerMigration("v4") { db in
            try db.alter(table: "worktree") { t in
                t.add(column: "pinnedAt", .datetime)
            }
        }

        migrator.registerMigration("v5") { db in
            try db.alter(table: "terminal") { t in
                t.add(column: "pinnedAt", .datetime)
            }
        }

        migrator.registerMigration("v6") { db in
            try db.alter(table: "terminal") { t in
                t.add(column: "claudeSessionID", .text)
                t.add(column: "suspendedAt", .datetime)
            }
        }

        migrator.registerMigration("v7") { db in
            try db.alter(table: "terminal") { t in
                t.add(column: "suspendedSnapshot", .text)
            }
        }

        migrator.registerMigration("v8") { db in
            try db.alter(table: "worktree") { t in
                t.add(column: "archivedClaudeSessions", .text)
            }
        }

        migrator.registerMigration("v9") { db in
            try db.create(table: "note") { t in
                t.primaryKey("id", .text).notNull()
                t.column("worktreeID", .text).notNull()
                    .references("worktree", onDelete: .cascade)
                t.column("title", .text).notNull()
                t.column("content", .text).notNull().defaults(to: "")
                t.column("createdAt", .datetime).notNull()
                t.column("updatedAt", .datetime).notNull()
            }
        }

        migrator.registerMigration("v10") { db in
            // Conductor table
            try db.create(table: "conductor") { t in
                t.primaryKey("id", .text).notNull()
                t.column("name", .text).notNull().unique()
                t.column("repos", .text).notNull().defaults(to: "[\"*\"]")
                t.column("worktrees", .text)
                t.column("terminalLabels", .text)
                t.column("heartbeatIntervalMinutes", .integer).notNull().defaults(to: 10)
                t.column("terminalID", .text)
                    .references("terminal", onDelete: .setNull)
                t.column("worktreeID", .text)
                    .references("worktree", onDelete: .setNull)
                t.column("createdAt", .datetime).notNull()
            }

            // Synthetic "conductors" pseudo-repo
            try db.execute(
                sql: """
                INSERT OR IGNORE INTO repo (id, path, displayName, defaultBranch, createdAt)
                VALUES (?, ?, 'Conductors', 'main', ?)
                """,
                arguments: [
                    TBDConstants.conductorsRepoID.uuidString,
                    TBDConstants.conductorsDir.path,
                    Date()
                ]
            )
        }

        migrator.registerMigration("v11") { db in
            try db.alter(table: "worktree") { t in
                t.add(column: "sortOrder", .integer).notNull().defaults(to: 0)
            }
            // Initialize sortOrder from rowid to preserve insertion order
            try db.execute(sql: "UPDATE worktree SET sortOrder = rowid")
        }

        migrator.registerMigration("v12") { db in
            try db.alter(table: "repo") { t in
                t.add(column: "renamePrompt", .text)
                t.add(column: "customInstructions", .text)
            }
        }

        migrator.registerMigration("v13") { db in
            try db.create(table: "claude_tokens") { t in
                t.primaryKey("id", .text).notNull()
                t.column("name", .text).notNull().unique()
                t.column("keychain_ref", .text).notNull()
                t.column("kind", .text).notNull()
                t.column("created_at", .datetime).notNull()
                t.column("last_used_at", .datetime)
            }

            try db.create(table: "claude_token_usage") { t in
                t.primaryKey("token_id", .text).notNull()
                    .references("claude_tokens", onDelete: .cascade)
                t.column("five_hour_pct", .double)
                t.column("seven_day_pct", .double)
                t.column("five_hour_resets_at", .datetime)
                t.column("seven_day_resets_at", .datetime)
                t.column("fetched_at", .datetime)
                t.column("last_status", .text)
            }

            try db.create(table: "config") { t in
                t.primaryKey("id", .text).notNull()
                t.column("default_claude_token_id", .text)
                    .references("claude_tokens", onDelete: .setNull)
            }
            try db.execute(
                sql: "INSERT OR IGNORE INTO config (id, default_claude_token_id) VALUES ('singleton', NULL)"
            )

            try db.alter(table: "repo") { t in
                t.add(column: "claude_token_override_id", .text)
            }

            try db.alter(table: "terminal") { t in
                t.add(column: "claude_token_id", .text)
            }
        }

        // Suffixed migration name avoids collisions with parallel in-flight
        // branches that may also be adding a "v14" — GRDB tracks migrations by
        // name, so a descriptive suffix is unambiguous.
        migrator.registerMigration("v14_worktree_location") { db in
            try db.alter(table: "repo") { t in
                t.add(column: "worktree_slot", .text)
                t.add(column: "worktree_root", .text)
                t.add(column: "status", .text).notNull().defaults(to: "ok")
            }
            // SQLite ALTER TABLE ADD COLUMN can't add inline UNIQUE; use a partial
            // index so pre-backfill NULLs coexist.
            try db.execute(sql: """
                CREATE UNIQUE INDEX idx_repo_worktree_slot
                ON repo(worktree_slot)
                WHERE worktree_slot IS NOT NULL
            """)

            try db.create(table: "tbd_meta") { t in
                t.primaryKey("key", .text).notNull()
                t.column("value", .text).notNull()
            }

            // Backfill worktree_slot for existing rows. Stable order
            // (createdAt ASC, then id ASC) means older repos keep the bare
            // slot; newer collisions get -2/-3/...
            let rows = try Row.fetchAll(
                db,
                sql: "SELECT id, displayName FROM repo ORDER BY createdAt ASC, id ASC"
            )
            var assigned = Set<String>()
            for row in rows {
                let id: String = row["id"]
                let displayName: String = row["displayName"]
                var base = WorktreeLayout.sanitize(displayName)
                if base.isEmpty {
                    let prefix = String(id.replacingOccurrences(of: "-", with: "").prefix(6))
                    base = "repo-\(prefix)"
                }
                var slot = base
                var n = 2
                while assigned.contains(slot) {
                    slot = "\(base)-\(n)"
                    n += 1
                }
                assigned.insert(slot)
                try db.execute(
                    sql: "UPDATE repo SET worktree_slot = ? WHERE id = ?",
                    arguments: [slot, id]
                )
            }
        }

        migrator.registerMigration("v15_model_profiles") { db in
            // SQLite's ALTER TABLE ... RENAME TO updates FK references in other
            // tables only when legacy_alter_table is OFF. GRDB pools default to
            // legacy_alter_table=OFF in modern SQLite, but be explicit so the
            // migration is robust to env changes.
            try db.execute(sql: "PRAGMA legacy_alter_table = OFF")

            // Rename tables. SQLite supports ALTER TABLE RENAME since 3.25.
            try db.execute(sql: "ALTER TABLE claude_tokens RENAME TO model_profiles")
            try db.execute(sql: "ALTER TABLE claude_token_usage RENAME TO model_profile_usage")

            // Add new optional columns to profiles.
            try db.alter(table: "model_profiles") { t in
                t.add(column: "base_url", .text)
                t.add(column: "model", .text)
            }

            // Rename token-id columns to profile-id columns.
            // SQLite >= 3.25 supports ALTER TABLE ... RENAME COLUMN.
            try db.execute(sql: "ALTER TABLE config RENAME COLUMN default_claude_token_id TO default_profile_id")
            try db.execute(sql: "ALTER TABLE repo RENAME COLUMN claude_token_override_id TO profile_override_id")
            try db.execute(sql: "ALTER TABLE terminal RENAME COLUMN claude_token_id TO profile_id")

            // Rename the foreign-key column inside model_profile_usage as well.
            try db.execute(sql: "ALTER TABLE model_profile_usage RENAME COLUMN token_id TO profile_id")
        }

        try migrator.migrate(writer)
    }
}
