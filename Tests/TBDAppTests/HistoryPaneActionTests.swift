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
        Thread { [self] in serve() }.start()
    }

    func stop() { lock.withLock { stopped = true } }

    private func serve() {
        defer { close(fd); try? FileManager.default.removeItem(atPath: root) }
        while !lock.withLock({ stopped }) {
            var pollFD = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            guard poll(&pollFD, 1, 100) > 0 else { continue }
            let connection = accept(fd, nil, nil)
            guard connection >= 0 else { continue }
            defer { close(connection) }
            var frame = Data()
            var buffer = [UInt8](repeating: 0, count: 4096)
            while !frame.contains(10) {
                let count = recv(connection, &buffer, buffer.count, 0)
                if count <= 0 { break }
                frame.append(contentsOf: buffer.prefix(count))
            }
            guard let line = frame.split(separator: 10).first,
                  let request = try? JSONDecoder().decode(RPCRequest.self, from: Data(line)) else { continue }
            lock.withLock { received.append(request) }
            let response = (try? answer(request)) ?? RPCResponse(error: "test response failed")
            guard var data = try? JSONEncoder().encode(response) else { continue }
            data.append(10)
            data.withUnsafeBytes { _ = send(connection, $0.baseAddress, $0.count, 0) }
        }
    }
}
