import Testing
import Foundation
@testable import TBDShared

@Suite struct WorktreeParentCodableTests {

    @Test func roundTripWithParent() throws {
        let parentID = UUID()
        let wt = Worktree(
            repoID: UUID(),
            name: "child",
            displayName: "child",
            branch: "tbd/child",
            path: "/tmp/child",
            tmuxServer: "srv",
            parentWorktreeID: parentID
        )
        let data = try JSONEncoder().encode(wt)
        let decoded = try JSONDecoder().decode(Worktree.self, from: data)
        #expect(decoded.parentWorktreeID == parentID)
    }

    @Test func decodesLegacyJSONWithoutParentField() throws {
        let legacy = """
        {
            "id": "\(UUID().uuidString)",
            "repoID": "\(UUID().uuidString)",
            "name": "legacy",
            "displayName": "legacy",
            "branch": "tbd/legacy",
            "path": "/tmp/legacy",
            "status": "active",
            "createdAt": 0,
            "tmuxServer": "srv"
        }
        """.data(using: .utf8)!
        let decoded = try JSONDecoder().decode(Worktree.self, from: legacy)
        #expect(decoded.parentWorktreeID == nil)
    }
}
