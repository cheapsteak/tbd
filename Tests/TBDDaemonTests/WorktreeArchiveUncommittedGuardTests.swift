import Foundation
import Testing
import DaemonTestSupport
import TestSupport
@testable import TBDDaemonLib
@testable import TBDShared

/// Tier 2 — real git repositories and worktrees in a temp directory, an
/// in-memory database, dry-run tmux, and a real actuation log beside them.
///
/// Archiving a local worktree deletes its folder, and a revive restores only
/// the branch, so `WorktreeLifecycle.beginArchiveWorktree` refuses a worktree
/// whose folder holds uncommitted changes, or whose `git status` it cannot
/// read, before it changes anything. The guard lives in the daemon so every
/// caller gets it: `worktree.archive` from the app and the CLI, and
/// auto-archive on merge. `force` lifts it and skips the archive hook;
/// `discardUncommittedChanges` lifts it alone; `repo.remove`'s cascade
/// bypasses it. One test per branch.
@Suite("worktree archive: the uncommitted-changes guard")
struct WorktreeArchiveUncommittedGuardTests {

    // MARK: - Fixture

    /// A real worktree of a throwaway repository, with a router and a merge
    /// coordinator built over the same lifecycle that created it.
    private struct Fixture {
        let tempDir: URL
        let db: TBDDatabase
        let lifecycle: WorktreeLifecycle
        let router: RPCRouter
        let actuationLog: ActuationLog
        let actuationLogPath: String
        let repo: Repo
        let worktree: Worktree

        var path: String { worktree.localPath }

        /// Where the archive hook `installArchiveHook` writes records that it
        /// ran: outside the worktree, so phase 2's deletion cannot take it.
        var hookMarkerPath: String { tempDir.appendingPathComponent("archive-hook-ran").path }

        func archive(force: Bool = false, discard: Bool? = nil) async throws -> RPCResponse {
            await router.handle(try RPCRequest(
                method: RPCMethod.worktreeArchive,
                params: WorktreeArchiveParams(
                    worktreeID: worktree.id, force: force, discardUncommittedChanges: discard),
                actor: .app))
        }

        func status() async throws -> WorktreeStatus? {
            try await db.worktrees.get(id: worktree.id)?.status
        }

        /// An untracked file that is not ignored.
        func writeUntracked(_ name: String, _ contents: String = "draft\n") throws {
            try contents.write(
                toFile: (path as NSString).appendingPathComponent(name),
                atomically: true, encoding: .utf8)
        }

        /// Commits `tracked.txt`, so a later write to it is a tracked edit.
        /// The fixture repository's only commit is empty.
        func commitTrackedFile() async throws {
            try await shell(
                "echo base > tracked.txt && git add tracked.txt && "
                    + "git -c user.email=t@example.com -c user.name=t commit -qm base",
                at: URL(fileURLWithPath: path))
        }

        /// An executable `.worktree-hooks/archive` that records it ran. The
        /// hook file is itself untracked, so installing it leaves the
        /// worktree dirty.
        func installArchiveHook() throws {
            let hooksDir = (path as NSString).appendingPathComponent(".worktree-hooks")
            try FileManager.default.createDirectory(
                atPath: hooksDir, withIntermediateDirectories: true)
            let hook = (hooksDir as NSString).appendingPathComponent("archive")
            try "#!/bin/sh\necho ran > '\(hookMarkerPath)'\n"
                .write(toFile: hook, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o755], ofItemAtPath: hook)
        }

        func coordinator() -> AutoArchiveOnMergeCoordinator {
            AutoArchiveOnMergeCoordinator(
                db: db, lifecycle: lifecycle, subscriptions: StateSubscriptionManager(),
                actuationLog: actuationLog)
        }

        /// Every actuation row written so far, decoded.
        func actuationRows() throws -> [[String: Any]] {
            guard let contents = try? String(contentsOfFile: actuationLogPath, encoding: .utf8)
            else { return [] }
            return try contents
                .split(separator: "\n", omittingEmptySubsequences: true)
                .map { line in
                    try #require(
                        try JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any])
                }
        }

        func cleanUp() {
            try? FileManager.default.removeItem(at: tempDir)
        }
    }

    /// `beforeWorktree` runs once the repository exists and before the
    /// worktree is created from its `main`, so what it commits there is on
    /// the branch the worktree starts from.
    private static func makeFixture(
        beforeWorktree: (_ tempDir: URL, _ repoDir: URL) async throws -> Void = { _, _ in }
    ) async throws -> Fixture {
        let (tempDir, repoDir) = try await createTestRepo()
        try await beforeWorktree(tempDir, repoDir)
        let db = try TBDDatabase(inMemory: true)
        // A global hooks directory that does not exist, so the only archive
        // hook that can resolve is one a test installs in the worktree.
        let lifecycle = WorktreeLifecycle(
            db: db, git: GitManager(), tmux: TmuxManager(dryRun: true),
            hooks: HookResolver(
                globalHooksDir: tempDir.appendingPathComponent("no-global-hooks").path))
        let repo = try await makeTestRepo(db: db, tempDir: tempDir, repoDir: repoDir)
        let worktree = try await lifecycle.createWorktree(repoID: repo.id, skipClaude: true)
        let actuationLogPath = tempDir
            .appendingPathComponent("actuations", isDirectory: true)
            .appendingPathComponent("actuations.jsonl").path
        let actuationLog = ActuationLog(path: actuationLogPath)
        let router = RPCRouter(
            db: db, lifecycle: lifecycle, tmux: TmuxManager(dryRun: true),
            subscriptions: StateSubscriptionManager(), actuationLog: actuationLog)
        return Fixture(
            tempDir: tempDir, db: db, lifecycle: lifecycle, router: router,
            actuationLog: actuationLog, actuationLogPath: actuationLogPath,
            repo: repo, worktree: worktree)
    }

    /// Phase 2 runs in a detached task, so an archive is finished once the
    /// folder has left its slot. Throws rather than recording, so a timeout
    /// stops the test at its cause and its message reaches the CI summary.
    private func waitForFolderGone(_ path: String) async throws {
        switch await pollUntilTrue(
            timeout: TestDeadlines.saturatedPass, { !FileManager.default.fileExists(atPath: path) }
        ) {
        case .satisfied: return
        case .cancelled: throw CancellationError()
        case .timedOut: throw FolderStillPresent(path: path, after: TestDeadlines.saturatedPass)
        }
    }

    /// Expects the refusal record — the request row, confirmed `refused`
    /// with the reason `not-eligible` — and returns the sentence the outcome
    /// carries, for the caller to compare with what it was told.
    @discardableResult
    private func expectRefusalRecorded(
        _ fixture: Fixture, sourceLocation: SourceLocation = #_sourceLocation
    ) throws -> String? {
        let rows = try fixture.actuationRows()
        try #require(
            rows.count == 2, "a refusal writes its request row and one outcome, got \(rows.count)",
            sourceLocation: sourceLocation)
        #expect(rows[1]["confirms"] as? String == rows[0]["id"] as? String,
                sourceLocation: sourceLocation)
        #expect(rows[1]["result"] as? String == "refused", sourceLocation: sourceLocation)
        #expect(rows[1]["reason"] as? String == "not-eligible", sourceLocation: sourceLocation)
        return rows[1]["error"] as? String
    }

    // MARK: - worktree.archive

    @Test func anUntrackedFileRefusesTheArchiveAndKeepsEverything() async throws {
        let f = try await Self.makeFixture()
        defer { f.cleanUp() }
        try f.writeUntracked("notes.md", "half a thought\n")

        let response = try await f.archive()

        #expect(!response.success)
        #expect(response.errorCode == RPCErrorCode.worktreeArchiveUncommitted.rawValue)
        #expect(response.error?.contains("notes.md") == true,
                "the refusal did not name the file: \(response.error ?? "no error")")
        #expect(response.error?.contains("1 uncommitted change(s)") == true)
        #expect(response.error?.contains("--force") == false,
                "the daemon's sentence names no surface's remedy")
        #expect(try await f.status() == .active)
        let notes = (f.path as NSString).appendingPathComponent("notes.md")
        #expect(try String(contentsOfFile: notes, encoding: .utf8) == "half a thought\n")
        #expect(try await f.db.terminals.list(worktreeID: f.worktree.id).isEmpty == false,
                "a refused archive must not have torn the worktree's terminals down")
        let rows = try f.actuationRows()
        #expect(rows.first?["method"] as? String == RPCMethod.worktreeArchive)
        #expect(try expectRefusalRecorded(f) == response.error)
    }

    @Test func aTrackedEditAloneRefusesTheArchive() async throws {
        let f = try await Self.makeFixture()
        defer { f.cleanUp() }
        try await f.commitTrackedFile()
        let tracked = (f.path as NSString).appendingPathComponent("tracked.txt")
        try "edited\n".write(toFile: tracked, atomically: true, encoding: .utf8)

        let response = try await f.archive()

        #expect(!response.success)
        #expect(response.errorCode == RPCErrorCode.worktreeArchiveUncommitted.rawValue)
        #expect(response.error?.contains("tracked.txt") == true,
                "the refusal did not name the file: \(response.error ?? "no error")")
        #expect(try await f.status() == .active)
        #expect(try String(contentsOfFile: tracked, encoding: .utf8) == "edited\n")
    }

    /// `status.showUntrackedFiles=no` hides untracked files from a plain
    /// `git status`, so the guard asks for them explicitly.
    @Test func anUntrackedFileHiddenByConfigStillRefusesTheArchive() async throws {
        let f = try await Self.makeFixture()
        defer { f.cleanUp() }
        try await shell("git config status.showUntrackedFiles no", at: URL(fileURLWithPath: f.path))
        try f.writeUntracked("notes.md", "half a thought\n")
        try #require(await GitManager().isDirty(worktreePath: f.path) == false,
                     "a plain git status still lists the file, so the setting is not exercised")

        let response = try await f.archive()

        #expect(!response.success)
        #expect(response.errorCode == RPCErrorCode.worktreeArchiveUncommitted.rawValue)
        #expect(response.error?.contains("notes.md") == true,
                "the refusal did not name the file: \(response.error ?? "no error")")
        #expect(try await f.status() == .active)
        let notes = (f.path as NSString).appendingPathComponent("notes.md")
        #expect(try String(contentsOfFile: notes, encoding: .utf8) == "half a thought\n")
    }

    /// `ignore = dirty` on a submodule in `.gitmodules` hides edits inside
    /// its checkout from a plain `git status`, so the guard overrides it.
    @Test func anEditInsideAnIgnoredSubmoduleStillRefusesTheArchive() async throws {
        let f = try await Self.makeFixture(beforeWorktree: { tempDir, repoDir in
            let subRepo = tempDir.appendingPathComponent("subrepo")
            try FileManager.default.createDirectory(at: subRepo, withIntermediateDirectories: true)
            try await shell(
                "git init -q -b main && echo base > file.txt && git add file.txt && "
                    + "git -c user.email=t@example.com -c user.name=t commit -qm sub",
                at: subRepo)
            try await shell(
                "git -c protocol.file.allow=always submodule add -q '\(subRepo.path)' sub && "
                    + "git config -f .gitmodules submodule.sub.ignore dirty && "
                    + "git add .gitmodules && "
                    + "git -c user.email=t@example.com -c user.name=t commit -qm 'add sub'",
                at: repoDir)
        })
        defer { f.cleanUp() }
        let worktreeDir = URL(fileURLWithPath: f.path)
        try await shell(
            "git -c protocol.file.allow=always submodule update --init -q", at: worktreeDir)
        let edited = worktreeDir.appendingPathComponent("sub/file.txt").path
        try "edited\n".write(toFile: edited, atomically: true, encoding: .utf8)
        try #require(await GitManager().isDirty(worktreePath: f.path) == false,
                     "a plain git status still lists the submodule, so the setting is not exercised")

        let response = try await f.archive()

        #expect(!response.success)
        #expect(response.errorCode == RPCErrorCode.worktreeArchiveUncommitted.rawValue)
        #expect(response.error?.contains(" M sub") == true,
                "the refusal did not name the submodule: \(response.error ?? "no error")")
        #expect(try await f.status() == .active)
        #expect(try String(contentsOfFile: edited, encoding: .utf8) == "edited\n")
    }

    @Test func aCleanWorktreeArchives() async throws {
        let f = try await Self.makeFixture()
        defer { f.cleanUp() }

        let response = try await f.archive()

        #expect(response.success, "a clean worktree was refused: \(response.error ?? "no error")")
        #expect(try await f.status() == .archived)
        try await waitForFolderGone(f.path)
    }

    @Test func anUnreadableStatusRefusesRatherThanReadingClean() async throws {
        let f = try await Self.makeFixture()
        defer { f.cleanUp() }
        // A linked worktree's `.git` is a file naming its git directory.
        // Pointing it nowhere makes every git command in the folder fail.
        try "gitdir: /nonexistent-\(UUID().uuidString)\n".write(
            toFile: (f.path as NSString).appendingPathComponent(".git"),
            atomically: true, encoding: .utf8)

        let response = try await f.archive()

        #expect(!response.success)
        #expect(response.errorCode == RPCErrorCode.worktreeArchiveUncommitted.rawValue)
        #expect(response.error?.contains("Could not check \(f.path) for uncommitted changes") == true,
                "unexpected refusal: \(response.error ?? "no error")")
        #expect(response.error?.contains("Archiving deletes the directory.") == true)
        #expect(try await f.status() == .active)
        #expect(FileManager.default.fileExists(atPath: f.path))
        #expect(try expectRefusalRecorded(f) == response.error)
    }

    /// `force` lifts the guard and skips the archive hook — what
    /// `tbd worktree archive --force` sends. The dirty file is the hook
    /// itself; its marker staying absent is the half that tells `force` from
    /// `discardUncommittedChanges` (`discardingKeepsTheArchiveHook`).
    @Test func forceArchivesADirtyWorktreeAndSkipsTheHook() async throws {
        let f = try await Self.makeFixture()
        defer { f.cleanUp() }
        try f.installArchiveHook()
        try f.writeUntracked("notes.md")

        let response = try await f.archive(force: true)

        #expect(response.success, "force did not lift the guard: \(response.error ?? "no error")")
        #expect(try await f.status() == .archived)
        try await waitForFolderGone(f.path)
        #expect(!FileManager.default.fileExists(atPath: f.hookMarkerPath),
                "force must skip the archive hook")
    }

    /// `discardUncommittedChanges` lifts the guard alone, so the archive hook
    /// still runs — what the app sends once the user confirms.
    @Test func discardingKeepsTheArchiveHook() async throws {
        let f = try await Self.makeFixture()
        defer { f.cleanUp() }
        try f.installArchiveHook()
        try f.writeUntracked("notes.md")

        let response = try await f.archive(discard: true)

        #expect(response.success,
                "discardUncommittedChanges did not lift the guard: \(response.error ?? "no error")")
        #expect(try await f.status() == .archived)
        // The hook runs before the folder leaves its slot, so it has run by
        // the time the folder is gone.
        try await waitForFolderGone(f.path)
        #expect(FileManager.default.fileExists(atPath: f.hookMarkerPath),
                "discardUncommittedChanges must not skip the archive hook")
    }

    /// A folder that is already gone holds nothing an archive could lose.
    @Test func aMissingFolderIsNotChecked() async throws {
        let f = try await Self.makeFixture()
        defer { f.cleanUp() }
        try FileManager.default.removeItem(atPath: f.path)

        let response = try await f.archive()

        #expect(response.errorCode != RPCErrorCode.worktreeArchiveUncommitted.rawValue)
        #expect(response.success, "a missing folder was refused: \(response.error ?? "no error")")
        #expect(try await f.status() == .archived)
    }

    // MARK: - repo.remove

    /// The cascade bypasses the guard as it bypasses the children guard:
    /// removing the repo was the caller's decision about every worktree in it.
    @Test func aForcedRepoRemovalStillArchivesADirtyWorktree() async throws {
        let f = try await Self.makeFixture()
        defer { f.cleanUp() }
        try f.writeUntracked("notes.md")

        let response = await f.router.handle(try RPCRequest(
            method: RPCMethod.repoRemove,
            params: RepoRemoveParams(repoID: f.repo.id, force: true),
            actor: .app))

        #expect(response.success, "repo.remove was refused: \(response.error ?? "no error")")
        #expect(response.errorCode == nil)
        try await waitForFolderGone(f.path)
    }

    // MARK: - Auto-archive on merge

    @Test func autoArchiveKeepsADirtyWorktreeAndSaysWhy() async throws {
        let f = try await Self.makeFixture()
        defer { f.cleanUp() }
        try await f.db.worktrees.setAutoArchiveOnMerge(id: f.worktree.id, value: true)
        try f.writeUntracked("notes.md")

        let archived = await f.coordinator().handleMergedTransition(
            worktreeID: f.worktree.id, prNumber: 42)

        #expect(archived == false)
        #expect(try await f.status() == .active)
        #expect(FileManager.default.fileExists(
            atPath: (f.path as NSString).appendingPathComponent("notes.md")))
        let notifications = try await f.db.notifications.unread(worktreeID: f.worktree.id)
        #expect(notifications.count == 1)
        let notification = try #require(notifications.first)
        #expect(notification.type == .attentionNeeded)
        #expect(notification.message?.contains("Kept") == true)
        #expect(notification.message?.contains("#42") == true)
        #expect(notification.message?.contains("uncommitted changes that archiving would delete") == true,
                "unexpected message: \(notification.message ?? "nil")")
        let rows = try f.actuationRows()
        #expect(rows.first?["kind"] as? String == "dispose")
        #expect(rows.first?["method"] as? String == nil, "the rail's row names no RPC method")
        let recorded = try expectRefusalRecorded(f)
        #expect(recorded?.contains("notes.md") == true,
                "the outcome does not carry the refusal sentence: \(recorded ?? "nil")")
    }

    @Test func autoArchiveKeepsAWorktreeItCannotCheck() async throws {
        let f = try await Self.makeFixture()
        defer { f.cleanUp() }
        try await f.db.worktrees.setAutoArchiveOnMerge(id: f.worktree.id, value: true)
        try "gitdir: /nonexistent-\(UUID().uuidString)\n".write(
            toFile: (f.path as NSString).appendingPathComponent(".git"),
            atomically: true, encoding: .utf8)

        let archived = await f.coordinator().handleMergedTransition(
            worktreeID: f.worktree.id, prNumber: 43)

        #expect(archived == false)
        #expect(try await f.status() == .active)
        let notifications = try await f.db.notifications.unread(worktreeID: f.worktree.id)
        #expect(notifications.count == 1)
        let notification = try #require(notifications.first)
        #expect(notification.type == .attentionNeeded)
        #expect(notification.message?.contains("Kept") == true)
        #expect(notification.message?.contains("#43") == true)
        #expect(notification.message?.contains("could not check it for uncommitted changes") == true,
                "unexpected message: \(notification.message ?? "nil")")
    }

    @Test func autoArchiveArchivesACleanWorktree() async throws {
        let f = try await Self.makeFixture()
        defer { f.cleanUp() }
        try await f.db.worktrees.setAutoArchiveOnMerge(id: f.worktree.id, value: true)

        let archived = await f.coordinator().handleMergedTransition(
            worktreeID: f.worktree.id, prNumber: 44)

        #expect(archived == true)
        #expect(try await f.status() == .archived)
        try await waitForFolderGone(f.path)
    }

    // MARK: - Remote lanes

    /// A remote lane's files are on another machine, so the local guard never
    /// applies to it: its own guards answer with their own code, and
    /// `discardUncommittedChanges` is not a flag they read.
    @Test func aRemoteLaneNeverMeetsTheLocalGuard() async throws {
        let fixture = try await RemoteLaneFixture.make(
            capabilities: ["archive"], tag: "archive-uncommitted-remote")
        defer { fixture.cleanup() }
        let lane = try await fixture.seedLane(
            agentState: .idle, meta: [RemoteLaneLifecycle.dirtyWorkspaceMetaKey: "true"])

        let response = await fixture.router().handle(try RPCRequest(
            method: RPCMethod.worktreeArchive,
            params: WorktreeArchiveParams(worktreeID: lane.id, discardUncommittedChanges: true),
            actor: .app))

        #expect(!response.success)
        #expect(response.errorCode != RPCErrorCode.worktreeArchiveUncommitted.rawValue)
        #expect(response.errorCode == RPCErrorCode.remoteLaneArchiveGuarded.rawValue)
        #expect(fixture.invoker.calls == [["describe"]], "the archive verb must not run")
        #expect(try await fixture.status(of: lane) == .active)
    }

    // MARK: - The refusal's wording, without git

    @Test func aCleanStatusIsNoRefusal() {
        #expect(UncommittedArchiveRefusal.evaluate(
            displayName: "acme-wt", path: "/tmp/acme-wt", status: .success("")) == nil)
        #expect(UncommittedArchiveRefusal.evaluate(
            displayName: "acme-wt", path: "/tmp/acme-wt", status: .success("\n  \n")) == nil)
    }

    /// The porcelain status code's leading space survives, each line indented
    /// by two more.
    @Test func aDirtyStatusListsItsChanges() throws {
        let refusal = try #require(UncommittedArchiveRefusal.evaluate(
            displayName: "acme-wt", path: "/tmp/acme-wt",
            status: .success(" M Sources/a.swift\n?? notes.md\n")))
        #expect(refusal.kind == .dirty(count: 2))
        #expect(refusal.message == """
            acme-wt has 2 uncommitted change(s) that archiving would delete:
               M Sources/a.swift
              ?? notes.md
            Commit or remove them first.
            """)
    }

    @Test func aLongStatusListsFiveAndCountsTheRest() throws {
        let lines = [" M a.swift", "?? b.md", "A  c.txt", " D d.txt", "?? e/", "?? f.txt", "?? g.txt"]
        let refusal = try #require(UncommittedArchiveRefusal.evaluate(
            displayName: "acme-wt", path: "/tmp/acme-wt",
            status: .success(lines.joined(separator: "\n") + "\n")))
        #expect(refusal.kind == .dirty(count: 7))
        #expect(refusal.message.hasPrefix(
            "acme-wt has 7 uncommitted change(s) that archiving would delete:\n"))
        for line in lines.prefix(5) {
            #expect(refusal.message.contains("\n  \(line)\n"), "missing \(line)")
        }
        #expect(!refusal.message.contains("f.txt"))
        #expect(!refusal.message.contains("g.txt"))
        #expect(refusal.message.hasSuffix("\n  … and 2 more\nCommit or remove them first."))
    }

    @Test func aFailedStatusRefusesAsUnverifiable() throws {
        let refusal = try #require(UncommittedArchiveRefusal.evaluate(
            displayName: "acme-wt", path: "/tmp/acme-wt",
            status: .failure(GitError(
                command: "git status --porcelain", exitCode: 128,
                stderr: "fatal: not a git repository: /nonexistent\n"))))
        #expect(refusal.kind == .unverifiable)
        #expect(refusal.message == """
            Could not check /tmp/acme-wt for uncommitted changes \
            (git status exited 128: fatal: not a git repository: /nonexistent). \
            Archiving deletes the directory.
            """)

        let other = try #require(UncommittedArchiveRefusal.evaluate(
            displayName: "acme-wt", path: "/tmp/acme-wt", status: .failure(ProbeFailure())))
        #expect(other.kind == .unverifiable)
        #expect(other.message.hasPrefix("Could not check /tmp/acme-wt for uncommitted changes (probe failed)."))
    }
}

// MARK: - Scratch spaces

extension TBDHomeSerialized {
    /// A scratch space's archive keeps its folder, so the guard never applies
    /// to it: an untracked file there is archived with the folder, and kept.
    /// Nested here because `scratch.create` writes under `TBD_HOME`.
    @Suite("worktree archive: the uncommitted-changes guard skips scratch spaces")
    struct WorktreeArchiveUncommittedGuardScratchTests {
        @Test func aScratchSpaceWithAnUntrackedFileArchivesAndKeepsIt() async throws {
            let (_, cleanup) = isolateTBDHome(); defer { cleanup() }
            let db = try TBDDatabase(inMemory: true)
            let router = RPCRouter(
                db: db,
                lifecycle: WorktreeLifecycle(
                    db: db, git: GitManager(), tmux: TmuxManager(dryRun: true),
                    hooks: HookResolver()),
                tmux: TmuxManager(dryRun: true),
                subscriptions: StateSubscriptionManager(), actuationLog: makeTestActuationLog())
            let created = await router.handle(try RPCRequest(
                method: RPCMethod.scratchCreate,
                params: ScratchCreateParams(name: "wt-scratch-uncommitted")))
            let scratch = try created.decodeResult(Worktree.self)
            let notes = (scratch.localPath as NSString).appendingPathComponent("notes.md")
            try "half a thought\n".write(toFile: notes, atomically: true, encoding: .utf8)

            let response = await router.handle(try RPCRequest(
                method: RPCMethod.worktreeArchive,
                params: WorktreeArchiveParams(worktreeID: scratch.id),
                actor: .app))

            #expect(response.success, "the scratch archive was refused: \(response.error ?? "no error")")
            #expect(response.errorCode == nil)
            #expect(try await db.worktrees.get(id: scratch.id)?.status == .archived)
            #expect(try String(contentsOfFile: notes, encoding: .utf8) == "half a thought\n")
        }
    }
}

/// The archive's phase 2 never took the folder away. Thrown, so the path and
/// the budget reach the primary failure line.
private struct FolderStillPresent: Error, CustomStringConvertible {
    let path: String
    let after: Duration
    var description: String {
        "the archived worktree's folder is still at \(path) after waiting \(after)"
    }
}

private struct ProbeFailure: Error, CustomStringConvertible {
    var description: String { "probe failed" }
}
