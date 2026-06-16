import Foundation
import Testing
@testable import TBDDaemonLib
@testable import TBDShared

// Nested under TBDHomeSerialized: several tests mutate the process-global
// `TBD_HOME` env var (via setenv/unsetenv) to isolate the overlay/runtime dir.
// Nesting prevents cross-suite races with the other TBD_HOME-mutating suites.
// See TBDHomeSerializedSuites.swift.
extension TBDHomeSerialized {
@Suite("Claude Token Spawn + Swap")
struct ModelProfileSpawnTests {

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

    private func seedOAuthProfile(_ db: TBDDatabase, name: String) async throws -> ModelProfile {
        let row = try await db.modelProfiles.create(name: name, kind: .oauth)
        return row
    }

    private func cleanup(_ db: TBDDatabase) async {
        let toks = (try? await db.modelProfiles.list()) ?? []
        for t in toks { try? ModelProfileKeychain.delete(id: t.id.uuidString) }
    }

    // MARK: - Spawn: no token configured

    @Test("spawn: no tokens → no env prefix, profileID nil")
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
        #expect(term.profileID == nil)
        #expect(!recorder.joinedAll.contains("CLAUDE_CODE_OAUTH_TOKEN"))
        #expect(!recorder.joinedAll.contains("CLAUDE_CONFIG_DIR"))
    }

    // MARK: - Spawn: global default

    @Test("spawn: global default oauth → CLAUDE_CONFIG_DIR + profileID, no token")
    func spawnWithGlobalDefaultOAuth() async throws {
        let (router, db, recorder) = makeFixture()
        defer { Task { await cleanup(db) } }
        let (_, wt) = try await seedRepoAndWorktree(db)
        let tok = try await seedOAuthProfile(db, name: "Default")
        try await db.config.setDefaultProfileID(tok.id)

        let req = try RPCRequest(
            method: RPCMethod.terminalCreate,
            params: TerminalCreateParams(worktreeID: wt.id, type: .claude)
        )
        let resp = await router.handle(req)
        #expect(resp.success)
        let term = try resp.decodeResult(Terminal.self)
        #expect(term.profileID == tok.id)
        // OAuth profiles inject CLAUDE_CONFIG_DIR, not a token.
        #expect(!recorder.joinedAll.contains("CLAUDE_CODE_OAUTH_TOKEN"))
        // The config dir is a path derived from the profile UUID, injected via tmux -e.
        #expect(recorder.joinedAll.contains("CLAUDE_CONFIG_DIR="))
        #expect(!recorder.shellBodies.contains("CLAUDE_CODE_OAUTH_TOKEN"))
    }

    // MARK: - Spawn: repo override beats default

    @Test("spawn: repo override beats global default")
    func spawnRepoOverride() async throws {
        let (router, db, recorder) = makeFixture()
        defer { Task { await cleanup(db) } }
        let (repo, wt) = try await seedRepoAndWorktree(db)
        let a = try await seedOAuthProfile(db, name: "A")
        let b = try await seedOAuthProfile(db, name: "B")
        try await db.config.setDefaultProfileID(a.id)
        try await db.repos.setProfileOverride(id: repo.id, profileID: b.id)

        let req = try RPCRequest(
            method: RPCMethod.terminalCreate,
            params: TerminalCreateParams(worktreeID: wt.id, type: .claude)
        )
        let resp = await router.handle(req)
        #expect(resp.success)
        let term = try resp.decodeResult(Terminal.self)
        #expect(term.profileID == b.id)
        // OAuth profiles inject CLAUDE_CONFIG_DIR, not a token.
        #expect(!recorder.joinedAll.contains("CLAUDE_CODE_OAUTH_TOKEN"))
        #expect(recorder.joinedAll.contains("CLAUDE_CONFIG_DIR="))
    }

    // MARK: - Spawn: non-claude type ignores token

    @Test("spawn: non-claude type ignores token")
    func spawnNonClaudeIgnoresToken() async throws {
        let (router, db, recorder) = makeFixture()
        defer { Task { await cleanup(db) } }
        let (_, wt) = try await seedRepoAndWorktree(db)
        let tok = try await seedOAuthProfile(db, name: "A")
        try await db.config.setDefaultProfileID(tok.id)

        let req = try RPCRequest(
            method: RPCMethod.terminalCreate,
            params: TerminalCreateParams(worktreeID: wt.id, cmd: "ls", type: .shell)
        )
        let resp = await router.handle(req)
        #expect(resp.success)
        let term = try resp.decodeResult(Terminal.self)
        #expect(term.profileID == nil)
        #expect(!recorder.joinedAll.contains("CLAUDE_CODE_OAUTH_TOKEN"))
    }

    // MARK: - Spawn: Codex free-form env overrides (branch-test rule)

    /// Build a lifecycle + recorder fixture. Unlike `makeFixture`, this exposes
    /// the `WorktreeLifecycle` so tests can drive `spawnPrimaryTerminals`
    /// directly — the chokepoint where the Codex env branch lives.
    private func makeLifecycleFixture() -> (WorktreeLifecycle, TBDDatabase, TmuxRecorder) {
        let recorder = TmuxRecorder()
        let tmux = TmuxManager(dryRun: true, dryRunRecorder: { args in recorder.record(args) })
        let db = try! TBDDatabase(inMemory: true)
        let lifecycle = WorktreeLifecycle(db: db, git: GitManager(), tmux: tmux, hooks: HookResolver())
        return (lifecycle, db, recorder)
    }

    /// Codex's primary spawn carries the merged free-form env overrides
    /// (global ∪ repo) via tmux `-e KEY=VALUE`. Covers the
    /// `primarySensitiveEnv = mergedEnvOverrides` branch in spawnPrimaryTerminals.
    @Test("spawn: Codex primary receives merged global+repo env overrides via -e")
    func codexReceivesMergedEnvOverrides() async throws {
        let codexHome = FileManager.default.temporaryDirectory
            .appendingPathComponent("tbd-codex-home-\(UUID().uuidString)")
        setenv("TBD_TEST_CODEX_HOME", codexHome.path, 1)
        defer {
            unsetenv("TBD_TEST_CODEX_HOME")
            try? FileManager.default.removeItem(at: codexHome)
        }

        let (lifecycle, db, recorder) = makeLifecycleFixture()
        defer { Task { await cleanup(db) } }
        let (repo, wt) = try await seedRepoAndWorktree(db)
        try await db.config.setPrimaryAgentPreference(.codex)
        try await db.config.setEnvOverrides(["FOO": "bar"])
        try await db.repos.setEnvOverrides(id: repo.id, overrides: ["REPO_VAR": "rv"])
        // Re-fetch so the repo passed to spawnPrimaryTerminals carries its
        // freshly-persisted envOverrides (the spawn reads repo.envOverrides
        // from the argument, not the DB).
        let freshRepo = try #require(try await db.repos.get(id: repo.id))

        _ = try await lifecycle.spawnPrimaryTerminals(
            worktree: wt, repo: freshRepo, skipClaude: false, preSessionTerminalID: nil
        )

        // Both scopes reach the Codex pane as sensitive -e env.
        #expect(recorder.joinedAll.contains("FOO=bar"))
        #expect(recorder.joinedAll.contains("REPO_VAR=rv"))
    }

    /// With no env overrides configured, the Codex primary spawn injects no
    /// sensitive `-e` env at all (the empty-config off branch).
    @Test("spawn: empty config → Codex primary gets no -e env overrides")
    func codexEmptyConfigInjectsNothing() async throws {
        let codexHome = FileManager.default.temporaryDirectory
            .appendingPathComponent("tbd-codex-home-\(UUID().uuidString)")
        setenv("TBD_TEST_CODEX_HOME", codexHome.path, 1)
        defer {
            unsetenv("TBD_TEST_CODEX_HOME")
            try? FileManager.default.removeItem(at: codexHome)
        }

        let (lifecycle, db, recorder) = makeLifecycleFixture()
        defer { Task { await cleanup(db) } }
        let (repo, wt) = try await seedRepoAndWorktree(db)
        try await db.config.setPrimaryAgentPreference(.codex)
        // No global or repo env overrides configured.

        _ = try await lifecycle.spawnPrimaryTerminals(
            worktree: wt, repo: repo, skipClaude: false, preSessionTerminalID: nil
        )

        // The Codex `new-window` call exists and carries no `-e` env flag.
        let codexCall = try #require(recorder.calls.first {
            $0.contains("new-window") && ($0.last?.contains("codex") ?? false)
        })
        #expect(!codexCall.contains("-e"))
        #expect(!recorder.joinedAll.contains("FOO=bar"))
    }

    // MARK: - Spawn: fallbackModels overlay routing

    @Test("spawn: profile WITHOUT fallbackModels uses the global overlay path")
    func spawnWithoutFallbackModelsUsesGlobalOverlay() async throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("tbd-spawn-test-\(UUID().uuidString)")
        setenv("TBD_HOME", tmp.path, 1)
        defer {
            unsetenv("TBD_HOME")
            try? FileManager.default.removeItem(at: tmp)
        }
        // The --settings flag is only emitted when the overlay file exists.
        ClaudeHookOverlay.writeOverlay()

        let (router, db, recorder) = makeFixture()
        defer { Task { await cleanup(db) } }
        let (_, wt) = try await seedRepoAndWorktree(db)
        let tok = try await seedOAuthProfile(db, name: "NoFallback")
        try await db.config.setDefaultProfileID(tok.id)

        let resp = await router.handle(try RPCRequest(
            method: RPCMethod.terminalCreate,
            params: TerminalCreateParams(worktreeID: wt.id, type: .claude)
        ))
        #expect(resp.success)

        let bodies = recorder.shellBodies
        #expect(bodies.contains("--settings"))
        // Uses the shared global overlay, NOT a per-session file.
        #expect(bodies.contains(ClaudeHookOverlay.overlayPath))
        #expect(!bodies.contains("claude-overlay-session-"))
    }

    @Test("spawn: profile WITH fallbackModels uses a per-session overlay path")
    func spawnWithFallbackModelsUsesPerSessionOverlay() async throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("tbd-spawn-test-\(UUID().uuidString)")
        setenv("TBD_HOME", tmp.path, 1)
        defer {
            unsetenv("TBD_HOME")
            try? FileManager.default.removeItem(at: tmp)
        }
        ClaudeHookOverlay.writeOverlay()

        let (router, db, recorder) = makeFixture()
        defer { Task { await cleanup(db) } }
        let (_, wt) = try await seedRepoAndWorktree(db)
        let tok = try await db.modelProfiles.create(
            name: "WithFallback", kind: .oauth,
            fallbackModels: ["claude-haiku-4-5-20251001"]
        )
        try await db.config.setDefaultProfileID(tok.id)

        let resp = await router.handle(try RPCRequest(
            method: RPCMethod.terminalCreate,
            params: TerminalCreateParams(worktreeID: wt.id, type: .claude)
        ))
        #expect(resp.success)

        let bodies = recorder.shellBodies
        #expect(bodies.contains("--settings"))
        // A per-session overlay file is used, NOT the shared global overlay.
        #expect(bodies.contains("claude-overlay-session-"))
        #expect(!bodies.contains(" --settings \(ClaudeHookOverlay.overlayPath)"))
    }

    @Test("delete: removes the per-session fallbackModel overlay on terminal teardown")
    func deleteRemovesPerSessionOverlay() async throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("tbd-spawn-test-\(UUID().uuidString)")
        setenv("TBD_HOME", tmp.path, 1)
        defer {
            unsetenv("TBD_HOME")
            try? FileManager.default.removeItem(at: tmp)
        }
        ClaudeHookOverlay.writeOverlay()

        let (router, db, _) = makeFixture()
        defer { Task { await cleanup(db) } }
        let (_, wt) = try await seedRepoAndWorktree(db)
        let tok = try await db.modelProfiles.create(
            name: "WithFallback", kind: .oauth,
            fallbackModels: ["claude-haiku-4-5-20251001"]
        )
        try await db.config.setDefaultProfileID(tok.id)

        let createResp = await router.handle(try RPCRequest(
            method: RPCMethod.terminalCreate,
            params: TerminalCreateParams(worktreeID: wt.id, type: .claude)
        ))
        #expect(createResp.success)
        let term = try createResp.decodeResult(Terminal.self)

        // The per-session overlay was written, keyed by the terminal id.
        let overlayPath = ClaudeHookOverlay.perSessionOverlayPath(sessionKey: term.id.uuidString)
        #expect(FileManager.default.fileExists(atPath: overlayPath))

        // Deleting the terminal reclaims the per-session overlay.
        let delResp = await router.handle(try RPCRequest(
            method: RPCMethod.terminalDelete,
            params: TerminalDeleteParams(terminalID: term.id)
        ))
        #expect(delResp.success)
        #expect(!FileManager.default.fileExists(atPath: overlayPath))
        // The shared global overlay is left intact.
        #expect(FileManager.default.fileExists(atPath: ClaudeHookOverlay.overlayPath))
    }

    // MARK: - Swap: to a different token

    @Test("swap on blank session: forks into a new tab with a fresh session id and new token")
    func swapToDifferentToken() async throws {
        let (router, db, recorder) = makeFixture()
        defer { Task { await cleanup(db) } }
        let (_, wt) = try await seedRepoAndWorktree(db)
        let a = try await seedOAuthProfile(db, name: "A")
        let b = try await seedOAuthProfile(db, name: "B")
        try await db.config.setDefaultProfileID(a.id)

        // Spawn original claude terminal with token A. The session is "blank" —
        // no JSONL exists on disk for it — so swap should pick the fresh path.
        let createResp = await router.handle(try RPCRequest(
            method: RPCMethod.terminalCreate,
            params: TerminalCreateParams(worktreeID: wt.id, type: .claude)
        ))
        #expect(createResp.success)
        let oldTerm = try createResp.decodeResult(Terminal.self)
        #expect(oldTerm.profileID == a.id)
        let oldSessionID = oldTerm.claudeSessionID

        let beforeSwap = recorder.calls.count

        // Swap to B → returns a NEW terminal row, old one untouched
        let swapResp = await router.handle(try RPCRequest(
            method: RPCMethod.terminalSwapProfile,
            params: TerminalSwapProfileParams(terminalID: oldTerm.id, newProfileID: b.id)
        ))
        #expect(swapResp.success)
        let newTerm = try swapResp.decodeResult(Terminal.self)
        #expect(newTerm.id != oldTerm.id)
        #expect(newTerm.profileID == b.id)
        // Blank session → fresh spawn with a NEW session id (not a resume of the old one).
        #expect(newTerm.claudeSessionID != nil)
        #expect(newTerm.claudeSessionID != oldSessionID)

        // Old terminal row is unchanged
        let oldAfter = try await db.terminals.get(id: oldTerm.id)
        #expect(oldAfter?.profileID == a.id)

        // Daemon did NOT send C-c or send-keys to the old pane
        let postSwap = Array(recorder.calls.dropFirst(beforeSwap))
        let joined = postSwap.map { $0.joined(separator: " ") }.joined(separator: "\n")
        #expect(!joined.contains("C-c"))
        #expect(!joined.contains("send-keys"))
        // The new tab was spawned with B's CLAUDE_CONFIG_DIR via tmux -e (NOT inlined),
        // and the shell body contains --session-id <newSessionID> (fresh path),
        // never --resume.
        #expect(joined.contains("CLAUDE_CONFIG_DIR="))
        #expect(joined.contains("claude --session-id \(newTerm.claudeSessionID!)"))
        #expect(!joined.contains("claude --resume"))
        #expect(joined.contains("--dangerously-skip-permissions"))
        // Negative: secrets and tokens must NOT appear in any shell body or tmux call.
        let postBodies = postSwap.compactMap { $0.last }.joined(separator: "\n")
        #expect(!postBodies.contains("CLAUDE_CODE_OAUTH_TOKEN"))
    }

    // MARK: - Swap: to nil

    @Test("swap: to nil forks new tab with no env prefix; old tab untouched")
    func swapToNil() async throws {
        let (router, db, recorder) = makeFixture()
        defer { Task { await cleanup(db) } }
        let (_, wt) = try await seedRepoAndWorktree(db)
        let a = try await seedOAuthProfile(db, name: "A")
        try await db.config.setDefaultProfileID(a.id)

        let createResp = await router.handle(try RPCRequest(
            method: RPCMethod.terminalCreate,
            params: TerminalCreateParams(worktreeID: wt.id, type: .claude)
        ))
        let oldTerm = try createResp.decodeResult(Terminal.self)
        #expect(oldTerm.profileID == a.id)

        let beforeSwap = recorder.calls.count

        let swapResp = await router.handle(try RPCRequest(
            method: RPCMethod.terminalSwapProfile,
            params: TerminalSwapProfileParams(terminalID: oldTerm.id, newProfileID: nil)
        ))
        #expect(swapResp.success)
        let newTerm = try swapResp.decodeResult(Terminal.self)
        #expect(newTerm.id != oldTerm.id)
        #expect(newTerm.profileID == nil)
        // Old terminal still has its original token
        let oldAfter = try await db.terminals.get(id: oldTerm.id)
        #expect(oldAfter?.profileID == a.id)

        let postSwap = Array(recorder.calls.dropFirst(beforeSwap))
        let joined = postSwap.map { $0.joined(separator: " ") }.joined(separator: "\n")
        // Blank session → fresh --session-id, never --resume.
        #expect(joined.contains("claude --session-id"))
        #expect(!joined.contains("claude --resume"))
        #expect(!joined.contains("CLAUDE_CODE_OAUTH_TOKEN"))
        #expect(!joined.contains("CLAUDE_CONFIG_DIR"))
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
            method: RPCMethod.terminalSwapProfile,
            params: TerminalSwapProfileParams(terminalID: term.id, newProfileID: nil)
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
            method: RPCMethod.terminalSwapProfile,
            params: TerminalSwapProfileParams(terminalID: term.id, newProfileID: UUID())
        ))
        #expect(!swapResp.success)
    }
}
}
