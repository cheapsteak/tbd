import Testing
import Foundation
@testable import TBDShared

@Suite struct AutoHibernateCodableTests {
    @Test func worktreeDefaultsToNilWhenKeyMissing() throws {
        // JSON without the new key must still decode (backward compat).
        let json = """
        {"id":"\(UUID().uuidString)","repoID":"\(UUID().uuidString)","name":"w",
         "displayName":"w","branch":"b","path":"/p","status":"active",
         "createdAt":0,"tmuxServer":"s"}
        """.data(using: .utf8)!
        let decoder = JSONDecoder()
        let wt = try decoder.decode(Worktree.self, from: json)
        #expect(wt.autoHibernateOnMerge == nil)
    }

    @Test func worktreeRoundTripsExplicitValues() throws {
        for value: Bool? in [nil, true, false] {
            var wt = Worktree(repoID: UUID(), name: "w", displayName: "w",
                              branch: "b", path: "/p", tmuxServer: "s")
            wt.autoHibernateOnMerge = value
            let data = try JSONEncoder().encode(wt)
            let back = try JSONDecoder().decode(Worktree.self, from: data)
            #expect(back.autoHibernateOnMerge == value)
        }
    }

    @Test func configDefaultsToFalseWhenKeyMissing() throws {
        let data = "{}".data(using: .utf8)!
        let cfg = try JSONDecoder().decode(Config.self, from: data)
        #expect(cfg.autoHibernateOnMergeDefault == false)
    }
}
