import Foundation
import TestSupport
import Testing
@testable import TBDDaemonLib
@testable import TBDShared

// Tier 2: uses temporary Git repositories and filesystem-backed transcript and
// note content, while tmux stays in deterministic dry-run mode.
//
// Nested under TBDHomeSerialized because isolateTBDHome() mutates TBD_HOME.
extension TBDHomeSerialized {
@Suite("Worktree conversation carryover")
struct WorktreeConversationCarryoverTests {
    @Test func inlineCreateCarriesConversationIntoForkedClaudePrimary() async throws {
        let (_, cleanup) = isolateTBDHome()
        defer { cleanup() }
        let (tempDir, repoDir) = try await createTestRepo()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let db = try TBDDatabase(inMemory: true)
        try await db.config.setPrimaryAgentPreference(.codex)
        let recorder = PreSessionRecordedCommands()
        let claudeHome = tempDir.appendingPathComponent("claude-home", isDirectory: true)
        let lifecycle = makeCarryoverLifecycle(
            db: db, recorder: recorder, claudeHome: claudeHome
        )
        let repo = try await makeTestRepo(db: db, tempDir: tempDir, repoDir: repoDir)
        let pending = try await lifecycle.beginCreateWorktree(repoID: repo.id)

        let sourceSessionID = UUID().uuidString
        let notesSeed = "# Revived conversation\n\nSource session: `\(sourceSessionID)`\n"
        let carryover = ConversationCarryover(
            sourceSessionID: sourceSessionID,
            notesSeed: notesSeed
        )
        try writeSourceTranscript(
            sessionID: sourceSessionID, projectsRoot: claudeHome.appendingPathComponent("projects")
        )

        let completion = try await lifecycle.completeCreateWorktree(
            worktreeID: pending.id,
            primaryAgentPreference: .codex,
            carryover: carryover
        )
        guard case .ready = completion else {
            Issue.record("expected inline create to complete synchronously")
            return
        }

        try await assertCarriedConversation(
            db: db,
            recorder: recorder,
            worktree: pending,
            sourceSessionID: sourceSessionID,
            notesSeed: notesSeed,
            projectsRoot: claudeHome.appendingPathComponent("projects")
        )
    }

    @Test func preSessionCreateCarriesConversationAfterHookCompletes() async throws {
        let (_, cleanup) = isolateTBDHome()
        defer { cleanup() }
        let (tempDir, repoDir) = try await createTestRepo()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let db = try TBDDatabase(inMemory: true)
        try await db.config.setPrimaryAgentPreference(.codex)
        let recorder = PreSessionRecordedCommands()
        let claudeHome = tempDir.appendingPathComponent("claude-home", isDirectory: true)
        let lifecycle = makeCarryoverLifecycle(
            db: db, recorder: recorder, claudeHome: claudeHome
        )
        let repo = try await makeTestRepo(db: db, tempDir: tempDir, repoDir: repoDir)
        try await installPreSessionHook(repoDir: repoDir)
        let pending = try await lifecycle.beginCreateWorktree(repoID: repo.id)

        let sourceSessionID = UUID().uuidString
        let notesSeed = "# Revived conversation\n\nSource session: `\(sourceSessionID)`\n"
        let carryover = ConversationCarryover(
            sourceSessionID: sourceSessionID,
            notesSeed: notesSeed
        )
        try writeSourceTranscript(
            sessionID: sourceSessionID, projectsRoot: claudeHome.appendingPathComponent("projects")
        )

        let completion = try await lifecycle.completeCreateWorktree(
            worktreeID: pending.id,
            primaryAgentPreference: .codex,
            carryover: carryover
        )
        guard case .preSessionPending(let phase3) = completion else {
            Issue.record("expected pre-session create to return its phase-3 task")
            return
        }
        try writeMarker(worktreeID: pending.id, exitCode: 0)
        await phase3.value

        try await assertCarriedConversation(
            db: db,
            recorder: recorder,
            worktree: pending,
            sourceSessionID: sourceSessionID,
            notesSeed: notesSeed,
            projectsRoot: claudeHome.appendingPathComponent("projects")
        )
    }

    @Test func ordinaryCreateKeepsConfiguredPrimaryAndEmptyNotes() async throws {
        let (_, cleanup) = isolateTBDHome()
        defer { cleanup() }
        let (tempDir, repoDir) = try await createTestRepo()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let db = try TBDDatabase(inMemory: true)
        try await db.config.setPrimaryAgentPreference(.codex)
        let lifecycle = makeCarryoverLifecycle(
            db: db,
            recorder: PreSessionRecordedCommands(),
            claudeHome: tempDir.appendingPathComponent("claude-home", isDirectory: true)
        )
        let repo = try await makeTestRepo(db: db, tempDir: tempDir, repoDir: repoDir)
        let pending = try await lifecycle.beginCreateWorktree(repoID: repo.id)

        _ = try await lifecycle.completeCreateWorktree(
            worktreeID: pending.id,
            carryover: nil
        )

        let terminals = try await db.terminals.list(worktreeID: pending.id)
        #expect(terminals.filter { $0.kind == .codex }.count == 1)
        #expect(terminals.allSatisfy { $0.kind != .claude })
        let note = try #require(try await db.notes.list(worktreeID: pending.id).first)
        #expect(note.title == "Notes")
        #expect(note.content.isEmpty)
    }

    /// An ordinary archived-session resume never carried an initial prompt, and
    /// still must not — even when the caller supplies one. Guards the
    /// precedence in `spawnPrimaryTerminals`, which is the expression the
    /// carryover-prompt removal edited.
    @Test func archivedSessionResumeStillSendsNoInitialPrompt() async throws {
        let (_, cleanup) = isolateTBDHome()
        defer { cleanup() }
        let (tempDir, repoDir) = try await createTestRepo()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let db = try TBDDatabase(inMemory: true)
        let recorder = PreSessionRecordedCommands()
        let claudeHome = tempDir.appendingPathComponent("claude-home", isDirectory: true)
        let lifecycle = makeCarryoverLifecycle(
            db: db, recorder: recorder, claudeHome: claudeHome
        )
        let repo = try await makeTestRepo(db: db, tempDir: tempDir, repoDir: repoDir)
        let worktree = try await db.worktrees.create(
            repoID: repo.id,
            name: "resume-source",
            branch: "tbd/resume-source",
            path: tempDir.appendingPathComponent("resume-source").path,
            tmuxServer: "tbd-test"
        )

        _ = try await lifecycle.spawnPrimaryTerminals(
            worktree: worktree,
            repo: repo,
            skipClaude: false,
            archivedClaudeSessions: ["ARCHIVED-1"],
            initialPrompt: "caller prompt that a resume must ignore",
            preSessionTerminalID: nil
        )

        let command = try #require(
            recorder.snapshot()
                .filter { $0.contains("new-window") }
                .compactMap(\.last)
                .first { $0.contains("claude ") }
        )
        #expect(command.contains("--resume ARCHIVED-1"))
        #expect(!command.contains("--fork-session"))
        #expect(
            isPromptFreeResumeInvocation(command, forkSession: false),
            "archived-session resume must carry no trailing prompt argument: \(command)"
        )
    }

    /// The other side of the same expression: a fresh Claude create still
    /// delivers the caller's initial prompt as its trailing argument.
    @Test func freshClaudeCreateStillSendsItsInitialPrompt() async throws {
        let (_, cleanup) = isolateTBDHome()
        defer { cleanup() }
        let (tempDir, repoDir) = try await createTestRepo()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let db = try TBDDatabase(inMemory: true)
        try await db.config.setPrimaryAgentPreference(.claude)
        let recorder = PreSessionRecordedCommands()
        let lifecycle = makeCarryoverLifecycle(
            db: db,
            recorder: recorder,
            claudeHome: tempDir.appendingPathComponent("claude-home", isDirectory: true)
        )
        let repo = try await makeTestRepo(db: db, tempDir: tempDir, repoDir: repoDir)
        let pending = try await lifecycle.beginCreateWorktree(repoID: repo.id)

        _ = try await lifecycle.completeCreateWorktree(
            worktreeID: pending.id,
            initialPrompt: "do the thing",
            carryover: nil
        )

        let command = try #require(
            recorder.snapshot()
                .filter { $0.contains("new-window") }
                .compactMap(\.last)
                .first { $0.contains("claude ") }
        )
        #expect(command.contains("--session-id "))
        #expect(!command.contains("--resume "))
        #expect(command.hasSuffix(" 'do the thing'"))
    }

    /// Self-test for the guard below: it must actually reject a trailing
    /// prompt, or the two assertions above would pass vacuously.
    @Test func promptFreeGuardRejectsATrailingPromptArgument() {
        let base = "export CLAUDE_CONFIG_DIR='/tmp/cfg'; claude --resume ABC-123"
            + " --fork-session --dangerously-skip-permissions --settings '/tmp/overlay.json'"
        #expect(isPromptFreeResumeInvocation(base, forkSession: true))
        #expect(!isPromptFreeResumeInvocation(base + " 'You have been moved.'", forkSession: true))
        #expect(!isPromptFreeResumeInvocation(base + " 'anything at all'", forkSession: true))
    }

    /// Whitelists the permitted shape rather than blacklisting a phrase: the
    /// claude invocation may consist only of its resume/fork/permission flags
    /// plus the optional file-path flags. Any trailing positional argument —
    /// whatever its wording — falls outside the shape and fails.
    private func isPromptFreeResumeInvocation(
        _ command: String, forkSession: Bool
    ) -> Bool {
        guard let start = command.range(of: "claude --resume") else { return false }
        let invocation = String(command[start.lowerBound...])
        let fork = forkSession ? " --fork-session" : ""
        let permitted = "^claude --resume [-0-9A-Za-z]+\(fork) --dangerously-skip-permissions"
            + "( --settings '[^']*')?( --plugin-dir '[^']*')?$"
        return invocation.range(of: permitted, options: .regularExpression) != nil
    }

    private func makeCarryoverLifecycle(
        db: TBDDatabase,
        recorder: PreSessionRecordedCommands,
        claudeHome: URL
    ) -> WorktreeLifecycle {
        WorktreeLifecycle(
            db: db,
            git: GitManager(),
            tmux: TmuxManager(
                dryRun: true,
                dryRunRecorder: { recorder.append($0) }
            ),
            hooks: HookResolver(),
            configDirManager: ClaudeProfileConfigDirManager(
                baseDirectory: claudeHome.appendingPathComponent("profiles", isDirectory: true),
                hostBaseDirectory: claudeHome
            ),
            preSessionPollInterval: 0.05,
            codexExecutableResolver: { "/usr/bin/true" }
        )
    }

    private func writeSourceTranscript(sessionID: String, projectsRoot: URL) throws {
        let source = projectsRoot
            .appendingPathComponent("source-project", isDirectory: true)
            .appendingPathComponent("\(sessionID).jsonl")
        try FileManager.default.createDirectory(
            at: source.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try #"{"type":"user","message":{"content":"source conversation"}}"#
            .write(to: source, atomically: true, encoding: .utf8)
    }

    private func assertCarriedConversation(
        db: TBDDatabase,
        recorder: PreSessionRecordedCommands,
        worktree: Worktree,
        sourceSessionID: String,
        notesSeed: String,
        projectsRoot: URL
    ) async throws {
        let terminals = try await db.terminals.list(worktreeID: worktree.id)
        let claudeTerminals = terminals.filter { $0.kind == .claude }
        #expect(claudeTerminals.count == 1)
        let primary = try #require(claudeTerminals.first)
        #expect(primary.claudeSessionID == sourceSessionID)

        let claudeCommands = recorder.snapshot()
            .filter { $0.contains("new-window") }
            .compactMap(\.last)
            .filter { $0.contains("claude ") }
        #expect(claudeCommands.count == 1)
        let command = try #require(claudeCommands.first)
        #expect(command.contains("--resume \(sourceSessionID)"))
        #expect(command.contains("--fork-session"))
        // The revived session must open idle at the composer: no trailing
        // prompt argument, so Claude does not immediately start a turn.
        #expect(
            isPromptFreeResumeInvocation(command, forkSession: true),
            "carryover spawn must carry no trailing prompt argument: \(command)"
        )

        let destination = TranscriptProjectDirSync.derivedProjectDir(
            worktreePath: worktree.path,
            projectsRoot: projectsRoot
        ).appendingPathComponent("\(sourceSessionID).jsonl")
        #expect(FileManager.default.fileExists(atPath: destination.path))

        let note = try #require(try await db.notes.list(worktreeID: worktree.id).first)
        #expect(note.title == "Notes")
        #expect(note.content == notesSeed)
    }
}
}
