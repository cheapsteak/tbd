import Testing
import Foundation
@testable import TBDDaemonLib

@Suite struct MigrationV36Tests {

    @Test func scratchInstructionsDefaultsToNil() async throws {
        let db = try TBDDatabase(inMemory: true)
        let cfg = try await db.config.get()
        #expect(cfg.scratchInstructions == nil)
    }
}
