import Foundation
import Testing
@testable import TBDDaemonLib
@testable import TBDShared

@Suite("terminal.continueInCodex RPC")
struct ContinueInCodexRPCTests {
    private struct ExpectedCodexPreparationFailure: Error {}
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

        var calls: [[String]] {
            lock.lock()
            defer { lock.unlock() }
            return storage
        }
    }

    private final class DeadWindows: @unchecked Sendable {
        private let lock = NSLock()
        private var storage = Set<String>()

        func markDead(_ windowID: String) {
            lock.lock()
            storage.insert(windowID)
            lock.unlock()
        }

        func contains(_ windowID: String) -> Bool {
            lock.lock()
            defer { lock.unlock() }
            return storage.contains(windowID)
        }
    }

    private struct Fixture {
        let root: URL
        let db: TBDDatabase
        let router: RPCRouter
        let recorder: Recorder
        let deadWindows: DeadWindows
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
        let deadWindows = DeadWindows()
        let tmux = TmuxManager(
            dryRun: true,
            dryRunRecorder: { recorder.append($0) },
            dryRunWindowIsDead: { deadWindows.contains($0) })
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
        router.codexHomeEnsurer = {
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
            deadWindows: deadWindows, worktree: worktree,
            configManager: configManager)
    }

    private func createSource(
        in fixture: Fixture,
        transcriptName: String = "source.jsonl"
    ) async throws -> (Terminal, RPCRequest) {
        let transcript = fixture.root.appendingPathComponent(transcriptName)
        try #"{"type":"user","message":{"content":"continue safely"}}"#
            .write(to: transcript, atomically: true, encoding: .utf8)
        let sessionID = UUID().uuidString
        let source = try await fixture.db.terminals.create(
            worktreeID: fixture.worktree.id,
            tmuxWindowID: "@claude",
            tmuxPaneID: "%claude",
            label: "Claude",
            claudeSessionID: sessionID,
            kind: .claude)
        try await fixture.db.terminals.updateSession(
            id: source.id,
            sessionID: sessionID,
            transcriptPath: transcript.path)
        let request = try RPCRequest(
            method: RPCMethod.terminalContinueInCodex,
            params: TerminalContinueInCodexParams(sourceTerminalID: source.id))
        return (source, request)
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
        let sourceProfile = try await fixture.db.modelProfiles.create(
            name: "Source profile", kind: .oauth)
        let source = try await fixture.db.terminals.create(
            worktreeID: fixture.worktree.id,
            tmuxWindowID: "@claude",
            tmuxPaneID: "%claude",
            label: "Claude",
            claudeSessionID: "session-moved",
            profileID: sourceProfile.id,
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
        #expect(first.terminal.profileID == nil)
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

        // Takeover is one fresh Codex launch with the final prompt already in
        // the create-window command. It must never create an intermediate
        // terminal and then use Claude's non-atomic profile-swap/input path.
        let firstCalls = fixture.recorder.calls
        let newWindowCalls = firstCalls.filter { $0.contains("new-window") }
        #expect(newWindowCalls.count == 1)
        let launchBody = newWindowCalls.first?.last ?? ""
        #expect(launchBody.contains(first.handoffPath))
        #expect(
            launchBody.contains(" --profile tbd ")
                || launchBody.contains(" --profile-v2 tbd "))
        #expect(!firstCalls.contains { $0.contains("respawn-window") })
        #expect(!firstCalls.contains { $0.contains("send-keys") })
        #expect(!firstCalls.contains { $0.contains("load-buffer") })
        #expect(!firstCalls.contains { $0.contains("paste-buffer") })

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

    @Test("Codex home preparation fails before handoff, tmux, or terminal mutation")
    func codexHomeFailurePrecedesMutation() async throws {
        let fixture = try await makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let transcript = fixture.root.appendingPathComponent("source.jsonl")
        try #"{"type":"user","message":{"content":"preserve this source"}}"#
            .write(to: transcript, atomically: true, encoding: .utf8)
        let source = try await fixture.db.terminals.create(
            worktreeID: fixture.worktree.id,
            tmuxWindowID: "@claude",
            tmuxPaneID: "%claude",
            label: TerminalLabel.claudeCode,
            claudeSessionID: "preflight-session",
            kind: .claude)
        try await fixture.db.terminals.updateSession(
            id: source.id,
            sessionID: "preflight-session",
            transcriptPath: transcript.path)
        fixture.router.codexHomeEnsurer = {
            throw ExpectedCodexPreparationFailure()
        }
        let request = try RPCRequest(
            method: RPCMethod.terminalContinueInCodex,
            params: TerminalContinueInCodexParams(sourceTerminalID: source.id))

        let response = await fixture.router.handle(request)

        #expect(!response.success)
        #expect(fixture.recorder.joined.isEmpty)
        let terminals = try await fixture.db.terminals.list(
            worktreeID: fixture.worktree.id)
        let preservedSource = try #require(
            try await fixture.db.terminals.get(id: source.id))
        #expect(terminals == [preservedSource])
        let handoffDirectory = fixture.root
            .appendingPathComponent("handoffs", isDirectory: true)
            .appendingPathComponent(
                fixture.worktree.id.uuidString, isDirectory: true)
            .appendingPathComponent(source.id.uuidString, isDirectory: true)
        #expect(!FileManager.default.fileExists(atPath: handoffDirectory.path))
    }

    @Test("a missing handoff for a live takeover fails closed without duplicating")
    func missingHandoffDoesNotDuplicate() async throws {
        let fixture = try await makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let (_, request) = try await createSource(in: fixture)
        let firstResponse = await fixture.router.handle(request)
        let first = try firstResponse.decodeResult(
            TerminalContinueInCodexResult.self)
        try FileManager.default.removeItem(
            at: URL(fileURLWithPath: first.handoffPath))

        let retry = await fixture.router.handle(request)

        #expect(!retry.success)
        #expect(retry.error?.contains("handoff is missing") == true)
        #expect(retry.error?.contains("did not create a duplicate") == true)
        let terminals = try await fixture.db.terminals.list(
            worktreeID: fixture.worktree.id)
        #expect(terminals.filter(\.isCodexTerminal).count == 1)
    }

    @Test("a dead mapped takeover fails closed without duplicating")
    func deadMappedTargetDoesNotDuplicate() async throws {
        let fixture = try await makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let (_, request) = try await createSource(in: fixture)
        let firstResponse = await fixture.router.handle(request)
        let first = try firstResponse.decodeResult(
            TerminalContinueInCodexResult.self)
        fixture.deadWindows.markDead(first.terminal.tmuxWindowID)

        let retry = await fixture.router.handle(request)

        #expect(!retry.success)
        #expect(retry.error?.contains("no longer live") == true)
        #expect(retry.error?.contains("did not create a duplicate") == true)
        let terminals = try await fixture.db.terminals.list(
            worktreeID: fixture.worktree.id)
        #expect(terminals.filter(\.isCodexTerminal).count == 1)
    }

    @Test("an unreadable takeover manifest fails closed without duplicating")
    func unreadableManifestDoesNotDuplicate() async throws {
        let fixture = try await makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let (_, request) = try await createSource(in: fixture)
        let firstResponse = await fixture.router.handle(request)
        let first = try firstResponse.decodeResult(
            TerminalContinueInCodexResult.self)
        let manifestURL = URL(fileURLWithPath: first.handoffPath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("target.json")
        try Data("not json".utf8).write(to: manifestURL, options: .atomic)

        let retry = await fixture.router.handle(request)

        #expect(!retry.success)
        #expect(retry.error?.contains("mapping is unreadable") == true)
        #expect(retry.error?.contains("left all terminals untouched") == true)
        let terminals = try await fixture.db.terminals.list(
            worktreeID: fixture.worktree.id)
        #expect(terminals.filter(\.isCodexTerminal).count == 1)
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
            // An existing directory is not a usable transcript. The resolver
            // must continue to the profile-aware fallback instead of trying
            // to open it as JSONL.
            transcriptPath: fallbackFixture.root.path)
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
