import Foundation
import Testing
import DaemonTestSupport
import TestSupport
@testable import TBDDaemonLib
import TBDShared

/// A replacement spawn's overlay is planned when its command is composed and
/// written only at launch (`ReplacementSpawnOverlay`), so a spawn that never
/// launches leaves the running process's overlay exactly as it was.
///
/// Nested under `TBDHomeSerialized`: the per-session overlay writes go through
/// the process-global `TBD_HOME`.
extension TBDHomeSerialized {
@Suite struct ReplacementSpawnOverlayTests {

    private struct Scratch {
        let home: URL
        let prior: String?
        init() {
            home = FileManager.default.temporaryDirectory
                .appendingPathComponent("tbd-replacement-overlay-\(UUID().uuidString)")
            prior = setTBDHome(home.path)
        }
        func cleanUp() {
            restoreTBDHome(prior)
            try? FileManager.default.removeItem(at: home)
        }
    }

    /// Fallback models make the overlay per-session, so the plan names this
    /// session's own file rather than the shared global one.
    private static let models = ["claude-haiku-4-5-20251001"]

    private func replacementOverlay(
        sessionKey: String, fallbackModels: [String]? = ReplacementSpawnOverlayTests.models
    ) -> ReplacementSpawnOverlay {
        ReplacementSpawnOverlay.plan(
            fallbackModels: fallbackModels,
            sessionKey: sessionKey,
            repoSettingsJSON: nil,
            extraSettingsJSON: nil)
    }

    /// Writes `bytes` where the session's per-session overlay lives, standing
    /// in for the overlay a running process was launched with.
    private func seedOverlay(sessionKey: String, _ bytes: Data) throws -> String {
        let path = ClaudeHookOverlay.perSessionOverlayPath(sessionKey: sessionKey)
        try FileManager.default.createDirectory(
            at: URL(fileURLWithPath: path).deletingLastPathComponent(),
            withIntermediateDirectories: true)
        try bytes.write(to: URL(fileURLWithPath: path))
        return path
    }

    private static let runningOverlay = Data(#"{"previous":"life"}"#.utf8)
    private static let command = "claude --resume s"

    private func commandNaming(_ path: String) -> String {
        "\(Self.command) --settings \(SystemPromptBuilder.shellEscape(path))"
    }

    // MARK: - Plan and settle

    /// Planning is what a spawn that never launches does — a wake that adopts
    /// a holder still running, a swap that fails before its replacement
    /// starts — so it must leave the running process's overlay as it is.
    @Test func planningWritesNothing() throws {
        let scratch = Scratch()
        defer { scratch.cleanUp() }
        let key = UUID().uuidString
        let overlayPath = try seedOverlay(sessionKey: key, Self.runningOverlay)

        let overlay = replacementOverlay(sessionKey: key)

        #expect(overlay.path == overlayPath)
        #expect(overlay.isPerSession)
        #expect(try Data(contentsOf: URL(fileURLWithPath: overlayPath)) == Self.runningOverlay)
    }

    /// The command is composed before `settle` writes the file, so the
    /// builder must be told the planned path will exist — otherwise a first
    /// launch would drop `--settings`, and with it every TBD hook.
    @Test func theCommandNamesThePlannedPathBeforeItExists() {
        let scratch = Scratch()
        defer { scratch.cleanUp() }
        let overlay = replacementOverlay(sessionKey: UUID().uuidString)
        #expect(!FileManager.default.fileExists(atPath: overlay.path))

        let spawn = ClaudeSpawnCommandBuilder.build(
            resumeID: "s", freshSessionID: nil, appendSystemPrompt: nil, initialPrompt: nil,
            profileSecret: nil, cmd: nil, shellFallback: "",
            settingsOverlayPath: overlay.path, fileExists: overlay.commandFileExists)

        #expect(spawn.command.contains(" --settings \(SystemPromptBuilder.shellEscape(overlay.path))"))
        // Anything else is still asked of the disk.
        #expect(!overlay.commandFileExists("/nonexistent/\(UUID().uuidString)"))
    }

    @Test func settlingASharedOverlayWritesNoPerSessionFile() throws {
        let scratch = Scratch()
        defer { scratch.cleanUp() }
        let key = UUID().uuidString
        let overlay = replacementOverlay(sessionKey: key, fallbackModels: nil)
        #expect(!overlay.isPerSession)
        #expect(overlay.path == ClaudeHookOverlay.overlayPath)

        #expect(overlay.settle(command: Self.command) == Self.command)

        #expect(!FileManager.default.fileExists(
            atPath: ClaudeHookOverlay.perSessionOverlayPath(sessionKey: key)))
    }

    @Test func aPerSessionOverlayIsWrittenAtLaunch() throws {
        let scratch = Scratch()
        defer { scratch.cleanUp() }
        let key = UUID().uuidString
        let overlay = replacementOverlay(sessionKey: key)
        #expect(overlay.isPerSession)
        #expect(!FileManager.default.fileExists(atPath: overlay.path))

        let command = commandNaming(overlay.path)
        #expect(overlay.settle(command: command) == command)

        #expect(try Data(contentsOf: URL(fileURLWithPath: overlay.path))
                == (try ClaudeHookOverlay.generateBody(fallbackModels: Self.models)))
    }

    /// When the per-session write fails at launch, `resolveOverlayPath` falls
    /// back to the global overlay, and the command must follow it rather than
    /// name a file that is missing or still holds an earlier process's overlay.
    @Test func aFailedWriteAtLaunchRepointsTheCommandAwayFromThePlannedFile() throws {
        let scratch = Scratch()
        defer { scratch.cleanUp() }
        let key = UUID().uuidString
        let overlay = replacementOverlay(sessionKey: key)
        // A directory where the file belongs: the atomic write cannot replace it.
        try FileManager.default.createDirectory(
            atPath: overlay.path, withIntermediateDirectories: true)
        let planned = " --settings \(SystemPromptBuilder.shellEscape(overlay.path))"

        let launched = overlay.settle(command: commandNaming(overlay.path))

        #expect(!launched.contains(planned), "the command still names the file that was not written")
        #expect(launched.hasPrefix(Self.command))
        if FileManager.default.fileExists(atPath: ClaudeHookOverlay.overlayPath) {
            #expect(launched.contains(
                " --settings \(SystemPromptBuilder.shellEscape(ClaudeHookOverlay.overlayPath))"))
        } else {
            #expect(!launched.contains("--settings"))
        }
    }

    @Test func repointingFollowsTheBuildersRuleForAMissingFile() {
        let from = "/runtime/claude-overlay-session-x.json"
        let to = "/runtime/claude-overlay.json"
        let command = "claude --settings \(SystemPromptBuilder.shellEscape(from)) --name n"

        #expect(ReplacementSpawnOverlay.repointSettings(
            in: command, from: from, to: to, fileExists: { _ in true })
            == "claude --settings \(SystemPromptBuilder.shellEscape(to)) --name n")
        #expect(ReplacementSpawnOverlay.repointSettings(
            in: command, from: from, to: to, fileExists: { _ in false })
            == "claude --name n")
    }

    // MARK: - A wake writes the overlay only when it launches

    private func isolatedConfigDirManager() -> ClaudeProfileConfigDirManager {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("tbd-replacement-overlay-claude-\(UUID().uuidString)", isDirectory: true)
        return ClaudeProfileConfigDirManager(
            baseDirectory: home.appendingPathComponent("profiles", isDirectory: true),
            hostBaseDirectory: home.appendingPathComponent("claude-host", isDirectory: true))
    }

    private static let repoFragment = #"{"skillOverrides":{"x":"off"}}"#

    /// A parked Claude terminal in a worktree whose path exists on disk (wake
    /// refuses to respawn into a missing directory), in a repo whose settings
    /// fragment makes every overlay it spawns per-session.
    private func parkedTerminal(
        _ scratch: Scratch, db: TBDDatabase, transport: TerminalTransport
    ) async throws -> Terminal {
        let repoPath = scratch.home.appendingPathComponent("repo", isDirectory: true).path
        try FileManager.default.createDirectory(atPath: repoPath, withIntermediateDirectories: true)
        let repo = try await db.repos.create(
            path: repoPath, displayName: "repo", defaultBranch: "main")
        let fragmentPath = TBDConstants.claudeSettingsOverlayPath(repoID: repo.id)
        try FileManager.default.createDirectory(
            at: URL(fileURLWithPath: fragmentPath).deletingLastPathComponent(),
            withIntermediateDirectories: true)
        try Data(Self.repoFragment.utf8).write(to: URL(fileURLWithPath: fragmentPath))
        let worktree = try await db.worktrees.create(
            repoID: repo.id, name: "wt", branch: "main", path: repoPath,
            tmuxServer: "tbd-replacement-overlay")
        let terminal = try await db.terminals.create(
            worktreeID: worktree.id, tmuxWindowID: "@0", tmuxPaneID: "%0",
            label: "claude", claudeSessionID: "sess-wake", kind: .claude,
            transport: transport)
        try await db.terminals.setHibernated(
            id: terminal.id, sessionID: "sess-wake", reason: .auto)
        return try #require(try await db.terminals.get(id: terminal.id))
    }

    private func wake(_ terminal: Terminal, db: TBDDatabase, _ scratch: Scratch) async throws -> WakeResult {
        let sessions = scratch.home.appendingPathComponent("sessions", isDirectory: true)
        try FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: true)
        let coordinator = HibernationCoordinator(
            db: db, tmux: TmuxManager(dryRun: true),
            configDirManager: isolatedConfigDirManager(), sessionsDir: sessions,
            sessionTitles: ClaudeSessionTitleStore(), actuationLog: makeTestActuationLog())
        return await coordinator.wake(terminalID: terminal.id)
    }

    @Test func aWakeThatLaunchesRewritesTheOverlay() async throws {
        let scratch = Scratch()
        defer { scratch.cleanUp() }
        let db = try TBDDatabase(inMemory: true)
        let terminal = try await parkedTerminal(scratch, db: db, transport: .tmux)
        let overlayPath = try seedOverlay(sessionKey: terminal.id.uuidString, Self.runningOverlay)

        #expect(try await wake(terminal, db: db, scratch).isOk)

        #expect(try Data(contentsOf: URL(fileURLWithPath: overlayPath))
                == (try ClaudeHookOverlay.generateBody(
                    extraSettings: ["skillOverrides": ["x": "off"]])),
                "a wake that launched did not write the overlay its command names")
    }

    /// A wake that adopts a holder still running returns from the same place
    /// this one does — before the launch, where the overlay is written — so the
    /// running process keeps the overlay it was spawned with. Staged as a
    /// holder row on a daemon with no holder registry, which refuses at that
    /// point without needing a live holder.
    @Test func aWakeThatLaunchesNothingLeavesTheOverlayAlone() async throws {
        let scratch = Scratch()
        defer { scratch.cleanUp() }
        let db = try TBDDatabase(inMemory: true)
        let terminal = try await parkedTerminal(scratch, db: db, transport: .holder)
        let overlayPath = try seedOverlay(sessionKey: terminal.id.uuidString, Self.runningOverlay)

        let result = try await wake(terminal, db: db, scratch)

        guard case .respawnFailed(let reason) = result else {
            Issue.record("expected the registry-less holder wake to refuse, got \(result)")
            return
        }
        #expect(reason.contains("holder registry"), "the wake refused somewhere else: \(reason)")
        #expect(try Data(contentsOf: URL(fileURLWithPath: overlayPath)) == Self.runningOverlay,
                "a wake that launched nothing rewrote the overlay")
    }
}
}
