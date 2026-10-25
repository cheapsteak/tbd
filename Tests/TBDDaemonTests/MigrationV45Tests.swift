import Testing
import Foundation
@testable import TBDDaemonLib
@testable import TBDShared

@Suite struct MigrationV45Tests {

    @Test func controlModeDefaultsToFalse() async throws {
        let db = try TBDDatabase(inMemory: true)
        let cfg = try await db.config.get()
        #expect(cfg.controlModeEnabled == false)
    }

    @Test func setControlModeEnabledRoundTrips() async throws {
        let db = try TBDDatabase(inMemory: true)
        try await db.config.setControlModeEnabled(true)
        #expect(try await db.config.get().controlModeEnabled == true)
        try await db.config.setControlModeEnabled(false)
        #expect(try await db.config.get().controlModeEnabled == false)
    }

    /// Codable back-compat: JSON from a pre-v45 daemon (no key) must decode
    /// with the field defaulting to false.
    @Test func configJSONWithoutKeyDecodesToFalse() throws {
        let json = Data(#"{"envSettingOverrides":{},"envOverrides":{}}"#.utf8)
        let cfg = try JSONDecoder().decode(Config.self, from: json)
        #expect(cfg.controlModeEnabled == false)
    }
}
