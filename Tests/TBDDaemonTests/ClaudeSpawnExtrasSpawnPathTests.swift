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
/// `terminal.create` with plugin folders and a settings overlay: what it
/// refuses, what it stores on the new row, and what reaches the spawned
/// command, fresh and resuming. Tier 2: an in-memory database, a dry-run tmux
/// and a real scratch directory; nothing is spawned.
@Suite("terminal.create keeps a Claude terminal's plugin folders and settings overlay")
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
        let worktree: Worktree
        let scratch: URL

        /// A real folder under this test's scratch directory, never under `~`.
        func makePluginDir(_ name: String) throws -> String {
            let url = scratch.appendingPathComponent("plugins/\(name)", isDirectory: true)
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            return url.path
        }

        func create(_ params: TerminalCreateParams) async throws -> RPCResponse {
            await router.handle(try RPCRequest(method: RPCMethod.terminalCreate, params: params))
        }
    }

    static let overlay = #"{"acmeSetting":"on"}"#

    /// TBD's own `--plugin-dir` flag, present only when its folder exists on
    /// this machine. Assertions about a terminal's extra folders strip it.
    static var ownPluginFlag: String {
        " --plugin-dir \(SystemPromptBuilder.shellEscape(PluginDirWriter.pluginDirPath))"
    }

    private func withFixture(_ body: (Fixture) async throws -> Void) async throws {
        let scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("tbd-spawn-extras-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        let priorTBDHome = setTBDHome(scratch.appendingPathComponent("home", isDirectory: true).path)
        defer {
            restoreTBDHome(priorTBDHome)
            try? FileManager.default.removeItem(at: scratch)
        }

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
            actuationLog: makeTestActuationLog())

        let repo = try await db.repos.create(
            path: scratch.appendingPathComponent("repo").path,
            displayName: "r",
            defaultBranch: "main")
        // terminal.create refuses a worktree whose directory is missing.
        let worktreePath = scratch.appendingPathComponent("wt", isDirectory: true).path
        try FileManager.default.createDirectory(
            atPath: worktreePath, withIntermediateDirectories: true)
        let worktree = try await db.worktrees.create(
            repoID: repo.id, name: "wt", branch: "main",
            path: worktreePath, tmuxServer: "tbd-test")

        try await body(Fixture(
            router: router, db: db, recorder: recorder, worktree: worktree, scratch: scratch))
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
        }
    }

    @Test(arguments: [TerminalCreateType.shell, .codex])
    func shellTerminalWithPluginDirsRefused(type: TerminalCreateType) async throws {
        try await withFixture { f in
            let plug = try f.makePluginDir("plug")
            let resp = try await f.create(TerminalCreateParams(
                worktreeID: f.worktree.id, type: type, pluginDirs: [plug]))
            #expect(!resp.success)
            #expect(resp.error == "pluginDirs require a Claude terminal")
            #expect(try await f.db.terminals.list(worktreeID: f.worktree.id).isEmpty)
            #expect(f.recorder.newWindowCommands.isEmpty)
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
}
}
