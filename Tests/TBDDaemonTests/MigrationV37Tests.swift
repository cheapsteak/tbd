import Testing
import Foundation
@testable import TBDDaemonLib

@Suite struct MigrationV37Tests {

    @Test func scratchRenamePromptDefaultsToNil() async throws {
        let db = try TBDDatabase(inMemory: true)
        let cfg = try await db.config.get()
        #expect(cfg.scratchRenamePrompt == nil)
    }

    @Test func scratchProfileOverrideIDDefaultsToNil() async throws {
        let db = try TBDDatabase(inMemory: true)
        let cfg = try await db.config.get()
        #expect(cfg.scratchProfileOverrideID == nil)
    }
}
