import Foundation
import Testing
@testable import TBDShared

@Suite("Worktree pinnedAt")
struct WorktreePinnedAtTests {
    private func makeWorktree(displayName: String = "wt",
                              repoID: UUID? = UUID(),
                              pinnedAt: Date? = nil) -> Worktree {
        Worktree(repoID: repoID, name: "wt", displayName: displayName,
                 branch: "b", path: "/tmp/wt", tmuxServer: "srv",
                 pinnedAt: pinnedAt)
    }

    @Test("pinnedAt defaults to nil")
    func defaultsToNil() {
        #expect(makeWorktree().pinnedAt == nil)
    }

    @Test("pinnedAt round-trips through Codable")
    func roundTrips() throws {
        let stamp = Date(timeIntervalSince1970: 1_700_000_000)
        let encoded = try JSONEncoder().encode(makeWorktree(pinnedAt: stamp))
        let decoded = try JSONDecoder().decode(Worktree.self, from: encoded)
        #expect(decoded.pinnedAt == stamp)
    }

    @Test("JSON written before this column still decodes")
    func decodesLegacyJSON() throws {
        // A payload with no pinnedAt key at all — the compatibility guarantee.
        let json = """
        {"id":"\(UUID().uuidString)","name":"wt","displayName":"wt","branch":"b",
         "path":"/tmp/wt","status":"active","createdAt":0,"tmuxServer":"srv"}
        """
        let decoded = try JSONDecoder().decode(Worktree.self, from: Data(json.utf8))
        #expect(decoded.pinnedAt == nil)
    }
}
