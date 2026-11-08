import Foundation
import GRDB
import TBDShared

/// GRDB row for the `phone_device` table.
struct PhoneDeviceRecord: Codable, FetchableRecord, PersistableRecord, Sendable {
    static let databaseTableName = "phone_device"

    var id: String
    var name: String
    var public_key: Data
    var room_id: String
    var paired_at: Date
    var last_seen_at: Date?

    init(from model: PhoneDevice) {
        self.id = model.id.uuidString
        self.name = model.name
        self.public_key = model.publicKey
        self.room_id = model.roomID
        self.paired_at = model.pairedAt
        self.last_seen_at = model.lastSeenAt
    }

    /// Nil when `id` is not a UUID: such a row is skipped rather than crashing
    /// the listing.
    func toModel() -> PhoneDevice? {
        guard let uuid = UUID(uuidString: id) else { return nil }
        return PhoneDevice(
            id: uuid, name: name, publicKey: public_key, roomID: room_id,
            pairedAt: paired_at, lastSeenAt: last_seen_at)
    }
}

/// Reads and writes the phones paired with this laptop.
public struct PhoneDeviceStore: Sendable {
    let writer: any DatabaseWriter

    init(writer: any DatabaseWriter) {
        self.writer = writer
    }

    /// Insert a paired phone. Throws when the id or the room already exists.
    public func insert(_ device: PhoneDevice) async throws {
        let row = PhoneDeviceRecord(from: device)
        try await writer.write { db in
            try row.insert(db)
        }
    }

    /// Every paired phone, oldest pairing first, then by id.
    public func list() async throws -> [PhoneDevice] {
        try await writer.read { db in
            try PhoneDeviceRecord
                .order(Column("paired_at"), Column("id"))
                .fetchAll(db)
                .compactMap { $0.toModel() }
        }
    }

    public func device(id: UUID) async throws -> PhoneDevice? {
        try await writer.read { db in
            try PhoneDeviceRecord.fetchOne(db, key: id.uuidString)?.toModel()
        }
    }

    public func device(roomID: String) async throws -> PhoneDevice? {
        try await writer.read { db in
            try PhoneDeviceRecord
                .filter(Column("room_id") == roomID)
                .fetchOne(db)?
                .toModel()
        }
    }

    /// Delete one phone. Returns whether a row went.
    @discardableResult
    public func delete(id: UUID) async throws -> Bool {
        try await writer.write { db in
            try db.execute(
                sql: "DELETE FROM phone_device WHERE id = ?",
                arguments: [id.uuidString])
            return db.changesCount > 0
        }
    }

    /// Stamp the last time this phone was seen. `date` is a seam for tests.
    public func touchLastSeen(id: UUID, at date: Date = Date()) async throws {
        try await writer.write { db in
            try db.execute(
                sql: "UPDATE phone_device SET last_seen_at = ? WHERE id = ?",
                arguments: [date, id.uuidString])
        }
    }
}
