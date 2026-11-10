import Foundation
import GRDB
import Testing
import DaemonTestSupport
import TestSupport
@testable import TBDDaemonLib
@testable import TBDShared

extension TBDHomeSerialized {
@Suite("Mixed local agent archive and revive")
struct LocalAgentArchiveTests {
    func lifecycle(_ db: TBDDatabase, _ recorder: PreSessionRecordedCommands,
                   home: URL, failPreparation: Bool = false) -> WorktreeLifecycle {
        WorktreeLifecycle(db: db, git: GitManager(),
            tmux: TmuxManager(dryRun: true, dryRunRecorder: { recorder.append($0) }),
            hooks: HookResolver(), configDirManager: makeIsolatedConfigDirManager(tag: "archive"),
            preSessionTimeout: 2, preSessionPollInterval: 0.01,
            codexExecutableResolver: { "/usr/bin/true" },
            codexHomeEnsurer: {
                if failPreparation { throw CocoaError(.fileNoSuchFile) }
                return home.appendingPathComponent("codex")
            })
    }

    func seedSnapshot(_ db: TBDDatabase, id: UUID) async throws -> [ArchivedAgentTab] {
        let tabs = [
            ArchivedAgentTab(identity: .init(agentKind: .codex, sessionID: "codex-A"),
                label: "A", ordinal: 0, isPrimary: false,
                codexLaunchOptions: .init(model: "model-a", disabledFeatures: ["feature-a"])),
            ArchivedAgentTab(identity: .init(agentKind: .claude, sessionID: "claude-B"),
                label: "B", ordinal: 2, isPrimary: true,
                claudeSpawnExtras: .init(pluginDirs: ["/tmp/acme-plugin"])),
            ArchivedAgentTab(identity: .init(agentKind: .codex, sessionID: "codex-C"),
                label: "C", ordinal: 3, isPrimary: false,
                codexLaunchOptions: .init(model: "model-c", disabledFeatures: []))
        ]
        let json = String(decoding: try JSONEncoder().encode(tabs), as: UTF8.self)
        try await db.writerForTests.write { conn in
            try conn.execute(sql: "UPDATE worktree SET archived_agent_tabs = ?, archivedClaudeSessions = ? WHERE id = ?",
                arguments: [json, "[\"claude-B\"]", id.uuidString])
        }
        return tabs
    }

    @Test func archiveCapturesOrderActiveAndMetadataBeforeTeardown() async throws {
        let (home, cleanup) = isolateTBDHome(); defer { cleanup() }
        let (db, repoDir, wt, _) = try await makeWorktreeFixture(status: .active)
        defer { try? FileManager.default.removeItem(at: repoDir.deletingLastPathComponent()) }
        let recorder = PreSessionRecordedCommands()
        let lc = lifecycle(db, recorder, home: home)
        let options = CodexLaunchOptions(model: "model-a", disabledFeatures: ["feature-a"])
        let extras = ClaudeSpawnExtras(pluginDirs: ["/tmp/acme-plugin"])
        let b = try await db.terminals.create(worktreeID: wt.id, tmuxWindowID: "@1", tmuxPaneID: "%1",
            label: "B", claudeSessionID: "claude-B", kind: .claude, claudeSpawnExtras: extras)
        let a = try await db.terminals.create(worktreeID: wt.id, tmuxWindowID: "@2", tmuxPaneID: "%2",
            label: "A", claudeSessionID: "codex-A", kind: .codex, codexLaunchOptions: options)
        let shell = try await db.terminals.create(worktreeID: wt.id, tmuxWindowID: "@3", tmuxPaneID: "%3", label: "shell", kind: .shell)
        let c = try await db.terminals.create(worktreeID: wt.id, tmuxWindowID: "@4", tmuxPaneID: "%4",
            label: "C", claudeSessionID: "codex-C", kind: .codex)
        _ = try await db.terminals.create(worktreeID: wt.id, tmuxWindowID: "@5", tmuxPaneID: "%5",
            label: "D", claudeSessionID: "codex-D", kind: .codex)
        try await db.worktrees.setTabOrder(worktreeID: wt.id, tabIDs: [a.id, shell.id, b.id, c.id])
        try await db.worktrees.setActiveTabID(worktreeID: wt.id, tabID: b.id)
        _ = try await lc.beginArchiveWorktree(worktreeID: wt.id, force: true, discardUncommittedChanges: true)
        let archived = try #require(try await db.worktrees.get(id: wt.id))
        let tabs = try #require(archived.archivedAgentTabs)
        #expect(tabs.map(\.identity.sessionID) == ["codex-A", "claude-B", "codex-C", "codex-D"])
        #expect(tabs.map(\.ordinal) == [0, 2, 3, 4])
        #expect(tabs.map(\.isPrimary) == [false, true, false, false])
        #expect(tabs[0].codexLaunchOptions == options)
        #expect(tabs[1].claudeSpawnExtras == extras)
        #expect(archived.archivedClaudeSessions == ["claude-B"])
        #expect(archived.archivedClaudeSpawnExtras?["claude-B"] == extras)
    }

    @Test func snapshotWriteFailureLeavesLiveStateUntouched() async throws {
        let (home, cleanup) = isolateTBDHome(); defer { cleanup() }
        let (db, repoDir, wt, _) = try await makeWorktreeFixture(status: .active)
        defer { try? FileManager.default.removeItem(at: repoDir.deletingLastPathComponent()) }
        let recorder = PreSessionRecordedCommands()
        let lc = lifecycle(db, recorder, home: home)
        let terminal = try await db.terminals.create(worktreeID: wt.id, tmuxWindowID: "@1", tmuxPaneID: "%1",
            label: "Codex", claudeSessionID: "codex-A", kind: .codex)
        try await db.writerForTests.write { conn in
            try conn.execute(sql: "CREATE TRIGGER reject_snapshot BEFORE UPDATE OF archived_agent_tabs ON worktree WHEN NEW.archived_agent_tabs IS NOT NULL BEGIN SELECT RAISE(ABORT, 'snapshot refused'); END")
        }
        await #expect(throws: (any Error).self) {
            _ = try await lc.beginArchiveWorktree(worktreeID: wt.id, force: true, discardUncommittedChanges: true)
        }
        #expect(try await db.worktrees.get(id: wt.id)?.status == .active)
        #expect(try await db.worktrees.get(id: wt.id)?.branch == wt.branch)
        #expect(try await db.terminals.get(id: terminal.id) != nil)
        #expect(!recorder.snapshot().contains { $0.contains("kill-window") })
    }

    @Test(arguments: [false, true])
    func reviveRestoresMixedTabsAndClearsOnlyOnSuccess(preSession: Bool) async throws {
        let (home, cleanup) = isolateTBDHome(); defer { cleanup() }
        let (temp, repoDir) = try await createTestRepo()
        defer { try? FileManager.default.removeItem(at: temp) }
        if preSession { try await installPreSessionHook(repoDir: repoDir) }
        let db = try TBDDatabase(inMemory: true)
        let repo = try await makeTestRepo(db: db, tempDir: temp, repoDir: repoDir)
        let recorder = PreSessionRecordedCommands()
        let lc = lifecycle(db, recorder, home: home)
        let wt = try await lc.beginCreateWorktree(repoID: repo.id)
        try await db.worktrees.updateStatus(id: wt.id, status: .archived)
        try await shell("git branch '\(wt.branch)'", at: repoDir)
        let tabs = try await seedSnapshot(db, id: wt.id)
        let completion = try await lc.beginReviveWorktree(worktreeID: wt.id)
        if case .preSessionPending(_, let task) = completion {
            #expect(try await db.worktrees.get(id: wt.id)?.archivedAgentTabs == tabs)
            try writeMarker(worktreeID: wt.id, exitCode: 0)
            await task.value
        }
        let restored = try #require(try await db.worktrees.get(id: wt.id))
        let terminals = try await db.terminals.list(worktreeID: wt.id)
        let order = try await db.worktrees.getTabOrder(worktreeID: wt.id)
        let agents = order.compactMap { id in terminals.first { $0.id == id } }.filter { $0.claudeSessionID != nil }
        #expect(agents.map(\.claudeSessionID) == ["claude-B", "codex-A", "codex-C"])
        #expect(agents.map(\.label) == ["B", "A", "C"])
        #expect(try await db.worktrees.getActiveTabID(worktreeID: wt.id) == agents.first?.id)
        #expect(agents.first { $0.kind == .codex }?.codexLaunchOptions?.model == "model-a")
        #expect(restored.archivedAgentTabs == nil)
        #expect(restored.archivedClaudeSessions == nil)
        #expect(restored.archivedClaudeSpawnExtras == nil)
        let commands = recorder.snapshot().filter { $0.contains("new-window") }.compactMap(\.last)
        #expect(commands.contains { $0.contains("resume") && $0.contains("codex-A") && $0.contains("model-a") })
        #expect(commands.contains { $0.contains("resume") && $0.contains("codex-C") && $0.contains("model-c") })
    }
    @Test(arguments: [false, true])
    func recoveryUsesNewSnapshotAndRetainsItOnSpawnFailure(failSpawn: Bool) async throws {
        let (home, cleanup) = isolateTBDHome(); defer { cleanup() }
        let (db, repoDir, wt, _) = try await makeWorktreeFixture(status: .creating)
        defer { try? FileManager.default.removeItem(at: repoDir.deletingLastPathComponent()) }
        let recorder = PreSessionRecordedCommands()
        let lc = lifecycle(db, recorder, home: home)
        let tabs = try await seedSnapshot(db, id: wt.id)
        if failSpawn {
            try await db.worktrees.setArchivedAgentTabs(id: wt.id, tabs: tabs)
        } else {
            try await db.writerForTests.write { conn in
                // New snapshot alone must identify a revive after a restart.
                try conn.execute(sql: "UPDATE worktree SET archivedClaudeSessions = NULL WHERE id = ?", arguments: [wt.id.uuidString])
            }
        }
        _ = try await db.terminals.create(worktreeID: wt.id, tmuxWindowID: "@9", tmuxPaneID: "%9", label: "pre-session", kind: .shell)
        if failSpawn {
            try await db.writerForTests.write { conn in
                try conn.execute(sql: "CREATE TRIGGER reject_agent BEFORE INSERT ON terminal WHEN NEW.kind = 'codex' BEGIN SELECT RAISE(ABORT, 'spawn refused'); END")
            }
        }
        let tasks = await lc.recoverCreatingWorktrees()
        #expect(tasks.count == 1)
        try writeMarker(worktreeID: wt.id, exitCode: 0)
        for task in tasks { await task.value }
        let restored = try #require(try await db.worktrees.get(id: wt.id))
        #expect(restored.status == .active)
        if failSpawn {
            #expect(restored.archivedAgentTabs == tabs)
            #expect(restored.archivedClaudeSessions == ["claude-B"])
            #expect(restored.archivedClaudeSpawnExtras?["claude-B"] == tabs[1].claudeSpawnExtras)
        } else {
            #expect(restored.archivedAgentTabs == nil)
            let terminals = try await db.terminals.list(worktreeID: wt.id)
            #expect(Set(terminals.compactMap(\.claudeSessionID)) == ["codex-A", "claude-B", "codex-C"])
        }
    }

    @Test(arguments: ["corrupt", "missing-home", "shared-preparation"])
    func codexPreparationRefusesBeforeCheckoutMutation(failure: String) async throws {
        let (home, cleanup) = isolateTBDHome(); defer { cleanup() }
        let (temp, repoDir) = try await createTestRepo()
        defer { try? FileManager.default.removeItem(at: temp) }
        let db = try TBDDatabase(inMemory: true)
        let repo = try await makeTestRepo(db: db, tempDir: temp, repoDir: repoDir)
        let recorder = PreSessionRecordedCommands()
        let lc = lifecycle(db, recorder, home: home, failPreparation: true)
        let wt = try await lc.beginCreateWorktree(repoID: repo.id)
        try await db.worktrees.updateStatus(id: wt.id, status: .archived)
        try await shell("git branch '\(wt.branch)'", at: repoDir)
        if failure == "shared-preparation" {
            try await db.config.setPrimaryAgentPreference(.codex)
        } else {
            _ = try await seedSnapshot(db, id: wt.id)
            let raw = failure == "corrupt" ? "{bad-json" : String(decoding: try JSONEncoder().encode([
                ArchivedAgentTab(identity: .init(agentKind: .codex, sessionID: "codex-A"), ordinal: 0,
                    isPrimary: true, codexLaunchOptions: .init(model: nil, disabledFeatures: [], codexHome: home.appendingPathComponent("missing").path))
            ]), as: UTF8.self)
            try await db.writerForTests.write { conn in
                try conn.execute(sql: "UPDATE worktree SET archived_agent_tabs = ? WHERE id = ?", arguments: [raw, wt.id.uuidString])
            }
        }
        await #expect(throws: (any Error).self) { _ = try await lc.beginReviveWorktree(worktreeID: wt.id) }
        #expect(!FileManager.default.fileExists(atPath: wt.localPath))
        #expect(try await db.worktrees.get(id: wt.id)?.status == .archived)
        #expect(try await db.terminals.list(worktreeID: wt.id).isEmpty)
    }

    @Test(arguments: [false, true])
    func skipAgentRetainsBothSnapshotsWithoutPreparingCodex(preSession: Bool) async throws {
        let (home, cleanup) = isolateTBDHome(); defer { cleanup() }
        let (temp, repoDir) = try await createTestRepo()
        defer { try? FileManager.default.removeItem(at: temp) }
        if preSession { try await installPreSessionHook(repoDir: repoDir) }
        let db = try TBDDatabase(inMemory: true)
        let repo = try await makeTestRepo(db: db, tempDir: temp, repoDir: repoDir)
        let lc = lifecycle(db, PreSessionRecordedCommands(), home: home, failPreparation: true)
        let wt = try await lc.beginCreateWorktree(repoID: repo.id)
        try await db.worktrees.updateStatus(id: wt.id, status: .archived)
        try await shell("git branch '\(wt.branch)'", at: repoDir)
        let tabs = try await seedSnapshot(db, id: wt.id)
        try await db.worktrees.setArchivedAgentTabs(id: wt.id, tabs: tabs)
        let before = try #require(try await db.worktrees.get(id: wt.id))
        let completion = try await lc.beginReviveWorktree(worktreeID: wt.id, skipClaude: true)
        if case .preSessionPending(_, let task) = completion {
            try writeMarker(worktreeID: wt.id, exitCode: 0)
            await task.value
        }
        let restored = try #require(try await db.worktrees.get(id: wt.id))
        #expect(restored.archivedAgentTabs == tabs)
        #expect(restored.archivedClaudeSessions == before.archivedClaudeSessions)
        #expect(restored.archivedClaudeSpawnExtras == before.archivedClaudeSpawnExtras)
        #expect(try await db.terminals.list(worktreeID: wt.id).allSatisfy { $0.kind == .shell })
    }

    @Test(arguments: [false, true])
    func explicitEmptySnapshotOverridesLegacyAndAbsentSnapshotRestoresIt(explicitEmpty: Bool) async throws {
        let (home, cleanup) = isolateTBDHome(); defer { cleanup() }
        let (temp, repoDir) = try await createTestRepo()
        defer { try? FileManager.default.removeItem(at: temp) }
        let db = try TBDDatabase(inMemory: true)
        let repo = try await makeTestRepo(db: db, tempDir: temp, repoDir: repoDir)
        let lc = lifecycle(db, PreSessionRecordedCommands(), home: home)
        let wt = try await lc.beginCreateWorktree(repoID: repo.id)
        try await db.worktrees.updateStatus(id: wt.id, status: .archived)
        try await shell("git branch '\(wt.branch)'", at: repoDir)
        try await db.worktrees.setArchivedClaudeSessions(id: wt.id, sessions: ["legacy-A", "legacy-B"])
        if explicitEmpty {
            try await db.writerForTests.write { conn in
                try conn.execute(sql: "UPDATE worktree SET archived_agent_tabs = '[]' WHERE id = ?", arguments: [wt.id.uuidString])
            }
        }
        _ = try await lc.beginReviveWorktree(worktreeID: wt.id, preferredSessionID: "legacy-B")
        let sessions = try await db.terminals.list(worktreeID: wt.id).compactMap(\.claudeSessionID)
        if explicitEmpty {
            #expect(sessions.count == 1)
            #expect(!sessions.contains("legacy-A") && !sessions.contains("legacy-B"))
        } else {
            #expect(sessions == ["legacy-B", "legacy-A"])
        }
    }

    @Test func recoveryRejectsCorruptSnapshotWithoutStartingAFreshAgent() async throws {
        let (home, cleanup) = isolateTBDHome(); defer { cleanup() }
        let (db, repoDir, wt, _) = try await makeWorktreeFixture(status: .creating)
        defer { try? FileManager.default.removeItem(at: repoDir.deletingLastPathComponent()) }
        let recorder = PreSessionRecordedCommands()
        let lc = lifecycle(db, recorder, home: home)
        try await db.writerForTests.write { conn in
            try conn.execute(sql: "UPDATE worktree SET archived_agent_tabs = '{invalid' WHERE id = ?", arguments: [wt.id.uuidString])
        }
        _ = try await db.terminals.create(worktreeID: wt.id, tmuxWindowID: "@9", tmuxPaneID: "%9", label: "pre-session", kind: .shell)
        try writeMarker(worktreeID: wt.id, exitCode: 0)
        let tasks = await lc.recoverCreatingWorktrees()
        for task in tasks { await task.value }
        #expect(!recorder.snapshot().contains { $0.contains("new-window") })
        #expect(try await db.worktrees.get(id: wt.id)?.status == .creating)
    }

    @Test func eachCodexTabKeepsItsPreparedHomeAcrossHookWait() async throws {
        let (home, cleanup) = isolateTBDHome(); defer { cleanup() }
        let (temp, repoDir) = try await createTestRepo()
        defer { try? FileManager.default.removeItem(at: temp) }
        try await installPreSessionHook(repoDir: repoDir)
        let homes = ["one", "two"].map { home.appendingPathComponent($0).resolvingSymlinksInPath() }
        for directory in homes {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try #"{"hooks":{"PreToolUse":[{"hooks":[{"type":"command","command":"exit 2"}]}]}}"#
                .write(to: directory.appendingPathComponent("hooks.json"), atomically: true, encoding: .utf8)
            try "".write(to: directory.appendingPathComponent("config.toml"), atomically: true, encoding: .utf8)
        }
        let db = try TBDDatabase(inMemory: true)
        let repo = try await makeTestRepo(db: db, tempDir: temp, repoDir: repoDir)
        let recorder = PreSessionRecordedCommands()
        let preparations = PreSessionRecordedCommands()
        let lc = WorktreeLifecycle(db: db, git: GitManager(),
            tmux: TmuxManager(dryRun: true, dryRunRecorder: { recorder.append($0) }), hooks: HookResolver(),
            configDirManager: makeIsolatedConfigDirManager(tag: "prepared-archive"),
            preSessionTimeout: 2, preSessionPollInterval: 0.01,
            codexExecutableResolver: {
                preparations.append(["prepare"])
                if preparations.snapshot().count > 2 { throw CocoaError(.fileNoSuchFile) }
                return "/usr/bin/true"
            }, codexHomeEnsurer: { throw CocoaError(.fileNoSuchFile) })
        let wt = try await lc.beginCreateWorktree(repoID: repo.id)
        try await db.worktrees.updateStatus(id: wt.id, status: .archived)
        try await shell("git branch '\(wt.branch)'", at: repoDir)
        let tabs = homes.enumerated().map { index, directory in
            ArchivedAgentTab(identity: .init(agentKind: .codex, sessionID: "same-thread"), ordinal: index,
                isPrimary: index == 0, codexLaunchOptions: .init(model: "model-\(index)", disabledFeatures: [], codexHome: directory.path))
        }
        try await db.worktrees.setArchivedAgentTabs(id: wt.id, tabs: tabs)
        let completion = try await lc.beginReviveWorktree(worktreeID: wt.id)
        guard case .preSessionPending(_, let task) = completion else { Issue.record("expected hook wait"); return }
        #expect(preparations.snapshot().count == 2)
        try writeMarker(worktreeID: wt.id, exitCode: 0)
        await task.value
        #expect(preparations.snapshot().count == 2)
        let launches = recorder.snapshot().filter { $0.contains("new-window") && ($0.last?.contains("same-thread") ?? false) }
        #expect(launches.count == 2)
        for (index, launch) in launches.enumerated() {
            #expect(launch.contains("CODEX_HOME=\(homes[index].path)"))
            #expect(launch.contains("DISABLE_AUTO_UPDATE=true"))
            #expect(launch.last?.contains("model-\(index)") == true)
            #expect(launch.last?.contains(" -- '") == false)
        }
    }

    @Test func restoredClaudeTabsKeepSeparateProfilesAndNeverReceiveAnInitialPrompt() async throws {
        let (_, cleanup) = isolateTBDHome(); defer { cleanup() }
        let (db, repoDir, wt, repo) = try await makeWorktreeFixture(status: .active)
        defer { try? FileManager.default.removeItem(at: repoDir.deletingLastPathComponent()) }
        let first = try await db.modelProfiles.create(name: "first", kind: .oauth)
        let second = try await db.modelProfiles.create(name: "second", kind: .oauth)
        let recorder = PreSessionRecordedCommands()
        let lc = WorktreeLifecycle(db: db, git: GitManager(),
            tmux: TmuxManager(dryRun: true, dryRunRecorder: { recorder.append($0) }), hooks: HookResolver(),
            modelProfileResolver: ModelProfileResolver(profiles: db.modelProfiles, repos: db.repos, config: db.config),
            configDirManager: makeIsolatedConfigDirManager(tag: "archive-profiles"))
        let tabs = [
            ArchivedAgentTab(identity: .init(agentKind: .claude, sessionID: "first"), ordinal: 0,
                isPrimary: false, profileID: first.id),
            ArchivedAgentTab(identity: .init(agentKind: .claude, sessionID: "second"), ordinal: 1,
                isPrimary: true, profileID: second.id)
        ]
        _ = try await lc.spawnPrimaryTerminals(worktree: wt, repo: repo, skipClaude: false,
            archivedAgentTabs: tabs, initialPrompt: "do-not-send-on-resume", preSessionTerminalID: nil)
        let terminals = try await db.terminals.list(worktreeID: wt.id)
        #expect(terminals.first { $0.claudeSessionID == "first" }?.profileID == first.id)
        #expect(terminals.first { $0.claudeSessionID == "second" }?.profileID == second.id)
        #expect(!recorder.snapshot().contains { $0.last?.contains("do-not-send-on-resume") == true })
    }

    @Test func newArchiveDoesNotReconstructAgentsFromAnOldProjection() async throws {
        let (home, cleanup) = isolateTBDHome(); defer { cleanup() }
        let (db, repoDir, wt, _) = try await makeWorktreeFixture(status: .active)
        defer { try? FileManager.default.removeItem(at: repoDir.deletingLastPathComponent()) }
        try await db.worktrees.setArchivedClaudeSessions(id: wt.id, sessions: ["prior-session"])
        _ = try await db.terminals.create(worktreeID: wt.id, tmuxWindowID: "@1", tmuxPaneID: "%1",
            label: "shell", kind: .shell)
        let lc = lifecycle(db, PreSessionRecordedCommands(), home: home)
        _ = try await lc.beginArchiveWorktree(worktreeID: wt.id, force: true, discardUncommittedChanges: true)
        let archived = try #require(try await db.worktrees.get(id: wt.id))
        #expect(archived.archivedAgentTabs == [])
        #expect(archived.archivedClaudeSessions == nil)
    }

    @Test func duplicateArchiveRequestsPreserveBothSessionRepresentations() async throws {
        let (home, cleanup) = isolateTBDHome(); defer { cleanup() }
        let (db, repoDir, wt, _) = try await makeWorktreeFixture(status: .active)
        defer { try? FileManager.default.removeItem(at: repoDir.deletingLastPathComponent()) }
        let lc = lifecycle(db, PreSessionRecordedCommands(), home: home)
        let extras = ClaudeSpawnExtras(pluginDirs: ["/tmp/acme-plugin"])
        _ = try await db.terminals.create(worktreeID: wt.id, tmuxWindowID: "@1", tmuxPaneID: "%1",
            label: "Claude", claudeSessionID: "claude-B", kind: .claude, claudeSpawnExtras: extras)
        _ = try await db.terminals.create(worktreeID: wt.id, tmuxWindowID: "@2", tmuxPaneID: "%2",
            label: "Codex", claudeSessionID: "codex-A", kind: .codex,
            codexLaunchOptions: .init(model: "model-a", disabledFeatures: ["feature-a"]))
        _ = try await lc.beginArchiveWorktree(worktreeID: wt.id, force: true, discardUncommittedChanges: true)
        let first = try #require(try await db.worktrees.get(id: wt.id))
        #expect(first.archivedAgentTabs?.count == 2)
        #expect(try await db.terminals.list(worktreeID: wt.id).isEmpty)

        // The repeated lifecycle request sees no terminals after teardown.
        _ = try await lc.beginArchiveWorktree(worktreeID: wt.id, force: true, discardUncommittedChanges: true)
        let repeated = try #require(try await db.worktrees.get(id: wt.id))
        #expect(repeated.archivedAgentTabs == first.archivedAgentTabs)
        #expect(repeated.archivedClaudeSessions == ["claude-B"])
        #expect(repeated.archivedClaudeSpawnExtras == ["claude-B": extras])
        #expect(repeated.archivedAt == first.archivedAt)
    }

    @Test(arguments: [false, true])
    func staleArchiveTransitionCannotOverwriteTheCommittedSnapshot(legacyWriter: Bool) async throws {
        let (_, cleanup) = isolateTBDHome(); defer { cleanup() }
        let (db, repoDir, wt, _) = try await makeWorktreeFixture(status: .active)
        defer { try? FileManager.default.removeItem(at: repoDir.deletingLastPathComponent()) }
        let tabs = try await seedSnapshot(db, id: wt.id)
        try await db.worktrees.archive(id: wt.id, archivedHeadSHA: "original-head", agentTabs: tabs, branch: "original-branch")
        let first = try #require(try await db.worktrees.get(id: wt.id))

        // A second caller already read the active row before the first write
        // committed. Only the transaction's current status can arbitrate it.
        let removed = try await db.worktrees.archive(id: wt.id,
            claudeSessionIDs: ["stale-session"],
            claudeSpawnExtras: ["stale-session": .init(pluginDirs: ["/tmp/acme-stale"])],
            archivedHeadSHA: "stale-head", agentTabs: legacyWriter ? nil : [], branch: "stale-branch")
        #expect(removed.isEmpty)
        let repeated = try #require(try await db.worktrees.get(id: wt.id))
        #expect(repeated == first)
        #expect(repeated.archivedAgentTabs == tabs)
        #expect(repeated.archivedClaudeSessions == ["claude-B"])
        #expect(repeated.archivedClaudeSpawnExtras?["claude-B"] == tabs[1].claudeSpawnExtras)
    }

}
}
