import Testing
import Foundation
@testable import TBDDaemonLib

@Suite struct TBDMetaStoreTests {
    @Test func roundTripsString() async throws {
        let db = try TBDDatabase(inMemory: true)
        try await db.meta.setString(key: "k", value: "hello")
        #expect(try await db.meta.getString(key: "k") == "hello")
    }

    @Test func roundTripsInt() async throws {
        let db = try TBDDatabase(inMemory: true)
        try await db.meta.setInt(key: "n", value: 42)
        #expect(try await db.meta.getInt(key: "n") == 42)
    }

    @Test func returnsNilForMissingKey() async throws {
        let db = try TBDDatabase(inMemory: true)
        #expect(try await db.meta.getString(key: "absent") == nil)
        #expect(try await db.meta.getInt(key: "absent") == nil)
    }

    @Test func upsertReplacesValue() async throws {
        let db = try TBDDatabase(inMemory: true)
        try await db.meta.setInt(key: "x", value: 1)
        try await db.meta.setInt(key: "x", value: 2)
        #expect(try await db.meta.getInt(key: "x") == 2)
    }
}
