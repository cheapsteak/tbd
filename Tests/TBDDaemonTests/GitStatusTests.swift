import Testing
import Foundation
import TestSupport
@testable import TBDDaemonLib
@testable import TBDShared

/// Runs `steps` as one `&&`-chained script through `shell(_:at:)`, which
/// waits off the cooperative pool and stops at the first failing step. One
/// bash per setup rather than one per step, and no repo-local identity or
/// `commit.gpgSign` config to write: `shell`'s hermetic environment already
/// supplies an identity and keeps the developer's global config out.
private func runSteps(_ steps: [String], at dir: URL) async throws {
    try await shell(steps.joined(separator: " && "), at: dir)
}

@Suite("GitStatus Tests")
struct GitStatusTests {

    @Test func newWorktreeHasNoConflicts() async throws {
        let db = try TBDDatabase(inMemory: true)
        let repo = try await db.repos.create(path: "/tmp/test", displayName: "test", defaultBranch: "main")
        let wt = try await db.worktrees.create(
            repoID: repo.id, name: "test-wt", branch: "tbd/test-wt",
            path: "/tmp/test/.tbd/worktrees/test-wt", tmuxServer: "tbd-a1b2c3d4"
        )
        #expect(wt.hasConflicts == false)
    }

    @Test func updateHasConflictsToTrue() async throws {
        let db = try TBDDatabase(inMemory: true)
        let repo = try await db.repos.create(path: "/tmp/test", displayName: "test", defaultBranch: "main")
        let wt = try await db.worktrees.create(
            repoID: repo.id, name: "test-wt", branch: "tbd/test-wt",
            path: "/tmp/test/.tbd/worktrees/test-wt", tmuxServer: "tbd-a1b2c3d4"
        )
        try await db.worktrees.updateHasConflicts(id: wt.id, hasConflicts: true)
        let updated = try await db.worktrees.get(id: wt.id)
        #expect(updated?.hasConflicts == true)
    }

    @Test func hasConflictsRoundTrip() async throws {
        let db = try TBDDatabase(inMemory: true)
        let repo = try await db.repos.create(path: "/tmp/test", displayName: "test", defaultBranch: "main")
        let wt = try await db.worktrees.create(
            repoID: repo.id, name: "test-wt", branch: "tbd/test-wt",
            path: "/tmp/test/.tbd/worktrees/test-wt", tmuxServer: "tbd-a1b2c3d4"
        )
        // Set to true, then back to false
        try await db.worktrees.updateHasConflicts(id: wt.id, hasConflicts: true)
        let withConflicts = try await db.worktrees.get(id: wt.id)
        #expect(withConflicts?.hasConflicts == true)

        try await db.worktrees.updateHasConflicts(id: wt.id, hasConflicts: false)
        let withoutConflicts = try await db.worktrees.get(id: wt.id)
        #expect(withoutConflicts?.hasConflicts == false)
    }

    @Test func isMergeBaseAncestor() async throws {
        // Set up a temp repo
        let repoDir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("tbd-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: repoDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: repoDir) }

        // Init repo and make initial commit on main, then create a feature
        // branch with a commit
        try await runSteps([
            "git init -b main",
            "touch README.md && git add . && git commit -m 'initial'",
            "git checkout -b feature",
            "touch feature.txt && git add . && git commit -m 'feature commit'",
        ], at: repoDir)

        // main IS an ancestor of feature
        let git = GitManager()
        let repoPath = repoDir.path
        let mainIsAncestor = await git.isMergeBaseAncestor(repoPath: repoPath, base: "main", branch: "feature")
        #expect(mainIsAncestor == true)

        // Now add a commit to main (diverge)
        try await runSteps([
            "git checkout main",
            "touch main-extra.txt && git add . && git commit -m 'main diverges'",
        ], at: repoDir)

        // main is now NOT an ancestor of feature (main has diverged)
        let mainIsAncestorAfterDiverge = await git.isMergeBaseAncestor(repoPath: repoPath, base: "main", branch: "feature")
        #expect(mainIsAncestorAfterDiverge == false)
    }

    /// `hasCommit` is what parts the two halves of an undecidable ancestry, so
    /// both of its answers have to be real: a commit this repository holds, and
    /// a well-formed sha it has never seen.
    @Test func hasCommitDistinguishesHeldFromNeverSeen() async throws {
        let repoDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("tbd-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: repoDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: repoDir) }

        try await runSteps([
            "git init -b main",
            "touch README.md && git add . && git commit -m 'initial'",
        ], at: repoDir)

        let git = GitManager()
        let repoPath = repoDir.path
        let head = try #require(await git.revParseHead(at: repoPath))
        #expect(await git.hasCommit(repoPath: repoPath, sha: head) == true)
        // A syntactically valid sha that no repository has: absent, not an error.
        #expect(
            await git.hasCommit(
                repoPath: repoPath, sha: "0123456789012345678901234567890123456789") == false)

        // And a path that is not a repository at all cannot answer either way.
        // This is the case that must never read as "absent": absent launches an
        // update in `auto` mode, and a broken checkout is not evidence that
        // `main` moved.
        let notARepo = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("tbd-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: notARepo, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: notARepo) }
        #expect(await git.hasCommit(repoPath: notARepo.path, sha: head) == nil)
    }

    // MARK: - refreshGitStatuses integration tests

    @Test func refreshGitStatusesDetectsConflicts() async throws {
        let tempBase = URL(fileURLWithPath: NSTemporaryDirectory())
        let suffix = UUID().uuidString
        let repoDir = tempBase.appendingPathComponent("tbd-test-\(suffix)")
        let originDir = tempBase.appendingPathComponent("tbd-test-origin-\(suffix).git")
        try FileManager.default.createDirectory(at: repoDir, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(at: repoDir)
            try? FileManager.default.removeItem(at: originDir)
        }

        try await runSteps([
            // Init repo with a file
            "git init -b main",
            "echo 'line1' > shared.txt && git add . && git commit -m 'initial'",

            // Set up bare origin remote and push the pre-conflict main
            "git init --bare '\(originDir.path)'",
            "git remote add origin '\(originDir.path)'",
            "git push -u origin main",

            // Create feature branch with conflicting change (NOT pushed to origin)
            "git checkout -b tbd/feature-wt",
            "echo 'feature-change' > shared.txt && git add . && git commit -m 'feature change'",

            // Back to main with conflicting change to same file, then push so
            // origin/main reflects the diverged state. The feature branch is NOT
            // pushed — origin/main is ahead of where feature branched off, with a
            // conflicting edit to shared.txt, which is what makes the conflict
            // detectable under the origin-based reconcile semantics.
            "git checkout main",
            "echo 'main-change' > shared.txt && git add . && git commit -m 'main change'",
            "git push origin main",
        ], at: repoDir)

        // Set up DB
        let db = try TBDDatabase(inMemory: true)
        let repo = try await db.repos.create(path: repoDir.path, displayName: "test", defaultBranch: "main")
        let wt = try await db.worktrees.create(
            repoID: repo.id, name: "feature-wt", branch: "tbd/feature-wt",
            path: repoDir.path + "/.tbd/worktrees/feature-wt", tmuxServer: "tbd-test"
        )
        #expect(wt.hasConflicts == false)

        // Run refreshGitStatuses
        let lifecycle = WorktreeLifecycle(
            db: db, git: GitManager(), tmux: TmuxManager(dryRun: true),
            hooks: HookResolver(), subscriptions: StateSubscriptionManager()
        )
        await lifecycle.refreshGitStatuses(repoID: repo.id)

        let updated = try await db.worktrees.get(id: wt.id)
        #expect(updated?.hasConflicts == true)
    }

    @Test func refreshGitStatusesNoConflictsWhenBranchMatchesOrigin() async throws {
        let tempBase = URL(fileURLWithPath: NSTemporaryDirectory())
        let suffix = UUID().uuidString
        let repoDir = tempBase.appendingPathComponent("tbd-test-\(suffix)")
        let originDir = tempBase.appendingPathComponent("tbd-test-origin-\(suffix).git")
        try FileManager.default.createDirectory(at: repoDir, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(at: repoDir)
            try? FileManager.default.removeItem(at: originDir)
        }

        try await runSteps([
            // Init repo with a file
            "git init -b main",
            "echo 'line1' > shared.txt && git add . && git commit -m 'initial'",

            // Set up bare origin remote and push main
            "git init --bare '\(originDir.path)'",
            "git remote add origin '\(originDir.path)'",
            "git push -u origin main",

            // Create feature branch pointing at the same commit as origin/main (no extra commits)
            "git checkout -b tbd/feature-wt",
        ], at: repoDir)

        // Set up DB
        let db = try TBDDatabase(inMemory: true)
        let repo = try await db.repos.create(path: repoDir.path, displayName: "test", defaultBranch: "main")
        let wt = try await db.worktrees.create(
            repoID: repo.id, name: "feature-wt", branch: "tbd/feature-wt",
            path: repoDir.path + "/.tbd/worktrees/feature-wt", tmuxServer: "tbd-test"
        )
        #expect(wt.hasConflicts == false)

        // Run refreshGitStatuses — branch is an ancestor of origin/main, no conflicts
        let lifecycle = WorktreeLifecycle(
            db: db, git: GitManager(), tmux: TmuxManager(dryRun: true),
            hooks: HookResolver(), subscriptions: StateSubscriptionManager()
        )
        await lifecycle.refreshGitStatuses(repoID: repo.id)

        let updated = try await db.worktrees.get(id: wt.id)
        #expect(updated?.hasConflicts == false)
    }

    @Test func refTipsResolvesLocalAndOriginBranches() async throws {
        let tempBase = URL(fileURLWithPath: NSTemporaryDirectory())
        let suffix = UUID().uuidString
        let repoDir = tempBase.appendingPathComponent("tbd-test-\(suffix)")
        let originDir = tempBase.appendingPathComponent("tbd-test-origin-\(suffix).git")
        try FileManager.default.createDirectory(at: repoDir, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(at: repoDir)
            try? FileManager.default.removeItem(at: originDir)
        }

        try await runSteps([
            "git init -b main",
            "touch README.md && git add . && git commit -m 'initial'",
            "git init --bare '\(originDir.path)'",
            "git remote add origin '\(originDir.path)'",
            "git push -u origin main",
            "git checkout -b feature",
            "touch feature.txt && git add . && git commit -m 'feature'",
        ], at: repoDir)

        let git = GitManager()
        let tips = try await git.refTips(repoPath: repoDir.path)
        let mainSHA = try await git.headSHA(repoPath: repoDir.path, ref: "main")
        let featureSHA = try await git.headSHA(repoPath: repoDir.path, ref: "feature")

        #expect(tips["main"] == mainSHA)
        #expect(tips["origin/main"] == mainSHA)
        #expect(tips["feature"] == featureSHA)
        #expect(featureSHA != mainSHA)
    }

    /// Dirty gate: a sweep whose (branch tip, base tip) pair is unchanged must
    /// NOT re-run the conflict check; moving either tip must re-run it.
    ///
    /// Skip is observed by tampering with the DB value between sweeps: a gated
    /// sweep leaves the tampered value in place (no check ran), while an
    /// invalidated sweep recomputes and corrects it.
    @Test func refreshGitStatusesDirtyGateSkipsAndInvalidates() async throws {
        let tempBase = URL(fileURLWithPath: NSTemporaryDirectory())
        let suffix = UUID().uuidString
        let repoDir = tempBase.appendingPathComponent("tbd-test-\(suffix)")
        let originDir = tempBase.appendingPathComponent("tbd-test-origin-\(suffix).git")
        try FileManager.default.createDirectory(at: repoDir, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(at: repoDir)
            try? FileManager.default.removeItem(at: originDir)
        }

        // Same conflict scenario as refreshGitStatusesDetectsConflicts:
        // feature edits shared.txt, origin/main diverges with a conflicting edit.
        try await runSteps([
            "git init -b main",
            "echo 'line1' > shared.txt && git add . && git commit -m 'initial'",
            "git init --bare '\(originDir.path)'",
            "git remote add origin '\(originDir.path)'",
            "git push -u origin main",
            "git checkout -b tbd/feature-wt",
            "echo 'feature-change' > shared.txt && git add . && git commit -m 'feature change'",
            "git checkout main",
            "echo 'main-change' > shared.txt && git add . && git commit -m 'main change'",
            "git push origin main",
        ], at: repoDir)

        let db = try TBDDatabase(inMemory: true)
        let repo = try await db.repos.create(path: repoDir.path, displayName: "test", defaultBranch: "main")
        let wt = try await db.worktrees.create(
            repoID: repo.id, name: "feature-wt", branch: "tbd/feature-wt",
            path: repoDir.path + "/.tbd/worktrees/feature-wt", tmuxServer: "tbd-test"
        )

        // The cache lives on the lifecycle instance — reuse ONE instance across
        // sweeps, like the daemon's periodic task does.
        let lifecycle = WorktreeLifecycle(
            db: db, git: GitManager(), tmux: TmuxManager(dryRun: true),
            hooks: HookResolver(), subscriptions: StateSubscriptionManager()
        )

        // Sweep 1: computes and stores the real answer (conflicts).
        await lifecycle.refreshGitStatuses(repoID: repo.id)
        #expect(try await db.worktrees.get(id: wt.id)?.hasConflicts == true)

        // Tamper, then sweep with unchanged tips: the gate must skip the
        // check, leaving the tampered value untouched.
        try await db.worktrees.updateHasConflicts(id: wt.id, hasConflicts: false)
        await lifecycle.refreshGitStatuses(repoID: repo.id)
        #expect(try await db.worktrees.get(id: wt.id)?.hasConflicts == false)

        // Move the branch tip: gate invalidates, the check re-runs and
        // corrects the tampered value.
        try await runSteps([
            "git checkout tbd/feature-wt",
            "echo 'more' >> shared.txt && git add . && git commit -m 'feature again'",
            "git checkout main",
        ], at: repoDir)
        await lifecycle.refreshGitStatuses(repoID: repo.id)
        #expect(try await db.worktrees.get(id: wt.id)?.hasConflicts == true)

        // Tamper again, then move the BASE tip (push a new commit to
        // origin/main): gate invalidates on the other half of the pair.
        try await db.worktrees.updateHasConflicts(id: wt.id, hasConflicts: false)
        try await runSteps([
            "echo 'base-moves' > other.txt && git add . && git commit -m 'base moves'",
            "git push origin main",
        ], at: repoDir)
        await lifecycle.refreshGitStatuses(repoID: repo.id)
        #expect(try await db.worktrees.get(id: wt.id)?.hasConflicts == true)
    }

    /// Ungated fallback: when the worktree's ref is not resolvable from the
    /// `for-each-ref` tips (here: a tag, which lives outside refs/heads and
    /// refs/remotes/origin), the dirty gate must fall through to checking
    /// unconditionally every sweep — fail-open, matching pre-gate behavior —
    /// rather than skipping (which would freeze hasConflicts forever).
    @Test func refreshGitStatusesChecksUnconditionallyWhenTipsUnresolvable() async throws {
        let tempBase = URL(fileURLWithPath: NSTemporaryDirectory())
        let suffix = UUID().uuidString
        let repoDir = tempBase.appendingPathComponent("tbd-test-\(suffix)")
        let originDir = tempBase.appendingPathComponent("tbd-test-origin-\(suffix).git")
        try FileManager.default.createDirectory(at: repoDir, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(at: repoDir)
            try? FileManager.default.removeItem(at: originDir)
        }

        // Conflict scenario as above, but the worktree row's "branch" is a TAG
        // pointing at the conflicting commit.
        try await runSteps([
            "git init -b main",
            "echo 'line1' > shared.txt && git add . && git commit -m 'initial'",
            "git init --bare '\(originDir.path)'",
            "git remote add origin '\(originDir.path)'",
            "git push -u origin main",
            "git checkout -b tbd/feature-wt",
            "echo 'feature-change' > shared.txt && git add . && git commit -m 'feature change'",
            "git tag feature-tag",
            "git checkout main",
            "echo 'main-change' > shared.txt && git add . && git commit -m 'main change'",
            "git push origin main",
        ], at: repoDir)

        let db = try TBDDatabase(inMemory: true)
        let repo = try await db.repos.create(path: repoDir.path, displayName: "test", defaultBranch: "main")
        let wt = try await db.worktrees.create(
            repoID: repo.id, name: "feature-wt", branch: "feature-tag",
            path: repoDir.path + "/.tbd/worktrees/feature-wt", tmuxServer: "tbd-test"
        )

        let lifecycle = WorktreeLifecycle(
            db: db, git: GitManager(), tmux: TmuxManager(dryRun: true),
            hooks: HookResolver(), subscriptions: StateSubscriptionManager()
        )

        // Sweep 1 computes the real answer through the ungated path.
        await lifecycle.refreshGitStatuses(repoID: repo.id)
        #expect(try await db.worktrees.get(id: wt.id)?.hasConflicts == true)

        // Tamper, then sweep again with nothing changed: because the ref isn't
        // gateable, the check re-runs and corrects the value (a gated worktree
        // would have skipped and left the tamper in place).
        try await db.worktrees.updateHasConflicts(id: wt.id, hasConflicts: false)
        await lifecycle.refreshGitStatuses(repoID: repo.id)
        #expect(try await db.worktrees.get(id: wt.id)?.hasConflicts == true)
    }

    /// The PR-poll remote-tip trigger end to end over a real repo and a bare
    /// origin: the first sweep is a baseline, a local commit with no push does
    /// not fire, and a push fires exactly once for that worktree.
    @Test func theSweepTriggersOnAPushButNotOnALocalCommit() async throws {
        let tempBase = URL(fileURLWithPath: NSTemporaryDirectory())
        let suffix = UUID().uuidString
        let repoDir = tempBase.appendingPathComponent("tbd-test-remotetip-\(suffix)")
        let originDir = tempBase.appendingPathComponent("tbd-test-remotetip-origin-\(suffix).git")
        try FileManager.default.createDirectory(at: repoDir, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(at: repoDir)
            try? FileManager.default.removeItem(at: originDir)
        }

        try await runSteps([
            "git init -b main",
            "echo 'line1' > f.txt && git add . && git commit -m 'initial'",
            "git init --bare '\(originDir.path)'",
            "git remote add origin '\(originDir.path)'",
            "git push -u origin main",
            "git checkout -b tbd/pushed",
            "echo 'a' > a.txt && git add . && git commit -m 'a'",
            "git push -u origin tbd/pushed",
        ], at: repoDir)

        let db = try TBDDatabase(inMemory: true)
        let repo = try await db.repos.create(
            path: repoDir.path, displayName: "test", defaultBranch: "main")
        let wt = try await db.worktrees.create(
            repoID: repo.id, name: "pushed", branch: "tbd/pushed",
            path: repoDir.path + "/.tbd/worktrees/pushed", tmuxServer: "tbd-test")

        let lifecycle = WorktreeLifecycle(
            db: db, git: GitManager(), tmux: TmuxManager(dryRun: true),
            hooks: HookResolver(), subscriptions: StateSubscriptionManager()
        )
        let moved = RemoteTipMoves()
        await lifecycle.remoteTipTracker.setOnMoved { await moved.add($0) }

        // Baseline: the first sighting of origin/tbd/pushed is not a change.
        await lifecycle.refreshGitStatuses(repoID: repo.id)
        #expect(await moved.ids.isEmpty)

        // A local commit moves refs/heads/tbd/pushed only.
        try await shell("echo 'b' > b.txt && git add . && git commit -m 'b'", at: repoDir)
        await lifecycle.refreshGitStatuses(repoID: repo.id)
        #expect(await moved.ids.isEmpty, "a local commit with no push fired the trigger")

        // The push moves origin/tbd/pushed.
        try await shell("git push origin tbd/pushed", at: repoDir)
        await lifecycle.refreshGitStatuses(repoID: repo.id)
        #expect(await moved.ids == [wt.id])

        // Unchanged since: no second fire.
        await lifecycle.refreshGitStatuses(repoID: repo.id)
        #expect(await moved.ids == [wt.id])
    }

    /// A sweep whose `refTips` fails observes nothing, so it cannot leave a
    /// nil baseline that the next good sweep would report as a push. The
    /// checkout is moved away for the first sweep, so every git call in it
    /// fails, and moved back for the second.
    @Test func aFailedTipReadLeavesNoBaselineToTriggerOn() async throws {
        let tempBase = URL(fileURLWithPath: NSTemporaryDirectory())
        let suffix = UUID().uuidString
        let repoDir = tempBase.appendingPathComponent("tbd-test-remotetip-fail-\(suffix)")
        let awayDir = tempBase.appendingPathComponent("tbd-test-remotetip-fail-away-\(suffix)")
        let originDir = tempBase.appendingPathComponent("tbd-test-remotetip-fail-origin-\(suffix).git")
        try FileManager.default.createDirectory(at: repoDir, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(at: repoDir)
            try? FileManager.default.removeItem(at: awayDir)
            try? FileManager.default.removeItem(at: originDir)
        }

        try await runSteps([
            "git init -b main",
            "echo 'line1' > f.txt && git add . && git commit -m 'initial'",
            "git init --bare '\(originDir.path)'",
            "git remote add origin '\(originDir.path)'",
            "git push -u origin main",
            "git checkout -b tbd/pushed",
            "echo 'a' > a.txt && git add . && git commit -m 'a'",
            "git push -u origin tbd/pushed",
        ], at: repoDir)

        let db = try TBDDatabase(inMemory: true)
        let repo = try await db.repos.create(
            path: repoDir.path, displayName: "test", defaultBranch: "main")
        _ = try await db.worktrees.create(
            repoID: repo.id, name: "pushed", branch: "tbd/pushed",
            path: repoDir.path + "/.tbd/worktrees/pushed", tmuxServer: "tbd-test")

        let lifecycle = WorktreeLifecycle(
            db: db, git: GitManager(), tmux: TmuxManager(dryRun: true),
            hooks: HookResolver(), subscriptions: StateSubscriptionManager()
        )
        let moved = RemoteTipMoves()
        await lifecycle.remoteTipTracker.setOnMoved { await moved.add($0) }

        // The checkout is gone: `refTips` throws and the sweep observes nothing.
        try FileManager.default.moveItem(at: repoDir, to: awayDir)
        await lifecycle.refreshGitStatuses(repoID: repo.id)
        #expect(await moved.ids.isEmpty)

        // Back again, with origin/tbd/pushed where it always was: this is the
        // first sighting, a baseline, and not a push.
        try FileManager.default.moveItem(at: awayDir, to: repoDir)
        await lifecycle.refreshGitStatuses(repoID: repo.id)
        #expect(await moved.ids.isEmpty, "a failed tip read left a nil baseline that fired on the next sweep")
    }
}

private actor RemoteTipMoves {
    var ids: [UUID] = []
    func add(_ id: UUID) { ids.append(id) }
}
