import Foundation
import Testing
@testable import TBDDaemonLib
@testable import TBDShared

@Suite("terminal.continueInCodex RPC")
struct ContinueInCodexRPCTests {
    private final class Recorder: @unchecked Sendable {
        private let lock = NSLock()
        private var storage: [[String]] = []

        func append(_ arguments: [String]) {
            lock.lock()
            storage.append(arguments)
            lock.unlock()
        }

        var joined: String {
            lock.lock()
            defer { lock.unlock() }
            return storage.map { $0.joined(separator: " ") }.joined(separator: "\n")
        }
    }

    private struct Fixture {
        let root: URL
        let db: TBDDatabase
        let router: RPCRouter
        let recorder: Recorder
        let worktree: Worktree
        let configManager: ClaudeProfileConfigDirManager
    }

    private func makeFixture() async throws -> Fixture {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("tbd-continue-codex-\(UUID())", isDirectory: true)
        let worktreeDirectory = root.appendingPathComponent("worktree", isDirectory: true)
        try FileManager.default.createDirectory(
            at: worktreeDirectory, withIntermediateDirectories: true)
        let db = try TBDDatabase(inMemory: true)
        let recorder = Recorder()
        let tmux = TmuxManager(
            dryRun: true, dryRunRecorder: { recorder.append($0) })
        let configManager = ClaudeProfileConfigDirManager(
            baseDirectory: root.appendingPathComponent("profiles", isDirectory: true),
            hostBaseDirectory: root.appendingPathComponent("claude", isDirectory: true))
        let router = RPCRouter(
            db: db,
            lifecycle: WorktreeLifecycle(
                db: db, git: GitManager(), tmux: tmux, hooks: HookResolver(),
                configDirManager: configManager),
            tmux: tmux,
            configDirManager: configManager)
        router.continueInCodexHandoffRoot = root.appendingPathComponent(
            "handoffs", isDirectory: true)
        router.codexExecutableResolver = { "/opt/test/bin/codex" }
        router.continueInCodexHomeEnsurer = {
            root.appendingPathComponent("codex-home", isDirectory: true)
        }
        let repo = try await db.repos.create(
            path: worktreeDirectory.path,
            displayName: "pilot-repo",
            defaultBranch: "main")
        let worktree = try await db.worktrees.create(
            repoID: repo.id,
            name: "pilot",
            branch: "feature/handoff",
            path: worktreeDirectory.path,
            tmuxServer: "tbd-continue-test")
        return Fixture(
            root: root, db: db, router: router, recorder: recorder,
            worktree: worktree, configManager: configManager)
    }

    @Test("creates one Codex target, preserves Claude, and dedupes retries")
    func createsAndDedupes() async throws {
        let fixture = try await makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let transcript = fixture.root.appendingPathComponent(
            "moved/unusual-session.jsonl")
        try FileManager.default.createDirectory(
            at: transcript.deletingLastPathComponent(),
            withIntermediateDirectories: true)
        try """
        {"type":"user","message":{"content":"finish takeover support"}}
        {"type":"assistant","message":{"content":"daemon handler is next"}}
        """.write(to: transcript, atomically: true, encoding: .utf8)
        let source = try await fixture.db.terminals.create(
            worktreeID: fixture.worktree.id,
            tmuxWindowID: "@claude",
            tmuxPaneID: "%claude",
            label: "Claude",
            claudeSessionID: "session-moved",
            kind: .claude)
        try await fixture.db.terminals.updateSession(
            id: source.id,
            sessionID: "session-moved",
            transcriptPath: transcript.path)
        let sourceAfterSetup = try await fixture.db.terminals.get(id: source.id)
        let request = try RPCRequest(
            method: RPCMethod.terminalContinueInCodex,
            params: TerminalContinueInCodexParams(sourceTerminalID: source.id))

        let firstResponse = await fixture.router.handle(request)
        #expect(firstResponse.success)
        let first = try firstResponse.decodeResult(TerminalContinueInCodexResult.self)
        #expect(first.created)
        #expect(first.terminal.isCodexTerminal)
        #expect(first.terminal.worktreeID == source.worktreeID)
        #expect(first.target == .localCodex)
        #expect(first.capture.transcriptBytesRead > 0)
        #expect(first.capture.transcriptBytesRendered > 0)
        #expect(first.capture.handoffBytesOutput > 0)
        #expect(!first.capture.transcriptTailTruncated)
        let warningCodes = Set(first.warnings.map(\.code))
        #expect(warningCodes.contains("readiness_pending"))
        #expect(warningCodes.contains("bootstrap_partial_or_missing"))
        #expect(warningCodes.contains("codex_skill_rewrite_broken"))
        #expect(warningCodes.contains("skill_context_overload"))
        #expect(warningCodes.contains("bootstrap_untouched"))
        let warningMessages = first.warnings.map(\.message).joined(separator: "\n")
        #expect(warningMessages.contains("machine-readable"))
        #expect(warningMessages.contains("partial or missing"))
        #expect(warningMessages.contains(".Codex/skills"))
        #expect(warningMessages.contains("context budget"))
        #expect(warningMessages.contains("did not stage, repair"))
        #expect(try await fixture.db.terminals.get(id: source.id) == sourceAfterSetup)
        let handoffDirectory = URL(fileURLWithPath: first.handoffPath)
            .deletingLastPathComponent()
        #expect(UUID(uuidString: handoffDirectory.lastPathComponent) != nil)
        let handoff = try String(contentsOfFile: first.handoffPath, encoding: .utf8)
        #expect(handoff.contains("finish takeover support"))
        #expect(handoff.contains("feature/handoff"))
        #expect(handoff.contains(transcript.path))
        #expect(fixture.recorder.joined.contains("/opt/test/bin/codex"))
        #expect(fixture.recorder.joined.contains(first.handoffPath))
        #expect(fixture.recorder.joined.contains("AGENTS.md"))
        #expect(fixture.recorder.joined.contains("claim-work"))
        #expect(fixture.recorder.joined.contains("Claude-only"))

        let secondResponse = await fixture.router.handle(request)
        #expect(secondResponse.success)
        let second = try secondResponse.decodeResult(TerminalContinueInCodexResult.self)
        #expect(!second.created)
        #expect(second.terminal.id == first.terminal.id)
        #expect(second.handoffPath == first.handoffPath)
        #expect(second.capture == first.capture)
        #expect(second.warnings == first.warnings)
        #expect(second.target == first.target)
        let manifestURL = handoffDirectory
            .deletingLastPathComponent()
            .appendingPathComponent("target.json")
        let manifest = try JSONDecoder().decode(
            ContinueInCodexManifest.self, from: Data(contentsOf: manifestURL))
        #expect(manifest.handoffPath == first.handoffPath)
        let terminals = try await fixture.db.terminals.list(
            worktreeID: fixture.worktree.id)
        #expect(terminals.filter(\.isCodexTerminal).count == 1)
    }

    @Test("unavailable transcript returns a useful error without creating Codex")
    func transcriptUnavailable() async throws {
        let fixture = try await makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let source = try await fixture.db.terminals.create(
            worktreeID: fixture.worktree.id,
            tmuxWindowID: "@claude",
            tmuxPaneID: "%claude",
            label: "Claude",
            claudeSessionID: "missing-session",
            kind: .claude)
        let request = try RPCRequest(
            method: RPCMethod.terminalContinueInCodex,
            params: TerminalContinueInCodexParams(sourceTerminalID: source.id))

        let response = await fixture.router.handle(request)

        #expect(!response.success)
        #expect(response.error?.contains("transcript unavailable") == true)
        let terminals = try await fixture.db.terminals.list(
            worktreeID: fixture.worktree.id)
        #expect(terminals.filter(\.isCodexTerminal).isEmpty)
    }

    @Test("uses profile-aware transcript fallback and rejects non-Claude without mutation")
    func fallbackAndSourceValidation() async throws {
        let fallbackFixture = try await makeFixture()
        defer { try? FileManager.default.removeItem(at: fallbackFixture.root) }
        let profile = try await fallbackFixture.db.modelProfiles.create(
            name: "Fallback profile", kind: .oauth)
        let sessionID = "profile-session"
        let slug = fallbackFixture.worktree.path.map {
            "/.".contains($0) ? "-" : String($0)
        }.joined()
        let transcript = fallbackFixture.configManager
            .configDirectory(forProfileID: profile.id)
            .appendingPathComponent("projects", isDirectory: true)
            .appendingPathComponent(slug, isDirectory: true)
            .appendingPathComponent("\(sessionID).jsonl")
        try FileManager.default.createDirectory(
            at: transcript.deletingLastPathComponent(),
            withIntermediateDirectories: true)
        try #"{"type":"user","message":{"content":"profile fallback found"}}"#
            .write(to: transcript, atomically: true, encoding: .utf8)
        let source = try await fallbackFixture.db.terminals.create(
            worktreeID: fallbackFixture.worktree.id,
            tmuxWindowID: "@claude",
            tmuxPaneID: "%claude",
            label: "Claude",
            claudeSessionID: sessionID,
            profileID: profile.id,
            kind: .claude)
        try await fallbackFixture.db.terminals.updateSession(
            id: source.id,
            sessionID: sessionID,
            transcriptPath: fallbackFixture.root
                .appendingPathComponent("stale.jsonl").path)
        ClaudeProjectDirectory.clearCache()

        let fallbackResponse = await fallbackFixture.router.handle(try RPCRequest(
            method: RPCMethod.terminalContinueInCodex,
            params: TerminalContinueInCodexParams(sourceTerminalID: source.id)))

        #expect(fallbackResponse.success)
        let fallbackResult = try fallbackResponse.decodeResult(
            TerminalContinueInCodexResult.self)
        let handoff = try String(
            contentsOfFile: fallbackResult.handoffPath, encoding: .utf8)
        #expect(handoff.contains("profile fallback found"))

        let rejectionFixture = try await makeFixture()
        defer { try? FileManager.default.removeItem(at: rejectionFixture.root) }
        let shell = try await rejectionFixture.db.terminals.create(
            worktreeID: rejectionFixture.worktree.id,
            tmuxWindowID: "@shell",
            tmuxPaneID: "%shell",
            label: "Shell",
            kind: .shell)
        let before = try await rejectionFixture.db.terminals.list(
            worktreeID: rejectionFixture.worktree.id)

        let unsupportedTarget = await rejectionFixture.router.handle(try RPCRequest(
            method: RPCMethod.terminalContinueInCodex,
            params: TerminalContinueInCodexParams(
                sourceTerminalID: shell.id,
                target: TerminalContinueInCodexTarget(
                    kind: "agent_box", workerID: "future-worker"))))
        let rejection = await rejectionFixture.router.handle(try RPCRequest(
            method: RPCMethod.terminalContinueInCodex,
            params: TerminalContinueInCodexParams(sourceTerminalID: shell.id)))

        #expect(!unsupportedTarget.success)
        #expect(unsupportedTarget.error?.contains("supports only local_codex") == true)
        #expect(!rejection.success)
        #expect(rejection.error?.contains("requires a Claude terminal") == true)
        #expect(rejectionFixture.recorder.joined.isEmpty)
        #expect(try await rejectionFixture.db.terminals.list(
            worktreeID: rejectionFixture.worktree.id) == before)
    }
}
