import Foundation
import GRDB
import TBDShared

public struct WatchDeskLease: Codable, Sendable, Equatable {
    public let worktreeID: UUID
    public let terminalID: UUID
    public let token: UUID
    public let generation: Int64
    public let acquiredAt: Date
    public let renewedAt: Date
    public let expiresAt: Date

    public func isValid(at date: Date) -> Bool { expiresAt > date }
}

public enum WatchDeskLeaseError: Error, LocalizedError, Equatable {
    case contended(holder: UUID, generation: Int64, expiresAt: Date)
    case notHeld
    case fenced
    case terminalNotFound
    case terminalOutsideDesk

    public var errorDescription: String? {
        switch self {
        case .contended(let holder, let generation, let expiry):
            return "Watch Desk judge lease is held by terminal \(holder) at generation \(generation) until \(expiry)"
        case .notHeld: return "Watch Desk judge lease is not held"
        case .fenced: return "Watch Desk judge lease credentials are stale"
        case .terminalNotFound: return "Watch Desk terminal not found"
        case .terminalOutsideDesk: return "Terminal does not belong to this Watch Desk"
        }
    }
}

private struct WatchDeskLeaseRecord: Codable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "watch_desk_judge_lease"
    var worktree_id: String
    var terminal_id: String
    var token: String
    var generation: Int64
    var acquired_at: Date
    var renewed_at: Date
    var expires_at: Date

    func model() -> WatchDeskLease? {
        guard let worktreeID = UUID(uuidString: worktree_id),
              let terminalID = UUID(uuidString: terminal_id),
              let token = UUID(uuidString: token) else { return nil }
        return WatchDeskLease(
            worktreeID: worktreeID, terminalID: terminalID, token: token,
            generation: generation, acquiredAt: acquired_at,
            renewedAt: renewed_at, expiresAt: expires_at)
    }
}

public struct WatchDeskLeaseStore: Sendable {
    /// Longer than both the 15-minute scheduler interval and the 10-minute
    /// overlap guard. The daemon refreshes it on every heartbeat; an agent also
    /// renews immediately before a mutation.
    public static let defaultLifetime: TimeInterval = 20 * 60
    let writer: any DatabaseWriter

    init(writer: any DatabaseWriter) { self.writer = writer }

    public func status(worktreeID: UUID) async throws -> WatchDeskLease? {
        try await writer.read { db in
            try WatchDeskLeaseRecord.fetchOne(db, key: worktreeID.uuidString)?.model()
        }
    }

    /// Acquires an absent/expired lease. An unexpired holder must authenticate
    /// through renew instead. Every takeover increments generation.
    public func acquire(
        worktreeID: UUID, terminalID: UUID, now: Date = Date(),
        lifetime: TimeInterval = defaultLifetime,
        token: UUID = UUID()
    ) async throws -> WatchDeskLease {
        try await writer.write { db in
            try Self.requireTerminal(terminalID, belongsTo: worktreeID, db: db)
            let old = try WatchDeskLeaseRecord.fetchOne(db, key: worktreeID.uuidString)
            if let old, old.expires_at > now, old.terminal_id != terminalID.uuidString {
                guard let holder = UUID(uuidString: old.terminal_id) else { throw WatchDeskLeaseError.fenced }
                throw WatchDeskLeaseError.contended(
                    holder: holder, generation: old.generation, expiresAt: old.expires_at)
            }
            if let old, old.expires_at > now, old.terminal_id == terminalID.uuidString {
                guard let holder = UUID(uuidString: old.terminal_id) else {
                    throw WatchDeskLeaseError.fenced
                }
                // Acquire is recovery, not an unauthenticated renewal path.
                throw WatchDeskLeaseError.contended(
                    holder: holder, generation: old.generation, expiresAt: old.expires_at)
            }
            let generation = (old?.generation ?? 0) + 1
            let record = WatchDeskLeaseRecord(
                worktree_id: worktreeID.uuidString,
                terminal_id: terminalID.uuidString,
                token: token.uuidString,
                generation: generation,
                acquired_at: now,
                renewed_at: now,
                expires_at: now.addingTimeInterval(lifetime))
            try record.save(db)
            try Self.setRoles(owner: terminalID, worktreeID: worktreeID, db: db)
            return record.model()!
        }
    }

    public func validate(
        worktreeID: UUID, terminalID: UUID, token: UUID, generation: Int64,
        now: Date = Date()
    ) async throws -> WatchDeskLease {
        try await writer.read { db in
            guard let record = try WatchDeskLeaseRecord.fetchOne(db, key: worktreeID.uuidString) else {
                throw WatchDeskLeaseError.notHeld
            }
            guard record.terminal_id == terminalID.uuidString,
                  record.token == token.uuidString,
                  record.generation == generation,
                  record.expires_at > now else { throw WatchDeskLeaseError.fenced }
            return record.model()!
        }
    }

    public func renew(
        worktreeID: UUID, terminalID: UUID, token: UUID, generation: Int64,
        now: Date = Date(), lifetime: TimeInterval = defaultLifetime
    ) async throws -> WatchDeskLease {
        try await writer.write { db in
            guard var record = try WatchDeskLeaseRecord.fetchOne(db, key: worktreeID.uuidString) else {
                throw WatchDeskLeaseError.notHeld
            }
            guard record.terminal_id == terminalID.uuidString,
                  record.token == token.uuidString,
                  record.generation == generation,
                  record.expires_at > now else { throw WatchDeskLeaseError.fenced }
            record.renewed_at = now
            record.expires_at = now.addingTimeInterval(lifetime)
            try record.update(db)
            // Terminals can be created after acquisition. Reassert roles on
            // renewal so every additional desk agent is visibly read-only.
            try Self.setRoles(owner: terminalID, worktreeID: worktreeID, db: db)
            return record.model()!
        }
    }

    public func transfer(
        worktreeID: UUID, fromTerminalID: UUID, toTerminalID: UUID,
        token: UUID, generation: Int64, now: Date = Date(),
        lifetime: TimeInterval = defaultLifetime,
        replacementToken: UUID = UUID()
    ) async throws -> WatchDeskLease {
        try await writer.write { db in
            try Self.requireTerminal(toTerminalID, belongsTo: worktreeID, db: db)
            guard var record = try WatchDeskLeaseRecord.fetchOne(db, key: worktreeID.uuidString) else {
                throw WatchDeskLeaseError.notHeld
            }
            guard record.terminal_id == fromTerminalID.uuidString,
                  record.token == token.uuidString,
                  record.generation == generation,
                  record.expires_at > now else { throw WatchDeskLeaseError.fenced }
            record.terminal_id = toTerminalID.uuidString
            record.token = replacementToken.uuidString
            record.generation += 1
            record.acquired_at = now
            record.renewed_at = now
            record.expires_at = now.addingTimeInterval(lifetime)
            try record.update(db)
            try Self.setRoles(owner: toTerminalID, worktreeID: worktreeID, db: db)
            return record.model()!
        }
    }

    public func release(
        worktreeID: UUID, terminalID: UUID, token: UUID, generation: Int64
    ) async throws {
        try await writer.write { db in
            guard let record = try WatchDeskLeaseRecord.fetchOne(db, key: worktreeID.uuidString) else {
                throw WatchDeskLeaseError.notHeld
            }
            guard record.terminal_id == terminalID.uuidString,
                  record.token == token.uuidString,
                  record.generation == generation else { throw WatchDeskLeaseError.fenced }
            var tombstone = record
            tombstone.expires_at = Date.distantPast
            try tombstone.update(db)
            try db.execute(
                sql: "UPDATE terminal SET watch_desk_role = NULL WHERE worktreeID = ?",
                arguments: [worktreeID.uuidString])
        }
    }

    public func revoke(worktreeID: UUID) async throws {
        try await writer.write { db in
            if var record = try WatchDeskLeaseRecord.fetchOne(db, key: worktreeID.uuidString) {
                record.expires_at = Date.distantPast
                try record.update(db)
            }
            try db.execute(
                sql: "UPDATE terminal SET watch_desk_role = NULL WHERE worktreeID = ?",
                arguments: [worktreeID.uuidString])
        }
    }

    private static func requireTerminal(_ id: UUID, belongsTo worktreeID: UUID, db: Database) throws {
        guard let terminal = try TerminalRecord.fetchOne(db, key: id.uuidString) else {
            throw WatchDeskLeaseError.terminalNotFound
        }
        guard terminal.worktreeID == worktreeID.uuidString else {
            throw WatchDeskLeaseError.terminalOutsideDesk
        }
    }

    private static func setRoles(owner: UUID, worktreeID: UUID, db: Database) throws {
        try db.execute(
            sql: "UPDATE terminal SET watch_desk_role = CASE WHEN id = ? THEN ? ELSE ? END WHERE worktreeID = ?",
            arguments: [owner.uuidString, WatchDeskRole.judge.rawValue,
                        WatchDeskRole.readOnlyCoordinator.rawValue, worktreeID.uuidString])
    }
}
