import Testing
import Foundation
@testable import TBDShared

@Suite("WorktreeArchiveParams")
struct WorktreeArchiveParamsTests {
    /// A payload from a client that predates `discardUncommittedChanges` has
    /// no such key and must still decode.
    @Test func decodesWhenDiscardUncommittedChangesIsOmitted() throws {
        let id = UUID()
        let json = """
        {"worktreeID":"\(id.uuidString)","force":false}
        """
        let decoded = try JSONDecoder().decode(WorktreeArchiveParams.self, from: Data(json.utf8))
        #expect(decoded.worktreeID == id)
        #expect(decoded.force == false)
        #expect(decoded.discardUncommittedChanges == nil)
    }

    @Test func roundTripsDiscardUncommittedChanges() throws {
        let params = WorktreeArchiveParams(
            worktreeID: UUID(), force: false, discardUncommittedChanges: true)
        let data = try JSONEncoder().encode(params)
        let decoded = try JSONDecoder().decode(WorktreeArchiveParams.self, from: data)
        #expect(decoded.discardUncommittedChanges == true)
        #expect(decoded.force == false)
    }
}
