import Foundation
import Testing
@testable import TBDDaemonLib
import TestSupport

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

    // MARK: - storage directory honors the TBD_HOME fence

    /// Under a fenced run every token file lands inside `TBD_HOME`. Before
    /// this, the store was built straight from the home directory, so the
    /// tests above created and deleted real `<uuid>.token` files in the
    /// developer's own `~/.tbd/claude-tokens` on every run — invisible to the
    /// fingerprint as well, because `claude-tokens` is volatile-pruned.
    @Test("storage dir follows TBD_HOME when set")
    func storageDirFollowsTBDHome() {
        let dir = ModelProfileKeychain.storageDir(
            environment: ["TBD_HOME": "/tmp/acme-scratch-home"])
        #expect(dir.path == "/tmp/acme-scratch-home/claude-tokens")
    }

    /// The other branch. The production path MUST NOT move — existing entries
    /// are keyed by it — so with no override (and with an empty one, treated
    /// as no override) it stays the legacy `~/.tbd/claude-tokens`.
    @Test("storage dir is the legacy ~/.tbd path without an override")
    func storageDirUnchangedWithoutOverride() {
        let expected = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".tbd/claude-tokens", isDirectory: true).path
        #expect(ModelProfileKeychain.storageDir(environment: [:]).path == expected)
        #expect(ModelProfileKeychain.storageDir(environment: ["TBD_HOME": ""]).path == expected)
    }

    // MARK: - load falls back to the legacy path under an override

    /// `TBD_HOME` is a general redirect, not only the test fence —
    /// `scripts/mock.sh` exports it to run a real daemon and app. Without a
    /// fallback read, anyone in that situation loses sight of every stored
    /// token and is re-prompted to authenticate while the files sit on disk.
    @Test("load tries the legacy path when TBD_HOME is overridden")
    func loadCandidatesFallBackUnderOverride() {
        let id = "acme-profile"
        let candidates = ModelProfileKeychain.loadCandidates(
            id: id, environment: ["TBD_HOME": "/tmp/acme-scratch-home"])
        let legacy = ModelProfileKeychain.legacyStorageDir()
            .appendingPathComponent("\(id).token", isDirectory: false).path
        #expect(candidates.map(\.path) == [
            "/tmp/acme-scratch-home/claude-tokens/\(id).token",
            legacy
        ])
    }

    /// The other branch. With no override the resolved dir already IS the
    /// legacy dir, so there is exactly one candidate — a second, identical
    /// `stat` would be dead weight and would misrepresent the contract.
    @Test("load has a single candidate without an override")
    func loadCandidatesSingleWithoutOverride() {
        let id = "acme-profile"
        let legacy = ModelProfileKeychain.legacyStorageDir()
            .appendingPathComponent("\(id).token", isDirectory: false).path
        #expect(ModelProfileKeychain.loadCandidates(id: id, environment: [:]).map(\.path) == [legacy])
        #expect(ModelProfileKeychain.loadCandidates(
            id: id, environment: ["TBD_HOME": ""]).map(\.path) == [legacy])
    }

    // MARK: - an injected Store stays inside the home it was given

    /// The seam `RPCRouter` takes so `ModelProfileRPCTests` can run outside
    /// `TBDHomeSerialized`. Nothing else pins that a `Store` built with an
    /// environment resolves from it: if it fell back to the process
    /// environment, every test seeding and reading through one would still
    /// pass, because seed and read would still agree, and the suite would be
    /// back in the `TBD_HOME` race without a failing test to say so. So this
    /// looks for the file at the injected path itself.
    @Test("Store(environment:) writes, reads and deletes inside the home it was given")
    func injectedStoreStaysInItsHome() throws {
        let home = URL(fileURLWithPath: fencedScratchRoot(prefix: "tbdkc"), isDirectory: true)
        defer { try? FileManager.default.removeItem(at: home) }
        let store = ModelProfileKeychain.Store(environment: ["TBD_HOME": home.path])
        let id = freshID()
        let file = home.appendingPathComponent("claude-tokens/\(id).token", isDirectory: false)

        try store.store(id: id, token: "sk-ant-secret-C")
        #expect(FileManager.default.fileExists(atPath: file.path))
        let mode = (try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions]
            as? NSNumber).map { $0.int16Value & 0o777 }
        #expect(mode == 0o600)
        #expect(try store.load(id: id) == "sk-ant-secret-C")

        try store.delete(id: id)
        #expect(!FileManager.default.fileExists(atPath: file.path))
        #expect(try store.load(id: id) == nil)
    }
}
