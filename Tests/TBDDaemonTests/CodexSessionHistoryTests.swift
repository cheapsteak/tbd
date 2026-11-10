import Darwin
import Foundation
import Testing
@testable import TBDDaemonLib
@testable import TBDShared
import DaemonTestSupport

@Suite("CodexSessionHistory")
struct CodexSessionHistoryTests {
    private struct Fixture {
        let root: URL
        let db: TBDDatabase
        let router: RPCRouter
        let worktree: Worktree
        let home: URL
        let file: URL
        let session: LocalAgentSession
    }

    private func fixture(sharedHome: Bool = false) async throws -> Fixture {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("codex-history-\(UUID().uuidString)").resolvingSymlinksInPath()
        let home = sharedHome ? CodexHomeManager().codexHome.appendingPathComponent(UUID().uuidString).resolvingSymlinksInPath() : root.appendingPathComponent("home")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        let file = home.appendingPathComponent("rollout.jsonl")
        try """
        {"type":"session_meta","payload":{"id":"same","source":"cli","cwd":"/acme/project","git":{"branch":"main"}}}
        {"type":"response_item","timestamp":"2026-01-01T00:00:00.125Z","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"Sample prompt"}]}}
        {"type":"response_item","timestamp":"2026-01-01T00:00:02Z","payload":{"type":"message","role":"assistant","content":[{"type":"output_text","text":"Sample answer"}]}}
        
        """.write(to: file, atomically: true, encoding: .utf8)
        let db = try TBDDatabase(inMemory: true)
        let tmux = TmuxManager(dryRun: true)
        let router = RPCRouter(db: db, lifecycle: WorktreeLifecycle(db: db, git: GitManager(), tmux: tmux, hooks: HookResolver()),
                               tmux: tmux, actuationLog: makeTestActuationLog())
        let repo = try await db.repos.create(path: root.path, displayName: "sample", defaultBranch: "main")
        let worktree = try await db.worktrees.create(repoID: repo.id, name: "sample", branch: "sample", path: root.path, tmuxServer: "history-test")
        let session = LocalAgentSession(worktreeID: worktree.id,
                                       identity: AgentSessionIdentity(agentKind: .codex, sessionID: "same"), transcriptPath: file.path,
                                       codexLaunchOptions: sharedHome ? nil : CodexLaunchOptions(codexHome: home.path),
                                       firstObservedAt: Date(timeIntervalSince1970: 100), lastObservedAt: Date(timeIntervalSince1970: 200))
        try await db.localAgentSessions.upsert(session)
        return Fixture(root: root, db: db, router: router, worktree: worktree, home: home, file: file, session: session)
    }

    private func messages(_ f: Fixture, worktreeID: UUID? = nil, identity: AgentSessionIdentity? = nil,
                          filePath: String? = nil, tailLimit: Int? = nil) async throws -> RPCResponse {
        await f.router.handle(try RPCRequest(method: RPCMethod.sessionMessages,
                                            params: SessionMessagesParams(filePath: filePath, worktreeID: worktreeID ?? f.worktree.id,
                                                                          identity: identity ?? f.session.identity, tailLimit: tailLimit)))
    }

    @Test("list merges legacy Claude scanning with cataloged Codex and sorts by last activity")
    func mergesProviders() async throws {
        let f = try await fixture()
        defer { try? FileManager.default.removeItem(at: f.root) }
        let project = ClaudeProjectDirectory.expectedDirectory(worktreePath: f.root.path)
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: project) }
        try "{\"type\":\"user\",\"sessionId\":\"same\",\"timestamp\":\"2025-01-01T00:00:00Z\",\"message\":{\"role\":\"user\",\"content\":\"Claude prompt\"}}\n"
            .write(to: project.appendingPathComponent("same.jsonl"), atomically: true, encoding: .utf8)
        // Catalog Claude rows must not replace or duplicate the legacy scan.
        try await f.db.localAgentSessions.upsert(LocalAgentSession(worktreeID: f.worktree.id,
            identity: AgentSessionIdentity(agentKind: .claude, sessionID: "same"), firstObservedAt: .distantPast, lastObservedAt: .distantPast))
        try await f.db.localAgentSessions.upsert(f.session)
        // An uncataloged rollout with a matching cwd is not ownership evidence.
        try Data(contentsOf: f.file).write(to: f.home.appendingPathComponent("uncataloged.jsonl"))
        let response = await f.router.handle(try RPCRequest(method: RPCMethod.sessionList, params: SessionListParams(worktreeID: f.worktree.id)))
        let summaries = try response.decodeResult([SessionSummary].self)
        #expect(summaries.count == 2)
        #expect(summaries.map(\.identity.agentKind) == [.codex, .claude])
        #expect(Set(summaries.map(\.id)).count == 2)
        #expect(summaries[0].firstUserMessage == "Sample prompt")
        #expect(summaries[0].lastUserMessage == "Sample prompt")
        #expect(summaries[0].cwd == "/acme/project")
        #expect(summaries[0].gitBranch == "main")
        #expect(summaries[0].transcriptAvailable)
    }

    @Test("reads only a cataloged dedicated or shared home and ignores a supplied client path", arguments: [false, true])
    func catalogAuthority(sharedHome: Bool) async throws {
        let f = try await fixture(sharedHome: sharedHome)
        defer {
            try? FileManager.default.removeItem(at: f.root)
            if sharedHome { try? FileManager.default.removeItem(at: f.home) }
        }
        let response = try await messages(f, filePath: "/untrusted/client/path", tailLimit: 1)
        #expect(response.success)
        let items = try response.decodeResult([TranscriptItem].self)
        #expect(items.count == 1)
        guard case .assistantText(_, "Sample answer", _, _) = items.first else {
            Issue.record("Expected recorded transcript"); return
        }
        #expect(try await messages(f, worktreeID: UUID()).success == false)
        #expect(try await messages(f, identity: AgentSessionIdentity(agentKind: .codex, sessionID: "wrong")).success == false)
    }

    @Test("missing and unreadable transcripts remain listed and keep their resumable association", arguments: [false, true])
    func unavailable(unreadable: Bool) async throws {
        let f = try await fixture()
        defer { try? FileManager.default.removeItem(at: f.root) }
        if unreadable { #expect(chmod(f.file.path, 0) == 0) }
        else { try FileManager.default.removeItem(at: f.file) }
        defer { if unreadable { chmod(f.file.path, 0o600) } }
        let response = await f.router.handle(try RPCRequest(method: RPCMethod.sessionList, params: SessionListParams(worktreeID: f.worktree.id)))
        let summaries = try response.decodeResult([SessionSummary].self)
        #expect(summaries.count == 1)
        #expect(summaries.first?.transcriptAvailable == false)
        #expect(summaries.first?.identity == f.session.identity)
        #expect(try await messages(f).decodeResult([TranscriptItem].self).isEmpty)
        #expect(try await f.db.localAgentSessions.get(worktreeID: f.worktree.id, identity: f.session.identity) == f.session)
    }

    @Test("refuses directories, symlinks, FIFOs, and paths escaping the cataloged home", arguments: ["directory", "symlink", "parent-link", "fifo", "outside", "prefix-sibling", "home-link", "broken-home-link"])
    func rejectsUnsafeFiles(kind: String) async throws {
        let f = try await fixture()
        defer { try? FileManager.default.removeItem(at: f.root) }
        let bytes = try Data(contentsOf: f.file)
        try FileManager.default.removeItem(at: f.file)
        var path = f.file.path
        switch kind {
        case "directory": try FileManager.default.createDirectory(at: f.file, withIntermediateDirectories: true)
        case "symlink":
            let other = f.home.appendingPathComponent("other.jsonl")
            try bytes.write(to: other)
            try FileManager.default.createSymbolicLink(at: f.file, withDestinationURL: other)
        case "parent-link":
            let actual = f.home.appendingPathComponent("actual")
            try FileManager.default.createDirectory(at: actual, withIntermediateDirectories: true)
            try bytes.write(to: actual.appendingPathComponent("rollout.jsonl"))
            let link = f.home.appendingPathComponent("linked")
            try FileManager.default.createSymbolicLink(at: link, withDestinationURL: actual)
            path = link.appendingPathComponent("rollout.jsonl").path
        case "home-link", "broken-home-link":
            let actual = f.root.appendingPathComponent("actual-home")
            try FileManager.default.moveItem(at: f.home, to: actual)
            let destination = kind == "home-link" ? actual : f.root.appendingPathComponent("missing-home")
            try FileManager.default.createSymbolicLink(at: f.home, withDestinationURL: destination)
        case "fifo": #expect(mkfifo(f.file.path, 0o600) == 0)
        case "prefix-sibling":
            let sibling = f.root.appendingPathComponent("home-other")
            try FileManager.default.createDirectory(at: sibling, withIntermediateDirectories: true)
            path = sibling.appendingPathComponent("rollout.jsonl").path
            try bytes.write(to: URL(fileURLWithPath: path))
        default:
            path = f.root.appendingPathComponent("outside.jsonl").path
            try bytes.write(to: URL(fileURLWithPath: path))
        }
        try await f.db.localAgentSessions.upsert(replacing(f.session, path: path))
        #expect(try await messages(f).success == false)
    }

    @Test("changing a catalog path or replacing its file while validation is pending refuses the read", arguments: ["association", "file", "parent", "association-after-parse"])
    func replacementDuringValidation(kind: String) async throws {
        let f = try await fixture()
        defer { try? FileManager.default.removeItem(at: f.root) }
        var validationCount = 0
        await #expect(throws: (any Error).self) {
            _ = try await CodexSessionScanner.messages(f.session, currentSession: {
                validationCount += 1
                if kind == "association-after-parse", validationCount == 1 { return f.session }
                if kind == "association" || kind == "association-after-parse" {
                    try await f.db.localAgentSessions.upsert(replacing(f.session, path: f.home.appendingPathComponent("changed.jsonl").path))
                } else if kind == "parent" {
                    try FileManager.default.moveItem(at: f.home, to: f.root.appendingPathComponent("old-home"))
                    try FileManager.default.createDirectory(at: f.home, withIntermediateDirectories: true)
                    try Data().write(to: f.file)
                } else {
                    try Data().write(to: f.file, options: .atomic)
                }
                return try await f.db.localAgentSessions.get(worktreeID: f.worktree.id, identity: f.session.identity)
            })
        }
    }

    @Test("legacy Claude path contract still reads inside projects and refuses outside")
    func legacyClaudePath() async throws {
        let f = try await fixture()
        defer { try? FileManager.default.removeItem(at: f.root) }
        let project = ClaudeProjectDirectory.expectedDirectory(worktreePath: f.root.path)
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: project) }
        let path = project.appendingPathComponent("legacy.jsonl")
        try "{\"type\":\"user\",\"message\":{\"role\":\"user\",\"content\":\"Legacy prompt\"}}\n".write(to: path, atomically: true, encoding: .utf8)
        let good = await f.router.handle(try RPCRequest(method: RPCMethod.sessionMessages, params: SessionMessagesParams(filePath: path.path)))
        #expect(try good.decodeResult([TranscriptItem].self).count == 1)
        let bad = await f.router.handle(try RPCRequest(method: RPCMethod.sessionMessages, params: SessionMessagesParams(filePath: f.file.path)))
        #expect(!bad.success)
    }

    @Test("legacy scanning does not require a catalog association")
    func legacyWithoutCatalog() async throws {
        let f = try await fixture()
        defer { try? FileManager.default.removeItem(at: f.root) }
        let worktree = try await f.db.worktrees.create(repoID: try #require(f.worktree.repoID), name: "legacy", branch: "legacy",
                                                       path: f.root.appendingPathComponent("legacy").path, tmuxServer: "history-legacy")
        let project = ClaudeProjectDirectory.expectedDirectory(worktreePath: f.root.appendingPathComponent("legacy").path)
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: project) }
        try #"{"type":"user","sessionId":"legacy","message":{"role":"user","content":"Legacy prompt"}}"#
            .write(to: project.appendingPathComponent("legacy.jsonl"), atomically: true, encoding: .utf8)
        let response = await f.router.handle(try RPCRequest(method: RPCMethod.sessionList, params: SessionListParams(worktreeID: worktree.id)))
        let summaries = try response.decodeResult([SessionSummary].self)
        #expect(summaries.count == 1)
        #expect(summaries.first?.firstUserMessage == "Legacy prompt")
        #expect(summaries.first?.identity.agentKind == .claude)
    }

    @Test("bounded summary skips oversized records and retains later previews and activity")
    func boundedSummary() async throws {
        let f = try await fixture()
        defer { try? FileManager.default.removeItem(at: f.root) }
        var bytes = try Data(contentsOf: f.file)
        bytes.append(try JSONSerialization.data(withJSONObject: ["type": "response_item", "payload": ["type": "function_call_output", "output": String(repeating: "x", count: 100_000)]]))
        bytes.append(0x0A)
        bytes.append(try JSONSerialization.data(withJSONObject: ["type": "event_msg", "timestamp": "2026-01-02T00:00:00Z", "payload": ["type": "user_message", "message": String(repeating: "y", count: 400)]]))
        bytes.append(0x0A)
        try bytes.write(to: f.file)
        let summary = CodexSessionScanner.summary(f.session)
        #expect(summary.firstUserMessage == "Sample prompt")
        #expect(summary.lastUserMessage == String(repeating: "y", count: 300))
        #expect(summary.lastMessageAt == Date(timeIntervalSince1970: 1_767_312_000))
        #expect(summary.lineCount == 5)
        #expect(summary.fileSize == bytes.count)
        #expect(summary.transcriptAvailable)
    }

    private func replacing(_ session: LocalAgentSession, path: String) -> LocalAgentSession {
        LocalAgentSession(id: session.id, worktreeID: session.worktreeID, identity: session.identity,
                          transcriptPath: path, codexLaunchOptions: session.codexLaunchOptions,
                          firstObservedAt: session.firstObservedAt, lastObservedAt: session.lastObservedAt)
    }
}
