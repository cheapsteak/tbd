import Testing
import Foundation
@testable import TBDDaemonLib
@testable import TBDShared

@Suite("ConfigStore")
struct ConfigStoreTests {
    @Test func defaultsToNil() async throws {
        let db = try TBDDatabase(inMemory: true)
        let cfg = try await db.config.get()
        #expect(cfg.defaultProfileID == nil)
    }

    @Test func setAndGetDefaultClaudeTokenID() async throws {
        let db = try TBDDatabase(inMemory: true)
        let tok = try await db.modelProfiles.create(name: "Personal", kind: .oauth)
        try await db.config.setDefaultProfileID(tok.id)
        let cfg = try await db.config.get()
        #expect(cfg.defaultProfileID == tok.id)
    }

    @Test func clearDefaultClaudeTokenID() async throws {
        let db = try TBDDatabase(inMemory: true)
        let tok = try await db.modelProfiles.create(name: "Personal", kind: .oauth)
        try await db.config.setDefaultProfileID(tok.id)
        try await db.config.setDefaultProfileID(nil)
        let cfg = try await db.config.get()
        #expect(cfg.defaultProfileID == nil)
    }
}
