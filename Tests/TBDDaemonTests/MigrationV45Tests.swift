import Testing
import Foundation
import GRDB
@testable import TBDDaemonLib
@testable import TBDShared

@Suite struct MigrationV45Tests {

    @Test func controlModeColumnExists() async throws {
        let db = try TBDDatabase(inMemory: true)
        try await db.writerForTests.read { dbConn in
            let columns = try Row.fetchAll(dbConn, sql: "PRAGMA table_info(config)")
            let names = columns.compactMap { $0["name"] as String? }
            #expect(names.contains("control_mode_enabled"))
        }
    }

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
