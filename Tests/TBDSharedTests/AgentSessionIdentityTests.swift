import Foundation
import Testing
@testable import TBDShared

@Suite struct AgentSessionIdentityTests {
    @Test func providerSeparatesNativeSessionCacheKeys() {
        let claude = AgentSessionIdentity(agentKind: .claude, sessionID: "same")
        let codex = AgentSessionIdentity(agentKind: .codex, sessionID: "same")
        #expect(claude.cacheKey == "local-agent:claude:same")
        #expect(codex.cacheKey == "local-agent:codex:same")
        #expect(Set([claude, codex]).count == 2)
    }

    @Test func archiveRoundTripsLaunchMetadataAndOverridesLegacySessions() throws {
        let tab = ArchivedAgentTab(
            identity: AgentSessionIdentity(agentKind: .codex, sessionID: "thread"),
            label: "Review", ordinal: 3, isPrimary: true, profileID: UUID(),
            claudeSpawnExtras: ClaudeSpawnExtras(pluginDirs: ["/synthetic/plugin"]),
            codexLaunchOptions: CodexLaunchOptions(model: "acme-model", disabledFeatures: ["browser_use"],
                                                  codexHome: "/synthetic/codex"))
        var worktree = makeWorktree()
        worktree.archivedClaudeSessions = ["legacy"]
        worktree.archivedAgentTabs = [tab]
        let read = try JSONDecoder().decode(Worktree.self, from: JSONEncoder().encode(worktree))
        #expect(read.archivedAgentTabs == [tab])
        #expect(read.resolvedArchivedAgentTabs == [tab])
        worktree.archivedAgentTabs = []
        #expect(worktree.resolvedArchivedAgentTabs.isEmpty)
    }

    @Test func legacyWirePayloadSynthesizesOrderedClaudeTabsWithExtras() throws {
        var worktree = makeWorktree()
        worktree.archivedClaudeSessions = ["second", "first"]
        worktree.archivedClaudeSpawnExtras = ["first": ClaudeSpawnExtras(pluginDirs: ["/synthetic/plugin"])]
        var payload = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(worktree)) as? [String: Any])
        payload.removeValue(forKey: "archivedAgentTabs")
        let read = try JSONDecoder().decode(Worktree.self, from: JSONSerialization.data(withJSONObject: payload))
        #expect(read.archivedAgentTabs == nil)
        #expect(read.resolvedArchivedAgentTabs == [
            ArchivedAgentTab(identity: AgentSessionIdentity(agentKind: .claude, sessionID: "second"),
                             label: nil, ordinal: 0, isPrimary: true, profileID: nil,
                             claudeSpawnExtras: nil, codexLaunchOptions: nil),
            ArchivedAgentTab(identity: AgentSessionIdentity(agentKind: .claude, sessionID: "first"),
                             label: nil, ordinal: 1, isPrimary: false, profileID: nil,
                             claudeSpawnExtras: ClaudeSpawnExtras(pluginDirs: ["/synthetic/plugin"]),
                             codexLaunchOptions: nil)
        ])
        #expect(makeWorktree().resolvedArchivedAgentTabs.isEmpty)
    }

    private func makeWorktree() -> Worktree {
        Worktree(repoID: nil, name: "acme", displayName: "Acme", branch: "main",
                 path: "/synthetic/worktree", tmuxServer: "tbd-test")
    }
}
