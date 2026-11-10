import Darwin
import Foundation
import TBDShared
import TestSupport
import Testing
@testable import TBDApp

@Suite("History transcript header actions")
struct HistoryPaneActionTests {
    @Test("active transcript presents one prominent resume action")
    func activeTranscriptPresentsResume() {
        #expect(TranscriptHeaderActions.descriptors(
            for: .resume, defaultBranch: "main"
        ) == [
            .init(kind: .resume, title: "Resume", prominent: true)
        ])
    }

    @Test("archived transcript presents original and fresh branch actions")
    func archivedTranscriptPresentsBothReviveActions() {
        #expect(TranscriptHeaderActions.descriptors(
            for: .reviveWithSession, defaultBranch: "master"
        ) == [
            .init(kind: .reviveOriginal, title: "in original branch", prominent: true),
            .init(kind: .reviveFresh, title: "on fresh master", prominent: false)
        ])
    }

    @Test("archived transcript labels its revive choices")
    func archivedTranscriptRevivePrefix() {
        #expect(TranscriptHeaderActions.revivePrefix == "Revive this session:")
    }
}

@MainActor
extension HistoryPaneActionTests {
    @Test("same native ID selects and caches provider histories independently")
    func providerSelection() async {
        let suite = TestDefaultsSuite("history-provider-selection")
        defer { suite.tearDown() }
        let state = AppState(userDefaults: suite.defaults)
        let worktreeID = UUID()
        let claude = Self.summary(kind: .claude)
        let codex = Self.summary(kind: .codex)
        state.historyLoadStates[worktreeID] = .loaded([claude, codex])
        let claudeItems: [TranscriptItem] = [.userPrompt(id: "c", text: "Claude", timestamp: nil)]
        let codexItems: [TranscriptItem] = [.userPrompt(id: "x", text: "Codex", timestamp: nil)]
        state.sessionTranscripts = [claude.id: claudeItems, codex.id: codexItems]
        await state.selectSession(claude, worktreeID: worktreeID)
        #expect(state.selectedSessionIDs[worktreeID] == claude.id)
        await state.selectSession(codex, worktreeID: worktreeID)
        #expect(state.selectedSessionIDs[worktreeID] == codex.id)
        #expect(state.historyLoadStates[worktreeID]?.currentSessions.count == 2)
        #expect(state.sessionTranscripts[claude.id] == claudeItems)
        #expect(state.sessionTranscripts[codex.id] == codexItems)
        #expect(state.sessionTranscripts["same"] == nil)
    }

    @Test("loading both provider histories keeps live and provider cache slots separate")
    func providerLoads() async throws {
        let root = fencedScratchRoot(prefix: "history-provider-load")
        try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: root) }
        let path = root + "/claude.jsonl"
        try #"{"type":"user","uuid":"c","message":{"role":"user","content":"Claude content"}}"#
            .write(toFile: path, atomically: true, encoding: .utf8)
        let codexItems: [TranscriptItem] = [.userPrompt(id: "x", text: "Codex content", timestamp: nil)]
        let liveItems: [TranscriptItem] = [.userPrompt(id: "live", text: "Live content", timestamp: nil)]
        let server = try HistoryRPCServer { _ in try RPCResponse(result: codexItems) }
        defer { server.stop() }
        let suite = TestDefaultsSuite("history-provider-load")
        defer { suite.tearDown() }
        let state = AppState(userDefaults: suite.defaults, daemonClient: DaemonClient(socketPath: server.path))
        let claude = Self.summary(kind: .claude, path: path)
        let codex = Self.summary(kind: .codex, path: path)
        state.sessionTranscripts["same"] = liveItems
        let worktreeID = UUID()
        await state.selectSession(claude, worktreeID: worktreeID)
        await state.selectSession(codex, worktreeID: worktreeID)
        #expect(state.sessionTranscripts[claude.id]?.first?.id == "c")
        #expect(state.sessionTranscripts[codex.id] == codexItems)
        #expect(state.sessionTranscripts["same"] == liveItems)
        #expect(state.sessionTranscriptLoading.isEmpty)
        #expect(server.requests.count == 2)
        let params = try server.requests.map { try JSONDecoder().decode(SessionMessagesParams.self, from: $0.paramsData) }
        #expect(params.allSatisfy { $0.identity == codex.identity && $0.filePath == nil })
    }

    @Test("reselection or refresh retries a Codex full read after its tail succeeded", arguments: ["reselect", "refresh", "refresh-closed"])
    func retriesIncompleteHistory(mode: String) async throws {
        let suite = TestDefaultsSuite("history-retry-action")
        defer { suite.tearDown() }
        let summary = Self.summary(kind: .codex)
        let claude = Self.summary(kind: .claude)
        let tail: [TranscriptItem] = [.userPrompt(id: "tail", text: "Recent", timestamp: nil)]
        let full: [TranscriptItem] = [.userPrompt(id: "older", text: "Older", timestamp: nil)] + tail
        let fullReads = FireRecorder<Int>()
        let server = try HistoryRPCServer { request in
            switch request.method {
            case RPCMethod.sessionList:
                let params = try JSONDecoder().decode(SessionListParams.self, from: request.paramsData)
                guard params.providerAware == true else {
                    return RPCResponse(error: "provider-aware history capability missing")
                }
                return try RPCResponse(result: [summary, claude])
            case RPCMethod.terminalHistoryList: return try RPCResponse(result: [TerminalHistoryEntry]())
            case RPCMethod.sessionMessages:
                let params = try JSONDecoder().decode(SessionMessagesParams.self, from: request.paramsData)
                if params.tailLimit != nil { return try RPCResponse(result: tail) }
                fullReads.record(1)
                return fullReads.values.count == 1
                    ? RPCResponse(error: "temporarily unavailable") : try RPCResponse(result: full)
            default: return RPCResponse(error: "unexpected request")
            }
        }
        defer { server.stop() }
        let state = AppState(userDefaults: suite.defaults, daemonClient: DaemonClient(socketPath: server.path))
        let worktreeID = UUID()
        state.historyLoadStates[worktreeID] = .loaded([summary, claude])
        state.sessionTranscripts[claude.id] = []
        await state.selectSession(summary, worktreeID: worktreeID)
        #expect(state.sessionTranscripts[summary.id] == tail)
        if mode == "refresh-closed" {
            let closedID = UUID()
            state.selectedClosedTerminalIDs[worktreeID] = closedID
            await state.fetchSessions(worktreeID: worktreeID)
            #expect(state.selectedClosedTerminalIDs[worktreeID] == closedID)
            #expect(state.sessionTranscripts[summary.id] == tail)
            #expect(fullReads.values.count == 1)
            await state.selectSession(summary, worktreeID: worktreeID)
        } else if mode == "refresh" {
            await state.fetchSessions(worktreeID: worktreeID)
        } else {
            await state.selectSession(claude, worktreeID: worktreeID)
            await state.selectSession(summary, worktreeID: worktreeID)
        }
        #expect(state.sessionTranscripts[summary.id] == full)
        #expect(state.sessionTranscripts[claude.id] == [])
        #expect(state.selectedSessionIDs[worktreeID] == summary.id)
        #expect(fullReads.values.count == 2)
        await state.selectSession(summary, worktreeID: worktreeID)
        #expect(fullReads.values.count == 2)
    }

    @Test("refresh invalidates completed history when its summary changes or disappears", arguments: ["changed", "unavailable", "removed"])
    func refreshInvalidatesCompletedHistory(change: String) async throws {
        let suite = TestDefaultsSuite("history-refresh-invalidate")
        defer { suite.tearDown() }
        let summary = Self.summary(kind: .codex)
        let changed = SessionSummary(sessionId: summary.sessionId, filePath: "", modifiedAt: summary.modifiedAt,
            fileSize: 1, lineCount: 1, firstUserMessage: nil, lastUserMessage: nil, cwd: nil, gitBranch: nil,
            agentKind: .codex, transcriptAvailable: change != "unavailable")
        let old: [TranscriptItem] = [.userPrompt(id: "old", text: "Old", timestamp: nil)]
        let fresh: [TranscriptItem] = [.userPrompt(id: "fresh", text: "Fresh", timestamp: nil)]
        let lists = FireRecorder<[SessionSummary]>()
        let fullReads = FireRecorder<Int>()
        lists.record([summary])
        let server = try HistoryRPCServer { request in
            switch request.method {
            case RPCMethod.sessionList: return try RPCResponse(result: lists.values.last ?? [])
            case RPCMethod.terminalHistoryList: return try RPCResponse(result: [TerminalHistoryEntry]())
            case RPCMethod.sessionMessages:
                let params = try JSONDecoder().decode(SessionMessagesParams.self, from: request.paramsData)
                if params.tailLimit != nil { return try RPCResponse(result: old) }
                fullReads.record(1)
                return try RPCResponse(result: fullReads.values.count == 1 ? old : fresh)
            default: return RPCResponse(error: "unexpected request")
            }
        }
        defer { server.stop() }
        let state = AppState(userDefaults: suite.defaults, daemonClient: DaemonClient(socketPath: server.path))
        let worktreeID = UUID()
        state.historyLoadStates[worktreeID] = .loaded([summary])
        await state.selectSession(summary, worktreeID: worktreeID)
        #expect(state.sessionTranscripts[summary.id] == old)
        lists.record(change == "removed" ? [] : [changed])
        await state.fetchSessions(worktreeID: worktreeID)
        if change != "changed" {
            #expect(state.sessionTranscripts[summary.id] == nil)
            #expect(!state.sessionTranscriptLoading.contains(summary.id))
            lists.record([summary])
            await state.fetchSessions(worktreeID: worktreeID)
        }
        #expect(state.sessionTranscripts[summary.id] == fresh)
        #expect(fullReads.values.count == 2)
    }

    @Test("stale refresh responses cannot invalidate a newer transcript load",
          arguments: ["unavailable", "removed", "error", "closed"], [false, true])
    func overlappingRefreshKeepsNewerLoad(staleResult: String, afterTail: Bool) async throws {
        let suite = TestDefaultsSuite("history-refresh-ownership")
        defer { suite.tearDown() }
        let worktreeID = UUID()
        let summary = Self.summary(kind: .codex)
        let unavailable = Self.summary(kind: .codex, available: false)
        let closed = TerminalHistoryEntry(id: UUID(), worktreeID: worktreeID)
        let tail: [TranscriptItem] = [.userPrompt(id: "tail", text: "Recent", timestamp: nil)]
        let full: [TranscriptItem] = [.userPrompt(id: "older", text: "Older", timestamp: nil)] + tail
        let oldStarted = FireRecorder<Int>()
        let newerStarted = FireRecorder<Int>()
        let listCalls = FireRecorder<Int>()
        let closedCalls = FireRecorder<Int>()
        let oldRelease = DispatchSemaphore(value: 0)
        let newerRelease = DispatchSemaphore(value: 0)
        defer { oldRelease.signal(); newerRelease.signal() }
        let server = try HistoryRPCServer { request in
            switch request.method {
            case RPCMethod.terminalHistoryList:
                closedCalls.record(1)
                if staleResult == "closed", closedCalls.values.count == 1 {
                    oldStarted.record(1)
                    oldRelease.waitForGate("older closed-history refresh response")
                    return try RPCResponse(result: [closed])
                }
                return try RPCResponse(result: [TerminalHistoryEntry]())
            case RPCMethod.sessionList:
                listCalls.record(1)
                if staleResult != "closed", listCalls.values.count == 1 {
                    oldStarted.record(1)
                    oldRelease.waitForGate("older session-list refresh response")
                    switch staleResult {
                    case "error": return RPCResponse(error: "older refresh failed")
                    case "removed": return try RPCResponse(result: [SessionSummary]())
                    default: return try RPCResponse(result: [unavailable])
                    }
                }
                return try RPCResponse(result: [summary])
            case RPCMethod.sessionMessages:
                let params = try JSONDecoder().decode(SessionMessagesParams.self, from: request.paramsData)
                if (params.tailLimit == nil) == afterTail {
                    newerStarted.record(1)
                    newerRelease.waitForGate("newer transcript load response")
                }
                return try RPCResponse(result: params.tailLimit == nil ? full : tail)
            default: return RPCResponse(error: "unexpected request")
            }
        }
        defer { server.stop() }
        let state = AppState(userDefaults: suite.defaults, daemonClient: DaemonClient(socketPath: server.path))
        state.historyLoadStates[worktreeID] = .loaded([summary])
        let older = Task { await state.fetchSessions(worktreeID: worktreeID) }
        _ = try await oldStarted.next(timeout: TestDeadlines.saturatedPass)
        let newer = Task { await state.fetchSessions(worktreeID: worktreeID) }
        _ = try await newerStarted.next(timeout: TestDeadlines.saturatedPass)
        let cache = state.sessionTranscripts
        let tokens = state.historyTranscriptRequests
        let loading = state.sessionTranscriptLoading
        let incomplete = state.incompleteHistoryTranscripts
        let selections = state.selectedSessionIDs
        #expect(loading.contains(summary.id) == !afterTail)
        #expect(incomplete.contains(summary.id) == afterTail)
        oldRelease.signal()
        await older.value
        #expect(state.historyLoadStates[worktreeID]?.currentSessions.map(\.id) == [summary.id])
        #expect(state.historyLoadStates[worktreeID]?.currentSessions.first?.transcriptAvailable == true)
        #expect(state.sessionTranscripts == cache)
        #expect(state.historyTranscriptRequests == tokens)
        #expect(state.sessionTranscriptLoading == loading)
        #expect(state.incompleteHistoryTranscripts == incomplete)
        #expect(state.selectedSessionIDs == selections)
        #expect(state.closedTerminalHistories[worktreeID] == [])
        if staleResult == "closed" { #expect(listCalls.values.count == 1) }
        newerRelease.signal()
        await newer.value
        #expect(state.sessionTranscripts[summary.id] == full)
        #expect(!state.incompleteHistoryTranscripts.contains(summary.id))
        #expect(!state.sessionTranscriptLoading.contains(summary.id))
    }

    @Test("a stale success cannot replace the current refresh error or invalidate its retained tail")
    func staleSuccessKeepsCurrentFailure() async throws {
        let suite = TestDefaultsSuite("history-refresh-error-owner")
        defer { suite.tearDown() }
        let summary = Self.summary(kind: .codex)
        let tail: [TranscriptItem] = [.userPrompt(id: "tail", text: "Recent", timestamp: nil)]
        let started = FireRecorder<Int>()
        let calls = FireRecorder<Int>()
        let release = DispatchSemaphore(value: 0)
        defer { release.signal() }
        let server = try HistoryRPCServer { request in
            if request.method == RPCMethod.terminalHistoryList {
                return try RPCResponse(result: [TerminalHistoryEntry]())
            }
            calls.record(1)
            if calls.values.count == 1 {
                started.record(1)
                release.waitForGate("stale successful refresh response")
                return try RPCResponse(result: [SessionSummary]())
            }
            return RPCResponse(error: "current refresh failed")
        }
        defer { server.stop() }
        let state = AppState(userDefaults: suite.defaults, daemonClient: DaemonClient(socketPath: server.path))
        let worktreeID = UUID()
        state.historyLoadStates[worktreeID] = .loaded([summary])
        await state.loadSessionTranscript(sessionID: summary.id, readTail: { tail },
            readFull: { throw DaemonClientError.rpcError("try again", code: nil) })
        let older = Task { await state.fetchSessions(worktreeID: worktreeID) }
        _ = try await started.next(timeout: TestDeadlines.saturatedPass)
        await state.fetchSessions(worktreeID: worktreeID)
        let failed = state.historyLoadStates[worktreeID]
        #expect(failed == .failed("RPC error: current refresh failed"))
        release.signal()
        await older.value
        #expect(state.historyLoadStates[worktreeID] == failed)
        #expect(state.sessionTranscripts[summary.id] == tail)
        #expect(state.incompleteHistoryTranscripts.contains(summary.id))
    }

    @Test("an older refresh finishing cannot relinquish a newer pending refresh")
    func olderCompletionKeepsNewerOwnership() async throws {
        let suite = TestDefaultsSuite("history-refresh-pending-owner")
        defer { suite.tearDown() }
        let summary = Self.summary(kind: .codex)
        let calls = FireRecorder<Int>()
        let started = FireRecorder<Int>()
        let oldRelease = DispatchSemaphore(value: 0)
        let newRelease = DispatchSemaphore(value: 0)
        defer { oldRelease.signal(); newRelease.signal() }
        let server = try HistoryRPCServer { request in
            if request.method == RPCMethod.terminalHistoryList {
                return try RPCResponse(result: [TerminalHistoryEntry]())
            }
            calls.record(1)
            let ordinal = calls.values.count
            started.record(ordinal)
            if ordinal == 1 {
                oldRelease.waitForGate("older pending refresh response")
                return RPCResponse(error: "old failure")
            }
            newRelease.waitForGate("newer pending refresh response")
            return try RPCResponse(result: [summary])
        }
        defer { server.stop() }
        let state = AppState(userDefaults: suite.defaults, daemonClient: DaemonClient(socketPath: server.path))
        let worktreeID = UUID()
        state.historyLoadStates[worktreeID] = .loaded([summary])
        state.sessionTranscripts[summary.id] = []
        let older = Task { await state.fetchSessions(worktreeID: worktreeID) }
        #expect(try await started.next(timeout: TestDeadlines.saturatedPass) == 1)
        let newer = Task { await state.fetchSessions(worktreeID: worktreeID) }
        #expect(try await started.next(timeout: TestDeadlines.saturatedPass) == 2)
        oldRelease.signal()
        await older.value
        #expect(state.historyLoadStates[worktreeID] == .loadingStale([summary]))
        newRelease.signal()
        await newer.value
        #expect(state.historyLoadStates[worktreeID] == .loaded([summary]))
        #expect(state.selectedSessionIDs[worktreeID] == summary.id)
    }

    @Test("refresh ownership is independent across worktrees while selection switches")
    func refreshesDifferentWorktrees() async throws {
        let suite = TestDefaultsSuite("history-refresh-worktrees")
        defer { suite.tearDown() }
        let firstID = UUID()
        let secondID = UUID()
        let first = Self.summary(kind: .claude)
        let second = Self.summary(kind: .codex)
        let firstStarted = FireRecorder<Int>()
        let release = DispatchSemaphore(value: 0)
        defer { release.signal() }
        let server = try HistoryRPCServer { request in
            if request.method == RPCMethod.terminalHistoryList {
                return try RPCResponse(result: [TerminalHistoryEntry]())
            }
            let params = try JSONDecoder().decode(SessionListParams.self, from: request.paramsData)
            if params.worktreeID == firstID {
                firstStarted.record(1)
                release.waitForGate("first worktree refresh response")
                return try RPCResponse(result: [first])
            }
            return try RPCResponse(result: [second])
        }
        defer { server.stop() }
        let state = AppState(userDefaults: suite.defaults, daemonClient: DaemonClient(socketPath: server.path))
        // Completed cache entries keep this control focused on refresh ownership.
        state.sessionTranscripts[first.id] = []
        state.sessionTranscripts[second.id] = []
        state.selectedWorktreeIDs = [firstID]
        let firstRefresh = Task { await state.fetchSessions(worktreeID: firstID) }
        _ = try await firstStarted.next(timeout: TestDeadlines.saturatedPass)
        state.selectedWorktreeIDs = [secondID]
        await state.fetchSessions(worktreeID: secondID)
        #expect(state.historyLoadStates[secondID]?.currentSessions.map(\.id) == [second.id])
        release.signal()
        await firstRefresh.value
        #expect(state.historyLoadStates[firstID]?.currentSessions.map(\.id) == [first.id])
        #expect(state.selectedSessionIDs[firstID] == first.id)
        #expect(state.selectedSessionIDs[secondID] == second.id)
        #expect(state.selectedWorktreeIDs == [secondID])
    }

    @Test("resume selects a distinct terminal for either provider", arguments: [LocalAgentKind.claude, .codex])
    func selectsResumedTerminal(kind: LocalAgentKind) async throws {
        let suite = TestDefaultsSuite("history-resume-selection")
        defer { suite.tearDown() }
        let worktreeID = UUID()
        let terminal = Terminal(id: UUID(), worktreeID: worktreeID, tmuxWindowID: "@1", tmuxPaneID: "%1",
            claudeSessionID: "same", kind: kind == .codex ? .codex : .claude)
        let server = try HistoryRPCServer { request in
            if request.method == "session.resume" { return try RPCResponse(result: terminal) }
            return RPCResponse(error: "Unexpected request")
        }
        defer { server.stop() }
        let state = AppState(userDefaults: suite.defaults, daemonClient: DaemonClient(socketPath: server.path))
        state.historyActiveWorktrees.insert(worktreeID)
        await state.resumeSession(worktreeID: worktreeID, identity: .init(agentKind: kind, sessionID: "same"))
        #expect(state.terminals[worktreeID]?.map(\.id) == [terminal.id])
        let index = try #require(state.activeTabIndices[worktreeID])
        #expect(state.tabs[worktreeID]?[index].content == .terminal(terminalID: terminal.id))
        #expect(!state.historyActiveWorktrees.contains(worktreeID))
        let request = try #require(server.requests.first)
        let params = try JSONDecoder().decode(SessionResumeParams.self, from: request.paramsData)
        #expect(params.identity == AgentSessionIdentity(agentKind: kind, sessionID: "same"))
    }

    @Test("an unavailable Codex history remains selectable without loading a client path")
    func unavailableSelection() async {
        let suite = TestDefaultsSuite("history-unavailable")
        defer { suite.tearDown() }
        let state = AppState(userDefaults: suite.defaults)
        let summary = Self.summary(kind: .codex, path: "/untrusted/client.jsonl", available: false)
        let worktreeID = UUID()
        await state.selectSession(summary, worktreeID: worktreeID)
        #expect(state.selectedSessionIDs[worktreeID] == summary.id)
        #expect(!state.sessionTranscriptLoading.contains(summary.id))
        #expect(state.sessionTranscripts[summary.id] == nil)
    }

    nonisolated static func summary(kind: LocalAgentKind, path: String = "", available: Bool = true) -> SessionSummary {
        SessionSummary(sessionId: "same", filePath: path, modifiedAt: Date(), fileSize: 0, lineCount: 0,
            firstUserMessage: nil, lastUserMessage: nil, cwd: nil, gitBranch: nil,
            agentKind: kind, transcriptAvailable: available)
    }
}

extension HistoryPaneActionTests {
    @Test("Claude resumes fall back only when an old daemon lacks the method", arguments: [LocalAgentKind.claude, .codex], ["Unknown method: session.resume", "Admission refused"])
    func resumeCompatibility(kind: LocalAgentKind, refusal: String) async throws {
        let worktree = UUID()
        let expected = Terminal(id: UUID(), worktreeID: worktree, tmuxWindowID: "@1", tmuxPaneID: "%1", claudeSessionID: "same")
        let server = try HistoryRPCServer { request in
            request.method == "session.resume" ? RPCResponse(error: refusal) : try RPCResponse(result: expected)
        }
        defer { server.stop() }
        do {
            let terminal = try await DaemonClient(socketPath: server.path).resumeSession(
                worktreeID: worktree, identity: .init(agentKind: kind, sessionID: "same"), cols: 123, rows: 45)
            #expect(kind == .claude && refusal.hasPrefix("Unknown method:"))
            #expect(terminal.id == expected.id)
        } catch {
            #expect(kind == .codex || !refusal.hasPrefix("Unknown method:"))
        }
        let requests = server.requests
        if kind == .claude && refusal.hasPrefix("Unknown method:") {
            #expect(requests.map(\.method) == ["session.resume", "terminal.create"])
            let params = try JSONDecoder().decode(TerminalCreateParams.self, from: requests[1].paramsData)
            #expect(params.resumeSessionID == "same" && params.cols == 123 && params.rows == 45)
        } else {
            #expect(requests.map(\.method) == ["session.resume"])
        }
    }

    @Test("Codex tail and full reads carry catalog identity, never client path")
    func codexReadsUseRPC() async throws {
        let item = TranscriptItem.userPrompt(id: "rpc", text: "RPC content", timestamp: nil)
        let server = try HistoryRPCServer { _ in try RPCResponse(result: [item]) }
        defer { server.stop() }
        let client = DaemonClient(socketPath: server.path)
        let summary = Self.summary(kind: .codex, path: "/untrusted/client.jsonl")
        let worktree = UUID()
        let tail = try await client.sessionMessages(summary: summary, worktreeID: worktree, tailLimit: 12)
        let full = try await client.sessionMessages(summary: summary, worktreeID: worktree)
        #expect(tail == [item] && full == [item])
        let requests = server.requests
        #expect(requests.map(\.method) == ["session.messages", "session.messages"])
        let params = try requests.map { try JSONDecoder().decode(SessionMessagesParams.self, from: $0.paramsData) }
        #expect(params.map(\.identity) == [summary.identity, summary.identity])
        #expect(params.map(\.worktreeID) == [worktree, worktree])
        #expect(params.allSatisfy { $0.filePath == nil })
        #expect(params.map(\.tailLimit) == [12, nil])
    }

    @Test("revive requests keep provider identity and Claude legacy fields", arguments: [LocalAgentKind.claude, .codex])
    func reviveRequests(kind: LocalAgentKind) async throws {
        let worktree = Worktree(id: UUID(), repoID: UUID(), name: "acme", displayName: "Acme", branch: "main", path: "/tmp/acme", status: .active, tmuxServer: "test")
        let server = try HistoryRPCServer { request in
            if request.method == "worktree.revive" { return try RPCResponse(result: worktree) }
            return try RPCResponse(result: WorktreeReviveConversationFreshResult(worktree: worktree, warning: nil))
        }
        defer { server.stop() }
        let client = DaemonClient(socketPath: server.path)
        let identity = AgentSessionIdentity(agentKind: kind, sessionID: "same")
        _ = try await client.reviveWorktree(id: worktree.id, preferredSession: identity)
        _ = try await client.reviveConversationOnFreshBranch(worktreeID: worktree.id, identity: identity)
        let requests = server.requests
        let original = try JSONDecoder().decode(WorktreeReviveParams.self, from: requests[0].paramsData)
        let fresh = try JSONDecoder().decode(WorktreeReviveConversationFreshParams.self, from: requests[1].paramsData)
        #expect(original.preferredSession == identity)
        #expect(original.preferredSessionID == (kind == .claude ? "same" : nil))
        #expect(fresh.identity == identity && fresh.sessionID == "same")
    }
}

/// A real client socket with only the external daemon boundary replaced.
private final class HistoryRPCServer: @unchecked Sendable {
    let path: String
    private let root: String
    private let fd: Int32
    private let answer: @Sendable (RPCRequest) throws -> RPCResponse
    private let lock = NSLock()
    private var stopped = false
    private var received: [RPCRequest] = []
    var requests: [RPCRequest] { lock.withLock { received } }

    init(answer: @escaping @Sendable (RPCRequest) throws -> RPCResponse) throws {
        self.answer = answer
        root = fencedScratchRoot(prefix: "history-rpc")
        try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
        path = root + "/s"
        fd = socket(AF_UNIX, SOCK_STREAM, 0)
        _ = fcntl(fd, F_SETFD, FD_CLOEXEC)
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let bytes = path.utf8CString
        precondition(bytes.count <= MemoryLayout.size(ofValue: address.sun_path))
        withUnsafeMutablePointer(to: &address.sun_path) { ptr in
            ptr.withMemoryRebound(to: CChar.self, capacity: bytes.count) { dest in
                for i in bytes.indices { dest[i] = bytes[i] }
            }
        }
        let result = withUnsafePointer(to: &address) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        precondition(result == 0 && listen(fd, 8) == 0)
        _ = gateHoldingTask { [self] in serve() }
    }

    func stop() { lock.withLock { stopped = true } }

    private func serve() {
        defer { close(fd); try? FileManager.default.removeItem(atPath: root) }
        while !lock.withLock({ stopped }) {
            var pollFD = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            guard poll(&pollFD, 1, 100) > 0 else { continue }
            let connection = accept(fd, nil, nil)
            guard connection >= 0 else { continue }
            _ = gateHoldingTask { [self] in
                defer { close(connection) }
                answerConnection(connection)
            }
        }
    }

    private func answerConnection(_ connection: Int32) {
        var frame = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while !frame.contains(10) {
            let count = recv(connection, &buffer, buffer.count, 0)
            if count <= 0 { break }
            frame.append(contentsOf: buffer.prefix(count))
        }
        guard let line = frame.split(separator: 10).first,
              let request = try? JSONDecoder().decode(RPCRequest.self, from: Data(line)) else { return }
        lock.withLock { received.append(request) }
        let response = (try? answer(request)) ?? RPCResponse(error: "test response failed")
        guard var data = try? JSONEncoder().encode(response) else { return }
        data.append(10)
        data.withUnsafeBytes { _ = send(connection, $0.baseAddress, $0.count, 0) }
    }
}
