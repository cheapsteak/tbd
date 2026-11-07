import Foundation
import GRDB
import Testing
import DaemonTestSupport

@testable import TBDDaemonLib
@testable import TBDShared

@Suite("PhoneDeviceStore")
struct PhoneDeviceStoreTests {

    private func make(
        id: UUID = UUID(), name: String = "Phone", room: String = UUID().uuidString,
        pairedAt: TimeInterval = 1_800_000_000
    ) -> PhoneDevice {
        PhoneDevice(
            id: id, name: name, publicKey: Data(repeating: 7, count: 32),
            roomID: room, pairedAt: Date(timeIntervalSince1970: pairedAt))
    }

    @Test func insertListAndLookUp() async throws {
        let db = try TBDDatabase(inMemory: true)
        let newer = make(name: "Newer", pairedAt: 1_800_000_100)
        let older = make(name: "Older", pairedAt: 1_800_000_000)
        try await db.phoneDevices.insert(newer)
        try await db.phoneDevices.insert(older)
        #expect(try await db.phoneDevices.list().map(\.id) == [older.id, newer.id])
        #expect(try await db.phoneDevices.device(roomID: newer.roomID) == newer)
        #expect(try await db.phoneDevices.device(id: older.id) == older)
        #expect(try await db.phoneDevices.device(id: UUID()) == nil)
    }

    @Test func deleteReportsWhetherARowWent() async throws {
        let db = try TBDDatabase(inMemory: true)
        let a = make()
        try await db.phoneDevices.insert(a)
        #expect(try await db.phoneDevices.delete(id: a.id) == true)
        #expect(try await db.phoneDevices.delete(id: a.id) == false)
    }

    @Test func touchLastSeenStampsTheGivenDate() async throws {
        let db = try TBDDatabase(inMemory: true)
        let a = make()
        try await db.phoneDevices.insert(a)
        let stamp = Date(timeIntervalSince1970: 1_800_000_500)
        try await db.phoneDevices.touchLastSeen(id: a.id, at: stamp)
        #expect(try await db.phoneDevices.device(id: a.id)?.lastSeenAt == stamp)
    }

    @Test func aRoomBelongsToOneDevice() async throws {
        let db = try TBDDatabase(inMemory: true)
        let a = make(room: "shared-room")
        let b = make(room: "shared-room")
        try await db.phoneDevices.insert(a)
        await #expect(throws: (any Error).self) { try await db.phoneDevices.insert(b) }
    }

    @Test func sharedModelDecodesWithOnlyAnID() throws {
        let json = #"{"id":"6F9619FF-8B86-D011-B42D-00C04FC964FF"}"#
        let d = try JSONDecoder().decode(PhoneDevice.self, from: Data(json.utf8))
        #expect(d.name == "Phone")
        #expect(d.publicKey.isEmpty)
        #expect(d.roomID == "")
        #expect(d.lastSeenAt == nil)
    }

    @Test func aRowWithABadIDIsSkipped() async throws {
        let db = try TBDDatabase(inMemory: true)
        try await db.writerForTests.write { conn in
            try conn.execute(
                sql: """
                    INSERT INTO phone_device (id, name, public_key, room_id, paired_at)
                    VALUES ('not-a-uuid', 'Bad', x'00', 'bad-room', ?)
                    """,
                arguments: [Date(timeIntervalSince1970: 1_700_000_000)])
        }
        let good = make()
        try await db.phoneDevices.insert(good)
        #expect(try await db.phoneDevices.list().map(\.id) == [good.id])
    }
}
