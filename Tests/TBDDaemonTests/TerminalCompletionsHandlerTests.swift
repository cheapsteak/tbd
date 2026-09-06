import Foundation
import TestSupport
import Testing
@testable import TBDDaemonLib
import TBDShared

/// `terminal.completions` — its flag gate, its unknown-terminal answer, and the
/// fields it resolves for the service.
@Suite("terminal.completions handler")
struct TerminalCompletionsHandlerTests {

    /// Records the environment the service handed the probe, so a test can assert
    /// what the handler assembled rather than only what came back.
    private actor EnvironmentRecorder {
        private(set) var environment: [String: String]?
        func record(_ environment: [String: String]) { self.environment = environment }
    }

    /// A throwaway actuation log per fixture. `ActuationLog` takes a PATH, not a
    /// database — the record is an append-only JSONL file.
    private static func scratchLogPath() -> String {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("tbd-plan-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true)
        return directory.appendingPathComponent("actuations.jsonl").path
    }

    private static let stubOutcome = ClaudeCompletionProbe.Outcome(
        commands: [CompletionCommand(name: "compact", description: "d")],
        agents: [])

    private func makeRouter(
        db: TBDDatabase,
        configDirManager: ClaudeProfileConfigDirManager
            = makeIsolatedConfigDirManager(tag: "completions-handler"),
        probe: @escaping CompletionInventoryService.Prober = { _, _, _ in stubOutcome }
    ) -> RPCRouter {
        let tmux = TmuxManager(dryRun: true)
        return RPCRouter(
            db: db,
            lifecycle: WorktreeLifecycle(
                db: db, git: GitManager(), tmux: tmux, hooks: HookResolver()),
            tmux: tmux,
            configDirManager: configDirManager,
            completionInventory: CompletionInventoryService(
                probe: probe,
                scan: { _, _ in ([], []) },
                resolveExecutable: { "/usr/local/bin/claude" },
                executablePathForPID: { _ in nil },
                fingerprint: { _, _ in "fp" }),
            actuationLog: ActuationLog(path: Self.scratchLogPath()))
    }

    private func makeTerminal(
        _ db: TBDDatabase, profileID: UUID? = nil
    ) async throws -> Terminal {
        let worktree = try await db.worktrees.createScratch(
            name: "wt", displayName: "wt",
            path: "/tmp/tbd-nonexistent-\(UUID().uuidString)", tmuxServer: "tbd-test")
        return try await db.terminals.create(
            worktreeID: worktree.id, tmuxWindowID: "@1", tmuxPaneID: "%1",
            label: "claude", claudeSessionID: "sess-1", profileID: profileID, kind: .claude)
    }

    /// **Both branches of the flag.** With it off the verb answers with an error
    /// rather than an empty inventory, so a caller cannot mistake "the feature is
    /// off" for "this session knows no commands".
    @Test func theFlagOffRefusesTheVerb() async throws {
        let db = try TBDDatabase(inMemory: true)
        let terminal = try await makeTerminal(db)
        let router = makeRouter(db: db)
        let data = try JSONEncoder().encode(
            TerminalCompletionsParams(terminalID: terminal.id))

        let response = try await router.handleTerminalCompletions(data)

        #expect(!response.success)
        #expect(try #require(response.error).contains("transcript composer"))
    }

    @Test func theFlagOnServesTheInventory() async throws {
        let db = try TBDDatabase(inMemory: true)
        try await db.config.setTranscriptComposerEnabled(true)
        let terminal = try await makeTerminal(db)
        let router = makeRouter(db: db)
        let data = try JSONEncoder().encode(
            TerminalCompletionsParams(terminalID: terminal.id))

        let response = try await router.handleTerminalCompletions(data)

        #expect(response.success)
        let result = try JSONDecoder().decode(
            TerminalCompletionsResult.self, from: Data((response.result ?? "{}").utf8))
        #expect(result.commands.map(\.name) == ["compact"])
        #expect(result.source == .probe)
    }

    @Test func anUnknownTerminalIsAnError() async throws {
        let db = try TBDDatabase(inMemory: true)
        try await db.config.setTranscriptComposerEnabled(true)
        let router = makeRouter(db: db)
        let data = try JSONEncoder().encode(
            TerminalCompletionsParams(terminalID: UUID()))

        let response = try await router.handleTerminalCompletions(data)
        #expect(!response.success)
        #expect(try #require(response.error).contains("Terminal not found"))
    }

    /// Scope: Claude sessions only. Codex and shell terminals are out of scope
    /// for the composer entirely, and a probe against them is meaningless.
    @Test func aShellTerminalIsRefused() async throws {
        let db = try TBDDatabase(inMemory: true)
        try await db.config.setTranscriptComposerEnabled(true)
        let worktree = try await db.worktrees.createScratch(
            name: "wt", displayName: "wt",
            path: "/tmp/tbd-nonexistent-\(UUID().uuidString)", tmuxServer: "tbd-test")
        let shell = try await db.terminals.create(
            worktreeID: worktree.id, tmuxWindowID: "@2", tmuxPaneID: "%2", kind: .shell)
        let router = makeRouter(db: db)
        let data = try JSONEncoder().encode(TerminalCompletionsParams(terminalID: shell.id))

        let response = try await router.handleTerminalCompletions(data)
        #expect(!response.success)
        #expect(try #require(response.error).contains("Claude"))
    }

    /// The probe must run in the SESSION's environment, not the daemon's. The
    /// one variable that decides the answer as much as the binary does is
    /// `CLAUDE_CONFIG_DIR`, and it must name the same directory the spawn path
    /// would have given this terminal's profile — resolved through the injected
    /// manager, so nothing here can be satisfied by the daemon's own value.
    ///
    /// The free-form env overrides ride underneath it, in the spawn builder's
    /// own precedence: global < repo < profile, with the routing variable
    /// layered on top so an override cannot redirect the probe.
    @Test func theProbeRunsInTheSessionsEnvironment() async throws {
        let db = try TBDDatabase(inMemory: true)
        try await db.config.setTranscriptComposerEnabled(true)
        try await db.config.setEnvOverrides(["TBD_TEST_GLOBAL": "global", "TBD_TEST_SCOPE": "global"])

        let profile = try await db.modelProfiles.create(name: "p", kind: .oauth)
        try await db.modelProfiles.setEnvOverrides(
            id: profile.id, overrides: ["TBD_TEST_SCOPE": "profile"])
        let terminal = try await makeTerminal(db, profileID: profile.id)

        let manager = makeIsolatedConfigDirManager(tag: "completions-env")
        let recorder = EnvironmentRecorder()
        let router = makeRouter(
            db: db, configDirManager: manager,
            probe: { _, _, environment in
                await recorder.record(environment)
                return Self.stubOutcome
            })
        let data = try JSONEncoder().encode(
            TerminalCompletionsParams(terminalID: terminal.id))

        let response = try await router.handleTerminalCompletions(data)
        #expect(response.success)

        let expectedConfigDir = try #require(await manager.resolveConfigDir(
            for: ResolvedModelProfile(
                profileID: profile.id, name: "p", kind: .oauth, baseURL: nil, model: nil,
                secret: nil, awsRegion: nil, awsProfile: nil, fallbackModels: nil,
                envOverrides: [:])))
        let environment = try #require(await recorder.environment)
        #expect(environment["CLAUDE_CONFIG_DIR"] == expectedConfigDir)
        // Free-form overrides reach the probe, profile beating global.
        #expect(environment["TBD_TEST_GLOBAL"] == "global")
        #expect(environment["TBD_TEST_SCOPE"] == "profile")
        // A probe carries no credential of its own — an OAuth profile that has
        // none must not acquire one on the way through.
        // Compared against the daemon's own environment rather than nil: the
        // claim is that the handler adds no credential, not that the machine
        // running the suite has none exported.
        let daemonEnvironment = ProcessInfo.processInfo.environment
        #expect(environment["ANTHROPIC_API_KEY"] == daemonEnvironment["ANTHROPIC_API_KEY"])
        #expect(
            environment["CLAUDE_CODE_OAUTH_TOKEN"]
                == daemonEnvironment["CLAUDE_CODE_OAUTH_TOKEN"])
    }

    /// A profile's ROUTING env decides *which* Claude answers, so the probe must
    /// carry it or a Bedrock session gets probed in first-party mode and answers
    /// with a command list it does not have. The keys come from the spawn
    /// builder's own `routingEnv`, so the probe and the session cannot drift.
    ///
    /// The same helper is the reason no credential can ride along: it returns
    /// non-secret keys only, and the spawn builder assigns the secret itself.
    @Test func theProbeCarriesTheProfilesRoutingEnv() async throws {
        let db = try TBDDatabase(inMemory: true)
        try await db.config.setTranscriptComposerEnabled(true)

        let profile = try await db.modelProfiles.create(
            name: "bedrock", kind: .bedrock, model: "acme.claude-model",
            awsRegion: "us-west-2", awsProfile: "acme-prod")
        let terminal = try await makeTerminal(db, profileID: profile.id)

        let manager = makeIsolatedConfigDirManager(tag: "completions-routing")
        let recorder = EnvironmentRecorder()
        let router = makeRouter(
            db: db, configDirManager: manager,
            probe: { _, _, environment in
                await recorder.record(environment)
                return Self.stubOutcome
            })
        let data = try JSONEncoder().encode(
            TerminalCompletionsParams(terminalID: terminal.id))

        let response = try await router.handleTerminalCompletions(data)
        #expect(response.success)

        let environment = try #require(await recorder.environment)
        #expect(environment["CLAUDE_CODE_USE_BEDROCK"] == "1")
        #expect(environment["AWS_REGION"] == "us-west-2")
        #expect(environment["AWS_PROFILE"] == "acme-prod")
        #expect(environment["ANTHROPIC_MODEL"] == "acme.claude-model")
        // Bedrock keeps no isolated config dir, so probe and scan both read the
        // ambient store — the one its session runs against.
        #expect(environment["CLAUDE_CONFIG_DIR"] == manager.ambientConfigDirectory.path)
        // And still no credential: `routingEnv` returns none, and the handler
        // adds none. Compared against the daemon's own environment so an
        // exported key on the developer's box cannot redden the run spuriously.
        let daemonEnvironment = ProcessInfo.processInfo.environment
        #expect(environment["ANTHROPIC_API_KEY"] == daemonEnvironment["ANTHROPIC_API_KEY"])
        #expect(
            environment["CLAUDE_CODE_OAUTH_TOKEN"]
                == daemonEnvironment["CLAUDE_CODE_OAUTH_TOKEN"])
    }

    /// The gate is read PER REQUEST, not cached at router construction: one
    /// router, refused before the column is flipped and answering after. A
    /// daemon lives for days, so a toggle has to take effect without a restart.
    @Test func theFlagIsReadPerRequest() async throws {
        let db = try TBDDatabase(inMemory: true)
        let terminal = try await makeTerminal(db)
        let router = makeRouter(db: db)
        let data = try JSONEncoder().encode(
            TerminalCompletionsParams(terminalID: terminal.id))

        let refused = try await router.handleTerminalCompletions(data)
        #expect(!refused.success)

        try await db.config.setTranscriptComposerEnabled(true)

        let served = try await router.handleTerminalCompletions(data)
        #expect(served.success)
        let result = try JSONDecoder().decode(
            TerminalCompletionsResult.self, from: Data((served.result ?? "{}").utf8))
        #expect(result.commands.map(\.name) == ["compact"])
    }
}
