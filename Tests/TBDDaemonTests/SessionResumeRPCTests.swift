import Foundation
import Testing
@testable import TBDDaemonLib
@testable import TBDShared
import DaemonTestSupport

@Suite("SessionResumeRPC")
struct SessionResumeRPCTests {
    private final class Commands: @unchecked Sendable {
        let lock = NSLock()
        var values: [[String]] = []
        func append(_ command: [String]) { lock.withLock { values.append(command) } }
        var snapshot: [[String]] { lock.withLock { values } }
    }

    private struct Fixture {
        let root: URL
        let db: TBDDatabase
        let router: RPCRouter
        let worktree: Worktree
        let commands: Commands
        let admission: StubAdmission
    }

    private func fixture() async throws -> Fixture {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("session-resume-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let db = try TBDDatabase(inMemory: true)
        let commands = Commands()
        let tmux = TmuxManager(dryRun: true, dryRunRecorder: { commands.append($0) })
        let manager = ClaudeProfileConfigDirManager(baseDirectory: root.appendingPathComponent("profiles"), hostBaseDirectory: root.appendingPathComponent("claude"))
        let lifecycle = WorktreeLifecycle(db: db, git: GitManager(), tmux: tmux, hooks: HookResolver(), configDirManager: manager)
        let router = RPCRouter(db: db, lifecycle: lifecycle, tmux: tmux,
            codexExecutableResolver: { "/usr/bin/true" }, codexHomeEnsurer: { root.appendingPathComponent("codex") },
            actuationLog: ActuationLog(path: root.appendingPathComponent("actuations.jsonl").path))
        let admission = StubAdmission(.admit)
        router.startAdmission = admission
        try await db.config.setStartAdmissionEnabled(true)
        let repo = try await db.repos.create(path: root.path, displayName: "acme", defaultBranch: "main")
        let worktree = try await db.worktrees.create(repoID: repo.id, name: "acme", branch: "main", path: root.path, tmuxServer: "resume-test")
        return Fixture(root: root, db: db, router: router, worktree: worktree, commands: commands, admission: admission)
    }

    private func request(_ f: Fixture, kind: LocalAgentKind, session: String = "same") throws -> RPCRequest {
        struct Params: Encodable {
            let worktreeID: UUID
            let identity: AgentSessionIdentity
            let cols = 132
            let rows = 41
        }
        return try RPCRequest(method: "session.resume", params: Params(worktreeID: f.worktree.id,
            identity: .init(agentKind: kind, sessionID: session)))
    }

    @Test("explicit Codex history selection requires catalog authority even inside the snapshot")
    func selectedReviveRequiresCodexCatalog() async throws {
        let f = try await fixture()
        defer { try? FileManager.default.removeItem(at: f.root) }
        try await f.db.worktrees.archive(id: f.worktree.id)
        let identity = AgentSessionIdentity(agentKind: .codex, sessionID: "selected")
        try await f.db.worktrees.setArchivedAgentTabs(id: f.worktree.id,
            tabs: [.init(identity: identity, ordinal: 0, isPrimary: true)])
        let response = await f.router.handle(try RPCRequest(method: RPCMethod.worktreeRevive,
            params: WorktreeReviveParams(worktreeID: f.worktree.id, preferredSession: identity)))
        #expect(!response.success)
        #expect(response.error?.contains("associated") == true)
        #expect(f.admission.requests.isEmpty)
    }

    @Test("selected catalog-only revive admits its provider before checkout mutation")
    func selectedReviveAdmission() async throws {
        let f = try await fixture()
        defer { try? FileManager.default.removeItem(at: f.root) }
        try await f.db.worktrees.archive(id: f.worktree.id)
        try await f.db.worktrees.setArchivedAgentTabs(id: f.worktree.id, tabs: [])
        let identity = AgentSessionIdentity(agentKind: .codex, sessionID: "selected")
        try await f.db.localAgentSessions.upsert(.init(worktreeID: f.worktree.id, identity: identity,
            firstObservedAt: .distantPast, lastObservedAt: .distantPast))
        f.admission.setVerdict(.hold(reason: "busy"))
        let response = await f.router.handle(try RPCRequest(method: RPCMethod.worktreeRevive,
            params: WorktreeReviveParams(worktreeID: f.worktree.id, preferredSession: identity)))
        #expect(!response.success)
        #expect(f.admission.requests.map(\.agent) == [.codex])
        #expect(try await f.db.worktrees.get(id: f.worktree.id)?.status == .archived)
        #expect(f.commands.snapshot.isEmpty)
    }

    @Test("provider resumes use native commands, admission, metadata and spawn records", arguments: [LocalAgentKind.claude, .codex])
    func resumes(kind: LocalAgentKind) async throws {
        let f = try await fixture()
        defer { try? FileManager.default.removeItem(at: f.root) }
        let options = CodexLaunchOptions(model: "acme-model", disabledFeatures: ["example_feature"])
        try await f.db.localAgentSessions.upsert(LocalAgentSession(worktreeID: f.worktree.id,
            identity: .init(agentKind: kind, sessionID: "same"), codexLaunchOptions: kind == .codex ? options : nil,
            firstObservedAt: Date(), lastObservedAt: Date()))
        let response = await f.router.handle(try request(f, kind: kind))
        #expect(response.success, "\(response.error ?? "")")
        guard response.success else { return }
        let terminal = try response.decodeResult(Terminal.self)
        #expect(terminal.kind?.rawValue == kind.rawValue)
        #expect(terminal.claudeSessionID == "same")
        #expect(try await f.db.terminals.list(worktreeID: f.worktree.id).map(\.id) == [terminal.id])
        #expect(f.admission.requests.map(\.agent.rawValue) == [kind.rawValue])
        let spawn = try #require(f.commands.snapshot.first { $0.contains("new-window") })
        let command = try #require(spawn.last)
        #expect(command.contains(kind == .codex ? "resume 'same'" : "--resume same"))
        #expect(spawn.contains("DISABLE_AUTO_UPDATE=true"))
        #expect(f.commands.snapshot.contains { $0.contains("132") && $0.contains("41") })
        if kind == .codex {
            #expect(terminal.codexLaunchOptions == options)
            #expect(command.contains("acme-model") && command.contains("example_feature"))
            #expect(!command.contains(" -- "))
        }
        let log = try String(contentsOf: f.root.appendingPathComponent("actuations.jsonl"), encoding: .utf8)
        #expect(log.contains("spawn") && log.contains("dispatched"))
    }

    @Test("uncataloged and foreign Codex identities refuse before admission or spawn", arguments: [false, true])
    func rejectsUnassociated(foreign: Bool) async throws {
        let f = try await fixture()
        defer { try? FileManager.default.removeItem(at: f.root) }
        if foreign {
            let other = try await f.db.worktrees.create(repoID: try #require(f.worktree.repoID), name: "other", branch: "other", path: f.root.appendingPathComponent("other").path, tmuxServer: "other")
            try await f.db.localAgentSessions.upsert(LocalAgentSession(worktreeID: other.id,
                identity: .init(agentKind: .codex, sessionID: "same"), firstObservedAt: Date(), lastObservedAt: Date()))
        }
        let response = await f.router.handle(try request(f, kind: .codex))
        #expect(!response.success)
        #expect(response.error?.contains("associated") == true)
        #expect(f.admission.requests.isEmpty)
        #expect(f.commands.snapshot.isEmpty)
        #expect(try await f.db.terminals.list(worktreeID: f.worktree.id).isEmpty)
    }

    @Test("provider admission holds create no terminal", arguments: [LocalAgentKind.claude, .codex])
    func admissionHolds(kind: LocalAgentKind) async throws {
        let f = try await fixture()
        defer { try? FileManager.default.removeItem(at: f.root) }
        try await f.db.localAgentSessions.upsert(LocalAgentSession(worktreeID: f.worktree.id,
            identity: .init(agentKind: kind, sessionID: "same"), firstObservedAt: Date(), lastObservedAt: Date()))
        f.admission.setVerdict(.hold(reason: "busy"))
        let response = await f.router.handle(try request(f, kind: kind))
        #expect(!response.success)
        #expect(f.admission.requests.map(\.agent.rawValue) == [kind.rawValue])
        #expect(f.commands.snapshot.isEmpty)
        #expect(try await f.db.terminals.list(worktreeID: f.worktree.id).isEmpty)
    }

    @Test("Codex dedicated home resumes strictly and retains options", arguments: ["valid", "missing", "malformed-options"])
    func strictHome(mode: String) async throws {
        let f = try await fixture()
        defer { try? FileManager.default.removeItem(at: f.root) }
        let home = f.root.appendingPathComponent("dedicated").resolvingSymlinksInPath()
        if mode == "valid" {
            try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
            try #"{"hooks":{"PreToolUse":[{"hooks":[{"type":"command","command":"true"}]}]}}"#
                .write(to: home.appendingPathComponent("hooks.json"), atomically: true, encoding: .utf8)
            try "".write(to: home.appendingPathComponent("config.toml"), atomically: true, encoding: .utf8)
        }
        let options = CodexLaunchOptions(model: "acme-model", disabledFeatures: ["example_feature"], codexHome: home.path)
        try await f.db.localAgentSessions.upsert(LocalAgentSession(worktreeID: f.worktree.id,
            identity: .init(agentKind: .codex, sessionID: "same"), codexLaunchOptions: options,
            firstObservedAt: Date(), lastObservedAt: Date()))
        if mode == "malformed-options" {
            try await f.db.writerForTests.write { db in
                try db.execute(sql: "UPDATE local_agent_session SET codex_launch_options = 'invalid'")
            }
        }
        let response = await f.router.handle(try request(f, kind: .codex))
        if mode == "valid" {
            #expect(response.success, "\(response.error ?? "")")
            guard response.success else { return }
            let terminal = try response.decodeResult(Terminal.self)
            #expect(terminal.codexLaunchOptions == options)
            let spawn = try #require(f.commands.snapshot.first { $0.contains("new-window") })
            #expect(spawn.contains("CODEX_HOME=\(home.path)"))
        } else {
            #expect(!response.success)
            #expect(f.admission.requests.isEmpty)
            #expect(f.commands.snapshot.isEmpty)
        }
    }

    @Test("Claude resumes retain the associated terminal's launch extras")
    func claudeLaunchExtras() async throws {
        let f = try await fixture()
        defer { try? FileManager.default.removeItem(at: f.root) }
        let plugin = f.root.appendingPathComponent("plugin")
        try FileManager.default.createDirectory(at: plugin, withIntermediateDirectories: true)
        let extras = ClaudeSpawnExtras(claudeSettingsOverlay: "{}", pluginDirs: [plugin.path])
        let source = try await f.db.terminals.create(worktreeID: f.worktree.id, tmuxWindowID: "@source",
            tmuxPaneID: "%source", claudeSessionID: "same", kind: .claude, claudeSpawnExtras: extras)
        try await f.db.localAgentSessions.upsert(LocalAgentSession(worktreeID: f.worktree.id, terminalID: source.id,
            identity: .init(agentKind: .claude, sessionID: "same"), firstObservedAt: Date(), lastObservedAt: Date()))
        let response = await f.router.handle(try request(f, kind: .claude))
        #expect(response.success, "\(response.error ?? "")")
        guard response.success else { return }
        #expect(try response.decodeResult(Terminal.self).claudeSpawnExtras == extras)
        #expect(f.commands.snapshot.contains { $0.last?.contains(plugin.path) == true })
    }

    @Test("legacy Claude resume does not require catalog adoption")
    func legacyClaude() async throws {
        let f = try await fixture()
        defer { try? FileManager.default.removeItem(at: f.root) }
        let response = await f.router.handle(try request(f, kind: .claude))
        #expect(response.success, "\(response.error ?? "")")
    }
}
