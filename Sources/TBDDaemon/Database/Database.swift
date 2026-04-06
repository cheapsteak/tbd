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
    public let claudeTokens: ClaudeTokenStore

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
        self.claudeTokens = ClaudeTokenStore(writer: pool)
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
        self.claudeTokens = ClaudeTokenStore(writer: queue)
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

        try migrator.migrate(writer)
    }
}
