import Testing
import Foundation
@testable import TBDDaemonLib
@testable import TBDShared

// config.setScratchRenamePrompt and config.setScratchProfileOverride RPC
// handlers, mirroring the round-trip style of
// RPCRouterConfigScratchInstructionsTests.
extension RPCRouterTests {

    @Test("config.setScratchRenamePrompt persists the custom rename prompt")
    func configSetScratchRenamePrompt() async throws {
        let request = try RPCRequest(
            method: RPCMethod.configSetScratchRenamePrompt,
            params: ConfigSetScratchRenamePromptParams(renamePrompt: "Rename it once it has a clear purpose.")
        )
        let response = await router.handle(request)
        #expect(response.success)

        let config = try await db.config.get()
        #expect(config.scratchRenamePrompt == "Rename it once it has a clear purpose.")
    }

    @Test("config.setScratchRenamePrompt with whitespace-only value resets to nil")
    func configSetScratchRenamePromptWhitespaceResetsToNil() async throws {
        try await db.config.setScratchRenamePrompt("Rename it once it has a clear purpose.")

        let request = try RPCRequest(
            method: RPCMethod.configSetScratchRenamePrompt,
            params: ConfigSetScratchRenamePromptParams(renamePrompt: "   \n  ")
        )
        let response = await router.handle(request)
        #expect(response.success)

        let config = try await db.config.get()
        #expect(config.scratchRenamePrompt == nil)
    }

    @Test("config.setScratchProfileOverride persists the profile override")
    func configSetScratchProfileOverride() async throws {
        let tok = try await db.modelProfiles.create(name: "Personal", kind: .oauth)

        let request = try RPCRequest(
            method: RPCMethod.configSetScratchProfileOverride,
            params: ConfigSetScratchProfileOverrideParams(profileID: tok.id)
        )
        let response = await router.handle(request)
        #expect(response.success)

        let config = try await db.config.get()
        #expect(config.scratchProfileOverrideID == tok.id)
    }

    @Test("config.setScratchProfileOverride with nil clears the override")
    func configSetScratchProfileOverrideNilClears() async throws {
        let tok = try await db.modelProfiles.create(name: "Personal", kind: .oauth)
        try await db.config.setScratchProfileOverride(tok.id)

        let request = try RPCRequest(
            method: RPCMethod.configSetScratchProfileOverride,
            params: ConfigSetScratchProfileOverrideParams(profileID: nil)
        )
        let response = await router.handle(request)
        #expect(response.success)

        let config = try await db.config.get()
        #expect(config.scratchProfileOverrideID == nil)
    }
}
