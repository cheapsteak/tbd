import Foundation
import GRDB
import TBDShared

/// GRDB Record type for the `terminal` table.
struct TerminalRecord: Codable, FetchableRecord, PersistableRecord, Sendable {
    static let databaseTableName = "terminal"

    var id: String
    var worktreeID: String
    var tmuxWindowID: String
    var tmuxPaneID: String
    var label: String?
    var createdAt: Date
    var pinnedAt: Date?
    var claudeSessionID: String?
    var suspendedAt: Date?
    var suspendedSnapshot: String?
    var profile_id: String?
    var transcriptPath: String?
    var kind: String?
    var activityState: String?

    init(from terminal: Terminal) {
        self.id = terminal.id.uuidString
        self.worktreeID = terminal.worktreeID.uuidString
        self.tmuxWindowID = terminal.tmuxWindowID
        self.tmuxPaneID = terminal.tmuxPaneID
        self.label = terminal.label
        self.createdAt = terminal.createdAt
        self.pinnedAt = terminal.pinnedAt
        self.claudeSessionID = terminal.claudeSessionID
        self.suspendedAt = terminal.suspendedAt
        self.suspendedSnapshot = terminal.suspendedSnapshot
        self.profile_id = terminal.profileID?.uuidString
        self.transcriptPath = terminal.transcriptPath
        self.kind = terminal.kind?.rawValue
        self.activityState = terminal.activityState.rawValue
    }

    func toModel() -> Terminal {
        Terminal(
            id: UUID(uuidString: id)!,
            worktreeID: UUID(uuidString: worktreeID)!,
            tmuxWindowID: tmuxWindowID,
            tmuxPaneID: tmuxPaneID,
            label: label,
            createdAt: createdAt,
            pinnedAt: pinnedAt,
            claudeSessionID: claudeSessionID,
            suspendedAt: suspendedAt,
            suspendedSnapshot: suspendedSnapshot,
            profileID: profile_id.flatMap(UUID.init(uuidString:)),
            transcriptPath: transcriptPath,
            kind: kind.flatMap(TerminalKind.init(rawValue:)),
            activityState: activityState.flatMap(TerminalActivityState.init(rawValue:)) ?? .unknown
        )
    }
}

/// Provides CRUD operations for terminals.
public struct TerminalStore: Sendable {
    let writer: any DatabaseWriter

    init(writer: any DatabaseWriter) {
        self.writer = writer
    }

    /// Create a new terminal record.
    ///
    /// `id` is optional. Callers that need to know the terminal ID *before*
    /// the tmux window is spawned (so it can be injected as `TBD_TERMINAL_ID`
    /// in the spawned env, used by the SessionStart hook bridge) can pre-mint
    /// a UUID and pass it here. Defaults to a fresh UUID otherwise.
    public func create(
        id: UUID = UUID(),
        worktreeID: UUID,
        tmuxWindowID: String,
        tmuxPaneID: String,
        label: String? = nil,
        claudeSessionID: String? = nil,
        profileID: UUID? = nil,
        kind: TerminalKind? = nil
    ) async throws -> Terminal {
        let terminal = Terminal(
            id: id,
            worktreeID: worktreeID,
            tmuxWindowID: tmuxWindowID,
            tmuxPaneID: tmuxPaneID,
            label: label,
            claudeSessionID: claudeSessionID,
            profileID: profileID,
            kind: kind
        )
        let record = TerminalRecord(from: terminal)
        try await writer.write { db in
            try record.insert(db)
        }
        return terminal
    }

    /// List terminals, optionally filtered by worktree.
    public func list(worktreeID: UUID? = nil) async throws -> [Terminal] {
        try await writer.read { db in
            var request = TerminalRecord.all()
            if let worktreeID {
                request = request.filter(Column("worktreeID") == worktreeID.uuidString)
            }
            request = request.order(Column("createdAt").asc, Column("id").asc)
            return try request.fetchAll(db).map { $0.toModel() }
        }
    }

    /// Get a terminal by ID.
    public func get(id: UUID) async throws -> Terminal? {
        try await writer.read { db in
            try TerminalRecord.fetchOne(db, key: id.uuidString)?.toModel()
        }
    }

    /// Delete a terminal by ID.
    public func delete(id: UUID) async throws {
        _ = try await writer.write { db in
            try TerminalRecord.deleteOne(db, key: id.uuidString)
        }
    }

    /// Delete all terminals for a worktree.
    public func deleteForWorktree(worktreeID: UUID) async throws {
        _ = try await writer.write { db in
            try TerminalRecord
                .filter(Column("worktreeID") == worktreeID.uuidString)
                .deleteAll(db)
        }
    }

    /// Set or clear the pinned timestamp for a terminal.
    public func setPin(id: UUID, pinned: Bool, at date: Date = Date()) async throws {
        try await writer.write { db in
            guard var record = try TerminalRecord.fetchOne(db, key: id.uuidString) else {
                throw DatabaseError(message: "Terminal not found")
            }
            record.pinnedAt = pinned ? date : nil
            try record.update(db)
        }
    }

    /// Mark a terminal as suspended, recording the session ID, snapshot, and current timestamp.
    public func setSuspended(id: UUID, sessionID: String, snapshot: String? = nil, at date: Date = Date()) async throws {
        try await writer.write { db in
            guard var record = try TerminalRecord.fetchOne(db, key: id.uuidString) else {
                throw DatabaseError(message: "Terminal not found")
            }
            record.claudeSessionID = sessionID
            record.suspendedAt = date
            record.suspendedSnapshot = snapshot
            try record.update(db)
        }
    }

    /// Clear the suspended state of a terminal. Keeps the snapshot so the
    /// app can feed it into TerminalPanelView as initial content while the
    /// tmux client connects. The snapshot is overwritten on the next suspend.
    public func clearSuspended(id: UUID) async throws {
        try await writer.write { db in
            guard var record = try TerminalRecord.fetchOne(db, key: id.uuidString) else {
                throw DatabaseError(message: "Terminal not found")
            }
            record.suspendedAt = nil
            try record.update(db)
        }
    }

    /// Update the Claude session ID for a terminal.
    public func updateSessionID(id: UUID, sessionID: String) async throws {
        try await writer.write { db in
            guard var record = try TerminalRecord.fetchOne(db, key: id.uuidString) else {
                throw DatabaseError(message: "Terminal not found")
            }
            record.claudeSessionID = sessionID
            try record.update(db)
        }
    }

    /// Update the Claude session ID and the absolute JSONL transcript path for
    /// a terminal in one write. Used by the SessionStart hook bridge so the
    /// transcript handler can target the exact file Claude is writing without
    /// re-deriving the project directory from cwd (which is fragile across
    /// `/clear` and `/compact` rollovers).
    public func updateSession(id: UUID, sessionID: String, transcriptPath: String?) async throws {
        try await writer.write { db in
            guard var record = try TerminalRecord.fetchOne(db, key: id.uuidString) else {
                throw DatabaseError(message: "Terminal not found")
            }
            record.claudeSessionID = sessionID
            // Only overwrite when the caller supplied a path. A SessionStart
            // payload that omits `transcript_path` (theoretical — Claude
            // currently always sends it) shouldn't clobber a previously
            // captured path; the existing value still points at the right
            // file as long as sessionID matches.
            if let transcriptPath = transcriptPath {
                record.transcriptPath = transcriptPath
            }
            try record.update(db)
        }
    }

    /// Clear Claude-specific metadata after window recreation.
    /// The recreated window runs a plain shell, not Claude.
    public func clearRecreated(id: UUID) async throws {
        try await writer.write { db in
            guard var record = try TerminalRecord.fetchOne(db, key: id.uuidString) else {
                throw DatabaseError(message: "Terminal not found")
            }
            record.claudeSessionID = nil
            record.transcriptPath = nil
            record.suspendedAt = nil
            record.suspendedSnapshot = nil
            record.label = "shell"
            record.kind = TerminalKind.shell.rawValue
            record.activityState = TerminalActivityState.unknown.rawValue
            try record.update(db)
        }
    }

    /// Set or clear the model profile ID for a terminal.
    public func setProfileID(id: UUID, profileID: UUID?) async throws {
        try await writer.write { db in
            try db.execute(
                sql: "UPDATE terminal SET profile_id = ? WHERE id = ?",
                arguments: [profileID?.uuidString, id.uuidString]
            )
        }
    }

    /// Update the tmux window and pane IDs for a terminal.
    public func updateTmuxIDs(id: UUID, windowID: String, paneID: String) async throws {
        try await writer.write { db in
            guard var record = try TerminalRecord.fetchOne(db, key: id.uuidString) else {
                throw DatabaseError(message: "Terminal not found")
            }
            record.tmuxWindowID = windowID
            record.tmuxPaneID = paneID
            try record.update(db)
        }
    }

    /// Update the current activity state for a terminal.
    public func setActivityState(id: UUID, activityState: TerminalActivityState) async throws {
        try await writer.write { db in
            guard var record = try TerminalRecord.fetchOne(db, key: id.uuidString) else {
                throw DatabaseError(message: "Terminal not found")
            }
            record.activityState = activityState.rawValue
            try record.update(db)
        }
    }
}
