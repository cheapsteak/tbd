import Testing
import Foundation
@testable import TBDDaemonLib
@testable import TBDShared

@Suite("ConfigStore")
struct ConfigStoreTests {
    @Test func defaultsToNil() async throws {
        let db = try TBDDatabase(inMemory: true)
        let cfg = try await db.config.get()
        #expect(cfg.defaultClaudeTokenID == nil)
    }

    @Test func setAndGetDefaultClaudeTokenID() async throws {
        let db = try TBDDatabase(inMemory: true)
        let tok = try await db.claudeTokens.create(name: "Personal", kind: .oauth)
        try await db.config.setDefaultClaudeTokenID(tok.id)
        let cfg = try await db.config.get()
        #expect(cfg.defaultClaudeTokenID == tok.id)
    }

    @Test func clearDefaultClaudeTokenID() async throws {
        let db = try TBDDatabase(inMemory: true)
        let tok = try await db.claudeTokens.create(name: "Personal", kind: .oauth)
        try await db.config.setDefaultClaudeTokenID(tok.id)
        try await db.config.setDefaultClaudeTokenID(nil)
        let cfg = try await db.config.get()
        #expect(cfg.defaultClaudeTokenID == nil)
    }
}
