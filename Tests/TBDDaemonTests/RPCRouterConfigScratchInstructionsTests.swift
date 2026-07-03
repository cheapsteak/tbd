import Testing
import Foundation
@testable import TBDDaemonLib
@testable import TBDShared

// config.setScratchInstructions RPC handler, mirroring the round-trip style
// of RPCRouterEnvOverridesTests.
extension RPCRouterTests {

    @Test("config.setScratchInstructions persists the custom instructions")
    func configSetScratchInstructions() async throws {
        let request = try RPCRequest(
            method: RPCMethod.configSetScratchInstructions,
            params: ConfigSetScratchInstructionsParams(instructions: "Always use uv, never pip.")
        )
        let response = await router.handle(request)
        #expect(response.success)

        let config = try await db.config.get()
        #expect(config.scratchInstructions == "Always use uv, never pip.")
    }

    @Test("config.setScratchInstructions with whitespace-only value resets to nil")
    func configSetScratchInstructionsWhitespaceResetsToNil() async throws {
        try await db.config.setScratchInstructions("Always use uv, never pip.")

        let request = try RPCRequest(
            method: RPCMethod.configSetScratchInstructions,
            params: ConfigSetScratchInstructionsParams(instructions: "   \n  ")
        )
        let response = await router.handle(request)
        #expect(response.success)

        let config = try await db.config.get()
        #expect(config.scratchInstructions == nil)
    }
}
