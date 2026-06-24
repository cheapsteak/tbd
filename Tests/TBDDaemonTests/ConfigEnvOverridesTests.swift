import Testing
@testable import TBDDaemonLib

@Suite("config env_overrides")
struct ConfigEnvOverridesTests {
    @Test func defaultsEmpty() async throws {
        let db = try TBDDatabase(inMemory: true)
        let cfg = try await db.config.get()
        #expect(cfg.envOverrides.isEmpty)
    }

    @Test func configEnvOverridesRoundTrip() async throws {
        let db = try TBDDatabase(inMemory: true)
        try await db.config.setEnvOverrides(["CLAUDE_CODE_USE_BEDROCK": "1"])
        let cfg = try await db.config.get()
        #expect(cfg.envOverrides == ["CLAUDE_CODE_USE_BEDROCK": "1"])
    }
}
