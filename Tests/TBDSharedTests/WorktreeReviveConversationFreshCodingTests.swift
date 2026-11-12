import Foundation
import Testing
@testable import TBDShared

@Suite("Revive conversation fresh RPC coding")
struct ReviveFreshRPCCodingTests {
    @Test(arguments: ["claude", "codex"])
    func providerIdentitySurvivesCoding(agent: String) throws {
        let json = """
        {"archivedWorktreeID":"11111111-2222-3333-4444-555555555555","sessionID":"legacy-id",
         "identity":{"agentKind":"\(agent)","sessionID":"native-id"}}
        """
        let value = try JSONDecoder().decode(WorktreeReviveConversationFreshParams.self, from: Data(json.utf8))
        let object = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(value)) as? [String: Any])
        let identity = try #require(object["identity"] as? [String: String])
        #expect(identity == ["agentKind": agent, "sessionID": "native-id"])
        #expect(value.sessionID == "legacy-id")
        #expect(value.resolvedIdentity.agentKind.rawValue == agent)
        #expect(value.resolvedIdentity.sessionID == "native-id")
    }

    @Test func paramsRoundTrip() throws {
        let id = UUID(uuidString: "11111111-2222-3333-4444-555555555555")!
        let value = WorktreeReviveConversationFreshParams(
            archivedWorktreeID: id,
            sessionID: "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee",
            cols: 132,
            rows: 43
        )
        let decoded = try JSONDecoder().decode(
            WorktreeReviveConversationFreshParams.self,
            from: JSONEncoder().encode(value)
        )
        #expect(decoded.archivedWorktreeID == id)
        #expect(decoded.sessionID == value.sessionID)
        #expect(decoded.identity == nil)
        #expect(decoded.resolvedIdentity == AgentSessionIdentity(agentKind: .claude, sessionID: value.sessionID))
        #expect(decoded.cols == 132)
        #expect(decoded.rows == 43)
    }

    @Test func resultRoundTripPreservesWarning() throws {
        let worktree = Worktree(
            repoID: UUID(), name: "brisk-elk", displayName: "stale-owl (revived)",
            branch: "tbd/brisk-elk", path: "/tmp/brisk-elk", tmuxServer: "tbd-test"
        )
        let value = WorktreeReviveConversationFreshResult(
            worktree: worktree,
            warning: "Fetch failed; using origin/main at def5678."
        )
        let decoded = try JSONDecoder().decode(
            WorktreeReviveConversationFreshResult.self,
            from: JSONEncoder().encode(value)
        )
        #expect(decoded.worktree == worktree)
        #expect(decoded.warning == value.warning)
    }

    @Test func resultRoundTripPreservesNilWarning() throws {
        let worktree = Worktree(
            repoID: UUID(), name: "brisk-elk", displayName: "stale-owl (revived)",
            branch: "tbd/brisk-elk", path: "/tmp/brisk-elk", tmuxServer: "tbd-test"
        )
        let value = WorktreeReviveConversationFreshResult(worktree: worktree, warning: nil)
        let decoded = try JSONDecoder().decode(
            WorktreeReviveConversationFreshResult.self,
            from: JSONEncoder().encode(value)
        )
        #expect(decoded.worktree == worktree)
        #expect(decoded.warning == nil)
    }
}
