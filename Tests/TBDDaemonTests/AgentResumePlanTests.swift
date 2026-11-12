import Foundation
import GRDB
import Testing
@testable import TBDDaemonLib
@testable import TBDShared

// Recovery must retain launch identity and placement while fencing every fact
// that belonged to the lost process. Shared by the two transport regressions.
func seedRecoveryTerminal(
    db: TBDDatabase, worktreeID: UUID, transport: TerminalTransport
) async throws -> Terminal {
    let stamp = Date(timeIntervalSince1970: 1_800_000_000)
    var terminal = Terminal(
        worktreeID: worktreeID,
        tmuxWindowID: transport == .tmux ? "@recovery" : "",
        tmuxPaneID: transport == .tmux ? "%recovery" : "",
        label: TerminalLabel.codex, claudeSessionID: "codex-recovery",
        transcriptPath: "/tmp/acme/rollout.jsonl", sessionOrderObservedAt: stamp,
        codexTranscriptBoundaryOffset: 123, sessionIncarnationID: UUID(),
        kind: .codex, activityState: .working,
        activityStateSource: .database, activityStateObservedAt: stamp,
        activityStateOrderObservedAt: stamp,
        awaitingInputReason: AwaitingInputReason(message: "Continue?", notificationType: "permission_prompt"),
        awaitingInputObservedAt: stamp,
        transport: transport, holderPID: transport == .holder ? 4242 : nil,
        childPID: transport == .holder ? 4243 : nil,
        holderChildStartedAt: transport == .holder ? stamp : nil)
    terminal.codexLaunchOptions = CodexLaunchOptions(
        model: "acme-model", disabledFeatures: ["acme-feature"], codexHome: "/tmp/acme/codex")
    let record = TerminalRecord(from: terminal)
    try await db.writerForTests.write { db in try record.insert(db) }
    _ = try await db.scheduledResumes.insertPending(ScheduledResume(
        terminalID: terminal.id, worktreeID: worktreeID, claudeSessionID: "codex-recovery",
        resetsAt: stamp, fireAt: stamp.addingTimeInterval(60),
        limitType: "session", rawMessage: "Usage limit"))
    try await db.tabs.setLabel(tabID: terminal.id, worktreeID: worktreeID, label: "Recovery tab")
    try await db.worktrees.setTabOrder(worktreeID: worktreeID, tabIDs: [terminal.id])
    return try #require(try await db.terminals.get(id: terminal.id))
}

func expectRecoveryPark(
    db: TBDDatabase, before: Terminal, logPath: String
) async throws {
    let after = try #require(try await db.terminals.get(id: before.id),
                             "identified Codex row must park rather than disappear")
    #expect(after.hibernateReason == .recovery)
    #expect(after.isParked)
    #expect(after.claudeSessionID == "codex-recovery")
    #expect(after.transcriptPath == "/tmp/acme/rollout.jsonl")
    #expect(after.codexLaunchOptions == CodexLaunchOptions(
        model: "acme-model", disabledFeatures: ["acme-feature"], codexHome: "/tmp/acme/codex"))
    #expect(after.kind == .codex)
    #expect(after.worktreeID == before.worktreeID)
    #expect(after.transport == before.transport)
    #expect(after.tmuxWindowID == before.tmuxWindowID)
    #expect(after.tmuxPaneID == before.tmuxPaneID)
    #expect(after.createdAt == before.createdAt)
    #expect(after.sessionIncarnationID != nil)
    #expect(after.sessionIncarnationID != before.sessionIncarnationID)
    #expect(after.pendingSessionIncarnationID == nil)
    #expect(after.sessionOrderObservedAt == nil)
    #expect(after.codexTranscriptBoundaryOffset == nil)
    #expect(after.activityState == .idle)
    #expect(after.activityStateSource == .database)
    #expect(after.awaitingInputReason == nil)
    #expect(after.awaitingInputObservedAt == nil)
    #expect(after.pendingResumeAt == nil)
    #expect(try await db.scheduledResumes.pending(terminalID: before.id) == nil)
    #expect(try await db.scheduledResumes.all(terminalID: before.id).first?.status == .cancelled)
    #expect(after.holderPID == nil)
    #expect(after.childPID == nil)
    #expect(after.holderChildStartedAt == nil)
    #expect(try await db.worktrees.getTabOrder(worktreeID: before.worktreeID) == [before.id])
    #expect(try await db.tabs.listForWorktree(worktreeID: before.worktreeID)
        .first(where: { $0.id == before.id })?.label == "Recovery tab")
    let rows = try String(contentsOfFile: logPath, encoding: .utf8).split(separator: "\n")
        .map { try JSONDecoder().decode(ActuationRow.self, from: Data($0.utf8)) }
    let expectedTarget = ActuationTarget.local(worktree: before.worktreeID, terminal: before.id)
    let request = try #require(rows.first { $0.kind == .hibernate && $0.target == expectedTarget })
    #expect(request.target == expectedTarget)
    #expect(request.actor == .daemon(rail: ActuationRail.reconcile))
    #expect(rows.contains { $0.confirms == request.id && $0.result == .synchronous(.dispatched) })
}

@Suite("Agent recovery resume plans")
struct AgentResumePlanTests {
    private func row(kind: TerminalKind?, label: String? = nil, sessionID: String?) -> Terminal {
        Terminal(worktreeID: UUID(), tmuxWindowID: "@1", tmuxPaneID: "%1",
                 label: label, claudeSessionID: sessionID, kind: kind)
    }

    @Test(arguments: [TerminalKind.claude, nil])
    func claudePlanPreservesItsLaunchMetadata(kind: TerminalKind?) throws {
        var terminal = row(kind: kind, sessionID: "claude-native")
        let profileID = UUID()
        terminal.profileID = profileID
        terminal.transcriptPath = "/tmp/acme/claude.jsonl"
        terminal.claudeSpawnExtras = ClaudeSpawnExtras(pluginDirs: ["/tmp/acme/plugin"])
        let plan = try #require(terminal.recoveryResumePlan)
        #expect(plan.identity == AgentSessionIdentity(agentKind: .claude, sessionID: "claude-native"))
        guard case let .claude(sessionID, path, profile, extras) = plan else {
            Issue.record("Claude terminal produced another provider's plan")
            return
        }
        #expect(sessionID == "claude-native")
        #expect(path == "/tmp/acme/claude.jsonl")
        #expect(profile == profileID)
        #expect(extras == ClaudeSpawnExtras(pluginDirs: ["/tmp/acme/plugin"]))
    }

    @Test func codexPlanPreservesNativeIdentityAndOptions() throws {
        var terminal = row(kind: .codex, sessionID: "codex-native")
        terminal.transcriptPath = "/tmp/acme/codex.jsonl"
        terminal.codexLaunchOptions = CodexLaunchOptions(
            model: "acme-model", disabledFeatures: ["acme-feature"], codexHome: "/tmp/acme/codex")
        let plan = try #require(terminal.recoveryResumePlan)
        #expect(plan.identity == AgentSessionIdentity(agentKind: .codex, sessionID: "codex-native"))
        guard case let .codex(sessionID, path, options) = plan else {
            Issue.record("Codex terminal produced another provider's plan")
            return
        }
        #expect(sessionID == "codex-native")
        #expect(path == "/tmp/acme/codex.jsonl")
        #expect(options == CodexLaunchOptions(
            model: "acme-model", disabledFeatures: ["acme-feature"], codexHome: "/tmp/acme/codex"))
    }

    @Test(arguments: [TerminalKind.claude, .codex, .shell, nil])
    func missingOrBlankIdentityCannotRecover(kind: TerminalKind?) {
        for sessionID in [nil, "", " \n"] as [String?] {
            #expect(row(kind: kind, sessionID: sessionID).recoveryResumePlan == nil)
        }
    }

    @Test func shellSessionAndConflictingCodexLabelsCannotRecover() {
        #expect(row(kind: .shell, sessionID: "native").recoveryResumePlan == nil)
        for kind in [TerminalKind.claude, .shell, nil] {
            #expect(row(kind: kind, label: TerminalLabel.codex, sessionID: "native")
                .recoveryResumePlan == nil)
        }
    }
}
