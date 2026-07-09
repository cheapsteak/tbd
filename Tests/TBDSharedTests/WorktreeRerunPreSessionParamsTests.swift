import Testing
import Foundation
@testable import TBDShared

@Suite("WorktreeRerunPreSessionParams")
struct WorktreeRerunPreSessionParamsTests {
    @Test func roundTripsColsAndRowsThroughJSON() throws {
        let id = UUID()
        let params = WorktreeRerunPreSessionParams(worktreeID: id, cols: 180, rows: 45)
        let data = try JSONEncoder().encode(params)
        let decoded = try JSONDecoder().decode(WorktreeRerunPreSessionParams.self, from: data)
        #expect(decoded.worktreeID == id)
        #expect(decoded.cols == 180)
        #expect(decoded.rows == 45)
    }

    /// Backward compatibility: an older app build's JSON has no `cols`/`rows`
    /// keys at all. `cols`/`rows` must decode to nil rather than failing, so
    /// old app + new daemon (or vice versa) keeps working — see the repo's
    /// CLAUDE.md rule that shared Codable model fields must be optional or
    /// defaulted.
    @Test func decodesWhenColsAndRowsAreOmitted() throws {
        let id = UUID()
        let json = """
        {"worktreeID":"\(id.uuidString)"}
        """
        let decoded = try JSONDecoder().decode(
            WorktreeRerunPreSessionParams.self, from: Data(json.utf8)
        )
        #expect(decoded.worktreeID == id)
        #expect(decoded.cols == nil)
        #expect(decoded.rows == nil)
    }
}
