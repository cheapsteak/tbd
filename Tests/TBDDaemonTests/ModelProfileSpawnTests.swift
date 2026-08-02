import Foundation
import Testing
@testable import TBDDaemonLib
@testable import TBDShared

/// A `ClaudeProfileConfigDirManager` pointed at fresh temp dirs, so the
/// wake/revive transcript-sync ambient fallback lists a sandbox — never the
/// developer's real `~/.claude/projects`. Every `WorktreeLifecycle`/`RPCRouter`
/// construction in this file must pass one.
private func isolatedConfigDirManager() -> ClaudeProfileConfigDirManager {
    let home = FileManager.default.temporaryDirectory
        .appendingPathComponent("tbd-spawn-claude-\(UUID().uuidString)", isDirectory: true)
    return ClaudeProfileConfigDirManager(
        baseDirectory: home.appendingPathComponent("profiles", isDirectory: true),
        hostBaseDirectory: home.appendingPathComponent("claude-host", isDirectory: true)
    )
}

// Nested under TBDHomeSerialized: several tests mutate the process-global
// `TBD_HOME` env var (via setenv/unsetenv) to isolate the overlay/runtime dir.
// Nesting prevents cross-suite races with the other TBD_HOME-mutating suites.
// See TBDHomeSerializedSuites.swift.
extension TBDHomeSerialized {
@Suite("Claude Token Spawn + Swap")
struct ModelProfileSpawnTests {
    private struct ExpectedCodexPreparationFailure: Error {}

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
        let lifecycle = WorktreeLifecycle(
            db: db, git: GitManager(), tmux: tmux, hooks: HookResolver(),
            configDirManager: isolatedConfigDirManager())
        let router = RPCRouter(
            db: db,
            lifecycle: lifecycle,
            tmux: tmux,
            startTime: Date(),
            usageFetcher: StubClaudeUsageFetcher(),
            configDirManager: isolatedConfigDirManager()
        )
        return (router, db, recorder)
    }

    private func seedRepoAndWorktree(_ db: TBDDatabase) async throws -> (Repo, Worktree) {
        let repo = try await db.repos.create(
            path: "/tmp/r-\(UUID().uuidString)",
            displayName: "r",
            defaultBranch: "main"
        )
        // terminal.create / recreate refuse to spawn into a missing directory
        // (tmux would silently fall back to $HOME), so the worktree path must
        // actually exist on disk.
        let wtPath = FileManager.default.temporaryDirectory
            .appendingPathComponent("wt-\(UUID().uuidString)").path
        try FileManager.default.createDirectory(
            atPath: wtPath, withIntermediateDirectories: true)
        let wt = try await db.worktrees.create(
            repoID: repo.id,
            name: "wt",
            branch: "main",
            path: wtPath,
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

    @Test("terminal.create prepares Codex home before tmux or terminal mutation")
    func terminalCreateCodexHomeFailurePrecedesMutation() async throws {
        let (router, db, recorder) = makeFixture()
        defer { Task { await cleanup(db) } }
        let (_, wt) = try await seedRepoAndWorktree(db)
        router.codexExecutableResolver = { "/opt/test/bin/codex" }
        router.codexHomeEnsurer = {
            throw ExpectedCodexPreparationFailure()
        }

        let response = await router.handle(try RPCRequest(
            method: RPCMethod.terminalCreate,
            params: TerminalCreateParams(worktreeID: wt.id, type: .codex)))

        #expect(!response.success)
        #expect(recorder.calls.isEmpty)
        #expect(try await db.terminals.list(worktreeID: wt.id).isEmpty)
    }

    @Test("terminal.create spawns the injected absolute Codex executable")
    func terminalCreateUsesResolvedAbsoluteCodexExecutable() async throws {
        let (router, db, recorder) = makeFixture()
        defer { Task { await cleanup(db) } }
        let (_, wt) = try await seedRepoAndWorktree(db)
        router.codexExecutableResolver = { "/opt/TBD Codex/bin/codex" }
        router.codexHomeEnsurer = {
            FileManager.default.temporaryDirectory.appendingPathComponent(
                "tbd-test-codex-home-\(UUID().uuidString)", isDirectory: true)
        }

        let response = await router.handle(try RPCRequest(
            method: RPCMethod.terminalCreate,
            params: TerminalCreateParams(worktreeID: wt.id, type: .codex)))

        #expect(response.success)
        #expect(recorder.shellBodies.contains("'/opt/TBD Codex/bin/codex'"))
        #expect(!recorder.shellBodies.contains("; codex --profile"))
        #expect(!recorder.shellBodies.contains("; codex --profile-v2"))
    }

    @Test("terminal.recreate prepares Codex home before killing the old window")
    func terminalRecreateCodexHomeFailurePreservesOldWindowAndRow() async throws {
        let (router, db, recorder) = makeFixture()
        defer { Task { await cleanup(db) } }
        let (_, wt) = try await seedRepoAndWorktree(db)
        let terminal = try await db.terminals.create(
            worktreeID: wt.id,
            tmuxWindowID: "@old-codex",
            tmuxPaneID: "%old-codex",
            label: TerminalLabel.codex,
            kind: .codex)
        router.codexExecutableResolver = { "/opt/test/bin/codex" }
        router.codexHomeEnsurer = {
            throw ExpectedCodexPreparationFailure()
        }

        let response = await router.handle(try RPCRequest(
            method: RPCMethod.terminalRecreateWindow,
            params: TerminalRecreateWindowParams(terminalID: terminal.id)))

        #expect(!response.success)
        #expect(recorder.calls.isEmpty)
        let unchanged = try #require(
            try await db.terminals.get(id: terminal.id))
        #expect(unchanged.tmuxWindowID == terminal.tmuxWindowID)
        #expect(unchanged.tmuxPaneID == terminal.tmuxPaneID)
        #expect(unchanged.kind == .codex)
    }

    // MARK: - Spawn: Codex free-form env overrides (branch-test rule)

    /// Build a lifecycle + recorder fixture. Unlike `makeFixture`, this exposes
    /// the `WorktreeLifecycle` so tests can drive `spawnPrimaryTerminals`
    /// directly — the chokepoint where the env-injection branches live. A real
    /// `ModelProfileResolver` is attached so the Claude branch resolves the
    /// worktree's effective profile (Codex tests ignore it — Codex resolves no
    /// profile).
    private func makeLifecycleFixture(
        codexExecutableResolver: @escaping @Sendable () throws -> String = {
            "/usr/bin/true"
        },
        codexHomeEnsurer: @escaping @Sendable () throws -> URL = {
            FileManager.default.temporaryDirectory.appendingPathComponent(
                "tbd-test-codex-home-\(UUID().uuidString)", isDirectory: true)
        }
    ) -> (WorktreeLifecycle, TBDDatabase, TmuxRecorder) {
        let recorder = TmuxRecorder()
        let tmux = TmuxManager(dryRun: true, dryRunRecorder: { args in recorder.record(args) })
        let db = try! TBDDatabase(inMemory: true)
        let resolver = ModelProfileResolver(
            profiles: db.modelProfiles, repos: db.repos, config: db.config
        )
        let lifecycle = WorktreeLifecycle(
            db: db, git: GitManager(), tmux: tmux, hooks: HookResolver(),
            modelProfileResolver: resolver,
            configDirManager: isolatedConfigDirManager(),
            codexExecutableResolver: codexExecutableResolver,
            codexHomeEnsurer: codexHomeEnsurer
        )
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
        // DISABLE_AUTO_UPDATE=false is deliberately included: the omz-update
        // suppression is FORCED on agent tabs (a user "false" would silently
        // reintroduce the spawn-blockage bug), so it must be overridden to true.
        try await db.config.setEnvOverrides(["FOO": "bar", "DISABLE_AUTO_UPDATE": "false"])
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
        // The forced omz suppression wins over the user's explicit "false";
        // other override keys merged untouched above.
        #expect(recorder.joinedAll.contains("DISABLE_AUTO_UPDATE=true"))
        #expect(!recorder.joinedAll.contains("DISABLE_AUTO_UPDATE=false"))
    }

    /// With no env overrides configured, the Codex primary spawn's only
    /// sensitive `-e` env is the omz update-prompt suppression (the
    /// empty-config off branch injects no user overrides).
    @Test("spawn: empty config → Codex primary gets only omz suppression as -e env")
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

        // The Codex `new-window` call exists; its only `-e` env is the
        // omz update-prompt suppression — an agent tab runs a command and
        // must never block on the interactive "Would you like to update?"
        // prompt. No user overrides leak in.
        let codexCall = try #require(recorder.calls.first {
            $0.contains("new-window") && ($0.last?.contains("codex") ?? false)
        })
        let eIndices = codexCall.indices.filter { codexCall[$0] == "-e" }
        #expect(eIndices.count == 1)
        #expect(codexCall.contains("DISABLE_AUTO_UPDATE=true"),
                "codex window must suppress the oh-my-zsh update prompt via -e")
        #expect(!recorder.joinedAll.contains("FOO=bar"))
    }

    @Test("spawn: missing Codex executable fails before tmux or terminal mutation")
    func codexResolutionFailurePrecedesSpawnMutation() async throws {
        let expected = CodexExecutableResolutionError.notFound(
            searchPath: "/missing",
            fallbackPath: CodexExecutableResolver.chatGPTBundlePath)
        let (lifecycle, db, recorder) = makeLifecycleFixture(
            codexExecutableResolver: { throw expected })
        defer { Task { await cleanup(db) } }
        let (repo, wt) = try await seedRepoAndWorktree(db)
        try await db.config.setPrimaryAgentPreference(.codex)

        await #expect(throws: expected) {
            _ = try await lifecycle.spawnPrimaryTerminals(
                worktree: wt,
                repo: repo,
                skipClaude: false,
                preSessionTerminalID: nil)
        }

        #expect(recorder.calls.isEmpty)
        #expect(try await db.terminals.list(worktreeID: wt.id).isEmpty)
    }

    // MARK: - Spawn: Claude free-form env overrides (branch-test rule)

    /// Claude's primary spawn carries the merged free-form env overrides from
    /// all three scopes (global ∪ repo ∪ resolved-profile) via tmux
    /// `-e KEY=VALUE`. Covers the
    /// `primarySensitiveEnv = mergedEnvOverrides.merging(spawn.sensitiveEnv)`
    /// branch in spawnPrimaryTerminals.
    @Test("spawn: Claude primary receives merged global+repo+profile env overrides via -e")
    func claudeReceivesMergedEnvOverrides() async throws {
        let (lifecycle, db, recorder) = makeLifecycleFixture()
        defer { Task { await cleanup(db) } }
        let (repo, wt) = try await seedRepoAndWorktree(db)
        try await db.config.setPrimaryAgentPreference(.claude)

        // Profile scope: an OAuth profile carrying a free-form var, set as the
        // global default so resolve(repoID:) returns it for this worktree.
        let profile = try await seedOAuthProfile(db, name: "WithEnv")
        try await db.modelProfiles.setEnvOverrides(id: profile.id, overrides: ["PROFILE_VAR": "pv"])
        try await db.config.setDefaultProfileID(profile.id)

        // Global + repo scopes.
        try await db.config.setEnvOverrides(["GLOBAL_VAR": "gv"])
        try await db.repos.setEnvOverrides(id: repo.id, overrides: ["REPO_VAR": "rv"])
        // Re-fetch so the repo passed in carries its persisted envOverrides
        // (the spawn reads repo.envOverrides from the argument, not the DB).
        let freshRepo = try #require(try await db.repos.get(id: repo.id))

        _ = try await lifecycle.spawnPrimaryTerminals(
            worktree: wt, repo: freshRepo, skipClaude: false, preSessionTerminalID: nil
        )

        // All three scopes reach the Claude pane as sensitive -e env.
        #expect(recorder.joinedAll.contains("GLOBAL_VAR=gv"))
        #expect(recorder.joinedAll.contains("REPO_VAR=rv"))
        #expect(recorder.joinedAll.contains("PROFILE_VAR=pv"))
    }

    /// The Claude builder's structured auth/routing env is layered ON TOP of the
    /// free-form overrides, so a free-form var that collides with an auth var
    /// cannot win. Exercises the auth-final invariant at the real spawn site
    /// (not just `Dictionary.merging` in isolation): a Bedrock profile sets
    /// AWS_REGION=us-west-2 while a free-form override tries AWS_REGION=us-east-1.
    @Test("spawn: Claude auth/routing env wins over a free-form collision")
    func claudeAuthEnvWinsOverFreeFormCollision() async throws {
        let (lifecycle, db, recorder) = makeLifecycleFixture()
        defer { Task { await cleanup(db) } }
        let (repo, wt) = try await seedRepoAndWorktree(db)
        try await db.config.setPrimaryAgentPreference(.claude)

        // Bedrock profile emits AWS_REGION=us-west-2 + CLAUDE_CODE_USE_BEDROCK=1
        // from its structured auth/routing fields. Its free-form override
        // deliberately collides on AWS_REGION.
        let bedrock = try await db.modelProfiles.create(
            name: "Bedrock", kind: .bedrock, awsRegion: "us-west-2"
        )
        try await db.modelProfiles.setEnvOverrides(id: bedrock.id, overrides: ["AWS_REGION": "us-east-1"])
        try await db.config.setDefaultProfileID(bedrock.id)

        _ = try await lifecycle.spawnPrimaryTerminals(
            worktree: wt, repo: repo, skipClaude: false, preSessionTerminalID: nil
        )

        // Builder's structured AWS_REGION is final; the free-form value loses.
        #expect(recorder.joinedAll.contains("AWS_REGION=us-west-2"))
        #expect(!recorder.joinedAll.contains("AWS_REGION=us-east-1"))
        #expect(recorder.joinedAll.contains("CLAUDE_CODE_USE_BEDROCK=1"))
    }

    // MARK: - Spawn: per-creation model override (picker model buttons)

    /// A worktree-create spawn with a model override injects it as
    /// ANTHROPIC_MODEL, winning over the profile's own model for this spawn.
    @Test("spawn: modelOverride wins over the profile's model as ANTHROPIC_MODEL")
    func spawnModelOverrideWinsOverProfileModel() async throws {
        let (lifecycle, db, recorder) = makeLifecycleFixture()
        defer { Task { await cleanup(db) } }
        let (repo, wt) = try await seedRepoAndWorktree(db)
        try await db.config.setPrimaryAgentPreference(.claude)
        let profile = try await db.modelProfiles.create(
            name: "WithModel", kind: .oauth, model: "claude-opus-4-8"
        )
        try await db.config.setDefaultProfileID(profile.id)

        _ = try await lifecycle.spawnPrimaryTerminals(
            worktree: wt, repo: repo, skipClaude: false,
            preSessionTerminalID: nil,
            modelOverride: "claude-fable-5"
        )

        #expect(recorder.joinedAll.contains("ANTHROPIC_MODEL=claude-fable-5"))
        #expect(!recorder.joinedAll.contains("ANTHROPIC_MODEL=claude-opus-4-8"))
    }

    /// Branch guard: with no override, the profile's own model is injected
    /// unchanged (today's behavior).
    @Test("spawn: nil modelOverride keeps the profile's model")
    func spawnNilModelOverrideKeepsProfileModel() async throws {
        let (lifecycle, db, recorder) = makeLifecycleFixture()
        defer { Task { await cleanup(db) } }
        let (repo, wt) = try await seedRepoAndWorktree(db)
        try await db.config.setPrimaryAgentPreference(.claude)
        let profile = try await db.modelProfiles.create(
            name: "WithModel", kind: .oauth, model: "claude-opus-4-8"
        )
        try await db.config.setDefaultProfileID(profile.id)

        _ = try await lifecycle.spawnPrimaryTerminals(
            worktree: wt, repo: repo, skipClaude: false,
            preSessionTerminalID: nil
        )

        #expect(recorder.joinedAll.contains("ANTHROPIC_MODEL=claude-opus-4-8"))
        #expect(!recorder.joinedAll.contains("claude-fable-5"))
    }

    /// Branch guard: an override on a profile WITHOUT a model still injects
    /// the override (the `??` fallback isn't required for injection).
    @Test("spawn: modelOverride injects even when the profile has no model")
    func spawnModelOverrideWithoutProfileModel() async throws {
        let (lifecycle, db, recorder) = makeLifecycleFixture()
        defer { Task { await cleanup(db) } }
        let (repo, wt) = try await seedRepoAndWorktree(db)
        try await db.config.setPrimaryAgentPreference(.claude)
        let profile = try await seedOAuthProfile(db, name: "NoModel")
        try await db.config.setDefaultProfileID(profile.id)

        _ = try await lifecycle.spawnPrimaryTerminals(
            worktree: wt, repo: repo, skipClaude: false,
            preSessionTerminalID: nil,
            modelOverride: "claude-sonnet-5"
        )

        #expect(recorder.joinedAll.contains("ANTHROPIC_MODEL=claude-sonnet-5"))
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

    @Test("fork on blank session: forks into a new tab with a fresh session id and new token")
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

        // FORK to B → returns a NEW terminal row, old one untouched.
        let swapResp = await router.handle(try RPCRequest(
            method: RPCMethod.terminalSwapProfile,
            params: TerminalSwapProfileParams(terminalID: oldTerm.id, newProfileID: b.id, mode: .fork)
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

        // Daemon did NOT send C-c or send-keys to the old pane (fork spawns a
        // brand-new window; it never interrupts the source pane).
        let postSwap = Array(recorder.calls.dropFirst(beforeSwap))
        let joined = postSwap.map { $0.joined(separator: " ") }.joined(separator: "\n")
        #expect(!joined.contains("C-c"))
        #expect(!joined.contains("send-keys"))
        #expect(!joined.contains("respawn-window"))
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

    @Test("in-place swap (default): keeps terminal id + tmux window id, updates profile_id")
    func inPlaceSwapKeepsRowAndWindow() async throws {
        let (router, db, recorder) = makeFixture()
        defer { Task { await cleanup(db) } }
        let (_, wt) = try await seedRepoAndWorktree(db)
        let a = try await seedOAuthProfile(db, name: "A")
        let b = try await seedOAuthProfile(db, name: "B")
        try await db.config.setDefaultProfileID(a.id)

        let createResp = await router.handle(try RPCRequest(
            method: RPCMethod.terminalCreate,
            params: TerminalCreateParams(worktreeID: wt.id, type: .claude)
        ))
        let oldTerm = try createResp.decodeResult(Terminal.self)
        #expect(oldTerm.profileID == a.id)
        let originalWindowID = oldTerm.tmuxWindowID

        let beforeSwap = recorder.calls.count

        // Default mode (nil → .inPlace): same tab.
        let swapResp = await router.handle(try RPCRequest(
            method: RPCMethod.terminalSwapProfile,
            params: TerminalSwapProfileParams(terminalID: oldTerm.id, newProfileID: b.id)
        ))
        #expect(swapResp.success)
        let result = try swapResp.decodeResult(Terminal.self)
        // Same terminal id + same tmux window id — the row and tab survive.
        #expect(result.id == oldTerm.id)
        #expect(result.tmuxWindowID == originalWindowID)
        // profile_id flipped to B, in place.
        #expect(result.profileID == b.id)
        // DB reflects the in-place update — no new row was created.
        let all = try await db.terminals.list(worktreeID: wt.id)
        #expect(all.count == 1)
        #expect(all.first?.profileID == b.id)

        // The pane was respawned in place (respawn-window -k on the SAME window),
        // not spawned as a new window.
        let postSwap = Array(recorder.calls.dropFirst(beforeSwap))
        let joined = postSwap.map { $0.joined(separator: " ") }.joined(separator: "\n")
        #expect(joined.contains("respawn-window"))
        #expect(joined.contains(originalWindowID))
        #expect(!joined.contains("new-window"))
        #expect(joined.contains("CLAUDE_CONFIG_DIR="))
    }

    // MARK: - Swap over a NON-BLANK session: resume + --fork-session flag

    /// Seed a real claude terminal, then give its session a NON-blank transcript
    /// on disk (via `transcriptPath`) so `ClaudeSessionScanner.isSessionBlank`
    /// returns false and `planTerminalSwap` picks the `.resume` branch. Returns
    /// the created terminal.
    private func seedNonBlankClaudeTerminal(
        _ router: RPCRouter, _ db: TBDDatabase, worktreeID: UUID
    ) async throws -> Terminal {
        let createResp = await router.handle(try RPCRequest(
            method: RPCMethod.terminalCreate,
            params: TerminalCreateParams(worktreeID: worktreeID, type: .claude)
        ))
        #expect(createResp.success)
        let term = try createResp.decodeResult(Terminal.self)
        let sessionID = try #require(term.claudeSessionID)

        // Write a transcript carrying a real user message; point the row at it so
        // isSessionBlank reads content (not the empty projects scan) → non-blank.
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("tbd-swap-transcript-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let file = dir.appendingPathComponent("\(sessionID).jsonl")
        try #"{"type":"user","message":{"role":"user","content":"hello there"}}"#
            .write(to: file, atomically: true, encoding: .utf8)
        try await db.terminals.updateSession(id: term.id, sessionID: sessionID, transcriptPath: file.path)
        return term
    }

    /// REGRESSION (PR #480): a `.fork` swap over a NON-BLANK session must reach
    /// the `.resume` plan AND emit `--fork-session`, so the fork gets a genuinely
    /// new session id while the source session keeps writing its own JSONL. The
    /// blank-session sibling (`swapToDifferentToken`) can't catch this — it takes
    /// the `.fresh` path, which never adds the flag.
    @Test("fork on non-blank session: router emits claude --resume WITH --fork-session")
    func forkOverNonBlankEmitsForkSessionFlag() async throws {
        let (router, db, recorder) = makeFixture()
        defer { Task { await cleanup(db) } }
        let (_, wt) = try await seedRepoAndWorktree(db)
        let a = try await seedOAuthProfile(db, name: "A")
        let b = try await seedOAuthProfile(db, name: "B")
        try await db.config.setDefaultProfileID(a.id)

        let oldTerm = try await seedNonBlankClaudeTerminal(router, db, worktreeID: wt.id)

        let beforeSwap = recorder.calls.count
        let swapResp = await router.handle(try RPCRequest(
            method: RPCMethod.terminalSwapProfile,
            params: TerminalSwapProfileParams(terminalID: oldTerm.id, newProfileID: b.id, mode: .fork)
        ))
        #expect(swapResp.success)

        let postSwap = Array(recorder.calls.dropFirst(beforeSwap))
        let joined = postSwap.map { $0.joined(separator: " ") }.joined(separator: "\n")
        // Non-blank → resume plan, and .fork adds --fork-session.
        #expect(joined.contains("claude --resume \(oldTerm.claudeSessionID!)"),
                "fork over a non-blank session must resume the source id; got: \(joined)")
        #expect(joined.contains("--fork-session"),
                "fork mode must append --fork-session so the fork gets a new id; got: \(joined)")
    }

    /// Inverse branch guard: the same non-blank session swapped `.inPlace` still
    /// resumes but must NOT carry `--fork-session` (the source process is killed,
    /// so a same-id resume is correct — no fork).
    @Test("in-place swap on non-blank session: resumes WITHOUT --fork-session")
    func inPlaceOverNonBlankOmitsForkSessionFlag() async throws {
        let (router, db, recorder) = makeFixture()
        defer { Task { await cleanup(db) } }
        let (_, wt) = try await seedRepoAndWorktree(db)
        let a = try await seedOAuthProfile(db, name: "A")
        let b = try await seedOAuthProfile(db, name: "B")
        try await db.config.setDefaultProfileID(a.id)

        let oldTerm = try await seedNonBlankClaudeTerminal(router, db, worktreeID: wt.id)

        let beforeSwap = recorder.calls.count
        let swapResp = await router.handle(try RPCRequest(
            method: RPCMethod.terminalSwapProfile,
            params: TerminalSwapProfileParams(terminalID: oldTerm.id, newProfileID: b.id, mode: .inPlace)
        ))
        #expect(swapResp.success)

        let postSwap = Array(recorder.calls.dropFirst(beforeSwap))
        let joined = postSwap.map { $0.joined(separator: " ") }.joined(separator: "\n")
        #expect(joined.contains("claude --resume \(oldTerm.claudeSessionID!)"),
                "in-place swap over a non-blank session must resume the source id; got: \(joined)")
        #expect(!joined.contains("--fork-session"),
                "in-place swap must NOT fork the session; got: \(joined)")
    }

    // MARK: - Swap: to nil

    @Test("fork: to nil forks new tab with no env prefix; old tab untouched")
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
            params: TerminalSwapProfileParams(terminalID: oldTerm.id, newProfileID: nil, mode: .fork)
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

    // MARK: - Cold profile swap (parked session re-home without waking)

    /// Swapping a PARKED (hibernated) session's profile must NOT wake it: no
    /// respawn-window / new-window is issued, the profile_id updates, and the
    /// parked timestamps + snapshot are left untouched.
    @Test("cold swap: parked (hibernated) session re-homes profile without respawn")
    func coldSwapParkedDoesNotRespawn() async throws {
        let (router, db, recorder) = makeFixture()
        defer { Task { await cleanup(db) } }
        let (_, wt) = try await seedRepoAndWorktree(db)
        let a = try await seedOAuthProfile(db, name: "A")
        let b = try await seedOAuthProfile(db, name: "B")
        try await db.config.setDefaultProfileID(a.id)

        let createResp = await router.handle(try RPCRequest(
            method: RPCMethod.terminalCreate,
            params: TerminalCreateParams(worktreeID: wt.id, type: .claude)
        ))
        let term = try createResp.decodeResult(Terminal.self)
        #expect(term.profileID == a.id)

        // Park it (hibernated) with a snapshot backdrop.
        try await db.terminals.setHibernated(
            id: term.id, sessionID: term.claudeSessionID ?? "s", snapshot: "FROZEN")
        let parkedBefore = try await db.terminals.get(id: term.id)
        let hibAt = parkedBefore?.hibernatedAt

        let beforeSwap = recorder.calls.count
        let swapResp = await router.handle(try RPCRequest(
            method: RPCMethod.terminalSwapProfile,
            params: TerminalSwapProfileParams(terminalID: term.id, newProfileID: b.id)
        ))
        #expect(swapResp.success)
        let result = try swapResp.decodeResult(Terminal.self)

        // profile flipped, but the session stays parked (result reads as parked).
        #expect(result.profileID == b.id)
        #expect(result.isParked, "cold swap must leave the session parked")

        // No spawn of any kind.
        let postSwap = Array(recorder.calls.dropFirst(beforeSwap))
        let joined = postSwap.map { $0.joined(separator: " ") }.joined(separator: "\n")
        #expect(!joined.contains("respawn-window"), "cold swap must not respawn; got: \(joined)")
        #expect(!joined.contains("new-window"), "cold swap must not spawn a new window; got: \(joined)")
        #expect(!joined.contains("C-c"), "cold swap must not interrupt the pane; got: \(joined)")

        // Parked timestamps + snapshot untouched.
        let after = try await db.terminals.get(id: term.id)
        #expect(after?.profileID == b.id)
        #expect(after?.hibernatedAt == hibAt, "hibernatedAt must be untouched")
        #expect(after?.suspendedSnapshot == "FROZEN", "snapshot backdrop must survive")
    }

    /// A legacy-parked session (only `suspendedAt` set) also gets a cold swap,
    /// not a respawn.
    @Test("cold swap: legacy-suspended session also re-homes without respawn")
    func coldSwapLegacySuspendedDoesNotRespawn() async throws {
        let (router, db, recorder) = makeFixture()
        defer { Task { await cleanup(db) } }
        let (_, wt) = try await seedRepoAndWorktree(db)
        let a = try await seedOAuthProfile(db, name: "A")
        let b = try await seedOAuthProfile(db, name: "B")
        try await db.config.setDefaultProfileID(a.id)

        let createResp = await router.handle(try RPCRequest(
            method: RPCMethod.terminalCreate,
            params: TerminalCreateParams(worktreeID: wt.id, type: .claude)
        ))
        let term = try createResp.decodeResult(Terminal.self)

        // Legacy park: only suspendedAt.
        try await db.terminals.setSuspended(id: term.id, sessionID: term.claudeSessionID ?? "s")

        let beforeSwap = recorder.calls.count
        let swapResp = await router.handle(try RPCRequest(
            method: RPCMethod.terminalSwapProfile,
            params: TerminalSwapProfileParams(terminalID: term.id, newProfileID: b.id)
        ))
        #expect(swapResp.success)
        let result = try swapResp.decodeResult(Terminal.self)
        #expect(result.profileID == b.id)
        #expect(result.isParked)

        let postSwap = Array(recorder.calls.dropFirst(beforeSwap))
        let joined = postSwap.map { $0.joined(separator: " ") }.joined(separator: "\n")
        #expect(!joined.contains("respawn-window"))
        #expect(!joined.contains("new-window"))

        let after = try await db.terminals.get(id: term.id)
        #expect(after?.suspendedAt != nil, "legacy suspendedAt stays set (still parked)")
        #expect(after?.profileID == b.id)
    }

    /// After a cold swap, waking the session resumes under the NEW profile's
    /// config dir — verified by the wake respawn carrying B's CLAUDE_CONFIG_DIR.
    @Test("cold swap then wake: resumes under the new profile's config dir")
    func wakeAfterColdSwapUsesNewProfileConfigDir() async throws {
        let (router, db, recorder) = makeFixture()
        defer { Task { await cleanup(db) } }
        let (_, wt) = try await seedRepoAndWorktree(db)
        let a = try await seedOAuthProfile(db, name: "A")
        let b = try await seedOAuthProfile(db, name: "B")
        try await db.config.setDefaultProfileID(a.id)

        let createResp = await router.handle(try RPCRequest(
            method: RPCMethod.terminalCreate,
            params: TerminalCreateParams(worktreeID: wt.id, type: .claude)
        ))
        let term = try createResp.decodeResult(Terminal.self)
        try await db.terminals.setHibernated(id: term.id, sessionID: "sess-cold")

        // Cold swap to B.
        _ = await router.handle(try RPCRequest(
            method: RPCMethod.terminalSwapProfile,
            params: TerminalSwapProfileParams(terminalID: term.id, newProfileID: b.id)
        ))
        #expect(try await db.terminals.get(id: term.id)?.profileID == b.id)

        // Now wake via the unified coordinator (the router's own instance).
        let beforeWake = recorder.calls.count
        let wakeResult = await router.hibernationCoordinator.wake(terminalID: term.id)
        #expect(wakeResult == .ok)

        let postWake = Array(recorder.calls.dropFirst(beforeWake))
        let joined = postWake.map { $0.joined(separator: " ") }.joined(separator: "\n")
        // Wake must respawn `claude --resume` under B's config dir. The config
        // dir path embeds the profile's (lowercased) UUID, so asserting B's UUID
        // appears in a CLAUDE_CONFIG_DIR arg proves the resume targets B — not A.
        #expect(joined.contains("claude --resume sess-cold"))
        #expect(joined.contains("CLAUDE_CONFIG_DIR="),
                "wake must inject a profile config dir; got: \(joined)")
        #expect(joined.lowercased().contains(b.id.uuidString.lowercased()),
                "wake after cold swap must resume under B's config dir (B's UUID); got: \(joined)")
        #expect(!joined.lowercased().contains(a.id.uuidString.lowercased()),
                "wake must NOT reference A's config dir after a cold swap to B")
    }

    // MARK: - Login sessions (Settings → "Open login session")

    /// Mutable pane-text holder so tests can drive what the auto-login pump
    /// "sees" in the (dry-run) tmux pane.
    final class PaneTextBox: @unchecked Sendable {
        private let lock = NSLock()
        private var _text = ""
        var text: String {
            lock.lock(); defer { lock.unlock() }
            return _text
        }
        func set(_ value: String) {
            lock.lock(); defer { lock.unlock() }
            _text = value
        }
    }

    /// Pane text mimicking Claude's interactive, logged-out idle state.
    static let readyPaneText = "Not logged in · Run /login\n❯"
    /// Pane text mimicking the /login method picker.
    static let loginDialogPaneText = "Login\nSelect login method:"

    /// Fixture whose LoginSessionCoordinator delays are test-tuned (fast
    /// pump, fast-expiring identity watcher so tests don't leave 30-minute
    /// poll tasks behind) and whose dry-run tmux serves pane text from the
    /// returned PaneTextBox.
    private func makeLoginFixture() -> (RPCRouter, TBDDatabase, TmuxRecorder, PaneTextBox) {
        let recorder = TmuxRecorder()
        let pane = PaneTextBox()
        let tmux = TmuxManager(
            dryRun: true,
            dryRunRecorder: { args in recorder.record(args) },
            dryRunCapturePane: { _, _ in pane.text }
        )
        let db = try! TBDDatabase(inMemory: true)
        let lifecycle = WorktreeLifecycle(
            db: db, git: GitManager(), tmux: tmux, hooks: HookResolver(),
            configDirManager: isolatedConfigDirManager())
        let router = RPCRouter(
            db: db,
            lifecycle: lifecycle,
            tmux: tmux,
            startTime: Date(),
            usageFetcher: StubClaudeUsageFetcher(),
            configDirManager: isolatedConfigDirManager(),
            loginSessions: LoginSessionCoordinator(delays: .init(
                pumpInitialDelay: .zero,
                pumpPollInterval: .milliseconds(5),
                // Wide enough that a test can observe a send and flip the
                // pane to the dialog BEFORE the pump's verify re-read —
                // otherwise the happy path races into a retry.
                pumpPostSendDelay: .milliseconds(500),
                pumpTimeout: .seconds(5),
                identityPollInterval: .milliseconds(5),
                identityPollTimeout: .milliseconds(50)
            ))
        )
        return (router, db, recorder, pane)
    }

    /// Poll until `condition` is true or `timeout` elapses.
    private func waitFor(
        _ condition: @Sendable () -> Bool,
        timeout: Duration = .seconds(5)
    ) async -> Bool {
        var elapsed: Duration = .zero
        let step: Duration = .milliseconds(10)
        while elapsed < timeout {
            if condition() { return true }
            try? await Task.sleep(for: step)
            elapsed += step
        }
        return condition()
    }

    /// REGRESSION (profile env clobbered by shell rc files): the profile's
    /// CLAUDE_CONFIG_DIR must ride in the shell command as an inline `export`
    /// (post-rc, can't be clobbered by ~/.zshenv account switchers), not only
    /// as tmux `-e` env. Also pins the login-session shape: label=login,
    /// profileID persisted on the DB row.
    @Test("login session: label=login, profileID persisted, config dir inline-exported")
    func loginSessionSpawn() async throws {
        let (router, db, recorder, _) = makeLoginFixture()
        defer { Task { await cleanup(db) } }
        let (_, wt) = try await seedRepoAndWorktree(db)
        let profile = try await seedOAuthProfile(db, name: "Login")

        let resp = await router.handle(try RPCRequest(
            method: RPCMethod.terminalCreate,
            params: TerminalCreateParams(
                worktreeID: wt.id, type: .claude,
                overrideProfileID: profile.id, loginSession: true
            )
        ))
        #expect(resp.success)
        let term = try resp.decodeResult(Terminal.self)
        #expect(term.label == TerminalLabel.login)
        #expect(term.profileID == profile.id)

        // The DB row is persisted with the profile id (no ghost terminals).
        let row = try #require(try await db.terminals.get(id: term.id))
        #expect(row.profileID == profile.id)
        #expect(row.label == TerminalLabel.login)

        // Inline export survives rc files; -e env still present too.
        #expect(recorder.shellBodies.contains("export CLAUDE_CONFIG_DIR="))
        #expect(recorder.joinedAll.contains("CLAUDE_CONFIG_DIR="))
    }

    /// Branch guard: the same spawn WITHOUT the loginSession flag keeps the
    /// normal Claude Code label and does not auto-type /login even when the
    /// pane looks ready for it.
    @Test("login session flag off: label stays Claude Code, no /login typed")
    func loginSessionFlagOff() async throws {
        let (router, db, recorder, pane) = makeLoginFixture()
        defer { Task { await cleanup(db) } }
        let (_, wt) = try await seedRepoAndWorktree(db)
        let profile = try await seedOAuthProfile(db, name: "Plain")
        pane.set(Self.readyPaneText)

        let resp = await router.handle(try RPCRequest(
            method: RPCMethod.terminalCreate,
            params: TerminalCreateParams(
                worktreeID: wt.id, type: .claude, overrideProfileID: profile.id
            )
        ))
        #expect(resp.success)
        let term = try resp.decodeResult(Terminal.self)
        #expect(term.label == TerminalLabel.claudeCode)

        // No pump was armed — nothing may type /login.
        try? await Task.sleep(for: .milliseconds(100))
        #expect(!recorder.joinedAll.contains("/login"))
    }

    @Test("login session: missing/unknown profile fails loud, no window spawned")
    func loginSessionUnknownProfile() async throws {
        let (router, db, recorder, _) = makeLoginFixture()
        defer { Task { await cleanup(db) } }
        let (_, wt) = try await seedRepoAndWorktree(db)

        let resp = await router.handle(try RPCRequest(
            method: RPCMethod.terminalCreate,
            params: TerminalCreateParams(
                worktreeID: wt.id, type: .claude,
                overrideProfileID: UUID(), loginSession: true
            )
        ))
        #expect(!resp.success)
        #expect(resp.error?.contains("Profile not found") == true)
        // ensureServer may have run, but no window was created and no row inserted.
        #expect(!recorder.joinedAll.contains("new-window"))
        #expect(try await db.terminals.list(worktreeID: wt.id).isEmpty)
    }

    @Test("login session: requires overrideProfileID")
    func loginSessionRequiresProfile() async throws {
        let (router, db, _, _) = makeLoginFixture()
        defer { Task { await cleanup(db) } }
        let (_, wt) = try await seedRepoAndWorktree(db)

        let resp = await router.handle(try RPCRequest(
            method: RPCMethod.terminalCreate,
            params: TerminalCreateParams(worktreeID: wt.id, type: .claude, loginSession: true)
        ))
        #expect(!resp.success)
        #expect(resp.error?.contains("require a profile") == true)
    }

    /// End-to-end pump behavior through the handler: the spawn arms the
    /// verified auto-login pump, which waits for the pane to become
    /// interactive, types `/login` + Enter, and stops once the login dialog
    /// is visible — exactly one send in the happy path.
    @Test("login session: pump types /login + Enter once the pane is ready, exactly once")
    func loginSessionAutoTypesWhenReady() async throws {
        let (router, db, recorder, pane) = makeLoginFixture()
        defer { Task { await cleanup(db) } }
        let (_, wt) = try await seedRepoAndWorktree(db)
        let profile = try await seedOAuthProfile(db, name: "AutoLogin")

        let createResp = await router.handle(try RPCRequest(
            method: RPCMethod.terminalCreate,
            params: TerminalCreateParams(
                worktreeID: wt.id, type: .claude,
                overrideProfileID: profile.id, loginSession: true
            )
        ))
        let term = try createResp.decodeResult(Terminal.self)

        // Pane still booting — no sends yet.
        try? await Task.sleep(for: .milliseconds(50))
        #expect(!recorder.joinedAll.contains("send-keys"))

        // Claude becomes interactive → the pump types /login + Enter.
        pane.set(Self.readyPaneText)
        #expect(await waitFor({ recorder.joinedAll.contains("send-keys -l -t \(term.tmuxPaneID) /login") }))
        #expect(await waitFor({ recorder.joinedAll.contains("send-keys -t \(term.tmuxPaneID) Enter") }))

        // The dialog appears → verified; the pump must stop at one send.
        pane.set(Self.loginDialogPaneText)
        try? await Task.sleep(for: .milliseconds(100))
        let loginSends = recorder.calls.filter { $0.contains("/login") && $0.contains("send-keys") }.count
        #expect(loginSends == 1)
    }

    /// If the first /login lands before Claude's input loop consumes pty
    /// input (send swallowed, dialog never appears), the pump verifies and
    /// re-sends instead of giving up — the exact failure observed live with
    /// fixed-delay sends.
    @Test("login session: pump re-sends when the first /login is swallowed")
    func loginSessionPumpRetries() async throws {
        let (router, db, recorder, pane) = makeLoginFixture()
        defer { Task { await cleanup(db) } }
        let (_, wt) = try await seedRepoAndWorktree(db)
        let profile = try await seedOAuthProfile(db, name: "Retry")
        pane.set(Self.readyPaneText)  // ready, but sends get "swallowed"

        let createResp = await router.handle(try RPCRequest(
            method: RPCMethod.terminalCreate,
            params: TerminalCreateParams(
                worktreeID: wt.id, type: .claude,
                overrideProfileID: profile.id, loginSession: true
            )
        ))
        let term = try createResp.decodeResult(Terminal.self)
        let sendMarker = "send-keys -l -t \(term.tmuxPaneID) /login"

        // First send happens…
        #expect(await waitFor({ recorder.joinedAll.contains(sendMarker) }))
        // …dialog still absent → the pump retries.
        #expect(await waitFor({
            recorder.calls.filter { $0.joined(separator: " ").contains(sendMarker) }.count >= 2
        }))

        // Once the dialog shows, the pump stops retrying.
        pane.set(Self.loginDialogPaneText)
        try? await Task.sleep(for: .milliseconds(100))
        let after = recorder.calls.filter { $0.joined(separator: " ").contains(sendMarker) }.count
        try? await Task.sleep(for: .milliseconds(100))
        let final = recorder.calls.filter { $0.joined(separator: " ").contains(sendMarker) }.count
        #expect(final == after)
    }
}
}
