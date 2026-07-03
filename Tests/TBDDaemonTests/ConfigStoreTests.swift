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
        #expect(cfg.primaryAgentPreference == .claude)
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

    @Test func envOverridesDefaultEmpty() async throws {
        let db = try TBDDatabase(inMemory: true)
        let cfg = try await db.config.get()
        #expect(cfg.envSettingOverrides.isEmpty)
    }

    @Test func setAndGetEnvOverrides() async throws {
        let db = try TBDDatabase(inMemory: true)
        try await db.config.setEnvSettingOverrides(["fullscreenRendering": .bool(false)])
        let cfg = try await db.config.get()
        #expect(cfg.envSettingOverrides["fullscreenRendering"] == .bool(false))
    }

    @Test func overwriteEnvOverrides() async throws {
        let db = try TBDDatabase(inMemory: true)
        try await db.config.setEnvSettingOverrides(["fullscreenRendering": .bool(false)])
        try await db.config.setEnvSettingOverrides([:])
        let cfg = try await db.config.get()
        #expect(cfg.envSettingOverrides.isEmpty)
    }

    @Test func setAndGetPrimaryAgentPreference() async throws {
        let db = try TBDDatabase(inMemory: true)
        try await db.config.setPrimaryAgentPreference(.codex)
        let cfg = try await db.config.get()
        #expect(cfg.primaryAgentPreference == .codex)
    }

    @Test func scratchInstructionsDefaultsToNil() async throws {
        let db = try TBDDatabase(inMemory: true)
        let cfg = try await db.config.get()
        #expect(cfg.scratchInstructions == nil)
    }

    @Test func setAndGetScratchInstructions() async throws {
        let db = try TBDDatabase(inMemory: true)
        try await db.config.setScratchInstructions("Always use uv, never pip.")
        let cfg = try await db.config.get()
        #expect(cfg.scratchInstructions == "Always use uv, never pip.")
    }

    @Test func setScratchInstructionsWhitespaceResetsToNil() async throws {
        let db = try TBDDatabase(inMemory: true)
        try await db.config.setScratchInstructions("   \n  ")
        let cfg = try await db.config.get()
        #expect(cfg.scratchInstructions == nil)
    }

    @Test func setScratchInstructionsNilResetsToNil() async throws {
        let db = try TBDDatabase(inMemory: true)
        try await db.config.setScratchInstructions("Always use uv, never pip.")
        try await db.config.setScratchInstructions(nil)
        let cfg = try await db.config.get()
        #expect(cfg.scratchInstructions == nil)
    }

    @Test func scratchRenamePromptDefaultsToNil() async throws {
        let db = try TBDDatabase(inMemory: true)
        let cfg = try await db.config.get()
        #expect(cfg.scratchRenamePrompt == nil)
    }

    @Test func setAndGetScratchRenamePrompt() async throws {
        let db = try TBDDatabase(inMemory: true)
        try await db.config.setScratchRenamePrompt("Rename it once it has a clear purpose.")
        let cfg = try await db.config.get()
        #expect(cfg.scratchRenamePrompt == "Rename it once it has a clear purpose.")
    }

    @Test func setScratchRenamePromptWhitespaceResetsToNil() async throws {
        let db = try TBDDatabase(inMemory: true)
        try await db.config.setScratchRenamePrompt("   \n  ")
        let cfg = try await db.config.get()
        #expect(cfg.scratchRenamePrompt == nil)
    }

    @Test func setScratchRenamePromptNilResetsToNil() async throws {
        let db = try TBDDatabase(inMemory: true)
        try await db.config.setScratchRenamePrompt("Rename it once it has a clear purpose.")
        try await db.config.setScratchRenamePrompt(nil)
        let cfg = try await db.config.get()
        #expect(cfg.scratchRenamePrompt == nil)
    }

    @Test func scratchProfileOverrideIDDefaultsToNil() async throws {
        let db = try TBDDatabase(inMemory: true)
        let cfg = try await db.config.get()
        #expect(cfg.scratchProfileOverrideID == nil)
    }

    @Test func setAndGetScratchProfileOverride() async throws {
        let db = try TBDDatabase(inMemory: true)
        let tok = try await db.modelProfiles.create(name: "Personal", kind: .oauth)
        try await db.config.setScratchProfileOverride(tok.id)
        let cfg = try await db.config.get()
        #expect(cfg.scratchProfileOverrideID == tok.id)
    }

    @Test func clearScratchProfileOverride() async throws {
        let db = try TBDDatabase(inMemory: true)
        let tok = try await db.modelProfiles.create(name: "Personal", kind: .oauth)
        try await db.config.setScratchProfileOverride(tok.id)
        try await db.config.setScratchProfileOverride(nil)
        let cfg = try await db.config.get()
        #expect(cfg.scratchProfileOverrideID == nil)
    }
}
