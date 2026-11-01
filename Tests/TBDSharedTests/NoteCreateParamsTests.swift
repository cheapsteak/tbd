import Testing
import Foundation
@testable import TBDShared

@Suite("NoteCreateParams")
struct NoteCreateParamsTests {
    /// A payload from a client that predates `title` has no such key and
    /// must still decode, with no title.
    @Test func decodesWhenTitleIsOmitted() throws {
        let id = UUID()
        let json = """
        {"worktreeID":"\(id.uuidString)"}
        """
        let decoded = try JSONDecoder().decode(NoteCreateParams.self, from: Data(json.utf8))
        #expect(decoded.worktreeID == id)
        #expect(decoded.title == nil)
    }

    @Test func roundTripsTitle() throws {
        let params = NoteCreateParams(worktreeID: UUID(), title: "Notes")
        let data = try JSONEncoder().encode(params)
        let decoded = try JSONDecoder().decode(NoteCreateParams.self, from: data)
        #expect(decoded.worktreeID == params.worktreeID)
        #expect(decoded.title == "Notes")
    }

    @Test func initDefaultsToNoTitle() {
        #expect(NoteCreateParams(worktreeID: UUID()).title == nil)
    }
}
