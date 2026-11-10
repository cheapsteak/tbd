import Foundation
import GRDB
import os
import TBDShared

private let localAgentSessionLogger = Logger(subsystem: "com.tbd.daemon", category: "database.decode")

/// One provider session observed in one worktree. Terminal deletion retains it.
public struct LocalAgentSession: Sendable, Equatable, Identifiable {
    public let id: UUID
    public let worktreeID: UUID
    public let terminalID: UUID?
    public let identity: AgentSessionIdentity
    public let transcriptPath: String?
    public let codexLaunchOptions: CodexLaunchOptions?
    public let firstObservedAt: Date
    public let lastObservedAt: Date

    public init(id: UUID = UUID(), worktreeID: UUID, terminalID: UUID? = nil,
                identity: AgentSessionIdentity, transcriptPath: String? = nil,
                codexLaunchOptions: CodexLaunchOptions? = nil,
                firstObservedAt: Date, lastObservedAt: Date) {
        self.id = id
        self.worktreeID = worktreeID
        self.terminalID = terminalID
        self.identity = identity
        self.transcriptPath = transcriptPath
        self.codexLaunchOptions = codexLaunchOptions
        self.firstObservedAt = firstObservedAt
        self.lastObservedAt = lastObservedAt
    }
}

struct LocalAgentSessionRecord: Codable, FetchableRecord, PersistableRecord, Sendable {
    static let databaseTableName = "local_agent_session"

    var id: String
    var worktree_id: String
    var terminal_id: String?
    var agent_kind: String
    var session_id: String
    var transcript_path: String?
    var codex_launch_options: String?
    var first_observed_at: Date
    var last_observed_at: Date

    init(from model: LocalAgentSession) throws {
        id = model.id.uuidString
        worktree_id = model.worktreeID.uuidString
        terminal_id = model.terminalID?.uuidString
        agent_kind = model.identity.agentKind.rawValue
        session_id = model.identity.sessionID
        transcript_path = model.transcriptPath
        codex_launch_options = try model.codexLaunchOptions.flatMap {
            String(data: try JSONEncoder().encode($0), encoding: .utf8)
        }
        first_observed_at = model.firstObservedAt
        last_observed_at = model.lastObservedAt
    }

    func toModel() -> LocalAgentSession? {
        guard let id = UUID(uuidString: id), let worktreeID = UUID(uuidString: worktree_id),
              let kind = LocalAgentKind(rawValue: agent_kind), !session_id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              terminal_id == nil || terminal_id.flatMap(UUID.init(uuidString:)) != nil else {
            localAgentSessionLogger.warning("Skipping malformed local agent session identity")
            return nil
        }
        let options: CodexLaunchOptions?
        do {
            options = try codex_launch_options.map { try JSONDecoder().decode(CodexLaunchOptions.self, from: Data($0.utf8)) }
        } catch {
            localAgentSessionLogger.warning("Skipping local agent session with unreadable launch options")
            return nil
        }
        return LocalAgentSession(
            id: id, worktreeID: worktreeID, terminalID: terminal_id.flatMap(UUID.init(uuidString:)),
            identity: AgentSessionIdentity(agentKind: kind, sessionID: session_id),
            transcriptPath: transcript_path, codexLaunchOptions: options,
            firstObservedAt: first_observed_at, lastObservedAt: last_observed_at)
    }

    /// Join the caller's accepted SessionStart transaction without nesting a write.
    static func upsert(_ model: LocalAgentSession, in db: GRDB.Database) throws {
        let record = try LocalAgentSessionRecord(from: model)
        // Raw SQL bindings bypass record date strategies. Numeric epochs retain
        // the accepted SessionStart's sub-millisecond ordering precision.
        try db.execute(sql: """
            INSERT INTO local_agent_session
                (id, worktree_id, terminal_id, agent_kind, session_id, transcript_path,
                 codex_launch_options, first_observed_at, last_observed_at)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(worktree_id, agent_kind, session_id) DO UPDATE SET
                terminal_id = excluded.terminal_id,
                transcript_path = excluded.transcript_path,
                codex_launch_options = excluded.codex_launch_options,
                last_observed_at = excluded.last_observed_at
            """, arguments: [record.id, record.worktree_id, record.terminal_id,
                             record.agent_kind, record.session_id, record.transcript_path,
                             record.codex_launch_options,
                             record.first_observed_at.timeIntervalSince1970,
                             record.last_observed_at.timeIntervalSince1970])
    }

    /// Decode independently: one corrupt timestamp or column must cost only its row.
    static func decode(_ row: Row) -> LocalAgentSession? {
        do {
            return try LocalAgentSessionRecord(row: row).toModel()
        } catch {
            localAgentSessionLogger.warning("Skipping unreadable local agent session row")
            return nil
        }
    }
}

public struct LocalAgentSessionStore: Sendable {
    let writer: any DatabaseWriter

    init(writer: any DatabaseWriter) {
        self.writer = writer
    }

    public func list(worktreeID: UUID) async throws -> [LocalAgentSession] {
        // The migration retains legacy text dates; live observations use numeric
        // epochs. Normalize text for ordering without rewriting existing rows.
        try await writer.read { db in
            try Row.fetchAll(db, sql: """
                SELECT * FROM local_agent_session WHERE worktree_id = ?
                ORDER BY CASE typeof(first_observed_at)
                    WHEN 'text' THEN CAST(strftime('%s', first_observed_at) AS REAL)
                        + CAST(substr(strftime('%f', first_observed_at), 3) AS REAL)
                    ELSE first_observed_at END, id
                """, arguments: [worktreeID.uuidString]).compactMap(LocalAgentSessionRecord.decode)
        }
    }

    public func get(worktreeID: UUID, identity: AgentSessionIdentity) async throws -> LocalAgentSession? {
        try await writer.read { db in
            try Row.fetchOne(db, sql: """
                SELECT * FROM local_agent_session WHERE worktree_id = ? AND agent_kind = ? AND session_id = ?
                """, arguments: [worktreeID.uuidString, identity.agentKind.rawValue, identity.sessionID])
                .flatMap(LocalAgentSessionRecord.decode)
        }
    }

    public func upsert(_ session: LocalAgentSession) async throws {
        try await writer.write { db in
            try LocalAgentSessionRecord.upsert(session, in: db)
        }
    }
}
