import Foundation
import GRDB
import TestSupport
import Testing
@testable import TBDDaemonLib
@testable import TBDShared

// Tier 2: uses temporary repositories and filesystem-backed transcript
// fixtures while tmux stays in deterministic dry-run mode.
//
// Nested under TBDHomeSerialized because the lifecycle's ambient Claude
// projects root is redirected through a temporary TBD_HOME fixture.
extension TBDHomeSerialized {
@Suite("Fresh-branch conversation revive")
struct WorktreeReviveFreshTests {
    private let operationDate = ISO8601DateFormatter()
        .date(from: "2026-07-27T15:00:00Z")!
    private let archiveDate = ISO8601DateFormatter()
        .date(from: "2026-06-01T12:00:00Z")!

    @Test func rejectsUnknownWorktree() async throws {
        let (_, cleanup) = isolateTBDHome()
        defer { cleanup() }
        let db = try TBDDatabase(inMemory: true)
        let lifecycle = makeReviveFreshLifecycle(db: db)
        let unknownID = UUID()

        do {
            _ = try await lifecycle.reviveConversationOnFreshBranch(
                archivedWorktreeID: unknownID,
                sessionID: "missing-session",
                date: operationDate
            )
            Issue.record("expected unknown worktree rejection")
        } catch let error as WorktreeLifecycleError {
            guard case .worktreeNotFound(let rejectedID) = error else {
                Issue.record("wrong WorktreeLifecycleError case: \(error)")
                return
            }
            #expect(rejectedID == unknownID)
        }
    }

    @Test func rejectsActiveWorktree() async throws {
        let (_, cleanup) = isolateTBDHome()
        defer { cleanup() }
        let (tempDir, repoDir) = try await createTestRepo()
        defer { try? FileManager.default.removeItem(at: tempDir) }
        let db = try TBDDatabase(inMemory: true)
        let lifecycle = makeReviveFreshLifecycle(db: db)
        let repo = try await makeTestRepo(db: db, tempDir: tempDir, repoDir: repoDir)
        let active = try await db.worktrees.create(
            repoID: repo.id,
            name: "active-source",
            branch: "tbd/active-source",
            path: tempDir.appendingPathComponent("active-source").path,
            tmuxServer: "tbd-test"
        )

        do {
            _ = try await lifecycle.reviveConversationOnFreshBranch(
                archivedWorktreeID: active.id,
                sessionID: "missing-session",
                date: operationDate
            )
            Issue.record("expected active worktree rejection")
        } catch let error as WorktreeLifecycleError {
            guard case .worktreeNotArchived(let rejectedID) = error else {
                Issue.record("wrong WorktreeLifecycleError case: \(error)")
                return
            }
            #expect(rejectedID == active.id)
        }
    }

    @Test func rejectsArchivedScratchWithoutRepository() async throws {
        let (_, cleanup) = isolateTBDHome()
        defer { cleanup() }
        let db = try TBDDatabase(inMemory: true)
        let lifecycle = makeReviveFreshLifecycle(db: db)
        let scratch = try await db.worktrees.createScratch(
            name: "archived-scratch",
            displayName: "Archived Scratch",
            path: FileManager.default.temporaryDirectory
                .appendingPathComponent("archived-scratch-\(UUID().uuidString)").path,
            tmuxServer: "tbd-scratch-test"
        )
        try await db.worktrees.archive(id: scratch.id)

        do {
            _ = try await lifecycle.reviveConversationOnFreshBranch(
                archivedWorktreeID: scratch.id,
                sessionID: "missing-session",
                date: operationDate
            )
            Issue.record("expected archived scratch rejection")
        } catch let error as WorktreeLifecycleError {
            guard case .invalidOperation(let message) = error else {
                Issue.record("wrong WorktreeLifecycleError case: \(error)")
                return
            }
            #expect(
                message
                    == "Cannot revive a conversation on a fresh branch without a repository."
            )
        }
    }

    @Test func missingTranscriptCreatesNoRowOrDirectory() async throws {
        let (_, cleanup) = isolateTBDHome()
        defer { cleanup() }
        let (tempDir, repoDir) = try await createTestRepo()
        defer { try? FileManager.default.removeItem(at: tempDir) }
        let db = try TBDDatabase(inMemory: true)
        let lifecycle = makeReviveFreshLifecycle(db: db)
        let repo = try await makeTestRepo(db: db, tempDir: tempDir, repoDir: repoDir)
        let archived = try await db.worktrees.create(
            repoID: repo.id,
            name: "archived-source",
            displayName: "Archived Source",
            branch: "tbd/archived-source",
            path: tempDir.appendingPathComponent("archived-source").path,
            tmuxServer: "tbd-test"
        )
        try await db.worktrees.archive(
            id: archived.id,
            claudeSessionIDs: ["missing-session"],
            archivedHeadSHA: "0123456789abcdef"
        )
        let rowsBefore = try await db.worktrees.list()
        let worktreeRoot = try #require(repo.worktreeRoot)
        let rootExistedBefore = FileManager.default.fileExists(atPath: worktreeRoot)

        do {
            _ = try await lifecycle.reviveConversationOnFreshBranch(
                archivedWorktreeID: archived.id,
                sessionID: "missing-session",
                date: operationDate
            )
            Issue.record("expected missing transcript rejection")
        } catch let error as WorktreeLifecycleError {
            guard case .invalidOperation(let message) = error else {
                Issue.record("wrong WorktreeLifecycleError case: \(error)")
                return
            }
            #expect(
                message
                    == "Cannot revive conversation: no transcript found for session missing-session."
            )
        }

        let rowsAfter = try await db.worktrees.list()
        #expect(rowsAfter == rowsBefore)
        #expect(FileManager.default.fileExists(atPath: worktreeRoot) == rootExistedBefore)
    }

    @Test func generatedNameCollisionFailsWithoutCreatingMisleadingFreshRevive() async throws {
        let (_, cleanup) = isolateTBDHome()
        defer { cleanup() }
        let (tempDir, repoDir) = try await createTestRepo()
        defer { try? FileManager.default.removeItem(at: tempDir) }
        let remoteDir = tempDir.appendingPathComponent("remote.git", isDirectory: true)
        try FileManager.default.createDirectory(at: remoteDir, withIntermediateDirectories: true)
        try await shell("git init --bare -b main", at: remoteDir)
        try await shell("git remote add origin '\(remoteDir.path)'", at: repoDir)
        try await shell("git push -u origin main", at: repoDir)
        _ = try installGeneratedBranchCollisionHook(repoDir: repoDir, rejections: 2)

        let db = try TBDDatabase(inMemory: true)
        let recorder = PreSessionRecordedCommands()
        let lifecycle = makeReviveFreshLifecycle(db: db, recorder: recorder)
        let repo = try await makeTestRepo(db: db, tempDir: tempDir, repoDir: repoDir)
        let archived = try await makeArchivedSource(
            db: db,
            repo: repo,
            tempDir: tempDir,
            sessions: ["A"],
            archivedHeadSHA: try await GitManager().headSHA(repoPath: repoDir.path)
        )
        try writeSourceTranscript(sessionID: "A")
        let rowsBefore = try await db.worktrees.list()

        await #expect(throws: WorktreeLifecycleError.self) {
            try await lifecycle.reviveConversationOnFreshBranch(
                archivedWorktreeID: archived.id,
                sessionID: "A",
                date: operationDate
            )
        }

        #expect(try await db.worktrees.list() == rowsBefore)
        #expect(try await db.notes.list().isEmpty)
        #expect(
            recorder.snapshot().flatMap { $0 }.contains {
                $0.contains("You have been moved to a fresh worktree.")
            } == false
        )
        let worktreeRoot = try #require(repo.worktreeRoot)
        let createdPaths = try FileManager.default.contentsOfDirectory(atPath: worktreeRoot)
        #expect(createdPaths.isEmpty)
    }

    @Test func ordinaryCreateStillRetriesGeneratedNameCollision() async throws {
        let (tempDir, repoDir) = try await createTestRepo()
        defer { try? FileManager.default.removeItem(at: tempDir) }
        let remoteDir = tempDir.appendingPathComponent("remote.git", isDirectory: true)
        try FileManager.default.createDirectory(at: remoteDir, withIntermediateDirectories: true)
        try await shell("git init --bare -b main", at: remoteDir)
        try await shell("git remote add origin '\(remoteDir.path)'", at: repoDir)
        try await shell("git push -u origin main", at: repoDir)
        let rejectionCount = try installGeneratedBranchCollisionHook(
            repoDir: repoDir,
            rejections: 2
        )

        let db = try TBDDatabase(inMemory: true)
        let lifecycle = makeReviveFreshLifecycle(db: db)
        let repo = try await makeTestRepo(db: db, tempDir: tempDir, repoDir: repoDir)

        let created = try await lifecycle.createWorktree(
            repoID: repo.id,
            skipClaude: true
        )

        #expect(created.status == .active)
        #expect(
            try String(contentsOf: rejectionCount, encoding: .utf8)
                .trimmingCharacters(in: .whitespacesAndNewlines) == "2"
        )
        let worktreeRoot = try #require(repo.worktreeRoot)
        #expect(try FileManager.default.contentsOfDirectory(atPath: worktreeRoot).count == 1)
    }

    @Test func successfulFetchCarriesOnlySelectedConversationAndSeedsProvenance() async throws {
        let (_, cleanup) = isolateTBDHome()
        defer { cleanup() }
        let (tempDir, repoDir) = try await createTestRepo()
        defer { try? FileManager.default.removeItem(at: tempDir) }
        let remoteDir = tempDir.appendingPathComponent("remote.git", isDirectory: true)
        try FileManager.default.createDirectory(at: remoteDir, withIntermediateDirectories: true)
        try await shell("git init --bare -b main", at: remoteDir)
        try await shell("git remote add origin '\(remoteDir.path)'", at: repoDir)
        try await shell("git push -u origin main", at: repoDir)
        let staleTrackingSHA = try await GitManager().headSHA(
            repoPath: repoDir.path, ref: "origin/main"
        )
        let advanceDir = tempDir.appendingPathComponent("remote-advance", isDirectory: true)
        try await shell("git clone '\(remoteDir.path)' '\(advanceDir.path)'", at: tempDir)
        try await shell(
            "GIT_AUTHOR_DATE=2026-07-20T12:00:00Z GIT_COMMITTER_DATE=2026-07-20T12:00:00Z git commit --allow-empty -m 'remote base'",
            at: advanceDir
        )
        try await shell("git push origin main", at: advanceDir)
        let remoteSHA = try await GitManager().headSHA(
            repoPath: advanceDir.path, ref: "HEAD"
        )
        let localSHA = try await GitManager().headSHA(repoPath: repoDir.path, ref: "main")
        #expect(staleTrackingSHA == localSHA)
        #expect(remoteSHA != staleTrackingSHA)
        #expect(
            try await GitManager().headSHA(repoPath: repoDir.path, ref: "origin/main")
                == staleTrackingSHA
        )

        let db = try TBDDatabase(inMemory: true)
        try await db.config.setPrimaryAgentPreference(.codex)
        let recorder = PreSessionRecordedCommands()
        let lifecycle = makeReviveFreshLifecycle(db: db, recorder: recorder)
        let repo = try await makeTestRepo(db: db, tempDir: tempDir, repoDir: repoDir)
        let archived = try await makeArchivedSource(
            db: db,
            repo: repo,
            tempDir: tempDir,
            sessions: ["A", "B"],
            archivedHeadSHA: localSHA
        )
        try writeSourceTranscript(sessionID: "A")
        let archivedBefore = try #require(try await db.worktrees.get(id: archived.id))

        let outcome = try await lifecycle.reviveConversationOnFreshBranch(
            archivedWorktreeID: archived.id,
            sessionID: "A",
            cols: 120,
            rows: 40,
            date: operationDate
        )
        guard case .ready = outcome.completion else {
            Issue.record("expected inline fresh revive to complete synchronously")
            return
        }

        let created = outcome.result.worktree
        #expect(outcome.result.warning == nil)
        #expect(created.status == .active)
        #expect(created.displayName == "stale-owl (revived)")
        #expect(created.branch == "tbd/\(created.name)")
        #expect(
            try await GitManager().headSHA(repoPath: created.path, ref: "HEAD")
                == remoteSHA
        )
        #expect(
            try await GitManager().headSHA(repoPath: repoDir.path, ref: "origin/main")
                == remoteSHA
        )

        let archivedAfter = try #require(try await db.worktrees.get(id: archived.id))
        #expect(archivedAfter == archivedBefore)
        #expect(archivedAfter.status == .archived)
        #expect(archivedAfter.branch == "tbd/stale-owl")
        #expect(archivedAfter.archivedHeadSHA == localSHA)
        #expect(archivedAfter.archivedClaudeSessions == ["A", "B"])

        let claudeTerminals = try await db.terminals.list(worktreeID: created.id)
            .filter { $0.kind == .claude }
        #expect(claudeTerminals.count == 1)
        #expect(claudeTerminals.first?.claudeSessionID == "A")

        let shortRemoteSHA = String(remoteSHA.prefix(7))
        let claudeCommand = try #require(
            recorder.snapshot()
                .filter { $0.contains("new-window") }
                .compactMap(\.last)
                .first { $0.contains("claude ") }
        )
        #expect(claudeCommand.contains("--resume A"))
        #expect(claudeCommand.contains("--fork-session"))
        #expect(claudeCommand.contains("branch tbd/stale-owl (archived 2026-06-01)"))
        #expect(claudeCommand.contains("You are now on \(created.branch)"))
        #expect(claudeCommand.contains("branched from origin/main (\(shortRemoteSHA))"))
        #expect(claudeCommand.contains("re-read any file before editing it"))

        let note = try #require(try await db.notes.list(worktreeID: created.id).first)
        #expect(note.title == "Notes")
        #expect(
            note.content == """
            # Revived conversation

            Forked from **stale-owl** on 2026-07-27.

            | | |
            | --- | --- |
            | Original branch | `tbd/stale-owl` @ `\(String(localSHA.prefix(7)))` (archived 2026-06-01) |
            | This branch | `\(created.branch)` |
            | Branched from | `origin/main` @ `\(shortRemoteSHA)` (2026-07-20) |
            | Source session | `A` |

            """
        )
    }

    @Test func fetchFailureCreatesFromLocalBaseAndReturnsStaleWarning() async throws {
        let (_, cleanup) = isolateTBDHome()
        defer { cleanup() }
        let (tempDir, repoDir) = try await createTestRepo()
        defer { try? FileManager.default.removeItem(at: tempDir) }
        try await shell(
            "GIT_AUTHOR_DATE=2026-07-20T12:00:00Z GIT_COMMITTER_DATE=2026-07-20T12:00:00Z git commit --allow-empty -m 'local base'",
            at: repoDir
        )
        let localSHA = try await GitManager().headSHA(repoPath: repoDir.path, ref: "main")

        let db = try TBDDatabase(inMemory: true)
        let lifecycle = makeReviveFreshLifecycle(db: db)
        let repo = try await makeTestRepo(db: db, tempDir: tempDir, repoDir: repoDir)
        let archived = try await makeArchivedSource(
            db: db,
            repo: repo,
            tempDir: tempDir,
            sessions: ["A"],
            archivedHeadSHA: "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
        )
        try writeSourceTranscript(sessionID: "A")

        let outcome = try await lifecycle.reviveConversationOnFreshBranch(
            archivedWorktreeID: archived.id,
            sessionID: "A",
            date: operationDate
        )
        guard case .ready = outcome.completion else {
            Issue.record("expected local fallback create to complete synchronously")
            return
        }

        #expect(
            try await GitManager().headSHA(
                repoPath: outcome.result.worktree.path, ref: "HEAD"
            ) == localSHA
        )
        let warning = try #require(outcome.result.warning)
        #expect(warning.contains("Worktree creation succeeded"))
        #expect(warning.contains("main"))
        #expect(warning.contains(String(localSHA.prefix(7))))
        #expect(warning.contains("2026-07-20"))
        #expect(warning.contains("7 days old"))
        #expect(warning.contains("may be stale"))
    }

    @Test func preSessionCompletionReturnsCreatingRowAndCarriesConversation() async throws {
        let (_, cleanup) = isolateTBDHome()
        defer { cleanup() }
        let (tempDir, repoDir) = try await createTestRepo()
        defer { try? FileManager.default.removeItem(at: tempDir) }
        try await installPreSessionHook(repoDir: repoDir)

        let db = try TBDDatabase(inMemory: true)
        let recorder = PreSessionRecordedCommands()
        let lifecycle = makeReviveFreshLifecycle(db: db, recorder: recorder)
        let repo = try await makeTestRepo(db: db, tempDir: tempDir, repoDir: repoDir)
        let archived = try await makeArchivedSource(
            db: db,
            repo: repo,
            tempDir: tempDir,
            sessions: ["A", "B"],
            archivedHeadSHA: try await GitManager().headSHA(repoPath: repoDir.path)
        )
        try writeSourceTranscript(sessionID: "A")

        let outcome = try await lifecycle.reviveConversationOnFreshBranch(
            archivedWorktreeID: archived.id,
            sessionID: "A",
            date: operationDate
        )
        guard case .preSessionPending(let phase3) = outcome.completion else {
            Issue.record("expected fresh revive to return pre-session phase 3")
            return
        }
        #expect(outcome.result.worktree.status == .creating)
        #expect(
            try await db.worktrees.get(id: outcome.result.worktree.id)
                == outcome.result.worktree
        )

        try writeMarker(worktreeID: outcome.result.worktree.id, exitCode: 0)
        await phase3.value
        let active = try #require(
            try await db.worktrees.get(id: outcome.result.worktree.id)
        )
        #expect(active.status == .active)
        let claudeTerminals = try await db.terminals.list(worktreeID: active.id)
            .filter { $0.kind == .claude }
        #expect(claudeTerminals.count == 1)
        #expect(claudeTerminals.first?.claudeSessionID == "A")
    }

    @Test func rpcReadyCompletionReturnsTypedResultAndBroadcastsOnce() async throws {
        let (_, cleanup) = isolateTBDHome()
        defer { cleanup() }
        let (tempDir, repoDir) = try await createTestRepo()
        defer { try? FileManager.default.removeItem(at: tempDir) }
        let db = try TBDDatabase(inMemory: true)
        let deltas = FreshReviveDeltas()
        let router = makeReviveFreshRouter(db: db, deltas: deltas)
        let repo = try await makeTestRepo(db: db, tempDir: tempDir, repoDir: repoDir)
        let archived = try await makeArchivedSource(
            db: db,
            repo: repo,
            tempDir: tempDir,
            sessions: ["A"],
            archivedHeadSHA: try await GitManager().headSHA(repoPath: repoDir.path)
        )
        try writeSourceTranscript(sessionID: "A")

        let response = await router.handle(try RPCRequest(
            method: RPCMethod.worktreeReviveConversationFresh,
            params: WorktreeReviveConversationFreshParams(
                archivedWorktreeID: archived.id,
                sessionID: "A"
            )
        ))

        #expect(response.success)
        let result = try response.decodeResult(WorktreeReviveConversationFreshResult.self)
        #expect(result.worktree.status == .active)
        #expect(result.warning != nil)
        #expect(deltas.createdCount(worktreeID: result.worktree.id) == 1)
    }

    @Test func rpcRejectsActiveScratchAsNotArchivedBeforeRepositoryValidation() async throws {
        let (_, cleanup) = isolateTBDHome()
        defer { cleanup() }
        let db = try TBDDatabase(inMemory: true)
        let router = makeReviveFreshRouter(db: db, deltas: FreshReviveDeltas())
        let scratch = try await db.worktrees.createScratch(
            name: "active-scratch",
            displayName: "Active Scratch",
            path: FileManager.default.temporaryDirectory
                .appendingPathComponent("active-scratch-\(UUID().uuidString)").path,
            tmuxServer: "tbd-scratch-test"
        )

        let response = await router.handle(try RPCRequest(
            method: RPCMethod.worktreeReviveConversationFresh,
            params: WorktreeReviveConversationFreshParams(
                archivedWorktreeID: scratch.id,
                sessionID: "missing-session"
            )
        ))

        #expect(!response.success)
        #expect(response.error == "Worktree is not archived: \(scratch.id)")
    }

    @Test func rpcPreSessionCompletionDoesNotDuplicateEarlyCreateBroadcast() async throws {
        let (_, cleanup) = isolateTBDHome()
        defer { cleanup() }
        let (tempDir, repoDir) = try await createTestRepo()
        defer { try? FileManager.default.removeItem(at: tempDir) }
        try await installPreSessionHook(repoDir: repoDir)
        let db = try TBDDatabase(inMemory: true)
        let deltas = FreshReviveDeltas()
        let router = makeReviveFreshRouter(db: db, deltas: deltas)
        let repo = try await makeTestRepo(db: db, tempDir: tempDir, repoDir: repoDir)
        let archived = try await makeArchivedSource(
            db: db,
            repo: repo,
            tempDir: tempDir,
            sessions: ["A"],
            archivedHeadSHA: try await GitManager().headSHA(repoPath: repoDir.path)
        )
        try writeSourceTranscript(sessionID: "A")

        let response = await router.handle(try RPCRequest(
            method: RPCMethod.worktreeReviveConversationFresh,
            params: WorktreeReviveConversationFreshParams(
                archivedWorktreeID: archived.id,
                sessionID: "A"
            )
        ))

        #expect(response.success)
        let result = try response.decodeResult(WorktreeReviveConversationFreshResult.self)
        #expect(result.worktree.status == .creating)
        #expect(deltas.createdCount(worktreeID: result.worktree.id) == 1)

        try writeMarker(worktreeID: result.worktree.id, exitCode: 0)
        let activated = try await waitUntil {
            try await db.worktrees.get(id: result.worktree.id)?.status == .active
        }
        #expect(activated)
        #expect(deltas.createdCount(worktreeID: result.worktree.id) == 1)
    }

    @Test func rpcPropagatesSerializedLifecycleError() async throws {
        let (_, cleanup) = isolateTBDHome()
        defer { cleanup() }
        let (tempDir, repoDir) = try await createTestRepo()
        defer { try? FileManager.default.removeItem(at: tempDir) }
        let db = try TBDDatabase(inMemory: true)
        let router = makeReviveFreshRouter(db: db, deltas: FreshReviveDeltas())
        let repo = try await makeTestRepo(db: db, tempDir: tempDir, repoDir: repoDir)
        let archived = try await makeArchivedSource(
            db: db,
            repo: repo,
            tempDir: tempDir,
            sessions: ["missing-session"],
            archivedHeadSHA: try await GitManager().headSHA(repoPath: repoDir.path)
        )
        let rowsBefore = try await db.worktrees.list()

        let response = await router.handle(try RPCRequest(
            method: RPCMethod.worktreeReviveConversationFresh,
            params: WorktreeReviveConversationFreshParams(
                archivedWorktreeID: archived.id,
                sessionID: "missing-session"
            )
        ))

        #expect(!response.success)
        #expect(
            response.error
                == "Cannot revive conversation: no transcript found for session missing-session."
        )
        #expect(try await db.worktrees.list() == rowsBefore)
    }

    /// Validation must consult the projects root the SPAWN will sync from —
    /// the resolved model profile's — not the ambient one. Checking ambient
    /// let a session that only exists there sail past validation and fail
    /// inside Claude with "No conversation found with session ID", leaving a
    /// fresh worktree with a blank agent behind.
    @Test func rejectsSessionMissingFromProfileResolvedProjectsRoot() async throws {
        let (home, cleanup) = isolateTBDHomeAndClaudeHost()
        defer { cleanup() }
        let (tempDir, repoDir) = try await createTestRepo()
        defer { try? FileManager.default.removeItem(at: tempDir) }
        let db = try TBDDatabase(inMemory: true)
        _ = try await seedDefaultOAuthProfile(db: db)
        let lifecycle = makeReviveFreshLifecycle(
            db: db,
            modelProfileResolver: ModelProfileResolver(
                profiles: db.modelProfiles, repos: db.repos, config: db.config
            )
        )
        let repo = try await makeTestRepo(db: db, tempDir: tempDir, repoDir: repoDir)
        let archived = try await makeArchivedSource(
            db: db,
            repo: repo,
            tempDir: tempDir,
            sessions: ["A"],
            archivedHeadSHA: try await GitManager().headSHA(repoPath: repoDir.path)
        )
        // Session A exists in the AMBIENT root only. The profile's mirrored
        // store — where the spawn looks — holds an unrelated session.
        try writeSourceTranscript(sessionID: "A")
        try writeHostStoreTranscript(home: home, slug: "-other-worktree", sessionID: "B")
        // Guard the fixture: the ambient root genuinely has A, so a rejection
        // can only come from consulting the profile root.
        #expect(
            TranscriptProjectDirSync.locateSessionTranscript(
                sessionID: "A", projectsRoot: ambientProjectsRoot()
            ) != nil
        )
        let rowsBefore = try await db.worktrees.list()

        do {
            _ = try await lifecycle.reviveConversationOnFreshBranch(
                archivedWorktreeID: archived.id,
                sessionID: "A",
                date: operationDate
            )
            Issue.record("expected profile-root transcript rejection")
        } catch let error as WorktreeLifecycleError {
            guard case .invalidOperation(let message) = error else {
                Issue.record("wrong WorktreeLifecycleError case: \(error)")
                return
            }
            #expect(
                message == "Cannot revive conversation: no transcript found for session A."
            )
        }

        #expect(try await db.worktrees.list() == rowsBefore)
    }

    /// The end-to-end shape of the shipped defect: the transcript lives in the
    /// host store, which the profile config dir reaches through a SYMLINKED
    /// `projects` slot. Validation must find it there and the spawn must
    /// mirror it into the new worktree's derived project dir.
    @Test func revivesSessionReachableOnlyThroughProfileProjectsSymlink() async throws {
        let (home, cleanup) = isolateTBDHomeAndClaudeHost()
        defer { cleanup() }
        let (tempDir, repoDir) = try await createTestRepo()
        defer { try? FileManager.default.removeItem(at: tempDir) }
        let db = try TBDDatabase(inMemory: true)
        let profileID = try await seedDefaultOAuthProfile(db: db)
        let recorder = PreSessionRecordedCommands()
        let lifecycle = makeReviveFreshLifecycle(
            db: db,
            recorder: recorder,
            modelProfileResolver: ModelProfileResolver(
                profiles: db.modelProfiles, repos: db.repos, config: db.config
            )
        )
        let repo = try await makeTestRepo(db: db, tempDir: tempDir, repoDir: repoDir)
        let archived = try await makeArchivedSource(
            db: db,
            repo: repo,
            tempDir: tempDir,
            sessions: ["A"],
            archivedHeadSHA: try await GitManager().headSHA(repoPath: repoDir.path)
        )
        // Only the host store has session A — nothing ambient.
        try writeHostStoreTranscript(home: home, slug: "-archived-slug", sessionID: "A")

        let outcome = try await lifecycle.reviveConversationOnFreshBranch(
            archivedWorktreeID: archived.id,
            sessionID: "A",
            date: operationDate
        )
        guard case .ready = outcome.completion else {
            Issue.record("expected inline fresh revive to complete synchronously")
            return
        }

        let profileRoot = home
            .appendingPathComponent("profiles/\(profileID.uuidString.lowercased())", isDirectory: true)
            .appendingPathComponent("claude/projects", isDirectory: true)
        #expect(
            (try? FileManager.default.destinationOfSymbolicLink(atPath: profileRoot.path)) != nil
        )
        let derived = TranscriptProjectDirSync.derivedProjectDir(
            worktreePath: outcome.result.worktree.path, projectsRoot: profileRoot)
        #expect(
            FileManager.default.fileExists(
                atPath: derived.appendingPathComponent("A.jsonl").path)
        )
        let claudeCommand = try #require(
            recorder.snapshot()
                .filter { $0.contains("new-window") }
                .compactMap(\.last)
                .first { $0.contains("claude ") }
        )
        #expect(claudeCommand.contains("--resume A"))
        #expect(claudeCommand.contains("--fork-session"))
    }

    /// `isolateTBDHome()` plus `TBD_CLAUDE_HOST_HOME`: the spawn (and now the
    /// validation) resolves the profile config dir through
    /// `ClaudeProfileConfigDirManager.resolveConfigDir`, which builds a DEFAULT
    /// manager — the env var is the only seam that keeps its mirrored
    /// `projects` slot off the developer's real `~/.claude`.
    private func isolateTBDHomeAndClaudeHost() -> (home: URL, cleanup: () -> Void) {
        let (home, cleanup) = isolateTBDHome()
        setenv("TBD_CLAUDE_HOST_HOME", home.appendingPathComponent("claude-host").path, 1)
        return (home, {
            unsetenv("TBD_CLAUDE_HOST_HOME")
            cleanup()
        })
    }

    private func seedDefaultOAuthProfile(db: TBDDatabase) async throws -> UUID {
        let profile = try await db.modelProfiles.create(name: "Revive Profile", kind: .oauth)
        try await db.config.setDefaultProfileID(profile.id)
        return profile.id
    }

    /// The root `makeReviveFreshLifecycle`'s injected config-dir manager falls
    /// back to when no profile resolves.
    private func ambientProjectsRoot() -> URL {
        TBDConstants.configDir
            .appendingPathComponent("claude-home/projects", isDirectory: true)
    }

    /// Writes a transcript into the host store that a profile config dir
    /// mirrors via its symlinked `projects` slot.
    private func writeHostStoreTranscript(home: URL, slug: String, sessionID: String) throws {
        let file = home
            .appendingPathComponent("claude-host/projects", isDirectory: true)
            .appendingPathComponent(slug, isDirectory: true)
            .appendingPathComponent("\(sessionID).jsonl")
        try FileManager.default.createDirectory(
            at: file.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try #"{"type":"user","message":{"content":"host store conversation"}}"#
            .write(to: file, atomically: true, encoding: .utf8)
    }

    private func makeReviveFreshLifecycle(
        db: TBDDatabase,
        recorder: PreSessionRecordedCommands? = nil,
        subscriptions: StateSubscriptionManager? = nil,
        modelProfileResolver: ModelProfileResolver? = nil
    ) -> WorktreeLifecycle {
        let claudeHome = TBDConstants.configDir
            .appendingPathComponent("claude-home", isDirectory: true)
        let dryRunRecorder: (@Sendable ([String]) -> Void)?
        if let recorder {
            dryRunRecorder = { arguments in recorder.append(arguments) }
        } else {
            dryRunRecorder = nil
        }
        let tmux = TmuxManager(
            dryRun: true,
            dryRunRecorder: dryRunRecorder
        )
        return WorktreeLifecycle(
            db: db,
            git: GitManager(),
            tmux: tmux,
            hooks: HookResolver(),
            subscriptions: subscriptions,
            modelProfileResolver: modelProfileResolver,
            configDirManager: ClaudeProfileConfigDirManager(
                baseDirectory: claudeHome.appendingPathComponent("profiles", isDirectory: true),
                hostBaseDirectory: claudeHome
            ),
            preSessionPollInterval: 0.05
        )
    }

    private func makeReviveFreshRouter(
        db: TBDDatabase,
        deltas: FreshReviveDeltas
    ) -> RPCRouter {
        let subscriptions = StateSubscriptionManager()
        subscriptions.addSubscriber { data in
            if let delta = try? JSONDecoder().decode(StateDelta.self, from: data) {
                deltas.append(delta)
            }
            return true
        }
        let lifecycle = makeReviveFreshLifecycle(
            db: db,
            subscriptions: subscriptions
        )
        return RPCRouter(
            db: db,
            lifecycle: lifecycle,
            tmux: lifecycle.tmux,
            subscriptions: subscriptions
        )
    }

    private func makeArchivedSource(
        db: TBDDatabase,
        repo: Repo,
        tempDir: URL,
        sessions: [String],
        archivedHeadSHA: String
    ) async throws -> Worktree {
        let source = try await db.worktrees.create(
            repoID: repo.id,
            name: "stale-owl",
            displayName: "stale-owl",
            branch: "tbd/stale-owl",
            path: tempDir.appendingPathComponent("stale-owl-\(UUID().uuidString)").path,
            tmuxServer: "tbd-test"
        )
        try await db.worktrees.archive(
            id: source.id,
            claudeSessionIDs: sessions,
            archivedHeadSHA: archivedHeadSHA
        )
        try await db.writerForTests.write { database in
            try database.execute(
                sql: "UPDATE worktree SET archivedAt = ? WHERE id = ?",
                arguments: [archiveDate, source.id.uuidString]
            )
        }
        return try #require(try await db.worktrees.get(id: source.id))
    }

    private func writeSourceTranscript(sessionID: String) throws {
        let source = TBDConstants.configDir
            .appendingPathComponent("claude-home/projects/source-project", isDirectory: true)
            .appendingPathComponent("\(sessionID).jsonl")
        try FileManager.default.createDirectory(
            at: source.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try #"{"type":"user","message":{"content":"source conversation"}}"#
            .write(to: source, atomically: true, encoding: .utf8)
    }

    private func installGeneratedBranchCollisionHook(
        repoDir: URL,
        rejections: Int
    ) throws -> URL {
        let hook = repoDir.appendingPathComponent(".git/hooks/reference-transaction")
        let rejectionCount = repoDir.appendingPathComponent(
            ".git/fresh-revive-test-rejection-count"
        )
        let script = """
        #!/bin/sh
        if [ "$1" = "prepared" ] && grep -q "refs/heads/tbd/"; then
            count=0
            if [ -f "\(rejectionCount.path)" ]; then
                count=$(cat "\(rejectionCount.path)")
            fi
            if [ "$count" -lt \(rejections) ]; then
                count=$((count + 1))
                echo "$count" > "\(rejectionCount.path)"
                exit 1
            fi
        fi
        exit 0
        """
        try script.write(to: hook, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: hook.path
        )
        return rejectionCount
    }

    private func waitUntil(
        timeout: TimeInterval = 10,
        _ condition: @Sendable () async throws -> Bool
    ) async throws -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if try await condition() {
                return true
            }
            try await Task.sleep(for: .milliseconds(50))
        }
        return try await condition()
    }
}
}

private final class FreshReviveDeltas: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [StateDelta] = []

    func append(_ delta: StateDelta) {
        lock.lock()
        defer { lock.unlock() }
        values.append(delta)
    }

    func createdCount(worktreeID: UUID) -> Int {
        lock.lock()
        defer { lock.unlock() }
        return values.filter {
            if case .worktreeCreated(let delta) = $0 {
                return delta.worktreeID == worktreeID
            }
            return false
        }.count
    }
}
