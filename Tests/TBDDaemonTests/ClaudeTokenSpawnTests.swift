import Foundation
import Testing
@testable import TBDDaemonLib
@testable import TBDShared

@Suite("Claude Token Spawn + Swap")
struct ClaudeTokenSpawnTests {

    /// Recorder for tmux argv lists invoked during dryRun.
    final class TmuxRecorder: @unchecked Sendable {
        private let lock = NSLock()
        private var _calls: [[String]] = []
        var calls: [[String]] {
            lock.lock(); defer { lock.unlock() }
            return _calls
        }
        func record(_ args: [String]) {
            lock.lock(); defer { lock.unlock() }
            _calls.append(args)
        }
        var joinedAll: String { calls.map { $0.joined(separator: " ") }.joined(separator: "\n") }
    }

    private func makeFixture() -> (RPCRouter, TBDDatabase, TmuxRecorder) {
        let recorder = TmuxRecorder()
        let tmux = TmuxManager(dryRun: true, dryRunRecorder: { args in recorder.record(args) })
        let db = try! TBDDatabase(inMemory: true)
        let lifecycle = WorktreeLifecycle(db: db, git: GitManager(), tmux: tmux, hooks: HookResolver())
        let router = RPCRouter(
            db: db,
            lifecycle: lifecycle,
            tmux: tmux,
            startTime: Date(),
            usageFetcher: StubClaudeUsageFetcher()
        )
        return (router, db, recorder)
    }

    private func seedRepoAndWorktree(_ db: TBDDatabase) async throws -> (Repo, Worktree) {
        let repo = try await db.repos.create(
            path: "/tmp/r-\(UUID().uuidString)",
            displayName: "r",
            defaultBranch: "main"
        )
        let wt = try await db.worktrees.create(
            repoID: repo.id,
            name: "wt",
            branch: "main",
            path: "/tmp/wt-\(UUID().uuidString)",
            tmuxServer: "tbd-test"
        )
        return (repo, wt)
    }

    private func seedToken(_ db: TBDDatabase, name: String, secret: String) async throws -> ClaudeToken {
        let row = try await db.claudeTokens.create(name: name, kind: .oauth)
        try ClaudeTokenKeychain.store(id: row.id.uuidString, token: secret)
        return row
    }

    private func cleanup(_ db: TBDDatabase) async {
        let toks = (try? await db.claudeTokens.list()) ?? []
        for t in toks { try? ClaudeTokenKeychain.delete(id: t.id.uuidString) }
    }

    // MARK: - Spawn: no token configured

    @Test("spawn: no tokens → no env prefix, claudeTokenID nil")
    func spawnNoToken() async throws {
        let (router, db, recorder) = makeFixture()
        defer { Task { await cleanup(db) } }
        let (_, wt) = try await seedRepoAndWorktree(db)

        let req = try RPCRequest(
            method: RPCMethod.terminalCreate,
            params: TerminalCreateParams(worktreeID: wt.id, type: .claude)
        )
        let resp = await router.handle(req)
        #expect(resp.success)
        let term = try resp.decodeResult(Terminal.self)
        #expect(term.claudeTokenID == nil)
        #expect(!recorder.joinedAll.contains("CLAUDE_CODE_OAUTH_TOKEN"))
    }

    // MARK: - Spawn: global default

    @Test("spawn: global default → env prefix + claudeTokenID")
    func spawnWithGlobalDefault() async throws {
        let (router, db, recorder) = makeFixture()
        defer { Task { await cleanup(db) } }
        let (_, wt) = try await seedRepoAndWorktree(db)
        let secret = "sk-ant-oat01-fakeAAAA"
        let tok = try await seedToken(db, name: "Default", secret: secret)
        try await db.config.setDefaultClaudeTokenID(tok.id)

        let req = try RPCRequest(
            method: RPCMethod.terminalCreate,
            params: TerminalCreateParams(worktreeID: wt.id, type: .claude)
        )
        let resp = await router.handle(req)
        #expect(resp.success)
        let term = try resp.decodeResult(Terminal.self)
        #expect(term.claudeTokenID == tok.id)
        #expect(recorder.joinedAll.contains("CLAUDE_CODE_OAUTH_TOKEN='\(secret)'"))
    }

    // MARK: - Spawn: repo override beats default

    @Test("spawn: repo override beats global default")
    func spawnRepoOverride() async throws {
        let (router, db, recorder) = makeFixture()
        defer { Task { await cleanup(db) } }
        let (repo, wt) = try await seedRepoAndWorktree(db)
        let secretA = "sk-ant-oat01-AAAA"
        let secretB = "sk-ant-oat01-BBBB"
        let a = try await seedToken(db, name: "A", secret: secretA)
        let b = try await seedToken(db, name: "B", secret: secretB)
        try await db.config.setDefaultClaudeTokenID(a.id)
        try await db.repos.setClaudeTokenOverride(id: repo.id, tokenID: b.id)

        let req = try RPCRequest(
            method: RPCMethod.terminalCreate,
            params: TerminalCreateParams(worktreeID: wt.id, type: .claude)
        )
        let resp = await router.handle(req)
        #expect(resp.success)
        let term = try resp.decodeResult(Terminal.self)
        #expect(term.claudeTokenID == b.id)
        #expect(recorder.joinedAll.contains("CLAUDE_CODE_OAUTH_TOKEN='\(secretB)'"))
        #expect(!recorder.joinedAll.contains(secretA))
    }

    // MARK: - Spawn: non-claude type ignores token

    @Test("spawn: non-claude type ignores token")
    func spawnNonClaudeIgnoresToken() async throws {
        let (router, db, recorder) = makeFixture()
        defer { Task { await cleanup(db) } }
        let (_, wt) = try await seedRepoAndWorktree(db)
        let secret = "sk-ant-oat01-AAAA"
        let tok = try await seedToken(db, name: "A", secret: secret)
        try await db.config.setDefaultClaudeTokenID(tok.id)

        let req = try RPCRequest(
            method: RPCMethod.terminalCreate,
            params: TerminalCreateParams(worktreeID: wt.id, cmd: "ls", type: .shell)
        )
        let resp = await router.handle(req)
        #expect(resp.success)
        let term = try resp.decodeResult(Terminal.self)
        #expect(term.claudeTokenID == nil)
        #expect(!recorder.joinedAll.contains("CLAUDE_CODE_OAUTH_TOKEN"))
    }

    // MARK: - Swap: to a different token

    @Test("swap: to different token updates row + sends respawn with new prefix")
    func swapToDifferentToken() async throws {
        let (router, db, recorder) = makeFixture()
        defer { Task { await cleanup(db) } }
        let (_, wt) = try await seedRepoAndWorktree(db)
        let secretA = "sk-ant-oat01-AAAA"
        let secretB = "sk-ant-oat01-BBBB"
        let a = try await seedToken(db, name: "A", secret: secretA)
        let b = try await seedToken(db, name: "B", secret: secretB)
        try await db.config.setDefaultClaudeTokenID(a.id)

        // Spawn a claude terminal with token A
        let createResp = await router.handle(try RPCRequest(
            method: RPCMethod.terminalCreate,
            params: TerminalCreateParams(worktreeID: wt.id, type: .claude)
        ))
        #expect(createResp.success)
        let term = try createResp.decodeResult(Terminal.self)
        #expect(term.claudeTokenID == a.id)

        // Swap to B
        let swapResp = await router.handle(try RPCRequest(
            method: RPCMethod.terminalSwapClaudeToken,
            params: TerminalSwapClaudeTokenParams(terminalID: term.id, newTokenID: b.id)
        ))
        #expect(swapResp.success)
        let updated = try swapResp.decodeResult(Terminal.self)
        #expect(updated.claudeTokenID == b.id)

        let joined = recorder.joinedAll
        #expect(joined.contains("send-keys"))
        // C-c was sent
        #expect(recorder.calls.contains { $0.contains("C-c") })
        // Respawn command contains B's secret
        #expect(joined.contains("CLAUDE_CODE_OAUTH_TOKEN='\(secretB)' claude --resume"))
        #expect(joined.contains("--dangerously-skip-permissions"))
    }

    // MARK: - Swap: to nil

    @Test("swap: to nil clears token + no env prefix")
    func swapToNil() async throws {
        let (router, db, recorder) = makeFixture()
        defer { Task { await cleanup(db) } }
        let (_, wt) = try await seedRepoAndWorktree(db)
        let secretA = "sk-ant-oat01-AAAA"
        let a = try await seedToken(db, name: "A", secret: secretA)
        try await db.config.setDefaultClaudeTokenID(a.id)

        let createResp = await router.handle(try RPCRequest(
            method: RPCMethod.terminalCreate,
            params: TerminalCreateParams(worktreeID: wt.id, type: .claude)
        ))
        let term = try createResp.decodeResult(Terminal.self)

        // Clear recorder of spawn commands so we only inspect swap output
        let beforeSwap = recorder.calls.count

        let swapResp = await router.handle(try RPCRequest(
            method: RPCMethod.terminalSwapClaudeToken,
            params: TerminalSwapClaudeTokenParams(terminalID: term.id, newTokenID: nil)
        ))
        #expect(swapResp.success)
        let updated = try swapResp.decodeResult(Terminal.self)
        #expect(updated.claudeTokenID == nil)

        let postSwap = Array(recorder.calls.dropFirst(beforeSwap))
        let joined = postSwap.map { $0.joined(separator: " ") }.joined(separator: "\n")
        #expect(joined.contains("claude --resume"))
        #expect(!joined.contains("CLAUDE_CODE_OAUTH_TOKEN"))
    }

    // MARK: - Swap: non-claude terminal errors

    @Test("swap: on non-claude terminal returns error")
    func swapOnNonClaude() async throws {
        let (router, db, _) = makeFixture()
        defer { Task { await cleanup(db) } }
        let (_, wt) = try await seedRepoAndWorktree(db)

        let createResp = await router.handle(try RPCRequest(
            method: RPCMethod.terminalCreate,
            params: TerminalCreateParams(worktreeID: wt.id, cmd: "ls", type: .shell)
        ))
        let term = try createResp.decodeResult(Terminal.self)
        #expect(term.claudeSessionID == nil)

        let swapResp = await router.handle(try RPCRequest(
            method: RPCMethod.terminalSwapClaudeToken,
            params: TerminalSwapClaudeTokenParams(terminalID: term.id, newTokenID: nil)
        ))
        #expect(!swapResp.success)
        #expect(swapResp.error?.contains("not a Claude terminal") == true)
    }

    // MARK: - Swap: unknown token id

    @Test("swap: unknown token id returns error")
    func swapUnknownToken() async throws {
        let (router, db, _) = makeFixture()
        defer { Task { await cleanup(db) } }
        let (_, wt) = try await seedRepoAndWorktree(db)

        let createResp = await router.handle(try RPCRequest(
            method: RPCMethod.terminalCreate,
            params: TerminalCreateParams(worktreeID: wt.id, type: .claude)
        ))
        let term = try createResp.decodeResult(Terminal.self)

        let swapResp = await router.handle(try RPCRequest(
            method: RPCMethod.terminalSwapClaudeToken,
            params: TerminalSwapClaudeTokenParams(terminalID: term.id, newTokenID: UUID())
        ))
        #expect(!swapResp.success)
    }
}
