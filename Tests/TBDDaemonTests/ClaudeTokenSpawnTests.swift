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
        /// Concatenation of just the shell-command bodies (last argv element of
        /// each new-window call). Used to assert that secrets do NOT leak into
        /// the long-running shell process arg.
        var shellBodies: String {
            calls.compactMap { $0.last }.joined(separator: "\n")
        }
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
        // Token must be passed via tmux -e flag, never inlined in shell body.
        #expect(recorder.joinedAll.contains("CLAUDE_CODE_OAUTH_TOKEN=\(secret)"))
        #expect(!recorder.shellBodies.contains(secret),
                "secret leaked into shell body")
        #expect(!recorder.shellBodies.contains("CLAUDE_CODE_OAUTH_TOKEN"))
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
        #expect(recorder.joinedAll.contains("CLAUDE_CODE_OAUTH_TOKEN=\(secretB)"))
        #expect(!recorder.joinedAll.contains(secretA))
        #expect(!recorder.shellBodies.contains(secretB),
                "secret leaked into shell body")
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

    @Test("swap on blank session: forks into a new tab with a fresh session id and new token")
    func swapToDifferentToken() async throws {
        let (router, db, recorder) = makeFixture()
        defer { Task { await cleanup(db) } }
        let (_, wt) = try await seedRepoAndWorktree(db)
        let secretA = "sk-ant-oat01-AAAA"
        let secretB = "sk-ant-oat01-BBBB"
        let a = try await seedToken(db, name: "A", secret: secretA)
        let b = try await seedToken(db, name: "B", secret: secretB)
        try await db.config.setDefaultClaudeTokenID(a.id)

        // Spawn original claude terminal with token A. The session is "blank" —
        // no JSONL exists on disk for it — so swap should pick the fresh path.
        let createResp = await router.handle(try RPCRequest(
            method: RPCMethod.terminalCreate,
            params: TerminalCreateParams(worktreeID: wt.id, type: .claude)
        ))
        #expect(createResp.success)
        let oldTerm = try createResp.decodeResult(Terminal.self)
        #expect(oldTerm.claudeTokenID == a.id)
        let oldSessionID = oldTerm.claudeSessionID

        let beforeSwap = recorder.calls.count

        // Swap to B → returns a NEW terminal row, old one untouched
        let swapResp = await router.handle(try RPCRequest(
            method: RPCMethod.terminalSwapClaudeToken,
            params: TerminalSwapClaudeTokenParams(terminalID: oldTerm.id, newTokenID: b.id)
        ))
        #expect(swapResp.success)
        let newTerm = try swapResp.decodeResult(Terminal.self)
        #expect(newTerm.id != oldTerm.id)
        #expect(newTerm.claudeTokenID == b.id)
        // Blank session → fresh spawn with a NEW session id (not a resume of the old one).
        #expect(newTerm.claudeSessionID != nil)
        #expect(newTerm.claudeSessionID != oldSessionID)

        // Old terminal row is unchanged
        let oldAfter = try await db.terminals.get(id: oldTerm.id)
        #expect(oldAfter?.claudeTokenID == a.id)

        // Daemon did NOT send C-c or send-keys to the old pane
        let postSwap = Array(recorder.calls.dropFirst(beforeSwap))
        let joined = postSwap.map { $0.joined(separator: " ") }.joined(separator: "\n")
        #expect(!joined.contains("C-c"))
        #expect(!joined.contains("send-keys"))
        // The new tab was spawned with B's secret via tmux -e (NOT inlined),
        // and the shell body contains --session-id <newSessionID> (fresh path),
        // never --resume.
        #expect(joined.contains("CLAUDE_CODE_OAUTH_TOKEN=\(secretB)"))
        #expect(joined.contains("claude --session-id \(newTerm.claudeSessionID!)"))
        #expect(!joined.contains("claude --resume"))
        #expect(joined.contains("--dangerously-skip-permissions"))
        // Negative: secret must NOT appear in any shell body of post-swap calls.
        let postBodies = postSwap.compactMap { $0.last }.joined(separator: "\n")
        #expect(!postBodies.contains(secretB),
                "secret leaked into shell body: \(postBodies)")
        #expect(!postBodies.contains("CLAUDE_CODE_OAUTH_TOKEN"))
    }

    // MARK: - Swap: to nil

    @Test("swap: to nil forks new tab with no env prefix; old tab untouched")
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
        let oldTerm = try createResp.decodeResult(Terminal.self)
        #expect(oldTerm.claudeTokenID == a.id)

        let beforeSwap = recorder.calls.count

        let swapResp = await router.handle(try RPCRequest(
            method: RPCMethod.terminalSwapClaudeToken,
            params: TerminalSwapClaudeTokenParams(terminalID: oldTerm.id, newTokenID: nil)
        ))
        #expect(swapResp.success)
        let newTerm = try swapResp.decodeResult(Terminal.self)
        #expect(newTerm.id != oldTerm.id)
        #expect(newTerm.claudeTokenID == nil)
        // Old terminal still has its original token
        let oldAfter = try await db.terminals.get(id: oldTerm.id)
        #expect(oldAfter?.claudeTokenID == a.id)

        let postSwap = Array(recorder.calls.dropFirst(beforeSwap))
        let joined = postSwap.map { $0.joined(separator: " ") }.joined(separator: "\n")
        // Blank session → fresh --session-id, never --resume.
        #expect(joined.contains("claude --session-id"))
        #expect(!joined.contains("claude --resume"))
        #expect(!joined.contains("CLAUDE_CODE_OAUTH_TOKEN"))
        #expect(!joined.contains("C-c"))
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
