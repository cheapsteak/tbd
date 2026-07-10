import Testing
import Foundation
@testable import TBDShared

@Suite("ReapRecord model")
struct ReapRecordTests {
    @Test func roundTrips() throws {
        let rec = ReapRecord(kind: .agentWorktree, repoPath: "/r", worktreePath: "/r/.claude/worktrees/agent-x",
                             branch: "b", headSHA: "abc", snapshotRef: "refs/tbd/snapshots/agent-x-20260710",
                             apparentBytes: 1_200_000)
        let data = try JSONEncoder().encode(rec)
        let back = try JSONDecoder().decode(ReapRecord.self, from: data)
        #expect(back == rec)
    }
    @Test func configDecodesGCDefaultsWhenFieldsAbsent() throws {
        // Encode a current Config, strip the gc keys, decode — must apply defaults.
        var obj = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(Config())) as? [String: Any])
        obj.removeValue(forKey: "gcEnabled"); obj.removeValue(forKey: "gcGraceSeconds"); obj.removeValue(forKey: "gcSnapshotRetentionDays")
        let data = try JSONSerialization.data(withJSONObject: obj)
        let cfg = try JSONDecoder().decode(Config.self, from: data)
        #expect(cfg.gcEnabled == true)
        #expect(cfg.gcGraceSeconds == 3600)
        #expect(cfg.gcSnapshotRetentionDays == 30)
    }
}
