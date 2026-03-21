import Foundation
import GRDB
import TBDShared

/// Central database class that manages the SQLite connection and exposes store accessors.
public final class TBDDatabase: Sendable {
    private let writer: any DatabaseWriter

    public let repos: RepoStore
    public let worktrees: WorktreeStore
    public let terminals: TerminalStore
    public let notifications: NotificationStore

    /// Create a production database at the given file path with WAL mode and a DatabasePool.
    public init(path: String) throws {
        var config = Configuration()
        config.prepareDatabase { db in
            db.trace { print($0) }
        }
        let pool = try DatabasePool(path: path)
        self.writer = pool
        self.repos = RepoStore(writer: pool)
        self.worktrees = WorktreeStore(writer: pool)
        self.terminals = TerminalStore(writer: pool)
        self.notifications = NotificationStore(writer: pool)
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

        try migrator.migrate(writer)
    }
}
