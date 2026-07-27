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
    private let contextPrompt =
        "You have been moved to a fresh worktree. Re-read files before editing."

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
            contextPrompt: contextPrompt,
            notesSeed: notesSeed
        )
        try writeSourceTranscript(
            sessionID: sourceSessionID, projectsRoot: claudeHome.appendingPathComponent("projects")
        )

        let completion = try await lifecycle.completeCreateWorktree(
            worktreeID: pending.id,
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
            contextPrompt: contextPrompt,
            notesSeed: notesSeed
        )
        try writeSourceTranscript(
            sessionID: sourceSessionID, projectsRoot: claudeHome.appendingPathComponent("projects")
        )

        let completion = try await lifecycle.completeCreateWorktree(
            worktreeID: pending.id,
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
            preSessionPollInterval: 0.05
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
        #expect(command.contains(contextPrompt))

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
