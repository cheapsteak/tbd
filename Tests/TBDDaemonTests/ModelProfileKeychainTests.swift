import Foundation
import Testing
@testable import TBDDaemonLib

@Suite("ModelProfileKeychain")
struct ModelProfileKeychainTests {

    private func freshID() -> String {
        "test-\(UUID().uuidString)"
    }

    @Test("store + load round-trip")
    func roundTrip() throws {
        let id = freshID()
        defer { try? ModelProfileKeychain.delete(id: id) }

        try ModelProfileKeychain.store(id: id, token: "sk-ant-secret-A")
        let loaded = try ModelProfileKeychain.load(id: id)
        #expect(loaded == "sk-ant-secret-A")
    }

    @Test("store overwrites existing (upsert)")
    func upsert() throws {
        let id = freshID()
        defer { try? ModelProfileKeychain.delete(id: id) }

        try ModelProfileKeychain.store(id: id, token: "value-A")
        try ModelProfileKeychain.store(id: id, token: "value-B")
        let loaded = try ModelProfileKeychain.load(id: id)
        #expect(loaded == "value-B")
    }

    @Test("delete removes item")
    func deleteRemoves() throws {
        let id = freshID()
        defer { try? ModelProfileKeychain.delete(id: id) }

        try ModelProfileKeychain.store(id: id, token: "to-be-deleted")
        try ModelProfileKeychain.delete(id: id)
        let loaded = try ModelProfileKeychain.load(id: id)
        #expect(loaded == nil)
    }

    @Test("delete of nonexistent id is idempotent")
    func deleteIdempotent() throws {
        let id = freshID()
        // No store; delete should not throw.
        try ModelProfileKeychain.delete(id: id)
    }

    @Test("load of nonexistent id returns nil")
    func loadMissing() throws {
        let id = freshID()
        let loaded = try ModelProfileKeychain.load(id: id)
        #expect(loaded == nil)
    }
}
