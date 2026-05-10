import Foundation
import GRDB
import Testing
@testable import TBDDaemonLib

@Suite struct ChannelIndexStoreTests {

    private func makeStore() throws -> (ChannelIndexStore, TBDDatabase, String) {
        let dbPath = NSTemporaryDirectory() + "tbd-cix-\(UUID().uuidString).db"
        let db = try TBDDatabase(path: dbPath)
        return (db.channels, db, dbPath)
    }

    @Test func recordOnFirstPostCreatesRow() async throws {
        let (store, _, dbPath) = try makeStore()
        defer { try? FileManager.default.removeItem(atPath: dbPath) }

        let now = Date()
        try await store.recordPost(name: "help", at: now)

        let entries = try await store.list(includeArchived: false)
        #expect(entries.count == 1)
        #expect(entries.first?.name == "help")
        #expect(entries.first?.messageCount == 1)
    }

    @Test func recordOnSubsequentPostsIncrements() async throws {
        let (store, _, dbPath) = try makeStore()
        defer { try? FileManager.default.removeItem(atPath: dbPath) }

        try await store.recordPost(name: "help", at: Date())
        try await store.recordPost(name: "help", at: Date())
        try await store.recordPost(name: "help", at: Date())

        let entries = try await store.list(includeArchived: false)
        #expect(entries.first?.messageCount == 3)
    }

    @Test func listReturnsAllChannelsSortedByLastMessage() async throws {
        let (store, _, dbPath) = try makeStore()
        defer { try? FileManager.default.removeItem(atPath: dbPath) }

        let earlier = Date().addingTimeInterval(-100)
        let later = Date()
        try await store.recordPost(name: "old", at: earlier)
        try await store.recordPost(name: "new", at: later)

        let entries = try await store.list(includeArchived: false)
        #expect(entries.map(\.name) == ["new", "old"])
    }

    @Test func deleteRemovesRow() async throws {
        let (store, _, dbPath) = try makeStore()
        defer { try? FileManager.default.removeItem(atPath: dbPath) }

        try await store.recordPost(name: "help", at: Date())
        try await store.delete(name: "help")

        let entries = try await store.list(includeArchived: false)
        #expect(entries.isEmpty)
    }
}
