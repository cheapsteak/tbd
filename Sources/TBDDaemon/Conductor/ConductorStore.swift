import Foundation
import GRDB
import TBDShared

struct ConductorRecord: Codable, FetchableRecord, PersistableRecord, Sendable {
    static let databaseTableName = "conductor"

    var id: String
    var name: String
    var repos: String           // JSON array
    var worktrees: String?      // JSON array
    var terminalLabels: String? // JSON array
    var heartbeatIntervalMinutes: Int
    var terminalID: String?
    var worktreeID: String?
    var createdAt: Date

    init(from conductor: Conductor) {
        self.id = conductor.id.uuidString
        self.name = conductor.name
        self.repos = (try? String(data: JSONEncoder().encode(conductor.repos), encoding: .utf8)) ?? "[\"*\"]"
        if let wt = conductor.worktrees {
            self.worktrees = try? String(data: JSONEncoder().encode(wt), encoding: .utf8)
        }
        if let labels = conductor.terminalLabels {
            self.terminalLabels = try? String(data: JSONEncoder().encode(labels), encoding: .utf8)
        }
        self.heartbeatIntervalMinutes = conductor.heartbeatIntervalMinutes
        self.terminalID = conductor.terminalID?.uuidString
        self.worktreeID = conductor.worktreeID?.uuidString
        self.createdAt = conductor.createdAt
    }

    func toModel() -> Conductor {
        let reposList: [String] = {
            guard let data = repos.data(using: .utf8) else { return ["*"] }
            return (try? JSONDecoder().decode([String].self, from: data)) ?? ["*"]
        }()
        let worktreesList: [String]? = {
            guard let json = worktrees, let data = json.data(using: .utf8) else { return nil }
            return try? JSONDecoder().decode([String].self, from: data)
        }()
        let labelsList: [String]? = {
            guard let json = terminalLabels, let data = json.data(using: .utf8) else { return nil }
            return try? JSONDecoder().decode([String].self, from: data)
        }()
        return Conductor(
            id: UUID(uuidString: id)!,
            name: name,
            repos: reposList,
            worktrees: worktreesList,
            terminalLabels: labelsList,
            heartbeatIntervalMinutes: heartbeatIntervalMinutes,
            terminalID: terminalID.flatMap { UUID(uuidString: $0) },
            worktreeID: worktreeID.flatMap { UUID(uuidString: $0) },
            createdAt: createdAt
        )
    }
}

public struct ConductorStore: Sendable {
    let writer: any DatabaseWriter

    init(writer: any DatabaseWriter) {
        self.writer = writer
    }

    public func create(
        name: String,
        repos: [String],
        worktrees: [String]? = nil,
        terminalLabels: [String]? = nil,
        heartbeatIntervalMinutes: Int
    ) async throws -> Conductor {
        let conductor = Conductor(
            name: name,
            repos: repos,
            worktrees: worktrees,
            terminalLabels: terminalLabels,
            heartbeatIntervalMinutes: heartbeatIntervalMinutes
        )
        let record = ConductorRecord(from: conductor)

        try await writer.write { db in
            try record.insert(db)
        }
        return conductor
    }

    public func list() async throws -> [Conductor] {
        try await writer.read { db in
            try ConductorRecord.fetchAll(db).map { $0.toModel() }
        }
    }

    public func get(name: String) async throws -> Conductor? {
        try await writer.read { db in
            try ConductorRecord
                .filter(Column("name") == name)
                .fetchOne(db)?
                .toModel()
        }
    }

    public func get(id: UUID) async throws -> Conductor? {
        try await writer.read { db in
            try ConductorRecord.fetchOne(db, key: id.uuidString)?.toModel()
        }
    }

    public func delete(id: UUID) async throws {
        _ = try await writer.write { db in
            try ConductorRecord.deleteOne(db, key: id.uuidString)
        }
    }

    public func updateTerminalID(conductorID: UUID, terminalID: UUID?) async throws {
        try await writer.write { db in
            guard var record = try ConductorRecord.fetchOne(db, key: conductorID.uuidString) else {
                throw DatabaseError(message: "Conductor not found")
            }
            record.terminalID = terminalID?.uuidString
            try record.update(db)
        }
    }

    public func updateWorktreeID(conductorID: UUID, worktreeID: UUID?) async throws {
        try await writer.write { db in
            guard var record = try ConductorRecord.fetchOne(db, key: conductorID.uuidString) else {
                throw DatabaseError(message: "Conductor not found")
            }
            record.worktreeID = worktreeID?.uuidString
            try record.update(db)
        }
    }
}
