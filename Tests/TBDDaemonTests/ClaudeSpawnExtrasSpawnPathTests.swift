import Foundation
import Testing
import TestSupport
@testable import TBDDaemonLib
@testable import TBDShared

// Nested under TBDHomeSerialized: every test points the process-global
// `TBD_HOME` at its own scratch directory, so the per-session settings file a
// spawn writes under `~/tbd/runtime/` lands there and can be read back. See
// TBDHomeSerializedSuites.swift.
extension TBDHomeSerialized {
/// `terminal.create` and `worktree.create` with plugin folders and a settings
/// overlay: what they refuse, what they store on the new rows, and what
/// reaches the spawned command, fresh and resuming. Tier 2: an in-memory
/// database, a dry-run tmux and a real scratch directory (a real git repo for
/// `worktree.create`); nothing is spawned.
@Suite("terminal.create and worktree.create keep a Claude terminal's plugin folders and settings overlay")
struct ClaudeSpawnExtrasSpawnPathTests {
    /// Every tmux argv the dry-run manager would have run.
    final class TmuxRecorder: @unchecked Sendable {
        private let lock = NSLock()
        private var _calls: [[String]] = []
        func record(_ args: [String]) { lock.withLock { _calls.append(args) } }
        var calls: [[String]] { lock.withLock { _calls } }
        /// The shell command of each `new-window` call: its last argv element,
        /// the spawn command with only the inline exports in front of it.
        var newWindowCommands: [String] {
            calls.filter { $0.contains("new-window") }.compactMap(\.last)
        }
    }

    struct Fixture {
        let router: RPCRouter
        let db: TBDDatabase
        let recorder: TmuxRecorder
        let repo: Repo
        let repoDir: URL
        let worktree: Worktree
        let scratch: URL
        let actuationLogPath: String

        /// A real folder under this test's scratch directory, never under `~`.
        func makePluginDir(_ name: String) throws -> String {
            let url = scratch.appendingPathComponent("plugins/\(name)", isDirectory: true)
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            return url.path
        }

        func create(_ params: TerminalCreateParams) async throws -> RPCResponse {
            await router.handle(try RPCRequest(method: RPCMethod.terminalCreate, params: params))
        }

        func createWorktree(_ params: WorktreeCreateParams) async throws -> RPCResponse {
            await router.handle(try RPCRequest(method: RPCMethod.worktreeCreate, params: params))
        }

        /// Waits until the create's detached phases leave `.creating` — or
        /// remove the row, which a failed create does — and returns the row.
        func settledWorktree(_ id: UUID) async throws -> Worktree? {
            let outcome = await pollUntilTrue(
                timeout: TestDeadlines.saturatedPass, pollInterval: .milliseconds(50)
            ) {
                do {
                    guard let row = try await db.worktrees.get(id: id) else { return true }
                    return row.status != .creating
                } catch {
                    return false
                }
            }
            #expect(outcome == .satisfied, "the create never left .creating")
            return try await db.worktrees.get(id: id)
        }

        /// Waits until `condition` holds for this worktree's terminal rows.
        func waitForTerminals(
            _ worktreeID: UUID, _ condition: @escaping ([Terminal]) -> Bool
        ) async -> Bool {
            let outcome = await pollUntilTrue(
                timeout: TestDeadlines.saturatedPass, pollInterval: .milliseconds(50)
            ) {
                guard let terminals = try? await db.terminals.list(worktreeID: worktreeID) else {
                    return false
                }
                return condition(terminals)
            }
            return outcome == .satisfied
        }

        /// Every row the router appended to its actuation log, in order.
        func actuationRows() throws -> [[String: Any]] {
            guard let contents = try? String(contentsOfFile: actuationLogPath, encoding: .utf8) else {
                return []
            }
            return try contents
                .split(separator: "\n", omittingEmptySubsequences: true)
                .map { line in
                    try #require(
                        try JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any])
                }
        }

        /// The create wrote its request row and closed it as a not-eligible
        /// refusal carrying the error the caller got.
        func expectRefusedActuation(_ resp: RPCResponse) throws {
            let written = try actuationRows()
            #expect(written.count == 2)
            #expect(written.first?["method"] as? String == "terminal.create")
            let outcome = try #require(written.last)
            #expect(outcome["result"] as? String == "refused")
            #expect(outcome["reason"] as? String == "not-eligible")
            #expect(outcome["error"] as? String == resp.error)
        }
    }

    static let overlay = #"{"acmeSetting":"on"}"#

    /// TBD's own `--plugin-dir` flag, present only when its folder exists on
    /// this machine. Assertions about a terminal's extra folders strip it.
    static var ownPluginFlag: String {
        " --plugin-dir \(SystemPromptBuilder.shellEscape(PluginDirWriter.pluginDirPath))"
    }

    /// `gitRepo` makes the repo a real git repository, which `worktree.create`
    /// needs; its worktrees then land under the scratch directory too.
    private func withFixture(
        gitRepo: Bool = false, _ body: (Fixture) async throws -> Void
    ) async throws {
        let scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("tbd-spawn-extras-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        let priorTBDHome = setTBDHome(scratch.appendingPathComponent("home", isDirectory: true).path)
        defer {
            restoreTBDHome(priorTBDHome)
            try? FileManager.default.removeItem(at: scratch)
        }

        let actuationDirectory = scratch.appendingPathComponent("actuations", isDirectory: true)
        try FileManager.default.createDirectory(
            at: actuationDirectory, withIntermediateDirectories: true)
        let actuationLogPath = actuationDirectory.appendingPathComponent("actuations.jsonl").path

        let recorder = TmuxRecorder()
        let tmux = TmuxManager(dryRun: true, dryRunRecorder: { args in recorder.record(args) })
        let db = try TBDDatabase(inMemory: true)
        func configDirManager(_ tag: String) -> ClaudeProfileConfigDirManager {
            let base = scratch.appendingPathComponent("claude-\(tag)", isDirectory: true)
            return ClaudeProfileConfigDirManager(
                baseDirectory: base.appendingPathComponent("profiles", isDirectory: true),
                hostBaseDirectory: base.appendingPathComponent("claude-host", isDirectory: true))
        }
        let lifecycle = WorktreeLifecycle(
            db: db, git: GitManager(), tmux: tmux, hooks: HookResolver(),
            configDirManager: configDirManager("lifecycle"))
        let router = RPCRouter(
            db: db,
            lifecycle: lifecycle,
            tmux: tmux,
            startTime: Date(),
            usageFetcher: StubClaudeUsageFetcher(),
            configDirManager: configDirManager("router"),
            sessionsDir: scratch.appendingPathComponent("sessions", isDirectory: true),
            actuationLog: ActuationLog(path: actuationLogPath))

        let repoDir = scratch.appendingPathComponent("repo", isDirectory: true)
        let repo: Repo
        if gitRepo {
            try FileManager.default.createDirectory(at: repoDir, withIntermediateDirectories: true)
            try await shell("git init -b main && git commit --allow-empty -m 'init'", at: repoDir)
            repo = try await makeTestRepo(db: db, tempDir: scratch, repoDir: repoDir)
        } else {
            repo = try await db.repos.create(
                path: repoDir.path,
                displayName: "r",
                defaultBranch: "main")
        }
        // terminal.create refuses a worktree whose directory is missing.
        let worktreePath = scratch.appendingPathComponent("wt", isDirectory: true).path
        try FileManager.default.createDirectory(
            atPath: worktreePath, withIntermediateDirectories: true)
        let worktree = try await db.worktrees.create(
            repoID: repo.id, name: "wt", branch: "main",
            path: worktreePath, tmuxServer: "tbd-test")

        try await body(Fixture(
            router: router, db: db, recorder: recorder, repo: repo, repoDir: repoDir,
            worktree: worktree, scratch: scratch, actuationLogPath: actuationLogPath))
    }

    /// The per-session settings file a spawn wrote for `terminalID`, parsed.
    private func perSessionSettings(_ terminalID: UUID) throws -> [String: Any] {
        let path = ClaudeHookOverlay.perSessionOverlayPath(sessionKey: terminalID.uuidString)
        let data = try Data(contentsOf: URL(fileURLWithPath: path))
        return try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    // MARK: - Starts that take the values

    @Test func freshCreateStoresExtrasAndPassesPluginDir() async throws {
        try await withFixture { f in
            let plug = try f.makePluginDir("plug")
            let resp = try await f.create(TerminalCreateParams(
                worktreeID: f.worktree.id, type: .claude,
                claudeSettingsOverlay: Self.overlay, pluginDirs: [plug]))
            #expect(resp.success, "\(resp.error ?? "")")
            let terminal = try resp.decodeResult(Terminal.self)

            let expected = ClaudeSpawnExtras(claudeSettingsOverlay: Self.overlay, pluginDirs: [plug])
            #expect(terminal.claudeSpawnExtras == expected)
            #expect(try await f.db.terminals.get(id: terminal.id)?.claudeSpawnExtras == expected)

            let command = try #require(f.recorder.newWindowCommands.last)
            #expect(command.contains("claude --session-id"), "\(command)")
            let extraFlag = " --plugin-dir \(SystemPromptBuilder.shellEscape(plug))"
            #expect(command.contains(extraFlag), "\(command)")
            // TBD's own folder, when it is there, comes first.
            if let own = command.range(of: Self.ownPluginFlag),
               let extra = command.range(of: extraFlag) {
                #expect(own.lowerBound < extra.lowerBound, "\(command)")
            }

            // The overlay still reaches a fresh start's settings file.
            let settings = try perSessionSettings(terminal.id)
            #expect(settings["acmeSetting"] as? String == "on")
            #expect(settings["hooks"] != nil)
        }
    }

    @Test func resumeCreateAppliesPassedOverlay() async throws {
        try await withFixture { f in
            let sessionID = UUID().uuidString
            let resp = try await f.create(TerminalCreateParams(
                worktreeID: f.worktree.id, type: .claude, resumeSessionID: sessionID,
                claudeSettingsOverlay: Self.overlay))
            #expect(resp.success, "\(resp.error ?? "")")
            let terminal = try resp.decodeResult(Terminal.self)

            let expected = ClaudeSpawnExtras(claudeSettingsOverlay: Self.overlay)
            #expect(terminal.claudeSpawnExtras == expected)
            #expect(try await f.db.terminals.get(id: terminal.id)?.claudeSpawnExtras == expected)

            // The fragment is merged into the resumed session's own settings
            // file, beside TBD's hooks, and that file is what `--settings` names.
            let settings = try perSessionSettings(terminal.id)
            #expect(settings["acmeSetting"] as? String == "on")
            #expect(settings["hooks"] != nil)

            let command = try #require(f.recorder.newWindowCommands.last)
            #expect(command.contains("claude --resume \(sessionID)"), "\(command)")
            let path = ClaudeHookOverlay.perSessionOverlayPath(sessionKey: terminal.id.uuidString)
            #expect(command.contains(" --settings \(SystemPromptBuilder.shellEscape(path))"), "\(command)")
        }
    }

    @Test func resumeCreateWithNothingStoresNoExtras() async throws {
        try await withFixture { f in
            // An older row for the same session, carrying values of its own.
            let olderPlug = try f.makePluginDir("older-plug")
            let sessionID = UUID().uuidString
            _ = try await f.db.terminals.create(
                worktreeID: f.worktree.id, tmuxWindowID: "@90", tmuxPaneID: "%90",
                label: "claude", claudeSessionID: sessionID, kind: .claude,
                claudeSpawnExtras: ClaudeSpawnExtras(
                    claudeSettingsOverlay: Self.overlay, pluginDirs: [olderPlug]))

            let resp = try await f.create(TerminalCreateParams(
                worktreeID: f.worktree.id, type: .claude, resumeSessionID: sessionID))
            #expect(resp.success, "\(resp.error ?? "")")
            let terminal = try resp.decodeResult(Terminal.self)

            // Nothing passed means nothing stored: no copy from the older row.
            #expect(terminal.claudeSpawnExtras == nil)
            #expect(try await f.db.terminals.get(id: terminal.id)?.claudeSpawnExtras == nil)

            let command = try #require(f.recorder.newWindowCommands.last)
            #expect(command.contains("claude --resume \(sessionID)"), "\(command)")
            #expect(!command.contains(olderPlug), "\(command)")
            let withoutOwn = command.replacingOccurrences(of: Self.ownPluginFlag, with: "")
            #expect(!withoutOwn.contains("--plugin-dir"), "\(command)")
            // No overlay, no fallback models, no repo file: the shared settings
            // file, not a per-session one carrying the older row's fragment.
            #expect(!FileManager.default.fileExists(
                atPath: ClaudeHookOverlay.perSessionOverlayPath(sessionKey: terminal.id.uuidString)))
        }
    }

    // MARK: - Refusals

    @Test func relativePluginDirRefused() async throws {
        try await withFixture { f in
            let resp = try await f.create(TerminalCreateParams(
                worktreeID: f.worktree.id, type: .claude, pluginDirs: ["rel"]))
            #expect(!resp.success)
            #expect(resp.error == "plugin folder path must be absolute or start with ~/: rel")
            #expect(try await f.db.terminals.list(worktreeID: f.worktree.id).isEmpty)
            #expect(f.recorder.newWindowCommands.isEmpty)
            try f.expectRefusedActuation(resp)
        }
    }

    @Test func missingPluginDirRefused() async throws {
        try await withFixture { f in
            let present = try f.makePluginDir("present")
            let missing = f.scratch.appendingPathComponent("plugins/absent").path
            let resp = try await f.create(TerminalCreateParams(
                worktreeID: f.worktree.id, type: .claude, pluginDirs: [present, missing]))
            #expect(!resp.success)
            #expect(resp.error == "plugin folder does not exist: \(missing)")
            #expect(try await f.db.terminals.list(worktreeID: f.worktree.id).isEmpty)
            #expect(f.recorder.newWindowCommands.isEmpty)
            try f.expectRefusedActuation(resp)
        }
    }

    @Test(arguments: [TerminalCreateType.shell, .codex])
    func shellTerminalWithPluginDirsRefused(type: TerminalCreateType) async throws {
        try await withFixture { f in
            let plug = try f.makePluginDir("plug")
            let resp = try await f.create(TerminalCreateParams(
                worktreeID: f.worktree.id, type: type, pluginDirs: [plug]))
            #expect(!resp.success)
            #expect(resp.error == TerminalCreateParams.pluginDirsRequireClaudeMessage)
            #expect(resp.error == "pluginDirs require a Claude terminal")
            #expect(try await f.db.terminals.list(worktreeID: f.worktree.id).isEmpty)
            #expect(f.recorder.newWindowCommands.isEmpty)
            // Refused as a bad request, beside the model refusal, before any
            // actuation row is written.
            #expect(try f.actuationRows().isEmpty)
        }
    }

    // MARK: - Controls

    @Test func shellTerminalWithEmptyPluginDirsIsCreated() async throws {
        try await withFixture { f in
            let resp = try await f.create(TerminalCreateParams(
                worktreeID: f.worktree.id, type: .shell, pluginDirs: []))
            #expect(resp.success, "\(resp.error ?? "")")
            let terminal = try resp.decodeResult(Terminal.self)
            #expect(terminal.claudeSpawnExtras == nil)
            #expect(f.recorder.newWindowCommands.count == 1)
        }
    }

    @Test func createWithoutExtrasUnchanged() async throws {
        try await withFixture { f in
            let resp = try await f.create(TerminalCreateParams(
                worktreeID: f.worktree.id, type: .claude))
            #expect(resp.success, "\(resp.error ?? "")")
            let terminal = try resp.decodeResult(Terminal.self)

            #expect(terminal.claudeSpawnExtras == nil)
            #expect(try await f.db.terminals.get(id: terminal.id)?.claudeSpawnExtras == nil)

            let command = try #require(f.recorder.newWindowCommands.last)
            #expect(command.contains("claude --session-id"), "\(command)")
            let withoutOwn = command.replacingOccurrences(of: Self.ownPluginFlag, with: "")
            #expect(!withoutOwn.contains("--plugin-dir"), "\(command)")
            #expect(!command.contains("claude-overlay-session-"), "\(command)")
            #expect(!FileManager.default.fileExists(
                atPath: ClaudeHookOverlay.perSessionOverlayPath(sessionKey: terminal.id.uuidString)))
        }
    }

    // MARK: - worktree.create

    /// No pre-session hook: phase 2 spawns the primary inline, and it starts
    /// with the create's values and keeps them on its row.
    @Test func worktreeCreatePrimaryGetsExtras() async throws {
        try await withFixture(gitRepo: true) { f in
            let plug = try f.makePluginDir("plug")
            let resp = try await f.createWorktree(WorktreeCreateParams(
                repoID: f.repo.id, claudeSettingsOverlay: Self.overlay, pluginDirs: [plug]))
            #expect(resp.success, "\(resp.error ?? "")")
            let pending = try resp.decodeResult(Worktree.self)
            let settled = try #require(try await f.settledWorktree(pending.id))
            #expect(settled.status == .active)

            let terminals = try await f.db.terminals.list(worktreeID: pending.id)
            let primary = try #require(terminals.first { $0.kind == .claude })
            #expect(primary.claudeSpawnExtras
                == ClaudeSpawnExtras(claudeSettingsOverlay: Self.overlay, pluginDirs: [plug]))
            // The setup tab is a shell and keeps nothing.
            #expect(terminals.filter { $0.id != primary.id }.allSatisfy { $0.claudeSpawnExtras == nil })

            let command = try #require(
                f.recorder.newWindowCommands.first { $0.contains("claude --session-id") })
            let extraFlag = " --plugin-dir \(SystemPromptBuilder.shellEscape(plug))"
            #expect(command.contains(extraFlag), "\(command)")
            if let own = command.range(of: Self.ownPluginFlag),
               let extra = command.range(of: extraFlag) {
                #expect(own.lowerBound < extra.lowerBound, "\(command)")
            }

            let settings = try perSessionSettings(primary.id)
            #expect(settings["acmeSetting"] as? String == "on")
            #expect(settings["hooks"] != nil)
        }
    }

    /// A relative or missing folder is refused before phase 1, so nothing of
    /// the create exists: no worktree row, no git worktree, no branch, no
    /// actuation row, no tmux call.
    @Test func worktreeCreateRefusesBadPluginDirBeforeCreating() async throws {
        try await withFixture(gitRepo: true) { f in
            let missing = f.scratch.appendingPathComponent("plugins/absent").path
            let cases: [(pluginDirs: [String], error: String)] = [
                (["rel"], "plugin folder path must be absolute or start with ~/: rel"),
                ([missing], "plugin folder does not exist: \(missing)"),
            ]
            for refusal in cases {
                let resp = try await f.createWorktree(WorktreeCreateParams(
                    repoID: f.repo.id, folder: "refused", pluginDirs: refusal.pluginDirs))
                #expect(!resp.success)
                #expect(resp.error == refusal.error)
            }

            // The fixture's own worktree row is the only one in the repo.
            #expect(try await f.db.worktrees.list(repoID: f.repo.id).map(\.id) == [f.worktree.id])
            let git = GitManager()
            #expect(try await git.worktreeList(repoPath: f.repoDir.path).count == 1)
            #expect(try await git.localBranchExists(repoPath: f.repoDir.path, name: "tbd/refused") == false)
            #expect(try f.actuationRows().isEmpty)
            #expect(f.recorder.newWindowCommands.isEmpty)
            #expect(!f.recorder.calls.contains { $0.contains("new-session") })
        }
    }

    /// A Codex primary has no use for Claude values: no row stores them —
    /// neither the primary nor the setup tab, nor the pre-session hook's row
    /// when a hook gates the create — and no command carries the folder.
    @Test(arguments: [false, true])
    func codexPrimaryIgnoresExtras(withPreSessionHook: Bool) async throws {
        try await withFixture(gitRepo: true) { f in
            if withPreSessionHook {
                try await installPreSessionHook(repoDir: f.repoDir)
            }
            let plug = try f.makePluginDir("plug")
            let resp = try await f.createWorktree(WorktreeCreateParams(
                repoID: f.repo.id, primaryAgentPreference: .codex,
                claudeSettingsOverlay: Self.overlay, pluginDirs: [plug]))
            #expect(resp.success, "\(resp.error ?? "")")
            let pending = try resp.decodeResult(Worktree.self)

            if withPreSessionHook {
                let hookSpawned = await f.waitForTerminals(pending.id) { terminals in
                    terminals.contains { $0.label == TerminalLabel.preSession }
                }
                #expect(hookSpawned, "phase 2 must spawn the pre-session terminal")
                let hook = try #require(try await f.db.terminals.list(worktreeID: pending.id)
                    .first { $0.label == TerminalLabel.preSession })
                #expect(hook.claudeSpawnExtras == nil)
                // The spawn deleted any stale marker, so writing it now is safe.
                try writeMarker(worktreeID: pending.id, exitCode: 0)
            }

            let settled = try #require(try await f.settledWorktree(pending.id))
            #expect(settled.status == .active)
            let terminals = try await f.db.terminals.list(worktreeID: pending.id)
            #expect(terminals.contains { $0.kind == .codex })
            #expect(!terminals.contains { $0.kind == .claude })
            #expect(terminals.allSatisfy { $0.claudeSpawnExtras == nil })
            #expect(!f.recorder.newWindowCommands.contains { $0.contains(plug) })
        }
    }
}
}
