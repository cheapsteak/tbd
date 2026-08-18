import Foundation
import GRDB
import os
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
    public let modelProfiles: ModelProfileStore
    public let modelProfileUsage: ModelProfileUsageStore
    public let oauthUsageSnapshots: OAuthUsageSnapshotStore
    public let config: ConfigStore
    public let meta: TBDMetaStore
    public let tabs: TabStore
    public let forgottenWorktrees: ForgottenWorktreeStore
    public let scheduledResumes: ScheduledResumeStore
    public let reapRecords: ReapRecordStore
    public let terminalHistory: TerminalHistoryStore
    public let panelSurface: PanelSurfaceStore
    public let remoteSessions: RemoteSessionStore
    public let watchDeskLeases: WatchDeskLeaseStore
    public let prBindings: PRBindingStore

    private static let logger = Logger(subsystem: "com.tbd.daemon", category: "migrations")

    /// Create a production database at the given file path with WAL mode and a DatabasePool.
    /// `notesDir` overrides the note-content file directory (tests only; nil
    /// resolves `TBDConstants.noteContentDir`, which honors TBD_HOME).
    /// `terminalHistoryDir` is the same seam for closed-terminal captures
    /// (nil resolves `TBDConstants.terminalHistoryDir`).
    public init(path: String, notesDir: String? = nil, terminalHistoryDir: String? = nil) throws {
        // Capture existence BEFORE DatabasePool opens the file — opening
        // creates an empty DB on the first launch, so we'd otherwise lose the
        // ability to distinguish "first launch" from "upgrade".
        let fileExisted = FileManager.default.fileExists(atPath: path)

        var config = Configuration()
        #if DEBUG
        config.prepareDatabase { db in
            db.trace { Self.logger.debug("\($0, privacy: .public)") }
        }
        #endif
        let pool = try DatabasePool(path: path, configuration: config)
        self.writer = pool
        self.repos = RepoStore(writer: pool)
        self.worktrees = WorktreeStore(writer: pool)
        self.terminals = TerminalStore(writer: pool)
        self.notifications = NotificationStore(writer: pool)
        self.notes = NoteStore(writer: pool, notesDir: notesDir)
        self.modelProfiles = ModelProfileStore(writer: pool)
        self.modelProfileUsage = ModelProfileUsageStore(writer: pool)
        self.oauthUsageSnapshots = OAuthUsageSnapshotStore(writer: pool)
        self.config = ConfigStore(writer: pool)
        self.meta = TBDMetaStore(writer: pool)
        self.tabs = TabStore(writer: pool)
        self.forgottenWorktrees = ForgottenWorktreeStore(writer: pool)
        self.scheduledResumes = ScheduledResumeStore(writer: pool)
        self.reapRecords = ReapRecordStore(writer: pool)
        self.terminalHistory = TerminalHistoryStore(writer: pool, historyDir: terminalHistoryDir)
        self.panelSurface = PanelSurfaceStore(writer: pool)
        self.remoteSessions = RemoteSessionStore(writer: pool)
        self.watchDeskLeases = WatchDeskLeaseStore(writer: pool)
        self.prBindings = PRBindingStore(writer: pool)

        let migrator = Self.buildMigrator()
        if fileExisted {
            let hasPending = try pool.read { db in
                try !migrator.hasCompletedMigrations(db)
            }
            if hasPending {
                Self.takePreMigrationSnapshot(pool: pool, path: path)
            }
        }
        try migrator.migrate(pool)
    }

    /// Create an in-memory database for testing using DatabaseQueue.
    /// `notesDir` overrides the note-content file directory so tests never
    /// touch the real `~/tbd/notes` (injection seam, like
    /// `ThemeStore(themesDirectory:)`). `terminalHistoryDir` is the same seam
    /// for closed-terminal captures (`~/tbd/terminal-history`).
    public init(inMemory: Bool, notesDir: String? = nil, terminalHistoryDir: String? = nil) throws {
        precondition(inMemory, "Use init(path:) for file-backed databases")
        let queue = try DatabaseQueue()
        self.writer = queue
        self.repos = RepoStore(writer: queue)
        self.worktrees = WorktreeStore(writer: queue)
        self.terminals = TerminalStore(writer: queue)
        self.notifications = NotificationStore(writer: queue)
        self.notes = NoteStore(writer: queue, notesDir: notesDir)
        self.modelProfiles = ModelProfileStore(writer: queue)
        self.modelProfileUsage = ModelProfileUsageStore(writer: queue)
        self.oauthUsageSnapshots = OAuthUsageSnapshotStore(writer: queue)
        self.config = ConfigStore(writer: queue)
        self.meta = TBDMetaStore(writer: queue)
        self.tabs = TabStore(writer: queue)
        self.forgottenWorktrees = ForgottenWorktreeStore(writer: queue)
        self.scheduledResumes = ScheduledResumeStore(writer: queue)
        self.reapRecords = ReapRecordStore(writer: queue)
        self.terminalHistory = TerminalHistoryStore(writer: queue, historyDir: terminalHistoryDir)
        self.panelSurface = PanelSurfaceStore(writer: queue)
        self.remoteSessions = RemoteSessionStore(writer: queue)
        self.watchDeskLeases = WatchDeskLeaseStore(writer: queue)
        self.prBindings = PRBindingStore(writer: queue)
        try Self.buildMigrator().migrate(queue)
    }

    /// Best-effort pre-migration snapshot. Failures are logged, not thrown —
    /// the migration must still be allowed to proceed even if e.g. the disk
    /// is full or the parent directory isn't writable.
    internal static func takePreMigrationSnapshot(pool: DatabasePool, path: String) {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.locale = Locale(identifier: "en_US_POSIX")
        let stamp = formatter.string(from: Date())
        let snapshotPath = "\(path).pre-migration.\(stamp)"
        do {
            // VACUUM INTO requires autocommit mode — it cannot run inside a
            // transaction. `pool.write` wraps the closure in a deferred
            // transaction, which silently turns the snapshot into a no-op
            // (catch-and-log path below was hiding the failure). Use
            // writeWithoutTransaction so SQLite stays in autocommit.
            try pool.writeWithoutTransaction { db in
                try db.execute(sql: "VACUUM INTO ?", arguments: [snapshotPath])
            }
            logger.info("Pre-migration snapshot written to \(snapshotPath, privacy: .public)")
        } catch {
            logger.error(
                "Pre-migration snapshot failed at \(snapshotPath, privacy: .public): \(String(describing: error), privacy: .public)"
            )
        }
    }

    /// Test-only accessor: allows migration tests to run migrations up to a
    /// specific identifier and inspect/insert state between steps. Production
    /// code paths must continue to call this through `init(...)` only.
    internal static func buildMigratorForTests() -> DatabaseMigrator {
        buildMigrator()
    }

    private static func buildMigrator() -> DatabaseMigrator {
        var migrator = DatabaseMigrator()

        // v1–v42 predate/are frozen under the helper mandate; new migrations below the enable line must use the helpers (see Database/CLAUDE.md).
        // swiftlint:disable migration_use_helpers
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

            // Synthetic "conductors" pseudo-repo. Hard-coded UUID + path —
            // the symbolic constants this migration used to reference
            // (`TBDConstants.conductorsRepoID`/`conductorsDir`) were removed
            // when the Conductor feature was deleted; the literal values are
            // preserved here so this historical migration still produces an
            // identical schema for the v24 cleanup step to act on.
            //
            // The hand-built `$HOME/tbd/conductors` below is a deliberate
            // exception to "derive every TBD-owned path from TBDConstants"
            // (CLAUDE.md, "Tests must not touch ~/tbd"), and must stay
            // hand-built. It is a STRING WRITTEN INTO A ROW, not a filesystem
            // access: nothing is created or read at that path, and v24 deletes
            // the row again. Routing it through `TBDConstants` would make a
            // frozen migration produce different bytes under `TBD_HOME`, which
            // is exactly what "never modify an existing migration" forbids.
            // Leave it alone.
            try db.execute(
                sql: """
                INSERT OR IGNORE INTO repo (id, path, displayName, defaultBranch, createdAt)
                VALUES (?, ?, 'Conductors', 'main', ?)
                """,
                arguments: [
                    "00000000-0000-0000-0000-000000000001",
                    // swiftlint:disable:next no_home_relative_store_path - frozen migration; see comment above
                    FileManager.default.homeDirectoryForCurrentUser
                        .appendingPathComponent("tbd")
                        .appendingPathComponent("conductors").path,
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

        // Track HEAD SHA captured at archive time so revive can fall back when
        // the archived branch was renamed/deleted on disk before archive captured it.
        migrator.registerMigration("v16_archived_head_sha") { db in
            try db.alter(table: "worktree") { t in
                t.add(column: "archivedHeadSHA", .text)
            }
        }

        // Persist the absolute JSONL path Claude reports via the SessionStart
        // hook. Lets the transcript handler stay accurate across `/clear` and
        // `/compact` rollovers where the session ID changes mid-stream and the
        // jsonl can land in a different `~/.claude/projects/` directory than
        // the worktree's cwd would suggest.
        migrator.registerMigration("v17_terminal_transcript_path") { db in
            try db.alter(table: "terminal") { t in
                t.add(column: "transcriptPath", .text)
            }
        }

        migrator.registerMigration("v18_repo_hidden") { db in
            try db.alter(table: "repo") { t in
                t.add(column: "hidden", .boolean).notNull().defaults(to: false)
            }
        }

        migrator.registerMigration("v19_tabs_and_order") { db in
            try db.create(table: "tab") { t in
                t.column("id", .text).primaryKey()
                t.column("worktreeID", .text).notNull()
                t.column("label", .text)         // nullable = use auto-derived
                t.column("createdAt", .datetime).notNull()
            }
            try db.alter(table: "worktree") { t in
                t.add(column: "tabOrder", .text).notNull().defaults(to: "[]")
            }
        }

        migrator.registerMigration("v20_worktree_active_tab") { db in
            try db.alter(table: "worktree") { t in
                t.add(column: "activeTabID", .text)  // nullable
            }
        }

        migrator.registerMigration("v21_repo_expanded") { db in
            try db.alter(table: "repo") { t in
                t.add(column: "expanded", .boolean).notNull().defaults(to: true)
            }
        }

        migrator.registerMigration("v22_terminal_kind") { db in
            try db.alter(table: "terminal") { t in
                t.add(column: "kind", .text)
            }
            // Backfill from existing label heuristics
            try db.execute(sql: "UPDATE terminal SET kind = 'codex' WHERE label = 'Codex'")
            try db.execute(sql: "UPDATE terminal SET kind = 'claude' WHERE kind IS NULL AND claudeSessionID IS NOT NULL")
            try db.execute(sql: "UPDATE terminal SET kind = 'shell' WHERE kind IS NULL")
        }

        migrator.registerMigration("v23_worktree_parent") { db in
            try db.alter(table: "worktree") { t in
                t.add(column: "parentWorktreeID", .text)
                    .references("worktree", onDelete: .setNull)
            }
        }

        // Drop the conductor feature. Removes:
        //   * the `conductor` table (added in v10)
        //   * any worktree rows whose status was 'conductor' (the synthetic
        //     per-repo conductor worktrees)
        //   * the synthetic "Conductors" pseudo-repo inserted in v10 with the
        //     well-known UUID 00000000-0000-0000-0000-000000000001
        // The Conductor feature was removed in favour of regular terminals + the
        // `tbd` skill. See `refactor: remove Conductor feature`.
        //
        // NOTE: v24 was previously buggy — it deleted conductor worktrees
        // without first cleaning up `terminal` rows that referenced them,
        // which made the migration roll back with a foreign-key violation at
        // commit (SQLite error 19 from PRAGMA foreign_key_check) and crashed
        // the daemon on every restart for any user with an orphan conductor
        // terminal. The repair is in-place because for affected users the
        // migration never recorded success in `grdb_migrations`, and for
        // unaffected users (no conductor rows left) the added DELETE is a
        // no-op.
        migrator.registerMigration("v24_drop_conductor") { db in
            // Remove all child-table rows that FK-reference conductor worktrees
            // before deleting the worktrees themselves. terminal, notification,
            // and note all have onDelete: .cascade FKs to worktree.id; with
            // GRDB's deferred FK checking (PRAGMA foreign_key_check at commit),
            // any surviving child row rolls back the transaction with SQLite
            // error 19 and crashes the daemon on every subsequent restart.
            try db.execute(
                sql: "DELETE FROM terminal WHERE worktreeID IN (SELECT id FROM worktree WHERE status = 'conductor')"
            )
            try db.execute(
                sql: "DELETE FROM notification WHERE worktreeID IN (SELECT id FROM worktree WHERE status = 'conductor')"
            )
            try db.execute(
                sql: "DELETE FROM note WHERE worktreeID IN (SELECT id FROM worktree WHERE status = 'conductor')"
            )
            try db.execute(sql: "DROP TABLE IF EXISTS conductor")
            try db.execute(sql: "DELETE FROM worktree WHERE status = 'conductor'")
            try db.execute(
                sql: "DELETE FROM repo WHERE id = ?",
                arguments: ["00000000-0000-0000-0000-000000000001"]
            )
        }

        migrator.registerMigration("v25_model_profiles_bedrock") { db in
            try db.addColumnIfMissing(table: "model_profiles", column: "aws_region",  type: .text)
            try db.addColumnIfMissing(table: "model_profiles", column: "aws_profile", type: .text)
        }

        migrator.registerMigration("v26_claude_env_settings") { db in
            try db.addColumnIfMissing(table: "config", column: "claude_env_settings", type: .text)
        }

        migrator.registerMigration("v27_primary_agent_preference") { db in
            try db.addColumnIfMissing(table: "config", column: "primary_agent_preference", type: .text)
        }

        // Records the originating terminal for a notification so banner
        // clicks can switch to the specific tab, not just select the
        // worktree. Nullable for backwards compat with rows inserted by
        // pre-v28 daemons.
        migrator.registerMigration("v28_notification_terminal_id") { db in
            try db.addColumnIfMissing(table: "notification", column: "terminalID", type: .text)
        }

        migrator.registerMigration("v29_terminal_activity_state") { db in
            try db.addColumnIfMissing(
                table: "terminal",
                column: "activityState",
                type: .text,
                defaults: TerminalActivityState.unknown.rawValue
            )
        }

        // Per-profile Claude `fallbackModel` list, stored as a JSON-encoded
        // string array (e.g. `["claude-haiku-4-5-20251001"]`). Nullable so
        // existing rows decode as "no fallback configured".
        migrator.registerMigration("v30_model_profile_fallback_models") { db in
            try db.addColumnIfMissing(table: "model_profiles", column: "fallback_models", type: .text)
        }

        // Free-form env-var overrides applied to spawned Claude/Codex sessions.
        // One JSON-encoded `[String: String]` per scope. Nullable so existing
        // rows decode as "no overrides". See docs/env-overrides.md.
        migrator.registerMigration("v31_env_overrides") { db in
            try db.addColumnIfMissing(table: "config",         column: "env_overrides", type: .text)
            try db.addColumnIfMissing(table: "repo",           column: "env_overrides", type: .text)
            try db.addColumnIfMissing(table: "model_profiles", column: "env_overrides", type: .text)
        }

        migrator.registerMigration("v32_worktree_auto_archive") { db in
            try db.addColumnIfMissing(table: "worktree", column: "autoArchiveOnMerge", type: .boolean)
        }

        migrator.registerMigration("v33_config_auto_archive_default") { db in
            try db.addColumnIfMissing(
                table: "config", column: "auto_archive_on_merge_default",
                type: .boolean, defaults: false)
        }

        // Last-known GitHub PR status per worktree, stored as a JSON-encoded
        // `PRStatus`. Nullable so existing rows decode as "no status yet". Lets the
        // PR icon survive app/daemon restarts (mirrors archivedClaudeSessions).
        migrator.registerMigration("v34_worktree_pr_status") { db in
            try db.addColumnIfMissing(table: "worktree", column: "prStatus", type: .text)
        }

        // Make worktree.repoID nullable (scratch spaces are repo-less rows) and
        // add the promotedToRepoID pointer. SQLite cannot drop a NOT NULL
        // constraint via ALTER, so rebuild the table. Idempotency-guarded:
        // re-running after the column already went nullable is a no-op.
        migrator.registerMigration("v35_worktree_nullable_repo") { db in
            let info = try Row.fetchAll(db, sql: "PRAGMA table_info(worktree)")
            let repoIDNotNull = (info.first { ($0["name"] as String?) == "repoID" }?["notnull"] as Int?) ?? 1
            let hasPromoted = info.contains { ($0["name"] as String?) == "promotedToRepoID" }
            if repoIDNotNull == 0 && hasPromoted { return }  // already applied

            try db.execute(sql: """
                CREATE TABLE worktree_new (
                    id TEXT PRIMARY KEY NOT NULL,
                    repoID TEXT REFERENCES repo(id) ON DELETE CASCADE,
                    name TEXT NOT NULL,
                    displayName TEXT NOT NULL,
                    branch TEXT NOT NULL,
                    path TEXT NOT NULL UNIQUE,
                    status TEXT NOT NULL DEFAULT 'active',
                    createdAt DATETIME NOT NULL,
                    archivedAt DATETIME,
                    tmuxServer TEXT NOT NULL,
                    gitStatus TEXT NOT NULL DEFAULT 'current',
                    hasConflicts BOOLEAN NOT NULL DEFAULT 0,
                    pinnedAt DATETIME,
                    archivedClaudeSessions TEXT,
                    sortOrder INTEGER NOT NULL DEFAULT 0,
                    archivedHeadSHA TEXT,
                    tabOrder TEXT NOT NULL DEFAULT '[]',
                    activeTabID TEXT,
                    parentWorktreeID TEXT REFERENCES worktree(id) ON DELETE SET NULL,
                    autoArchiveOnMerge BOOLEAN,
                    prStatus TEXT,
                    promotedToRepoID TEXT
                )
                """)
            try db.execute(sql: """
                INSERT INTO worktree_new
                    (id, repoID, name, displayName, branch, path, status, createdAt,
                     archivedAt, tmuxServer, gitStatus, hasConflicts, pinnedAt,
                     archivedClaudeSessions, sortOrder, archivedHeadSHA, tabOrder,
                     activeTabID, parentWorktreeID, autoArchiveOnMerge, prStatus)
                SELECT
                     id, repoID, name, displayName, branch, path, status, createdAt,
                     archivedAt, tmuxServer, gitStatus, hasConflicts, pinnedAt,
                     archivedClaudeSessions, sortOrder, archivedHeadSHA, tabOrder,
                     activeTabID, parentWorktreeID, autoArchiveOnMerge, prStatus
                FROM worktree
                """)
            try db.drop(table: "worktree")
            try db.rename(table: "worktree_new", to: "worktree")
        }

        // Global, user-customizable system-prompt override for scratch spaces
        // (repo-less worktrees). Nullable text; nil means "use the built-in
        // default" (RepoConstants.defaultScratchInstructions).
        migrator.registerMigration("v36_config_scratch_instructions") { db in
            try db.addColumnIfMissing(table: "config", column: "scratch_instructions", type: .text)
        }

        // Global, user-customizable rename-nudge override for scratch spaces,
        // plus a global model-profile override applied to scratch terminal
        // spawns. Both nullable; nil means "use the built-in default" /
        // "fall back to the global default profile" respectively.
        migrator.registerMigration("v37_config_scratch_rename_and_profile") { db in
            try db.addColumnIfMissing(table: "config", column: "scratch_rename_prompt", type: .text)
            try db.addColumnIfMissing(table: "config", column: "scratch_profile_override_id", type: .text)
        }

        // Tombstones for `tbd worktree forget`: reconcile skips re-adopting a
        // git worktree whose path has a tombstone, so forget sticks even for
        // paths under a TBD-managed prefix. Keyed by exact absolute path;
        // cleared when the path is deliberately re-added via adopt/create.
        //
        // NOTE: identifier says "v35" but registers after v37 — this migration
        // shipped as v35_forgotten_worktree on pre-rebase deployments before
        // upstream took v35–v37, and GRDB identifies migrations by string, so
        // renaming it would orphan databases that already applied it. New
        // databases simply apply it here, in registration order. (Precedent:
        // v33_channel_message_sender_kind already registers after
        // v33_config_auto_archive_default.) Idempotent via IfNotExists/IfMissing.
        migrator.registerMigration("v35_forgotten_worktree") { db in
            try db.createTableIfNotExists("forgotten_worktree") { t in
                t.primaryKey("path", .text).notNull()
                t.column("repoID", .text).notNull()
                t.column("forgottenAt", .datetime).notNull()
                    .defaults(sql: "CURRENT_TIMESTAMP")
            }
            try db.addIndexIfMissing(
                "idx_forgotten_worktree_repoID",
                on: "forgotten_worktree",
                columns: ["repoID"]
            )
        }

        // Nightwatch mode: 'off', 'daywatch', or 'nightwatch'. Nullable so
        // existing rows decode to the default 'off'. See Phase 0 design.
        migrator.registerMigration("v38_nightwatch_mode") { db in
            try db.addColumnIfMissing(table: "config", column: "nightwatch_mode", type: .text, defaults: "off")
        }

        // Session hibernation: per-terminal hibernated timestamp + keep-warm
        // pin, and the global auto-hibernate master switch + idle-timeout.
        // `hibernatedAt` nullable (nil = not hibernated); `keepWarm` defaults
        // false; `auto_hibernate_enabled` defaults true (feature ON) and
        // `hibernate_idle_minutes` defaults 30. All additive/nullable-or-
        // defaulted so pre-v39 rows decode unchanged.
        migrator.registerMigration("v39_session_hibernation") { db in
            try db.addColumnIfMissing(table: "terminal", column: "hibernatedAt", type: .datetime)
            try db.addColumnIfMissing(
                table: "terminal", column: "keepWarm", type: .boolean, defaults: false)
            try db.addColumnIfMissing(
                table: "config", column: "auto_hibernate_enabled", type: .boolean, defaults: true)
            try db.addColumnIfMissing(
                table: "config", column: "hibernate_idle_minutes", type: .integer, defaults: 30)
        }

        migrator.registerMigration("v41_clearance_ledger") { db in
            try db.createTableIfNotExists("clearance") { t in
                t.primaryKey("id", .text).notNull()
                t.column("pr_number", .integer).notNull()
                t.column("repo", .text).notNull()
                t.column("cleared_when_sha", .text).notNull()
                t.column("pr_state_at_clear", .text)
                t.column("clearance_kind", .text).notNull()
                t.column("granted_by", .text)
                t.column("granted_at", .datetime).notNull()
                t.column("void_reason", .text)
            }
            // Index for quick lookups by PR and repo
            try db.addIndexIfMissing(
                "idx_clearance_pr_repo", on: "clearance", columns: ["pr_number", "repo"])
        }

        migrator.registerMigration("v42_audit_log") { db in
            try db.createTableIfNotExists("audit_log") { t in
                t.primaryKey("id", .text).notNull()
                t.column("action", .text).notNull()
                t.column("pr_number", .integer)
                t.column("repo", .text)
                t.column("head_sha", .text)
                t.column("merge_commit", .text)
                t.column("ts", .datetime).notNull()
                t.column("details", .text)
            }
            // Index for efficient time-range queries
            try db.addIndexIfMissing("idx_audit_log_ts", on: "audit_log", columns: ["ts"])
        }
        // swiftlint:enable migration_use_helpers

        // Session-limit auto-resume (spec 2026-07-03). `scheduled_resumes`
        // rows are the double-send latch (at most one `pending` row per
        // terminal, enforced by the partial unique index below).
        // `terminal.pendingResumeAt` mirrors the pending row for UI badges;
        // `config.auto_resume_on_limit_reset` is the global gate (default OFF).
        migrator.registerMigration("v43_scheduled_resumes") { db in
            try db.createTableIfNotExists("scheduled_resumes") { t in
                t.column("id", .text).primaryKey()
                t.column("terminalID", .text).notNull()
                t.column("worktreeID", .text).notNull()
                t.column("claudeSessionID", .text)
                t.column("resetsAt", .datetime).notNull()
                t.column("fireAt", .datetime).notNull()
                t.column("limitType", .text).notNull()
                t.column("rawMessage", .text).notNull()
                t.column("createdAt", .datetime).notNull()
                t.column("status", .text).notNull()
                t.column("attemptCount", .integer).notNull().defaults(to: 0)
            }
            try db.addIndexIfMissing(
                "idx_scheduled_resumes_one_pending", on: "scheduled_resumes",
                columns: ["terminalID"], unique: true, where: "status = 'pending'")
            try db.addColumnIfMissing(table: "terminal", column: "pendingResumeAt", type: .datetime)
            try db.addColumnIfMissing(
                table: "config", column: "auto_resume_on_limit_reset",
                type: .boolean, defaults: false)
        }

        // Suspend/Hibernate merge: converge every parked row on ONE authoritative
        // timestamp. Post-merge, `hibernatedAt` is the single source of truth for
        // "this session is parked" — all new code writes it (via the unified park
        // path) and never writes `suspendedAt`. `suspendedAt` becomes LEGACY /
        // read-only: honored when reading old rows, but never set again.
        //
        // Backfill: any row parked by the pre-merge Suspend feature has only
        // `suspendedAt` set. Copy that timestamp into `hibernatedAt` (where NULL)
        // so those rows read as parked through the authoritative column and wake
        // (which keys on `hibernatedAt`) can un-park them. We intentionally LEAVE
        // `suspendedAt` in place — never drop a column — so an older daemon build
        // sharing this DB still sees its parked state; `isParked` reads either
        // column, and wake's `clearHibernated` now nils both. No schema change
        // here, only a data normalization; wrapped so a re-run under a renamed
        // id is a harmless idempotent UPDATE (rows already backfilled won't match
        // `hibernatedAt IS NULL`).
        //
        // Renumbered v40 -> v44 during the reconcile with main's limit-driven
        // auto-resume (#341, whose migration is v43_scheduled_resumes above):
        // this id must register AFTER main's highest migration so it applies
        // last (append-only). GRDB tolerates an already-applied `v40_...` id on
        // a DB that ran the pre-reconcile branch — the default migrator does not
        // fail on unknown applied migrations, and this backfill is an idempotent
        // UPDATE (guarded by `hibernatedAt IS NULL`), so re-running once under
        // the new v44 id is a harmless no-op on rows already backfilled.
        migrator.registerMigration("v44_unify_suspend_hibernate") { db in
            try db.execute(sql: """
                UPDATE terminal
                SET hibernatedAt = suspendedAt
                WHERE suspendedAt IS NOT NULL AND hibernatedAt IS NULL
                """)
        }

        // Persisted opt-in for the tmux control-mode render path (#318 M5).
        // The attach gate evaluates `env || flag` per decision, so flipping
        // this from Settings affects the next attach without a daemon restart.
        // (Authored as v35 on the feature branch; renumbered on rebase as
        // upstream took v35–v44 first — this migration never shipped to a
        // live database under an earlier name, so renaming is safe.)
        migrator.registerMigration("v45_config_control_mode") { db in
            try db.addColumnIfMissing(
                table: "config", column: "control_mode_enabled",
                type: .boolean, defaults: false)
        }

        // `config.auto_resume_on_api_error` gates transient API-error auto-continue
        // (spec 2026-07-08, default OFF) — sibling of auto_resume_on_limit_reset.
        migrator.registerMigration("v46_auto_resume_api_error") { db in
            try db.addColumnIfMissing(
                table: "config", column: "auto_resume_on_api_error",
                type: .boolean, defaults: false)
        }

        // WHO parked a session (`auto` idle sweep / `manual` "Hibernate now" /
        // `recovery` crash-recovery reconcile — see `HibernateReason`), so an
        // explicit user park is not silently undone by wake-on-focus. Nullable
        // TEXT: legacy parked rows stay NULL and keep the old behavior (focus
        // still wakes them). (Authored as v46 on the feature branch; renumbered
        // on rebase as upstream took v46 first — never shipped to a live
        // database under the old name, so renaming is safe.)
        migrator.registerMigration("v47_hibernate_reason") { db in
            try db.addColumnIfMissing(
                table: "terminal", column: "hibernateReason", type: .text)
        }

        // Per-worktree auto-hibernate-on-PR-merge override (sibling of
        // v32_worktree_auto_archive). NULLABLE with NO default — tri-state:
        // NULL = follow the global default (`config.auto_hibernate_on_merge_default`),
        // `true`/`false` = explicit user override. Set only by user action.
        migrator.registerMigration("v48_worktree_auto_hibernate") { db in
            try db.addColumnIfMissing(table: "worktree", column: "autoHibernateOnMerge", type: .boolean)
        }

        // Global default for auto-hibernate-on-PR-merge (sibling of
        // v33_config_auto_archive_default). Defaults false so existing rows
        // decode to "feature OFF".
        migrator.registerMigration("v49_config_auto_hibernate_default") { db in
            try db.addColumnIfMissing(
                table: "config", column: "auto_hibernate_on_merge_default",
                type: .boolean, defaults: false)
        }

        // One-time forced opt-out of the auto-hibernate idle sweep.
        //
        // The idle sweep drives `HibernationSafetyChecks.hasPendingInput`, a
        // sanctioned TUI screen-scrape whose failure direction is asymmetric:
        // if Claude Code changes its `>` composer rendering, typed-but-unsent
        // input goes unrecognized and gets EATEN by the park. Defaulting the
        // sweep off shrinks the default-on scraping surface to zero.
        //
        // A forcing UPDATE (not just a Swift default flip) is required: v39
        // added `auto_hibernate_enabled` with `DEFAULT 1`, and SQLite's
        // `ADD COLUMN ... DEFAULT 1` backfills every pre-existing row to `1`
        // rather than NULL — so an explicit-true is byte-identical to a
        // never-touched-true, and `auto_hibernate_enabled ?? true` never fires.
        // The only way to move existing installs off the sweep is to rewrite
        // the column. This deliberately clears an explicit `true` too; that is
        // the approved one-time opt-out. Naturally idempotent, and a later user
        // opt-in (`setAutoHibernate(enabled: true, ...)`) is not fought.
        migrator.registerMigration("v50_auto_hibernate_idle_sweep_off_by_default") { db in
            try db.execute(sql: "UPDATE config SET auto_hibernate_enabled = 0")
        }

        // Soak flag for the input-pipeline pending-input veto (design
        // 2026-07-09-pending-input-detection-design). Default false: the veto is
        // opt-in until it soaks; when on it's the primary machine-interface guard
        // against parking a pane with typed-but-unsent input, demoting the TUI
        // scrape to a backup.
        migrator.registerMigration("v51_config_hibernate_input_veto") { db in
            try db.addColumnIfMissing(
                table: "config", column: "hibernate_input_veto_enabled",
                type: .boolean, defaults: false)
        }

        // Orphan GC: persisted record of every agent-worktree/scratchpad the
        // daemon-owned GC swept (and optionally snapshotted) before removal,
        // plus the config knobs that gate the sweep (default ON, 1h grace,
        // 30-day snapshot retention).
        migrator.registerMigration("v52_reap_records_and_gc_config") { db in
            try db.createTableIfNotExists("reap_records") { t in
                t.column("id", .text).primaryKey()
                t.column("kind", .text).notNull()
                t.column("repoPath", .text).notNull()
                t.column("worktreePath", .text).notNull()
                t.column("branch", .text)
                t.column("headSHA", .text)
                t.column("snapshotRef", .text)
                t.column("apparentBytes", .integer)
                t.column("reapedAt", .datetime).notNull()
                t.column("restoredAt", .datetime)
            }
            try db.addIndexIfMissing("idx_reap_records_repo", on: "reap_records", columns: ["repoPath"])
            try db.addColumnIfMissing(table: "config", column: "gc_enabled", type: .boolean, defaults: true)
            try db.addColumnIfMissing(table: "config", column: "gc_grace_seconds", type: .integer, defaults: 3600)
            try db.addColumnIfMissing(table: "config", column: "gc_snapshot_retention_days", type: .integer, defaults: 30)
        }

        // Per-repo Claude settings overlay fragment (JSON object string,
        // plain-text passthrough). NULL = unset. Resolved at Claude spawn
        // time and deep-merged into TBD's per-session `--settings` overlay
        // beneath the per-spawn `--claude-settings` fragment. See
        // docs/claude-settings-overlay.md.
        migrator.registerMigration("v53_repo_claude_settings_overlay") { db in
            try db.addColumnIfMissing(table: "repo", column: "claude_settings_overlay", type: .text)
        }

        // Number of the GitHub PR a worktree was created from, if any. Nullable —
        // NULL means "not created from a PR". Lets PRStatusManager resolve status
        // by direct number lookup instead of viewer-authored/branch-name matching,
        // which is the only way fork PRs (no matching local branch) get tracked.
        migrator.registerMigration("v54_worktree_pr_number") { db in
            try db.addColumnIfMissing(table: "worktree", column: "pr_number", type: .integer)
        }

        // Last-known OAuth usage snapshot per profile (JSON blob of the shared
        // ProfileUsageSnapshot model), so daemon restarts render stale-but-real
        // usage bars immediately instead of "usage unavailable" and the
        // startup sweep can skip profiles whose data is still fresh. Cache
        // state — rows regenerate on the next successful fetch.
        migrator.registerMigration("v55_oauth_usage_snapshot_cache") { db in
            try db.createTableIfNotExists("oauth_profile_usage_snapshot") { t in
                t.primaryKey("profile_id", .text).notNull()
                    .references("model_profiles", onDelete: .cascade)
                t.column("snapshot_json", .text).notNull()
            }
        }

        // Drag-and-drop reordering for model profiles (mirrors v11's worktree
        // sortOrder). Initialize existing rows from rowid to preserve current
        // insertion order.
        migrator.registerMigration("v56_model_profiles_sort_order") { db in
            try db.addColumnIfMissing(
                table: "model_profiles", column: "sort_order", type: .integer, defaults: 0)
            try db.execute(sql: "UPDATE model_profiles SET sort_order = rowid")
        }

        // Soak flag for auto-closing the setup-hook tab after a clean run
        // (default OFF per the default-off-flag rule: it kills a pane and
        // deletes terminal/tab rows without a user gesture). When on, a
        // resolved setup hook's exit code is written to a marker file and a
        // clean exit tears the tab down; nonzero keeps the tab open (execs
        // the interactive shell) for debugging.
        // (Renumbered v56→v57 on rebase: main's #482 took v56.)
        migrator.registerMigration("v57_config_auto_close_setup") { db in
            try db.addColumnIfMissing(
                table: "config", column: "auto_close_setup_enabled",
                type: .boolean, defaults: false)
        }

        // Read-only closed-terminal history: metadata for scrollback captured
        // at terminal close (content is file-backed at
        // ~/tbd/terminal-history/<worktreeID>/<terminalID>.txt). Additive —
        // close semantics are unchanged; capture is best-effort. Rows are
        // pruned to the newest 50 per worktree on insert and removed (with
        // their files) on worktree hard-delete; archive keeps them.
        // (Renumbered v57→v58 on rebase: main's #482 took v56, shifting this branch's ids.)
        migrator.registerMigration("v58_terminal_history") { db in
            try db.createTableIfNotExists("terminal_history") { t in
                t.primaryKey("id", .text).notNull()
                t.column("worktreeID", .text).notNull()
                t.column("label", .text)
                t.column("kind", .text)
                t.column("closedAt", .datetime).notNull()
                t.column("claudeSessionID", .text)
                t.column("lineCount", .integer).notNull().defaults(to: 0)
            }
            try db.addIndexIfMissing(
                "idx_terminal_history_worktree", on: "terminal_history", columns: ["worktreeID"])
        }

        // (Renumbered v57→v59 on rebase: main's #485 took v57 and v58.)
        // Spec C Phase 2 (§8): daemon-owned panel-surface rows — one row per
        // workspace tab (layout tree + primary + revision), per-panel MRU
        // history, and bounded operation receipts for §7.4 idempotency. Both
        // feature flags land default-OFF per the repo flag policy: the store
        // is inert until `daemon_panel_surface_enabled` is turned on, and
        // agent-originated mutations additionally require
        // `agent_panel_control_enabled`. `worktree.panel_surface_imported_at`
        // distinguishes "imported an empty layout" from "never imported".
        migrator.registerMigration("v59_panel_surface") { db in
            try db.createTableIfNotExists("workspace_tab_surface") { t in
                t.primaryKey("id", .text).notNull()
                t.column("worktreeID", .text).notNull()
                    .references("worktree", onDelete: .cascade)
                t.column("primaryContent", .text).notNull()   // PrimaryContent JSON
                t.column("label", .text)
                t.column("position", .integer).notNull()
                t.column("layout", .text).notNull()           // PanelLayoutNode JSON
                t.column("revision", .integer).notNull().defaults(to: 0)
                t.column("updatedAt", .datetime).notNull()
            }
            try db.addIndexIfMissing("idx_workspace_tab_surface_worktree",
                                     on: "workspace_tab_surface", columns: ["worktreeID", "position"])
            // history rows cascade via tabID → workspace_tab_surface, which
            // itself cascades to worktree — so deleting a worktree reaps its
            // surfaces and their history rows in one chain.
            try db.createTableIfNotExists("panel_history") { t in
                t.primaryKey("panelID", .text).notNull()
                t.column("tabID", .text).notNull()
                    .references("workspace_tab_surface", onDelete: .cascade)
                t.column("history", .text).notNull()          // PanelHistory JSON
                t.column("updatedAt", .datetime).notNull()
            }
            try db.addIndexIfMissing("idx_panel_history_tab", on: "panel_history", columns: ["tabID"])
            try db.createTableIfNotExists("panel_operation_receipt") { t in
                t.primaryKey("operationID", .text).notNull()
                t.column("worktreeID", .text).notNull()
                    .references("worktree", onDelete: .cascade)
                t.column("tabID", .text).notNull()
                t.column("revision", .integer).notNull()
                t.column("result", .text).notNull()           // PanelApplyResult JSON
                t.column("appliedAt", .datetime).notNull()
            }
            try db.addIndexIfMissing("idx_panel_receipt_worktree",
                                     on: "panel_operation_receipt", columns: ["worktreeID", "appliedAt"])
            try db.addColumnIfMissing(table: "config", column: "daemon_panel_surface_enabled",
                                      type: .boolean, defaults: false)
            try db.addColumnIfMissing(table: "config", column: "agent_panel_control_enabled",
                                      type: .boolean, defaults: false)
            try db.addColumnIfMissing(table: "worktree", column: "panel_surface_imported_at",
                                      type: .datetime)
        }

        // The compiled merge gate (MergeGate / NightwatchPolicy) and its two
        // stores were deleted: the gate built its input from placeholder
        // values (`headSHA: "unknown"`, `hasApprovedReview: false`), so every
        // row it ever wrote recorded the same `escalate` decision, and the
        // `clearance` table never had a production writer or reader at all.
        // Nothing of value is lost by dropping them. Merge authorization is
        // delegated to the forge (GitHub branch protection + auto-merge),
        // which sits outside the trust boundary of the machine running the
        // agents. v41/v42 stay registered and untouched — a fresh DB creates
        // the tables and this migration drops them again, which is cheap and
        // keeps the migration history append-only.
        migrator.registerMigration("v60_drop_nightwatch_merge_gate_tables") { db in
            try db.execute(sql: "DROP TABLE IF EXISTS clearance")
            try db.execute(sql: "DROP TABLE IF EXISTS audit_log")
        }

        // Remote agent backends (spec 2026-07-24). Flag lands default-OFF per
        // the repo flag policy: the feature polls in the background, spawns
        // provider subprocesses, and can stop remote sessions. `remote_session`
        // mirrors provider-owned sessions keyed (provider, sessionID); the
        // provider is the source of truth — rows here are a cache with drift
        // bookkeeping (missingCount/gone per the two-absence rule).
        // (Renumbered v60→v61 on merge: main's #514-adjacent work took v60 as
        // `v60_drop_nightwatch_merge_gate_tables`. Safe because the migration
        // body uses the idempotent helpers — see Database/CLAUDE.md.)
        migrator.registerMigration("v61_remote_backends") { db in
            try db.addColumnIfMissing(
                table: "config", column: "remote_backends_enabled",
                type: .boolean, defaults: false)
            try db.createTableIfNotExists("remote_session") { t in
                t.column("provider", .text).notNull()
                t.column("sessionID", .text).notNull()
                t.column("payload", .text).notNull()      // raw contract Session JSON
                t.column("state", .text).notNull()
                t.column("agentState", .text)
                t.column("firstSeen", .datetime).notNull()
                t.column("lastSeen", .datetime).notNull()
                t.column("missingCount", .integer).notNull().defaults(to: 0)
                t.column("gone", .boolean).notNull().defaults(to: false)
                t.column("dismissed", .boolean).notNull().defaults(to: false)
                t.primaryKey(["provider", "sessionID"])
            }
        }

        // Pin remote sessions to a local repo (spec 2026-07-24, follow-up to
        // v61): `resolvedRepoID` caches the outcome of matching a provider's
        // `meta["repo"]` against registered repos' `remoteURL`
        // (`RemoteRepoMatching`), computed once at first sighting and never
        // re-derived once non-null — see `RemoteSessionStore.upsert`.
        // (Renumbered v61→v62 on merge: see comment on v61_remote_backends above.)
        migrator.registerMigration("v62_remote_session_resolved_repo") { db in
            try db.addColumnIfMissing(
                table: "remote_session", column: "resolvedRepoID",
                type: .text)
        }

        // Pin a worktree to the sidebar dock. Nullable with NO default: existing
        // rows must land on NULL (= unpinned), and there is no Swift-side default
        // to flip later, so the `ADD COLUMN ... DEFAULT` backfill trap does not
        // apply. Purely presentational — nothing in the daemon reads this value.
        // (Renumbered v60→v63 on rebase: main took v60/v61/v62 first. Safe
        // because the body uses the idempotent `addColumnIfMissing` helper —
        // see Database/CLAUDE.md — so a DB that already ran this under the old
        // identifier just no-ops.)
        migrator.registerMigration("v63_worktree_pinned_at") { db in
            try db.addColumnIfMissing(table: "worktree", column: "pinnedAt", type: .datetime)
        }

        // Custom ordering for the sidebar's pinned dock. Nullable with NO
        // default and NO backfill: `PinnedDockContent` falls back to `pinnedAt`
        // order for rows that are still NULL, so existing pins keep their
        // current visual order the moment this lands and the first drag assigns
        // real values. Separate from `sortOrder`, which drives repo-section tree
        // ordering — writing pin order there would scramble the sidebar.
        migrator.registerMigration("v64_worktree_pin_sort_order") { db in
            try db.addColumnIfMissing(table: "worktree", column: "pinSortOrder", type: .integer)
        }

        // Pin a remote session to the same sidebar dock worktrees pin to.
        // Nullable with NO default and NO backfill, for the same reasons
        // v63 gives for `worktree.pinnedAt`: existing rows must land on NULL
        // (= unpinned), and there is no Swift-side default to flip later, so
        // the `ADD COLUMN ... DEFAULT` backfill trap does not apply. The pin
        // rides on the mirror row rather than a side table because the row's
        // primary key `(provider, sessionID)` is already the durable identity
        // for a remote session (see `RemoteSessionIdentity`) and mirror rows
        // are never deleted — only marked gone/dismissed — so a pin survives
        // provider drift and daemon restarts.
        migrator.registerMigration("v65_remote_session_pinned_at") { db in
            try db.addColumnIfMissing(table: "remote_session", column: "pinnedAt", type: .datetime)
        }

        // Pre-accept Claude Code's folder-trust dialog for worktrees TBD itself
        // created. Default ON — deliberately, and NOT a soak flag:
        //
        // The dialog asks "is this a project you created or one you trust?" For
        // a worktree TBD created from a repo the operator explicitly registered,
        // the answer is yes *by construction* — TBD holds every fact the dialog
        // is asking about. Pre-seeding just writes that already-known answer
        // through Claude's own config persistence, so the dialog never renders.
        //
        // Prevention is the only available fix: the dialog blocks BEFORE
        // SessionStart, so no hook fires while it is up and a stalled-on-trust
        // session is machine-invisible to TBD. A default-OFF flag would leave
        // the stall in place for everyone who never finds the toggle.
        //
        // `ADD COLUMN ... DEFAULT true` backfills existing rows to true, which
        // IS the intent here (see the CLAUDE.md default-flip note): every
        // existing install should stop stalling on first spawn.
        migrator.registerMigration("v66_config_auto_trust_worktrees") { db in
            try db.addColumnIfMissing(
                table: "config", column: "auto_trust_worktrees",
                type: .boolean, defaults: true)
        }

        // Marks a worktree whose CONTENTS came from a ref TBD cannot vouch for
        // — a `refs/pull/<n>/head` checkout, whose commits may be authored by a
        // third-party fork contributor. TBD created the directory; it did not
        // create what is inside it, so v66's auto-trust seeding must skip these
        // rows and let Claude ask (see `ClaudeTrustSeeder`).
        //
        // Persisted rather than passed as a create-time parameter because
        // seeding happens at six call sites — create, extra-session restore,
        // terminal create, revive, profile swap, hibernation wake — and all but
        // the first see only the stored row.
        //
        // `ADD COLUMN ... DEFAULT false` backfills existing rows to false, which
        // is the intended reading: rows created before this column existed are
        // treated as ordinary TBD-created contents (the status quo ante). The
        // default-flip trap in CLAUDE.md does not apply — this is not a
        // user-facing toggle and there is no plan to flip its default.
        migrator.registerMigration("v67_worktree_foreign_head") { db in
            try db.addColumnIfMissing(
                table: "worktree", column: "foreign_head",
                type: .boolean, defaults: false)
        }

        migrator.registerMigration("v68_watch_desk_judge_lease") { db in
            try db.addColumnIfMissing(
                table: "terminal", column: "watch_desk_role", type: .text,
                defaults: DatabaseValue.null)
            try db.createTableIfNotExists("watch_desk_judge_lease") { t in
                t.primaryKey("worktree_id", .text).notNull()
                    .references("worktree", onDelete: .cascade)
                // Deliberately not an FK: a dead terminal row may be deleted,
                // but its generation tombstone must survive so fencing tokens
                // are never reused for this desk.
                t.column("terminal_id", .text).notNull()
                t.column("token", .text).notNull()
                t.column("generation", .integer).notNull()
                t.column("acquired_at", .datetime).notNull()
                t.column("renewed_at", .datetime).notNull()
                t.column("expires_at", .datetime).notNull()
            }
        }

        // Soak flag for delivery acknowledgement (fleet-supervision design
        // §12). Default false, following the `hibernate_input_veto_enabled`
        // (v51) / `control_mode_enabled` precedent rather than the v39/v50
        // cautionary one: the re-check acts on no user gesture and its retry
        // types into a live session, so the whole path ships off and is opted
        // into for its soak. Shipping OFF also means no forcing `UPDATE`
        // migration is ever needed to flip the default later.
        //
        // The flag does not gate the dispatch envelope — attribution rides
        // every text send to an agent regardless, verified or not (§12).
        // Whether a target gets one at all is a property of the target: a shell
        // would execute the tag, so it receives the text alone.
        migrator.registerMigration("v69_config_delivery_verification") { db in
            try db.addColumnIfMissing(
                table: "config", column: "delivery_verification_enabled",
                type: .boolean, defaults: false)
        }

        // Where a worktree's files live. Backfilling 'local' states a fact
        // rather than a preference — every pre-v70 row IS local — so no later
        // migration has to force it (contrast auto_hibernate_enabled, whose
        // backfilled default needed a forcing UPDATE in v50). `providerName`
        // and `providerSessionID` are set together with location = 'remote'
        // and are null for every local row.
        migrator.registerMigration("v70_worktree_location") { db in
            try db.addColumnIfMissing(
                table: "worktree", column: "location", type: .text, defaults: "local")
            try db.addColumnIfMissing(
                table: "worktree", column: "providerName", type: .text)
            try db.addColumnIfMissing(
                table: "worktree", column: "providerSessionID", type: .text)
        }

        // Multi-PR support: one durable binding row per (worktree, PR).
        // `detached` is a tombstone — a deleted row would be re-created by the
        // next poll or hook fire, so a user's removal has to be recorded.
        //
        // Numbered v71 because main took v70 for `worktree_location` while this
        // branch was open. Renumbering an additive migration is only safe
        // because the body goes through the idempotent helpers: a machine that
        // already applied it under the old ID re-runs this body and finds the
        // table and both indexes present, so it logs a no-op instead of
        // throwing on a duplicate.
        migrator.registerMigration("v71_worktree_pull_request") { db in
            try db.createTableIfNotExists("worktree_pull_request") { t in
                t.primaryKey("id", .text).notNull()
                t.column("worktreeID", .text).notNull()
                    .references("worktree", onDelete: .cascade)
                t.column("host", .text).notNull().defaults(to: "github.com")
                t.column("owner", .text).notNull()
                t.column("repo", .text).notNull()
                t.column("number", .integer).notNull()
                t.column("url", .text).notNull()
                t.column("headBranch", .text)
                t.column("baseRef", .text)
                t.column("prStatus", .text)              // PRStatus JSON
                t.column("source", .text).notNull()
                t.column("detached", .boolean).notNull().defaults(to: false)
                t.column("boundAt", .datetime).notNull()
            }
            try db.addIndexIfMissing(
                "idx_worktree_pull_request_worktree",
                on: "worktree_pull_request", columns: ["worktreeID"])
            // Owner and repo are stored lowercased by PRBindingStore, so this
            // unique index is effectively case-insensitive without a collation
            // change.
            try db.addIndexIfMissing(
                "idx_worktree_pull_request_identity",
                on: "worktree_pull_request",
                columns: ["worktreeID", "host", "owner", "repo", "number"],
                unique: true)
        }

        // Adoption probes "does a row already exist for this provider
        // session" once per sighted session on every poll, so the binding
        // needs an index rather than a scan of the whole worktree table.
        //
        // Partial: only remote rows carry a provider binding, so local rows
        // stay out of the index entirely.
        //
        // NOT unique, and the reason is worth stating precisely, because
        // adoption's `findRemote` check is NOT what makes a duplicate binding
        // impossible: it is a check-then-act across two transactions, and
        // `RemoteProviderManager` is a reentrant actor whose poll and events
        // paths can both be inside it for one session at once. What actually
        // forbids the duplicate is `worktree.path`'s pre-existing NOT NULL
        // UNIQUE constraint — a remote row's path is
        // `WorktreeLocation.storagePath`, a pure function of
        // `(provider, sessionID)` — so the losing insert fails on that
        // constraint and the next poll finds the winner's row. This index is
        // therefore a performance index only. It is not UNIQUE because that
        // would turn a pre-existing duplicate into a migration-time failure on
        // the install that has one, rather than something the code can log and
        // step over.
        migrator.registerMigration("v72_worktree_provider_session_index") { db in
            try db.addIndexIfMissing(
                "idx_worktree_provider_session",
                on: "worktree",
                columns: ["providerName", "providerSessionID"],
                where: "providerName IS NOT NULL")
        }

        // Numbered v73/v74 because main took v70, v71 and v72 while this
        // branch was open. Renumbering is safe only because both bodies go
        // through the idempotent helpers: a machine that already applied them
        // under the old ids re-runs the bodies, finds every column present,
        // and logs a no-op instead of throwing.
        //
        // Soak flag for the queued prompt taken at worktree creation
        // (`docs/specs/2026-08-10-queued-prompt-on-create-design.md`). Default
        // OFF: the feature has the daemon type into a live session on no user
        // gesture beyond the original submit.
        //
        // **The missing `defaults:` argument is deliberate — do not add one.**
        // Every boolean flag before this one passes `defaults: false`. SQLite
        // stores that in the schema and hands it back for every row written
        // before the column existed, and the `config` singleton row is seeded
        // by v1, so a fresh install and a years-old one both read `0` —
        // indistinguishable from a deliberate opt-out. Omitting the default
        // leaves the column genuinely NULL, which is a third state: "never
        // chose". `ConfigRecord.toModel()` resolves NULL to
        // `Config.queuedPromptDefault`, so graduation is a change to that one
        // constant and needs no forcing `UPDATE` migration, while an explicit
        // `false` survives it untouched.
        //
        // `QueuedPromptSchemaTests.queuedPromptEnabledIsNullBeforeAnyGesture`
        // is the guard on this; it goes red the moment a default reappears.
        migrator.registerMigration("v73_config_queued_prompt") { db in
            try db.addColumnIfMissing(
                table: "config", column: "queued_prompt_enabled", type: .boolean)
        }

        // The parked prompt itself. `pending_prompt_submit` DOES carry a SQL
        // default, because it is data rather than a feature gate: there is no
        // third "nobody chose" state worth preserving. That default IS reached
        // — `ADD COLUMN ... DEFAULT 1` backfills every row that already
        // existed, which then reads a present `true` rather than NULL
        // (`QueuedPromptSchemaTests.rowWrittenBeforeV71DecodesWithNothingParked`
        // pins that). It is inert, not unreachable: the rows it lands on get a
        // NULL `pending_prompt` in the same breath, so the bit describes a
        // prompt that does not exist and nobody will ever deliver.
        //
        // Both columns are added here together and `setPendingPrompt` — their
        // only writer — always names both, so a prompt with no recorded submit
        // bit is a shape no writer produces. Where the bit is genuinely absent
        // (a row saved from a `Worktree` that never named it),
        // `Worktree.pendingPromptSubmitResolved` is the one place that decides
        // what it means, for delivery and for the read-back alike.
        migrator.registerMigration("v74_worktree_pending_prompt") { db in
            try db.addColumnIfMissing(
                table: "worktree", column: "pending_prompt", type: .text)
            try db.addColumnIfMissing(
                table: "worktree", column: "pending_prompt_submit",
                type: .boolean, defaults: true)
        }

        // Provenance for `terminal.activityState` (fleet-supervision design
        // §2): a fact TBD reports about a session is the value, the source it
        // came from, and when it was observed — never a bare enumeration.
        //
        // All four columns are deliberately nullable WITHOUT a default. There
        // is no honest default for "where did this come from": a backfilled
        // `derived` or `database` would attach manufactured provenance to
        // rows nobody observed, which is precisely the laundering the state
        // model exists to prevent. NULL means "not yet observed", and
        // `Terminal.observedActivity` reads a half-stamped row as no fact at
        // all rather than as a fact with a guessed source.
        //
        // Numbered v75/v76 because main took v70 through v74 while this branch
        // was open. Renumbering is safe only because both bodies go through
        // `addColumnIfMissing`: a machine that already applied them under the
        // old ids re-runs the bodies, finds every column present, and logs a
        // no-op instead of throwing.
        migrator.registerMigration("v75_terminal_state_provenance") { db in
            try db.addColumnIfMissing(
                table: "terminal", column: "activityStateSource", type: .text)
            try db.addColumnIfMissing(
                table: "terminal", column: "activityStateObservedAt", type: .datetime)
            try db.addColumnIfMissing(
                table: "terminal", column: "awaitingInputReason", type: .text)
            try db.addColumnIfMissing(
                table: "terminal", column: "awaitingInputObservedAt", type: .datetime)
        }

        // The outcome of the last attempt to learn a worktree's PR state, as
        // distinct from the value that attempt found (`worktree.prStatus`).
        // A nil `prStatus` cannot tell "the forge answered; no PR" from "the
        // query failed", and treating an outage as a fleet with no pull
        // requests looks exactly like a calm night.
        //
        // Nullable without a default for the same reason as v75: NULL means no
        // attempt is on record, which is a third thing again from a recorded
        // `.none` or `.undetermined`.
        migrator.registerMigration("v76_worktree_pr_observation") { db in
            try db.addColumnIfMissing(
                table: "worktree", column: "prObservation", type: .text)
        }

        // The fleet supervision brake (design 2026-07-26 §3, §7): one
        // fleet-wide on/off switch, shipped OFF per the house
        // default-off-flag rule. Numbered v77 because main took v75 and v76 while this branch
        // was open; renumbering is safe for the same reason theirs was —
        // `addColumnIfMissing` re-runs as a no-op on a machine that already
        // applied it under the old id. Tri-state like `v73_config_queued_prompt`,
        // not `v69_config_delivery_verification`: no SQL default, so a
        // pre-migration row reads NULL ("never chose") rather than 0. NULL
        // resolves through `Config.supervisionEnabledDefault` in
        // `ConfigRecord.toModel()` — the single place graduation changes.
        migrator.registerMigration("v77_config_supervision_enabled") { db in
            try db.addColumnIfMissing(
                table: "config", column: "supervision_enabled", type: .boolean)
        }

        // Gate for `ProfileDirCollector` — the reconciler for
        // `~/tbd/profiles/<uuid>/` (docs/specs/2026-08-15-profile-dir-gc-design.md).
        // Ships OFF: unlike the other collectors' targets, those directories
        // hold per-profile credentials and user content, so the classifier
        // soaks behind its own switch before graduating. Tri-state like
        // v73/v77 — no SQL default, so a pre-migration row reads NULL ("never
        // chose") rather than 0, and NULL resolves through
        // `Config.gcProfileDirsEnabledDefault` in `ConfigRecord.toModel()`,
        // the single place graduation changes.
        migrator.registerMigration("v78_config_gc_profile_dirs") { db in
            try db.addColumnIfMissing(
                table: "config", column: "gc_profile_dirs_enabled", type: .boolean)
        }

        // Where a quarantined `.profileDir` reap parked the directory. Nullable
        // and left NULL by every other kind, which deletes outright. camelCase
        // to match the columns this table already has (`repoPath`,
        // `worktreePath`, `snapshotRef`).
        migrator.registerMigration("v79_reap_records_quarantine_path") { db in
            try db.addColumnIfMissing(
                table: "reap_records", column: "quarantinePath", type: .text)
        }

        // Clear the PR attempt outcome recorded against scratch rows. A scratch
        // row (`repoID IS NULL`) has no repo, no branch, and a path that is not a
        // checkout, so the poll skips it. `pr.refresh` queried it anyway on
        // select, failed in that directory, and wrote `.undetermined` to the row.
        // Every PR surface renders that as "PR status unknown", so a scratch lane
        // grew a `?` badge it can never resolve.
        //
        // `RPCRouter.isPollable` now gates both paths, so no row can acquire one
        // again, but the recorded ones outlive the guard, and by two separate
        // readers: the daemon re-hydrates them into `PRStatusManager` at every
        // start, and the app seeds `prObservations` straight off the worktree row.
        // Both read the column, so the column is where the fix has to land.
        //
        // Scoped to `prObservation`. A scratch row's `prStatus` is left alone
        // because no path ever wrote one: the failing query kept the (absent)
        // cached value rather than replacing it.
        migrator.registerMigration("v80_clear_scratch_pr_observation") { db in
            try db.execute(
                sql: "UPDATE worktree SET prObservation = NULL WHERE repoID IS NULL")
        }

        return migrator
    }
}
