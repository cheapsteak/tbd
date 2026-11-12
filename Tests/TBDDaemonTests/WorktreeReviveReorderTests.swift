import Foundation
import Testing
import GRDB
import DaemonTestSupport
import TestSupport
@testable import TBDDaemonLib
import TBDShared

extension TBDHomeSerialized {
@Suite("WorktreeReviveReorderTests")
struct MixedReviveSelectionTests {
    @Test func primaryAndPreferredOrderingPreserveOriginalOrdinals() {
        let tabs = [
            ArchivedAgentTab(identity: .init(agentKind: .codex, sessionID: "shared-id"), ordinal: 0, isPrimary: false),
            ArchivedAgentTab(identity: .init(agentKind: .claude, sessionID: "shared-id"), ordinal: 2, isPrimary: true),
            ArchivedAgentTab(identity: .init(agentKind: .codex, sessionID: "C"), ordinal: 3, isPrimary: false)
        ]
        #expect(orderedArchivedAgentTabs(tabs).map(\.ordinal) == [2, 0, 3])
        #expect(preferredArchivedAgentTabs(tabs, preferred: nil) == tabs)
        #expect(preferredArchivedAgentTabs(tabs, preferred: .init(agentKind: .claude, sessionID: "unknown")) == tabs)
        let preferred = preferredArchivedAgentTabs(tabs, preferred: .init(agentKind: .codex, sessionID: "C"))
        #expect(preferred.map(\.ordinal) == [0, 2, 3])
        #expect(orderedArchivedAgentTabs(preferred).map(\.ordinal) == [3, 0, 2])
        let sameID = preferredArchivedAgentTabs(tabs, preferred: .init(agentKind: .codex, sessionID: "shared-id"))
        #expect(orderedArchivedAgentTabs(sameID).map(\.ordinal) == [0, 2, 3])
        #expect(orderedArchivedAgentTabs([]).isEmpty)
    }

    @Test func preferredCodexIdentityAndAdmissionReachTheLifecycle() async throws {
        let (home, cleanup) = isolateTBDHome(); defer { cleanup() }
        let (temp, repoDir) = try await createTestRepo()
        defer { try? FileManager.default.removeItem(at: temp) }
        let db = try TBDDatabase(inMemory: true)
        let repo = try await makeTestRepo(db: db, tempDir: temp, repoDir: repoDir)
        let recorder = PreSessionRecordedCommands()
        let helper = LocalAgentArchiveTests()
        let lc = helper.lifecycle(db, recorder, home: home)
        let wt = try await lc.beginCreateWorktree(repoID: repo.id)
        try await db.worktrees.updateStatus(id: wt.id, status: .archived)
        try await shell("git branch '\(wt.branch)'", at: repoDir)
        _ = try await helper.seedSnapshot(db, id: wt.id)
        try await db.localAgentSessions.upsert(.init(worktreeID: wt.id,
            identity: .init(agentKind: .codex, sessionID: "codex-C"),
            firstObservedAt: .distantPast, lastObservedAt: .distantPast))
        let router = RPCRouter(db: db, lifecycle: lc, tmux: TmuxManager(dryRun: true), startTime: Date(),
            actuationLog: ActuationLog(path: home.appendingPathComponent("actuations.jsonl").path))
        let admission = StubAdmission(.admit)
        router.startAdmission = admission
        try await db.config.setStartAdmissionEnabled(true)
        let params: [String: Any] = ["worktreeID": wt.id.uuidString,
            "preferredSessionID": "claude-B",
            "preferredSession": ["agentKind": "codex", "sessionID": "codex-C"]]
        let request = RPCRequest(method: RPCMethod.worktreeRevive,
            params: String(decoding: try JSONSerialization.data(withJSONObject: params), as: UTF8.self))
        let response = await router.handle(request)
        #expect(response.success, "\(response.error ?? "")")
        #expect(admission.requests.map(\.agent).sorted { $0.rawValue < $1.rawValue } == [.claude, .codex])
        let terminals = try await db.terminals.list(worktreeID: wt.id)
        let order = try await db.worktrees.getTabOrder(worktreeID: wt.id)
        let agents = order.compactMap { id in terminals.first { $0.id == id } }.filter { $0.claudeSessionID != nil }
        #expect(agents.map(\.claudeSessionID) == ["codex-C", "codex-A", "claude-B"])
        #expect(try await db.worktrees.getActiveTabID(worktreeID: wt.id) == agents.first?.id)
    }
}
}
