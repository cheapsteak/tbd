import Foundation
import Testing
import TestSupport
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
        private let releaseGate = DispatchSemaphore(value: 0)
        private var _calls: [[String]] = []
        private var blockMatch: String?
        private var _isBlocked = false
        private var _blockedCommand: [String]?
        var calls: [[String]] {
            lock.lock(); defer { lock.unlock() }
            return _calls
        }
        func record(_ args: [String]) {
            let shouldBlock = lock.withLock { () -> Bool in
                _calls.append(args)
                guard let blockMatch,
                      !_isBlocked,
                      args.joined(separator: " ").contains(blockMatch) else {
                    return false
                }
                _isBlocked = true
                _blockedCommand = args
                return true
            }
            if shouldBlock {
                releaseGate.waitForGate("profile respawn")
            }
        }
        func arm(matching value: String) {
            lock.withLock {
                blockMatch = value
                _isBlocked = false
                _blockedCommand = nil
            }
        }
        var isBlocked: Bool { lock.withLock { _isBlocked } }
        var blockedCommand: [String]? { lock.withLock { _blockedCommand } }
        func release() {
            releaseGate.signal()
        }
        var joinedAll: String { calls.map { $0.joined(separator: " ") }.joined(separator: "\n") }
        /// Concatenation of just the shell-command bodies (last argv element of
        /// each new-window call). Used to assert that secrets do NOT leak into
        /// the long-running shell process arg.
        var shellBodies: String {
            calls.compactMap { $0.last }.joined(separator: "\n")
        }
    }

    final class StateDeltaRecorder: @unchecked Sendable {
        private let lock = NSLock()
        private var values: [StateDelta] = []

        func subscribe(to router: RPCRouter) {
            router.subscriptions.addSubscriber { [weak self] data in
                guard let delta = try? JSONDecoder().decode(StateDelta.self, from: data) else {
                    return true
                }
                guard let self else { return false }
                self.lock.withLock { self.values.append(delta) }
                return true
            }
        }

        func snapshot() -> [StateDelta] {
            lock.withLock { values }
        }
    }

    private func makeFixture(
        respawnWindowError: (@Sendable (String) -> Error?)? = nil
    ) -> (RPCRouter, TBDDatabase, TmuxRecorder) {
        let recorder = TmuxRecorder()
        let tmux = TmuxManager(
            dryRun: true,
            dryRunRecorder: { args in recorder.record(args) },
            dryRunRespawnWindowError: respawnWindowError)
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
            actuationLog: makeTestActuationLog()
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

    /// A token profile plus its stored secret. The secret goes through the real
    /// `ModelProfileKeychain` because the spawn path reads it back through the
    /// same static store — this suite runs under `TBDHomeSerialized` so that
    /// file lands inside the harness fence. `cleanup(_:)` reclaims it.
    private func seedTokenProfile(_ db: TBDDatabase, name: String,
                                  secret: String) async throws -> ModelProfile {
        let row = try await db.modelProfiles.create(name: name, kind: .oauthToken)
        try ModelProfileKeychain.store(id: row.id.uuidString, token: secret)
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

    // MARK: - Spawn: token profiles (CredentialKind.oauthToken)

    /// The whole security property of a token profile in one assertion pair:
    /// the secret reaches the pane as process env through tmux's `-e`, and it
    /// is nowhere in the command string, which is `ps`-visible for as long as
    /// the pane lives.
    @Test("builder: oauthToken injects CLAUDE_CODE_OAUTH_TOKEN via env only")
    func builderOAuthTokenInjectsViaEnvOnly() {
        let secret = "sk-ant-oat01-TESTTOKEN"
        let r = ClaudeSpawnCommandBuilder.build(
            resumeID: nil,
            freshSessionID: "sid",
            appendSystemPrompt: nil,
            initialPrompt: nil,
            profileSecret: secret,
            profileKind: .oauthToken,
            profileConfigDir: "/tmp/profiles/abc/claude",
            cmd: nil,
            shellFallback: ""
        )
        #expect(r.sensitiveEnv["CLAUDE_CODE_OAUTH_TOKEN"] == secret)
        #expect(!r.command.contains(secret))
        #expect(!r.command.contains("CLAUDE_CODE_OAUTH_TOKEN"))
        // ...and it is not an api-key profile, so the other secret var stays
        // unset: the two kinds pick one variable each, never both.
        #expect(r.sensitiveEnv["ANTHROPIC_API_KEY"] == nil)
    }

    /// The config dir *is* a routing key while the token is not: rc files
    /// clobber CLAUDE_CONFIG_DIR, so it must be re-exported inline after every
    /// startup file, and a secret must never be.
    @Test("builder: oauthToken still inlines CLAUDE_CONFIG_DIR")
    func builderOAuthTokenStillInlinesConfigDir() {
        let secret = "sk-ant-oat01-TESTTOKEN"
        let r = ClaudeSpawnCommandBuilder.build(
            resumeID: nil,
            freshSessionID: "sid",
            appendSystemPrompt: nil,
            initialPrompt: nil,
            profileSecret: secret,
            profileKind: .oauthToken,
            profileConfigDir: "/tmp/profiles/abc/claude",
            cmd: nil,
            shellFallback: ""
        )
        #expect(r.command.contains("export CLAUDE_CONFIG_DIR="))
        #expect(r.sensitiveEnv["CLAUDE_CONFIG_DIR"] == "/tmp/profiles/abc/claude")
        #expect(!r.command.contains(secret))
    }

    /// Off-branch: a signed-in profile is authenticated by the credential in
    /// its config dir, so a secret that somehow reached the builder for one —
    /// a stale `<uuid>.token` file, say — must NOT be injected. Injecting it
    /// would silently outrank the dir's own login.
    @Test("builder: oauth profile with a stray secret injects nothing")
    func builderOAuthWithStraySecretInjectsNothing() {
        let stray = "sk-ant-oat01-STRAY"
        let r = ClaudeSpawnCommandBuilder.build(
            resumeID: nil,
            freshSessionID: "sid",
            appendSystemPrompt: nil,
            initialPrompt: nil,
            profileSecret: stray,
            profileKind: .oauth,
            profileConfigDir: "/tmp/profiles/abc/claude",
            cmd: nil,
            shellFallback: ""
        )
        #expect(r.sensitiveEnv["CLAUDE_CODE_OAUTH_TOKEN"] == nil)
        #expect(r.sensitiveEnv["ANTHROPIC_API_KEY"] == nil)
        #expect(!r.command.contains(stray))
    }

    /// Off-branch: a token profile whose secret is missing spawns with the
    /// config dir and no token, rather than with an empty one.
    @Test("builder: oauthToken with no secret injects no token")
    func builderOAuthTokenWithoutSecretInjectsNothing() {
        let r = ClaudeSpawnCommandBuilder.build(
            resumeID: nil,
            freshSessionID: "sid",
            appendSystemPrompt: nil,
            initialPrompt: nil,
            profileSecret: nil,
            profileKind: .oauthToken,
            profileConfigDir: "/tmp/profiles/abc/claude",
            cmd: nil,
            shellFallback: ""
        )
        #expect(r.sensitiveEnv["CLAUDE_CODE_OAUTH_TOKEN"] == nil)
        #expect(r.sensitiveEnv["CLAUDE_CONFIG_DIR"] == "/tmp/profiles/abc/claude")
    }

    /// The same property end to end, through the real spawn path: the stored
    /// secret is read by the resolver, injected by tmux's `-e`, and absent from
    /// the long-running shell command.
    @Test("spawn: oauthToken default → token via tmux -e, never in the shell body")
    func spawnWithTokenProfile() async throws {
        let (router, db, recorder) = makeFixture()
        defer { Task { await cleanup(db) } }
        let (_, wt) = try await seedRepoAndWorktree(db)
        let secret = "sk-ant-oat01-\(UUID().uuidString)"
        let profile = try await seedTokenProfile(db, name: "Acme (token)", secret: secret)
        try await db.config.setDefaultProfileID(profile.id)

        let req = try RPCRequest(
            method: RPCMethod.terminalCreate,
            params: TerminalCreateParams(worktreeID: wt.id, type: .claude)
        )
        let resp = await router.handle(req)
        #expect(resp.success)
        let term = try resp.decodeResult(Terminal.self)
        #expect(term.profileID == profile.id)

        // Delivered as process env via `-e KEY=VALUE`...
        #expect(recorder.joinedAll.contains("CLAUDE_CODE_OAUTH_TOKEN=\(secret)"))
        // ...and a token profile still gets its isolated config dir.
        #expect(recorder.joinedAll.contains("CLAUDE_CONFIG_DIR="))
        // The shell command body is what `ps` shows for the pane's whole life.
        #expect(!recorder.shellBodies.contains(secret))
        #expect(!recorder.shellBodies.contains("CLAUDE_CODE_OAUTH_TOKEN"))
    }

    /// Off-branch of the same path: a signed-in profile spawned the same way
    /// carries no token at all, not even when a secret file exists for it.
    @Test("spawn: oauth default with a stray stored secret → no token injected")
    func spawnOAuthWithStrayStoredSecret() async throws {
        let (router, db, recorder) = makeFixture()
        defer { Task { await cleanup(db) } }
        let (_, wt) = try await seedRepoAndWorktree(db)
        let profile = try await seedOAuthProfile(db, name: "SignedIn")
        let stray = "sk-ant-oat01-\(UUID().uuidString)"
        try ModelProfileKeychain.store(id: profile.id.uuidString, token: stray)
        try await db.config.setDefaultProfileID(profile.id)

        let resp = await router.handle(try RPCRequest(
            method: RPCMethod.terminalCreate,
            params: TerminalCreateParams(worktreeID: wt.id, type: .claude)))
        #expect(resp.success)
        #expect(!recorder.joinedAll.contains("CLAUDE_CODE_OAUTH_TOKEN"))
        #expect(!recorder.joinedAll.contains(stray))
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
        let priorCodexHome = setCodexTestHome(codexHome.path)
        defer {
            restoreCodexTestHome(priorCodexHome)
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
        let priorCodexHome = setCodexTestHome(codexHome.path)
        defer {
            restoreCodexTestHome(priorCodexHome)
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

    // MARK: - Spawn: per-create Codex model override (branch-test rule)

    /// A Codex primary created with `codexModelOverride` launches with
    /// `-c 'model="<id>"'` between the profile selection and the bypass flag.
    @Test("spawn: Codex primary with a model override passes -c model=<id>")
    func codexPrimaryReceivesModelOverride() async throws {
        let codexHome = FileManager.default.temporaryDirectory
            .appendingPathComponent("tbd-codex-home-\(UUID().uuidString)")
        let priorCodexHome = setCodexTestHome(codexHome.path)
        defer {
            restoreCodexTestHome(priorCodexHome)
            try? FileManager.default.removeItem(at: codexHome)
        }

        let (lifecycle, db, recorder) = makeLifecycleFixture()
        defer { Task { await cleanup(db) } }
        let (repo, wt) = try await seedRepoAndWorktree(db)
        try await db.config.setPrimaryAgentPreference(.codex)

        _ = try await lifecycle.spawnPrimaryTerminals(
            worktree: wt, repo: repo, skipClaude: false, preSessionTerminalID: nil,
            codexModelOverride: "acme-model"
        )

        #expect(recorder.shellBodies.contains(
            #"tbd -c 'model="acme-model"' --dangerously-bypass-approvals-and-sandbox"#))
    }

    /// Without an override the Codex primary command carries no `-c` at all.
    @Test("spawn: Codex primary without a model override passes no -c")
    func codexPrimaryWithoutModelOverrideIsUnchanged() async throws {
        let codexHome = FileManager.default.temporaryDirectory
            .appendingPathComponent("tbd-codex-home-\(UUID().uuidString)")
        let priorCodexHome = setCodexTestHome(codexHome.path)
        defer {
            restoreCodexTestHome(priorCodexHome)
            try? FileManager.default.removeItem(at: codexHome)
        }

        let (lifecycle, db, recorder) = makeLifecycleFixture()
        defer { Task { await cleanup(db) } }
        let (repo, wt) = try await seedRepoAndWorktree(db)
        try await db.config.setPrimaryAgentPreference(.codex)

        _ = try await lifecycle.spawnPrimaryTerminals(
            worktree: wt, repo: repo, skipClaude: false, preSessionTerminalID: nil
        )

        #expect(recorder.shellBodies.contains(
            " tbd --dangerously-bypass-approvals-and-sandbox"))
        #expect(!recorder.shellBodies.contains("model="))
    }

    /// The override is scoped to the Codex arm: a Claude primary ignores it
    /// rather than treating it as a second agent-selection mechanism.
    @Test("spawn: Claude primary ignores a Codex model override")
    func claudePrimaryIgnoresCodexModelOverride() async throws {
        let (lifecycle, db, recorder) = makeLifecycleFixture()
        defer { Task { await cleanup(db) } }
        let (repo, wt) = try await seedRepoAndWorktree(db)
        try await db.config.setPrimaryAgentPreference(.claude)

        _ = try await lifecycle.spawnPrimaryTerminals(
            worktree: wt, repo: repo, skipClaude: false, preSessionTerminalID: nil,
            codexModelOverride: "acme-model"
        )

        #expect(!recorder.calls.isEmpty)
        #expect(!recorder.joinedAll.contains("acme-model"))
    }

    @Test("terminal.create passes a Codex model override to the Codex launch")
    func terminalCreateCodexModelOverride() async throws {
        let (router, db, recorder) = makeFixture()
        defer { Task { await cleanup(db) } }
        let (_, wt) = try await seedRepoAndWorktree(db)
        router.codexExecutableResolver = { "/opt/test/bin/codex" }
        router.codexHomeEnsurer = {
            FileManager.default.temporaryDirectory.appendingPathComponent(
                "tbd-test-codex-home-\(UUID().uuidString)", isDirectory: true)
        }

        let response = await router.handle(try RPCRequest(
            method: RPCMethod.terminalCreate,
            params: TerminalCreateParams(
                worktreeID: wt.id, type: .codex, model: "acme-model")))

        #expect(response.success)
        #expect(recorder.shellBodies.contains(
            #"tbd -c 'model="acme-model"' --dangerously-bypass-approvals-and-sandbox"#))
    }

    @Test("terminal.create refuses a model override for non-Codex terminals",
          arguments: [TerminalCreateType?.none, .claude, .shell])
    func terminalCreateRefusesModelForNonCodex(type: TerminalCreateType?) async throws {
        let (router, db, recorder) = makeFixture()
        defer { Task { await cleanup(db) } }
        let (_, wt) = try await seedRepoAndWorktree(db)

        let response = await router.handle(try RPCRequest(
            method: RPCMethod.terminalCreate,
            params: TerminalCreateParams(worktreeID: wt.id, type: type, model: "acme-model")))

        #expect(!response.success)
        #expect(response.error == TerminalCreateParams.modelRequiresCodexMessage)
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
        let priorTBDHome = setTBDHome(tmp.path)
        defer {
            restoreTBDHome(priorTBDHome)
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
        let priorTBDHome = setTBDHome(tmp.path)
        defer {
            restoreTBDHome(priorTBDHome)
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
        let priorTBDHome = setTBDHome(tmp.path)
        defer {
            restoreTBDHome(priorTBDHome)
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
        // its JSONL exists but holds no conversation — so swap should pick the
        // fresh path. (A MISSING JSONL refuses a fork instead; see
        // `forkOverMissingTranscriptIsRefused`.)
        let createResp = await router.handle(try RPCRequest(
            method: RPCMethod.terminalCreate,
            params: TerminalCreateParams(worktreeID: wt.id, type: .claude)
        ))
        #expect(createResp.success)
        let oldTerm = try createResp.decodeResult(Terminal.self)
        let blankDir = try await seedBlankTranscript(db, oldTerm)
        defer { try? FileManager.default.removeItem(at: blankDir) }
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

    @Test("in-place swap: handler event from the respawn gap is fenced")
    func inPlaceSwapFencesSessionStartHandledDuringRespawnGap() async throws {
        let (router, db, recorder) = makeFixture()
        let deltas = StateDeltaRecorder()
        deltas.subscribe(to: router)
        defer { Task { await cleanup(db) } }
        let (_, worktree) = try await seedRepoAndWorktree(db)
        let profileA = try await seedOAuthProfile(db, name: "A")
        let profileB = try await seedOAuthProfile(db, name: "B")
        try await db.config.setDefaultProfileID(profileA.id)

        let createResponse = await router.handle(try RPCRequest(
            method: RPCMethod.terminalCreate,
            params: TerminalCreateParams(worktreeID: worktree.id, type: .claude)))
        let terminal = try createResponse.decodeResult(Terminal.self)

        let swapRequest = try RPCRequest(
            method: RPCMethod.terminalSwapProfile,
            params: TerminalSwapProfileParams(
                terminalID: terminal.id,
                newProfileID: profileB.id,
                mode: .inPlace))
        recorder.arm(matching: "respawn-window")
        let swap = gateHoldingTask {
            await router.handle(swapRequest)
        }
        guard await waitUntil({ recorder.isBlocked }) else {
            recorder.release()
            _ = await swap.value
            Issue.record("profile swap never reached the respawn")
            return
        }
        let staged = try #require(try await db.terminals.get(id: terminal.id))
        let intendedSessionID = try #require(staged.claudeSessionID)
        let replacementToken = try #require(staged.sessionIncarnationID)
        #expect(recorder.blockedCommand?.last?.contains(
            "TBD_TERMINAL_INCARNATION_ID='\(replacementToken.uuidString)'") == true)
        let matchedCLIPath = try #require(AgentProcessEnvironment.cliPath)
        #expect(recorder.blockedCommand?.last?.contains(
            "TBD_CLI_PATH=\(SystemPromptBuilder.shellEscape(matchedCLIPath))") == true)

        let gapEvent = try RPCRequest(
            method: RPCMethod.terminalSessionEvent,
            params: TerminalSessionEventParams(
                terminalID: terminal.id,
                sessionID: "old-process-gap-session",
                transcriptPath: "/tmp/old-process-gap-session.jsonl",
                source: "startup"))
        #expect((await router.handle(gapEvent)).success)
        #expect(try await db.terminals.get(id: terminal.id)?.claudeSessionID
                == intendedSessionID)

        let replacementEvent = try RPCRequest(
            method: RPCMethod.terminalSessionEvent,
            params: TerminalSessionEventParams(
                terminalID: terminal.id,
                sessionID: "replacement-session",
                transcriptPath: "/tmp/replacement-session.jsonl",
                source: "startup",
                sessionIncarnationID: replacementToken))
        #expect((await router.handle(replacementEvent)).success)
        #expect(try await db.terminals.get(id: terminal.id)?.claudeSessionID
                == "replacement-session")

        recorder.release()
        #expect((await swap.value).success)
        let finalized = try #require(try await db.terminals.get(id: terminal.id))
        #expect(finalized.profileID == profileB.id)
        #expect(finalized.claudeSessionID == "replacement-session")
        #expect(finalized.transcriptPath == "/tmp/replacement-session.jsonl")

        let sessionDeltas = deltas.snapshot().compactMap { delta -> TerminalSessionDelta? in
            guard case .terminalSessionUpdated(let session) = delta else { return nil }
            return session
        }
        #expect(sessionDeltas.last?.sessionID == "replacement-session")
        #expect(sessionDeltas.last?.transcriptPath == "/tmp/replacement-session.jsonl")
    }

    @Test("in-place swap: launch failure broadcasts the derived unknown reset")
    func inPlaceSwapLaunchFailureBroadcastsActivityReset() async throws {
        let (router, db, _) = makeFixture(respawnWindowError: { _ in
            TmuxError.unexpectedOutput("replacement launch failed")
        })
        defer { Task { await cleanup(db) } }
        let (_, worktree) = try await seedRepoAndWorktree(db)
        let profileA = try await seedOAuthProfile(db, name: "A")
        let profileB = try await seedOAuthProfile(db, name: "B")
        try await db.config.setDefaultProfileID(profileA.id)
        let createResponse = await router.handle(try RPCRequest(
            method: RPCMethod.terminalCreate,
            params: TerminalCreateParams(worktreeID: worktree.id, type: .claude)))
        let terminal = try createResponse.decodeResult(Terminal.self)
        try await db.terminals.setActivityState(
            id: terminal.id,
            activityState: .working,
            source: .hookEvent("UserPromptSubmit"),
            observedAt: Date(timeIntervalSinceReferenceDate: 5))
        let deltas = StateDeltaRecorder()
        deltas.subscribe(to: router)

        _ = await router.handle(try RPCRequest(
            method: RPCMethod.terminalSwapProfile,
            params: TerminalSwapProfileParams(
                terminalID: terminal.id,
                newProfileID: profileB.id,
                mode: .inPlace)))

        let stored = try #require(try await db.terminals.get(id: terminal.id))
        #expect(stored.activityState == .unknown)
        #expect(stored.activityStateSource == .derived)
        let activityDeltas = deltas.snapshot().compactMap { delta -> TerminalActivityDelta? in
            guard case .terminalActivityUpdated(let activity) = delta else { return nil }
            return activity
        }
        let reset = try #require(activityDeltas.last)
        #expect(reset.activityState == stored.activityState)
        #expect(reset.activityStateSource == stored.activityStateSource)
        #expect(reset.activityStateObservedAt == stored.activityStateObservedAt)
        #expect(reset.activityStateOrderObservedAt == stored.activityStateOrderObservedAt)
    }

    /// An in-place swap kills the pane's Claude and respawns it, keeping the
    /// SAME terminal row — so a permission prompt that was on screen when the
    /// user switched account died with the old process while its recorded
    /// reason stayed on the row.
    ///
    /// The post-respawn lifecycle transition retracts the prompt and replaces
    /// old-process activity with derived unknown. The resumed process's hooks
    /// establish its new activity after that durable fence.
    @Test("in-place swap: retracts a prompt recorded against the process it killed")
    func inPlaceSwapRetractsAStandingWaitReason() async throws {
        let (router, db, _) = makeFixture()
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

        let workingAt = Date(timeIntervalSince1970: 1_700_000_000)
        let promptAt = workingAt.addingTimeInterval(30)
        try await db.terminals.setActivityState(
            id: oldTerm.id, activityState: .working,
            source: .hookEvent(RPCMethod.terminalActivityEvent), observedAt: workingAt)
        try await db.terminals.recordAwaitingInputReason(
            id: oldTerm.id,
            reason: AwaitingInputReason(
                message: "Claude needs your permission to use Bash",
                hookEventName: "Notification",
                notificationType: "permission_prompt"),
            observedAt: promptAt)

        let swapResp = await router.handle(try RPCRequest(
            method: RPCMethod.terminalSwapProfile,
            params: TerminalSwapProfileParams(
                terminalID: oldTerm.id, newProfileID: b.id, mode: .inPlace)
        ))
        #expect(swapResp.success)

        let after = try #require(try await db.terminals.get(id: oldTerm.id))
        #expect(after.profileID == b.id)
        #expect(after.awaitingInputReason == nil)
        #expect(after.awaitingInputObservedAt == nil)
        // The dead prompt and activity are gone from the composed answer.
        let state = SessionStateResolver().resolve(SessionStateFacts(terminal: after))
        #expect(state.value == .unknown(
            why: "the activity rail recorded state 'unknown' for this session"))
        #expect(after.activityState == .unknown)
        #expect(after.activityStateSource == .derived)
        #expect(after.activityStateObservedAt != workingAt)
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

    /// Give `term`'s session a BLANK transcript on disk: the file exists and
    /// carries only a metadata line, so the scanner answers `.blank` (not
    /// `.missing`) and a fork plans a fresh spawn rather than being refused.
    /// Returns the directory holding it, for the caller to remove.
    private func seedBlankTranscript(_ db: TBDDatabase, _ term: Terminal) async throws -> URL {
        let sessionID = try #require(term.claudeSessionID)
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("tbd-swap-blank-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let file = dir.appendingPathComponent("\(sessionID).jsonl")
        try #"{"type":"permission-mode","permissionMode":"default"}"#
            .write(to: file, atomically: true, encoding: .utf8)
        try await db.terminals.updateSession(id: term.id, sessionID: sessionID, transcriptPath: file.path)
        return dir
    }

    // MARK: - Fork over a MISSING transcript: refused

    /// A fork of a session with NO transcript on disk must be refused, not
    /// quietly turned into a blank fresh tab presented as a fork. The refusal
    /// names the session and the path that was looked for, spawns nothing,
    /// creates no row, and is recorded as a refused actuation.
    @Test("fork over a missing transcript: refused, nothing spawned, no row, refusal recorded")
    func forkOverMissingTranscriptIsRefused() async throws {
        let recorder = TmuxRecorder()
        let tmux = TmuxManager(dryRun: true, dryRunRecorder: { args in recorder.record(args) })
        let db = try TBDDatabase(inMemory: true)
        defer { Task { await cleanup(db) } }
        let logDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("tbd-fork-missing-log-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: logDir) }
        let logPath = logDir.appendingPathComponent("actuations.jsonl").path
        let router = RPCRouter(
            db: db,
            lifecycle: WorktreeLifecycle(
                db: db, git: GitManager(), tmux: tmux, hooks: HookResolver(),
                configDirManager: isolatedConfigDirManager()),
            tmux: tmux,
            startTime: Date(),
            usageFetcher: StubClaudeUsageFetcher(),
            configDirManager: isolatedConfigDirManager(),
            actuationLog: ActuationLog(path: logPath))
        let (_, wt) = try await seedRepoAndWorktree(db)
        let b = try await seedOAuthProfile(db, name: "B")

        // A freshly created session: no JSONL anywhere, no transcriptPath.
        let createResp = await router.handle(try RPCRequest(
            method: RPCMethod.terminalCreate,
            params: TerminalCreateParams(worktreeID: wt.id, type: .claude)
        ))
        #expect(createResp.success)
        let oldTerm = try createResp.decodeResult(Terminal.self)
        let sessionID = try #require(oldTerm.claudeSessionID)
        #expect(oldTerm.transcriptPath == nil)

        let beforeSwap = recorder.calls.count
        let swapResp = await router.handle(try RPCRequest(
            method: RPCMethod.terminalSwapProfile,
            params: TerminalSwapProfileParams(terminalID: oldTerm.id, newProfileID: b.id, mode: .fork)
        ))

        #expect(!swapResp.success)
        let error = try #require(swapResp.error)
        #expect(error.contains(sessionID), "refusal must name the session: \(error)")
        #expect(error.contains("no transcript to fork"), "refusal must say why: \(error)")
        #expect(error.contains("\(sessionID).jsonl"), "refusal must name the looked-for path: \(error)")

        // Nothing spawned, and the only row in the worktree is the source.
        let postSwap = Array(recorder.calls.dropFirst(beforeSwap))
        let joined = postSwap.map { $0.joined(separator: " ") }.joined(separator: "\n")
        #expect(!joined.contains("new-window"), "a refused fork spawned a window: \(joined)")
        #expect(!joined.contains("claude --session-id"), "a refused fork composed a spawn: \(joined)")
        let rows = try await db.terminals.list(worktreeID: wt.id)
        #expect(rows.map(\.id) == [oldTerm.id], "a refused fork left a row behind")
        #expect(try await db.terminals.get(id: oldTerm.id)?.profileID == oldTerm.profileID)

        // The actuation record: one request, one refused outcome naming why.
        let contents = try String(contentsOfFile: logPath, encoding: .utf8)
        let records = try contents.split(separator: "\n", omittingEmptySubsequences: true).map {
            try #require(try JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any])
        }
        let swapRecords = records.filter { ($0["method"] as? String) == RPCMethod.terminalSwapProfile }
        #expect(swapRecords.count == 1, "the refused fork should open one request row: \(records)")
        let outcome = try #require(records.last)
        #expect(outcome["result"] as? String == "refused", "outcome: \(outcome)")
        #expect(outcome["reason"] as? String == "not-found", "outcome: \(outcome)")
        #expect((outcome["error"] as? String)?.contains(sessionID) == true, "outcome: \(outcome)")
    }

    /// The transcript scan looks in the host store; a session whose transcript
    /// lives only under the SOURCE config dir (the one the transcript carry
    /// searches) must not be refused as missing — it has a conversation, so the
    /// fork resumes it with `--fork-session`.
    @Test("fork: transcript found only under the source config dir is resumed, not refused")
    func forkFindsTranscriptUnderSourceConfigDir() async throws {
        let recorder = TmuxRecorder()
        let tmux = TmuxManager(dryRun: true, dryRunRecorder: { args in recorder.record(args) })
        let db = try TBDDatabase(inMemory: true)
        defer { Task { await cleanup(db) } }
        let manager = isolatedConfigDirManager()
        defer { try? FileManager.default.removeItem(at: manager.ambientConfigDirectory.deletingLastPathComponent()) }
        let router = RPCRouter(
            db: db,
            lifecycle: WorktreeLifecycle(
                db: db, git: GitManager(), tmux: tmux, hooks: HookResolver(),
                configDirManager: manager),
            tmux: tmux,
            startTime: Date(),
            usageFetcher: StubClaudeUsageFetcher(),
            configDirManager: manager,
            actuationLog: makeTestActuationLog())
        let (_, wt) = try await seedRepoAndWorktree(db)

        // Ambient session (no default profile), transcriptPath nil, transcript
        // only under the router's ambient config dir's projects/ tree.
        let createResp = await router.handle(try RPCRequest(
            method: RPCMethod.terminalCreate,
            params: TerminalCreateParams(worktreeID: wt.id, type: .claude)
        ))
        let oldTerm = try createResp.decodeResult(Terminal.self)
        #expect(oldTerm.profileID == nil)
        let sessionID = try #require(oldTerm.claudeSessionID)
        let projectDir = ClaudeProjectDirectory.expectedDirectory(
            worktreePath: wt.localPath,
            projectsBase: manager.ambientConfigDirectory.appendingPathComponent("projects", isDirectory: true))
        try FileManager.default.createDirectory(at: projectDir, withIntermediateDirectories: true)
        try #"{"type":"user","message":{"role":"user","content":"hello there"}}"#
            .write(to: projectDir.appendingPathComponent("\(sessionID).jsonl"), atomically: true, encoding: .utf8)

        let beforeSwap = recorder.calls.count
        let swapResp = await router.handle(try RPCRequest(
            method: RPCMethod.terminalSwapProfile,
            params: TerminalSwapProfileParams(terminalID: oldTerm.id, newProfileID: nil, mode: .fork)
        ))
        #expect(swapResp.success, "\(swapResp.error ?? "")")
        let joined = Array(recorder.calls.dropFirst(beforeSwap))
            .map { $0.joined(separator: " ") }.joined(separator: "\n")
        #expect(joined.contains("claude --resume \(sessionID)"), "got: \(joined)")
        #expect(joined.contains("--fork-session"), "got: \(joined)")
    }

    /// The slug lookup is not the last word before a refusal. A transcript
    /// the slug cannot reach — written under a project dir named for a path
    /// the worktree no longer has, or hidden behind a cached miss — is still
    /// found by the by-session-ID scan, so the fork resumes it.
    @Test("fork: transcript under a stale slug or behind a cached miss is resumed, not refused",
          arguments: [false, true])
    func forkFindsTranscriptTheSlugLookupMisses(cachedMiss: Bool) async throws {
        let recorder = TmuxRecorder()
        let tmux = TmuxManager(dryRun: true, dryRunRecorder: { args in recorder.record(args) })
        let db = try TBDDatabase(inMemory: true)
        defer { Task { await cleanup(db) } }
        let manager = isolatedConfigDirManager()
        defer { try? FileManager.default.removeItem(at: manager.ambientConfigDirectory.deletingLastPathComponent()) }
        let router = RPCRouter(
            db: db,
            lifecycle: WorktreeLifecycle(
                db: db, git: GitManager(), tmux: tmux, hooks: HookResolver(),
                configDirManager: manager),
            tmux: tmux,
            startTime: Date(),
            usageFetcher: StubClaudeUsageFetcher(),
            configDirManager: manager,
            actuationLog: makeTestActuationLog())
        let (_, wt) = try await seedRepoAndWorktree(db)

        let createResp = await router.handle(try RPCRequest(
            method: RPCMethod.terminalCreate,
            params: TerminalCreateParams(worktreeID: wt.id, type: .claude)
        ))
        let oldTerm = try createResp.decodeResult(Terminal.self)
        #expect(oldTerm.profileID == nil)
        #expect(oldTerm.transcriptPath == nil)
        let sessionID = try #require(oldTerm.claudeSessionID)
        let projectsBase = manager.ambientConfigDirectory.appendingPathComponent("projects", isDirectory: true)

        let projectDir: URL
        if cachedMiss {
            // Resolve before the project dir exists: the resolver caches the
            // miss for 30 s, and the dir created next is the CURRENT slug.
            try FileManager.default.createDirectory(at: projectsBase, withIntermediateDirectories: true)
            #expect(ClaudeProjectDirectory.resolve(worktreePath: wt.localPath, projectsBase: projectsBase) == nil)
            projectDir = ClaudeProjectDirectory.expectedDirectory(
                worktreePath: wt.localPath, projectsBase: projectsBase)
        } else {
            // A slug no tier of the resolver maps the current path to.
            projectDir = projectsBase.appendingPathComponent("-old-home-of-this-worktree-\(UUID().uuidString.prefix(8))")
        }
        try FileManager.default.createDirectory(at: projectDir, withIntermediateDirectories: true)
        try #"{"type":"user","message":{"role":"user","content":"hello there"}}"#
            .write(to: projectDir.appendingPathComponent("\(sessionID).jsonl"), atomically: true, encoding: .utf8)

        let beforeSwap = recorder.calls.count
        let swapResp = await router.handle(try RPCRequest(
            method: RPCMethod.terminalSwapProfile,
            params: TerminalSwapProfileParams(terminalID: oldTerm.id, newProfileID: nil, mode: .fork)
        ))
        #expect(swapResp.success, "\(swapResp.error ?? "")")
        let joined = Array(recorder.calls.dropFirst(beforeSwap))
            .map { $0.joined(separator: " ") }.joined(separator: "\n")
        #expect(joined.contains("claude --resume \(sessionID)"), "got: \(joined)")
        #expect(joined.contains("--fork-session"), "got: \(joined)")
    }

    /// `.inPlace` on the tmux transport is deliberately unchanged: a session
    /// with NO transcript on disk still plans fresh and lands on the new
    /// account — the refusal is `.fork`'s alone.
    @Test("in-place swap over a missing transcript: still spawns fresh on the new account")
    func inPlaceOverMissingTranscriptStillSpawnsFresh() async throws {
        let (router, db, recorder) = makeFixture()
        defer { Task { await cleanup(db) } }
        let (_, wt) = try await seedRepoAndWorktree(db)
        let b = try await seedOAuthProfile(db, name: "B")

        let createResp = await router.handle(try RPCRequest(
            method: RPCMethod.terminalCreate,
            params: TerminalCreateParams(worktreeID: wt.id, type: .claude)
        ))
        let oldTerm = try createResp.decodeResult(Terminal.self)
        #expect(oldTerm.transcriptPath == nil)

        let beforeSwap = recorder.calls.count
        let swapResp = await router.handle(try RPCRequest(
            method: RPCMethod.terminalSwapProfile,
            params: TerminalSwapProfileParams(terminalID: oldTerm.id, newProfileID: b.id, mode: .inPlace)
        ))
        #expect(swapResp.success, "\(swapResp.error ?? "")")
        let after = try #require(try await db.terminals.get(id: oldTerm.id))
        #expect(after.profileID == b.id)
        let joined = Array(recorder.calls.dropFirst(beforeSwap))
            .map { $0.joined(separator: " ") }.joined(separator: "\n")
        #expect(joined.contains("claude --session-id"), "got: \(joined)")
        #expect(!joined.contains("claude --resume"), "got: \(joined)")
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
        let blankDir = try await seedBlankTranscript(db, oldTerm)
        defer { try? FileManager.default.removeItem(at: blankDir) }

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
        #expect(wakeResult.isOk)

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

    /// Pane text mimicking Claude's interactive, logged-out idle state — the
    /// screen a tab that typed `/login` for the person would have acted on.
    static let readyPaneText = "Not logged in · Run /login\n❯"

    /// Counts every pane capture the dry-run tmux serves.
    final class CaptureCounter: @unchecked Sendable {
        private let lock = NSLock()
        private var _count = 0
        var count: Int {
            lock.lock(); defer { lock.unlock() }
            return _count
        }
        func record() {
            lock.lock(); defer { lock.unlock() }
            _count += 1
        }
    }

    /// Every delta the router broadcast, decoded.
    final class DeltaRecorder: @unchecked Sendable {
        private let lock = NSLock()
        private var _deltas: [StateDelta] = []
        var profilesChangedCount: Int {
            lock.lock(); defer { lock.unlock() }
            return _deltas.filter {
                if case .modelProfilesChanged = $0 { return true }
                return false
            }.count
        }
        func record(_ delta: StateDelta) {
            lock.lock(); defer { lock.unlock() }
            _deltas.append(delta)
        }
    }

    private struct LoginFixture {
        let router: RPCRouter
        let db: TBDDatabase
        let tmux: TmuxRecorder
        let captures: CaptureCounter
        let deltas: DeltaRecorder
        let configDirManager: ClaudeProfileConfigDirManager
    }

    /// Fixture whose identity watcher is test-tuned (fast poll, bounded life so
    /// tests don't leave 30-minute poll tasks behind), whose dry-run tmux
    /// serves a pane that is ready for `/login` and counts every capture of
    /// it, and whose broadcasts are recorded.
    private func makeLoginFixture() -> LoginFixture {
        let recorder = TmuxRecorder()
        let captures = CaptureCounter()
        let tmux = TmuxManager(
            dryRun: true,
            dryRunRecorder: { args in recorder.record(args) },
            dryRunCapturePane: { _, _ in
                captures.record()
                return Self.readyPaneText
            }
        )
        let db = try! TBDDatabase(inMemory: true)
        let configDirManager = isolatedConfigDirManager()
        let subscriptions = StateSubscriptionManager()
        let deltas = DeltaRecorder()
        subscriptions.addSubscriber { data in
            if let delta = try? JSONDecoder().decode(StateDelta.self, from: data) {
                deltas.record(delta)
            }
            return true
        }
        let lifecycle = WorktreeLifecycle(
            db: db, git: GitManager(), tmux: tmux, hooks: HookResolver(),
            configDirManager: configDirManager)
        let router = RPCRouter(
            db: db,
            lifecycle: lifecycle,
            tmux: tmux,
            startTime: Date(),
            subscriptions: subscriptions,
            usageFetcher: StubClaudeUsageFetcher(),
            configDirManager: configDirManager,
            loginSessions: LoginSessionCoordinator(delays: .init(
                identityPollInterval: .milliseconds(5),
                identityPollTimeout: TestDeadlines.saturatedPass
            )),
            actuationLog: makeTestActuationLog()
        )
        return LoginFixture(
            router: router, db: db, tmux: recorder, captures: captures,
            deltas: deltas, configDirManager: configDirManager)
    }

    /// Poll until `condition` is true or `timeout` elapses.
    ///
    /// The deadline is the shared saturated-pass budget, not a literal: what it
    /// waits for is produced by the coordinator's own detached watcher task,
    /// which runs on the cooperative pool behind the whole fast pass regardless
    /// of how the test was started (`gateHoldingTask` in
    /// `Tests/TestSupport/BoundedGateSupport.swift`). Five seconds is far below
    /// that pass's healthy per-test latency.
    private func waitFor(
        _ condition: @Sendable () -> Bool,
        timeout: Duration = TestDeadlines.saturatedPass
    ) async -> Bool {
        var elapsed: Duration = .zero
        let step: Duration = .milliseconds(10)
        while elapsed < timeout {
            if condition() { return true }
            try? await Task.sleep(for: step)
            // `try?` swallows the CancellationError, and a cancelled sleep
            // returns instantly — so without this the loop would spin through
            // every remaining step at full speed instead of ending. Report
            // whatever the condition says at the moment of cancellation.
            if Task.isCancelled { return condition() }
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
        let fixture = makeLoginFixture()
        let (router, db, recorder) = (fixture.router, fixture.db, fixture.tmux)
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
    /// normal Claude Code label and types nothing, even when the pane looks
    /// ready for `/login`.
    @Test("login session flag off: label stays Claude Code, no /login typed")
    func loginSessionFlagOff() async throws {
        let fixture = makeLoginFixture()
        let (router, db, recorder) = (fixture.router, fixture.db, fixture.tmux)
        defer { Task { await cleanup(db) } }
        let (_, wt) = try await seedRepoAndWorktree(db)
        let profile = try await seedOAuthProfile(db, name: "Plain")

        let resp = await router.handle(try RPCRequest(
            method: RPCMethod.terminalCreate,
            params: TerminalCreateParams(
                worktreeID: wt.id, type: .claude, overrideProfileID: profile.id
            )
        ))
        #expect(resp.success)
        let term = try resp.decodeResult(Terminal.self)
        #expect(term.label == TerminalLabel.claudeCode)

        // Nothing may type /login.
        try? await Task.sleep(for: .milliseconds(100))
        #expect(!recorder.joinedAll.contains("/login"))
    }

    @Test("login session: missing/unknown profile fails loud, no window spawned")
    func loginSessionUnknownProfile() async throws {
        let fixture = makeLoginFixture()
        let (router, db, recorder) = (fixture.router, fixture.db, fixture.tmux)
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
        let fixture = makeLoginFixture()
        let (router, db) = (fixture.router, fixture.db)
        defer { Task { await cleanup(db) } }
        let (_, wt) = try await seedRepoAndWorktree(db)

        let resp = await router.handle(try RPCRequest(
            method: RPCMethod.terminalCreate,
            params: TerminalCreateParams(worktreeID: wt.id, type: .claude, loginSession: true)
        ))
        #expect(!resp.success)
        #expect(resp.error?.contains("require a profile") == true)
    }

    /// A login tab is left to the person: the daemon neither reads the pane
    /// nor types into it, even when the pane already shows the logged-out
    /// footer hint. The badge-flip test below is the positive leg — the same
    /// spawn does arm the identity watcher.
    @Test("login session: the pane is never read and nothing is typed into it")
    func loginSessionTypesNothing() async throws {
        let fixture = makeLoginFixture()
        defer { Task { await cleanup(fixture.db) } }
        let (_, wt) = try await seedRepoAndWorktree(fixture.db)
        let profile = try await seedOAuthProfile(fixture.db, name: "Manual")

        let resp = await fixture.router.handle(try RPCRequest(
            method: RPCMethod.terminalCreate,
            params: TerminalCreateParams(
                worktreeID: wt.id, type: .claude,
                overrideProfileID: profile.id, loginSession: true
            )
        ))
        #expect(resp.success, "\(resp.error ?? "")")
        let term = try resp.decodeResult(Terminal.self)
        #expect(term.label == TerminalLabel.login)

        // Anything armed by the spawn has had the whole window to act on a
        // pane that is ready for it.
        #expect(!(await waitFor({
            fixture.captures.count > 0
                || fixture.tmux.calls.contains { $0.contains("send-keys") || $0.contains("paste-buffer") }
        }, timeout: .milliseconds(300))))
        #expect(fixture.captures.count == 0, "the login pane was read")
        #expect(
            !fixture.tmux.calls.contains { $0.contains("send-keys") },
            "keys were sent into the login pane: \(fixture.tmux.calls)")
        #expect(!fixture.tmux.joinedAll.contains("/login"))
    }

    /// The identity watcher is what a login tab still arms: once the profile's
    /// isolated `.claude.json` gains an `oauthAccount`, the daemon broadcasts
    /// `.modelProfilesChanged` so the Settings badge flips to "Logged in as …".
    @Test("login session: the badge refresh fires when the profile's credential appears")
    func loginSessionIdentityWatcherBroadcasts() async throws {
        let fixture = makeLoginFixture()
        defer { Task { await cleanup(fixture.db) } }
        let (_, wt) = try await seedRepoAndWorktree(fixture.db)
        let profile = try await seedOAuthProfile(fixture.db, name: "Badge")

        let resp = await fixture.router.handle(try RPCRequest(
            method: RPCMethod.terminalCreate,
            params: TerminalCreateParams(
                worktreeID: wt.id, type: .claude,
                overrideProfileID: profile.id, loginSession: true
            )
        ))
        #expect(resp.success, "\(resp.error ?? "")")
        let baseline = fixture.deltas.profilesChangedCount

        // Not logged in yet — the watcher is polling and has nothing to say.
        #expect(fixture.configDirManager.loginIdentity(forProfileID: profile.id) == nil)

        // The person completes `/login`: Claude writes the account into the
        // profile's isolated config dir.
        let configDir = fixture.configDirManager.configDirectory(forProfileID: profile.id)
        try FileManager.default.createDirectory(at: configDir, withIntermediateDirectories: true)
        let claudeJSON = #"{"oauthAccount":{"emailAddress":"person@acme.example"}}"#
        try Data(claudeJSON.utf8).write(to: configDir.appendingPathComponent(".claude.json"))

        #expect(await waitFor({ fixture.deltas.profilesChangedCount > baseline }))
    }
}
}
