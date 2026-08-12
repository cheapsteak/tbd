import Foundation
import TestSupport
import Testing
@testable import TBDDaemonLib
@testable import TBDShared

/// Tier 2 (real git subprocesses, real filesystem, no tmux — `dryRun: true`).
///
/// Covers what a *failed* `git worktree add` leaves behind, and how the create
/// path decides whether retrying can help.
///
/// The failure is induced with a stale `.git/config.lock`, which is a faithful
/// reproduction rather than a contrivance: `git worktree add -b <branch>
/// origin/<default>` creates the branch, then writes upstream tracking
/// configuration, and a lock file left by a crashed git makes only the second
/// half fail. Git rolls back the directory and the worktree registration but
/// keeps the branch — so the create fails with a `tbd/<name>` branch standing.
/// `GitManager` is a concrete struct, so real git is also the only way to drive
/// these paths.
@Suite struct WorktreeCreateFailureCleanupTests {

    /// A bare remote plus a clone with `main` pushed, so `origin/main` resolves
    /// and the upstream-config write is actually attempted. Returns the clone's
    /// host directory (the caller's `tempDir`) and the clone itself.
    private func makeClonedTestRepo() async throws -> (parentDir: URL, hostDir: URL, repoDir: URL) {
        let parentDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("tbd-create-failure-\(UUID().uuidString)")
        let remoteDir = parentDir.appendingPathComponent("remote.git")
        let hostDir = parentDir.appendingPathComponent("clone-host")
        let repoDir = hostDir.appendingPathComponent("repo")
        try FileManager.default.createDirectory(at: remoteDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: hostDir, withIntermediateDirectories: true)

        try await shell("git init --bare -b main", at: remoteDir)

        let sourceDir = parentDir.appendingPathComponent("source")
        try FileManager.default.createDirectory(at: sourceDir, withIntermediateDirectories: true)
        try await shell("git init -b main && git commit --allow-empty -m 'init'", at: sourceDir)
        try await shell("git remote add origin '\(remoteDir.path)'", at: sourceDir)
        try await shell("git push origin main", at: sourceDir)

        try await shell("git clone '\(remoteDir.path)' '\(repoDir.path)'", at: hostDir)
        return (parentDir, hostDir, repoDir)
    }

    /// Jams the repo so `git worktree add -b … origin/main` fails *after*
    /// creating the branch. No process holds this lock; it is exactly the
    /// residue a crashed git leaves.
    private func jamConfigLock(_ repoDir: URL) throws {
        try Data().write(to: repoDir.appendingPathComponent(".git/config.lock"))
    }

    /// Every local branch. Deliberately not `listBranches`, which filters out
    /// branches that are checked out in a worktree — exactly the ones these
    /// tests need to see.
    private func localBranches(_ repoDir: URL) async throws -> [String] {
        try await GitManager()
            .listRefs(repoPath: repoDir.path, prefix: "refs/heads")
            .map { String($0.dropFirst("refs/heads/".count)) }
    }

    private func makeLifecycle(db: TBDDatabase) -> WorktreeLifecycle {
        WorktreeLifecycle(
            db: db, git: GitManager(), tmux: TmuxManager(dryRun: true), hooks: HookResolver()
        )
    }

    // MARK: - Bug 1: a failed create must not leak the branch it just made

    @Test func failedCreateLeavesNothingBehind() async throws {
        let (parentDir, hostDir, repoDir) = try await makeClonedTestRepo()
        defer { try? FileManager.default.removeItem(at: parentDir) }
        try jamConfigLock(repoDir)

        let db = try TBDDatabase(inMemory: true)
        let lifecycle = makeLifecycle(db: db)
        let repo = try await makeTestRepo(db: db, tempDir: hostDir, repoDir: repoDir)

        await #expect(throws: WorktreeLifecycleError.self) {
            _ = try await lifecycle.createWorktree(repoID: repo.id, skipClaude: true)
        }

        // The whole point: git created `tbd/<name>` before failing, and nothing
        // cleaned it up. Against the unfixed tree this listed one branch per
        // generated name — e.g. ["tbd/…-thirsty-marmoset", "tbd/…-underlying-vole"].
        let branches = try await localBranches(repoDir)
        let leaked = branches.filter { $0.hasPrefix("tbd/") }
        #expect(leaked.isEmpty, "failed create leaked branches: \(leaked)")

        // Registration and directory, checked in the same run so the sweep is
        // whole. Git rolls both back by itself for this particular failure, so
        // these two are a guard against a future failure mode that doesn't —
        // which is why `worktreePrune` is part of the cleanup.
        let listed = try await GitManager().worktreeList(repoPath: repoDir.path)
        #expect(listed.count == 1, "stray worktree registrations: \(listed.map(\.path))")

        let base = WorktreeLayout().basePath(for: repo)
        let survivors = (try? FileManager.default.contentsOfDirectory(atPath: base)) ?? []
        #expect(survivors.isEmpty, "failed create left worktree directories: \(survivors)")
    }

    // MARK: - Bug 2: a repo-level failure must fail fast, with git's own words

    @Test func repoLevelFailureSurfacesGitStderr() async throws {
        let (parentDir, hostDir, repoDir) = try await makeClonedTestRepo()
        defer { try? FileManager.default.removeItem(at: parentDir) }
        try jamConfigLock(repoDir)

        let db = try TBDDatabase(inMemory: true)
        let lifecycle = makeLifecycle(db: db)
        let repo = try await makeTestRepo(db: db, tempDir: hostDir, repoDir: repoDir)

        do {
            _ = try await lifecycle.createWorktree(repoID: repo.id, skipClaude: true)
            Issue.record("expected the jammed config lock to fail the create")
        } catch {
            let text = String(describing: error)
            // Before the fix, the surfaced stderr came from the LAST attempt —
            // "a branch named 'tbd/…' already exists", an artifact of the leak
            // in bug 1 — and the real cause never reached the user.
            #expect(text.contains("could not lock config file"),
                    "the real cause was masked: \(text)")
            #expect(!text.contains("the folder or branch may already exist"),
                    "repo-level failure reported as a collision guess: \(text)")
            #expect(text.contains(".git/config.lock"),
                    "no actionable hint for a stale lock: \(text)")
        }
    }

    @Test func repoLevelFailureDoesNotGenerateASecondName() async throws {
        let (parentDir, hostDir, repoDir) = try await makeClonedTestRepo()
        defer { try? FileManager.default.removeItem(at: parentDir) }
        try jamConfigLock(repoDir)

        let db = try TBDDatabase(inMemory: true)
        let lifecycle = makeLifecycle(db: db)
        let repo = try await makeTestRepo(db: db, tempDir: hostDir, repoDir: repoDir)

        do {
            _ = try await lifecycle.createWorktree(repoID: repo.id, skipClaude: true)
            Issue.record("expected the jammed config lock to fail the create")
        } catch {
            let text = String(describing: error)
            // "after all attempts" is produced ONLY by the name-retry leg, so
            // its absence is direct evidence that no second folder/branch name
            // was generated for a cause no name can fix.
            #expect(!text.contains("after all attempts"),
                    "a second name was attempted for a repo-level failure: \(text)")
            #expect(!text.contains("already exists"),
                    "a second name was attempted and collided: \(text)")
        }

        let branches = try await localBranches(repoDir)
        #expect(branches.filter { $0.hasPrefix("tbd/") }.isEmpty)
        let base = WorktreeLayout().basePath(for: repo)
        let survivors = (try? FileManager.default.contentsOfDirectory(atPath: base)) ?? []
        #expect(survivors.isEmpty, "second name left a directory: \(survivors)")
    }

    /// An unresolvable base is not fixable by a fresh name either, so it must
    /// fail fast the same way a repo-level cause does, and say which bases it
    /// tried. Without the `lastKind == .baseUnresolvable` arm the create falls
    /// through to the name-retry leg, burns two more identical failures, and
    /// reports the generic "after all attempts" — the mutation this asserts
    /// against.
    @Test func unresolvableBaseFailsFastNamingTheBasesTried() async throws {
        let (tempDir, repoDir) = try await createTestRepo()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        // No `origin`, and a default branch that does not exist locally either,
        // so BOTH bases are unresolvable rather than just the remote one.
        let db = try TBDDatabase(inMemory: true)
        let created = try await db.repos.create(
            path: repoDir.path, displayName: "test", defaultBranch: "no-such-base"
        )
        try await db.repos.updateWorktreeRoot(
            id: created.id, path: tempDir.appendingPathComponent(".tbd/worktrees").path
        )
        let repo = try #require(try await db.repos.get(id: created.id))
        let lifecycle = makeLifecycle(db: db)

        do {
            _ = try await lifecycle.createWorktree(repoID: repo.id, skipClaude: true)
            Issue.record("expected an unresolvable base to fail the create")
        } catch {
            let text = String(describing: error)
            #expect(text.contains("no usable base branch"),
                    "unresolvable base reported as something else: \(text)")
            #expect(text.contains("origin/no-such-base") && text.contains("no-such-base"),
                    "the bases tried are not named: \(text)")
            #expect(!text.contains("after all attempts"),
                    "a second name was attempted for an unresolvable base: \(text)")
        }

        let base = WorktreeLayout().basePath(for: repo)
        let survivors = (try? FileManager.default.contentsOfDirectory(atPath: base)) ?? []
        #expect(survivors.isEmpty, "failed create left worktree directories: \(survivors)")
    }

    // MARK: - Branches we did NOT create are never deleted

    /// An occupied worktree *path* is the case that keeps the deletion gate
    /// honest in the other direction: git creates the branch, then discovers the
    /// path is taken and fails — so this failure really does leak a branch we
    /// made, even though its stderr says "already exists" like a branch
    /// collision does. Widening the gate from "git refused to create the branch"
    /// to the whole `.nameCollision` classification passes every other test in
    /// this file and reintroduces the leak here.
    @Test func occupiedPathLeaksNoBranchEvenThoughItLooksLikeACollision() async throws {
        // A cloned repo, so `origin/main` resolves and the FIRST attempt is the
        // one that trips over the path. Against an origin-less repo the base
        // fallback gets there first, and its cleanup deletes the planted
        // directory before any branch exists — the leak never forms.
        let (parentDir, hostDir, repoDir) = try await makeClonedTestRepo()
        defer { try? FileManager.default.removeItem(at: parentDir) }

        let db = try TBDDatabase(inMemory: true)
        let lifecycle = makeLifecycle(db: db)
        let repo = try await makeTestRepo(db: db, tempDir: hostDir, repoDir: repoDir)

        // Reserve the name, then occupy its path so the FIRST attempt fails
        // with "fatal: '<path>' already exists" after having created the branch.
        let pending = try await lifecycle.beginCreateWorktree(repoID: repo.id, skipClaude: true)
        try FileManager.default.createDirectory(
            atPath: pending.localPath, withIntermediateDirectories: true
        )
        try Data("occupied".utf8).write(
            to: URL(fileURLWithPath: pending.localPath).appendingPathComponent("stray.txt")
        )

        let completion = try await lifecycle.completeCreateWorktree(
            worktreeID: pending.id, skipClaude: true
        )
        if case .preSessionPending(let phase3) = completion {
            await phase3.value
        }

        let branches = try await localBranches(repoDir)
        #expect(!branches.contains(pending.branch),
                "an occupied path leaked the branch git created: \(branches)")
    }

    /// The probe→attempt window, driven directly because no test can reliably
    /// win a race against a subprocess spawn: a branch that appeared after the
    /// probe answered "absent" is indistinguishable from one we created by
    /// bookkeeping alone, and only git's own "a branch named … already exists"
    /// tells the two apart. Both arms asserted — the same inputs with that
    /// signal absent must still delete, or the gate would just be a synonym for
    /// "never clean up".
    @Test func branchTakenBetweenProbeAndAddIsNeverDeleted() async throws {
        let (tempDir, repoDir) = try await createTestRepo()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let db = try TBDDatabase(inMemory: true)
        let lifecycle = makeLifecycle(db: db)
        try await shell("git branch appeared-mid-flight", at: repoDir)
        try await shell("git branch ours-to-clean-up", at: repoDir)

        await lifecycle.cleanUpFailedWorktreeAdd(
            repoPath: repoDir.path,
            worktreePath: tempDir.appendingPathComponent("never-created").path,
            branch: "appeared-mid-flight",
            branchPreExisted: false,
            branchNameWasAlreadyTaken: true
        )
        await lifecycle.cleanUpFailedWorktreeAdd(
            repoPath: repoDir.path,
            worktreePath: tempDir.appendingPathComponent("never-created").path,
            branch: "ours-to-clean-up",
            branchPreExisted: false,
            branchNameWasAlreadyTaken: false
        )

        let branches = try await localBranches(repoDir)
        #expect(branches.contains("appeared-mid-flight"),
                "cleanup deleted a branch git had refused to create: \(branches)")
        #expect(!branches.contains("ours-to-clean-up"),
                "cleanup left behind a branch it did create: \(branches)")
    }

    /// A failed probe (`nil`) is not the same answer as "absent", so it must
    /// keep the branch — the third arm of the pre-existence tri-state, which the
    /// other tests only reach as `false` or `true`.
    @Test func unknownPreExistenceNeverDeletes() async throws {
        let (tempDir, repoDir) = try await createTestRepo()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let db = try TBDDatabase(inMemory: true)
        let lifecycle = makeLifecycle(db: db)
        try await shell("git branch probe-failed", at: repoDir)

        await lifecycle.cleanUpFailedWorktreeAdd(
            repoPath: repoDir.path,
            worktreePath: tempDir.appendingPathComponent("never-created").path,
            branch: "probe-failed",
            branchPreExisted: nil,
            branchNameWasAlreadyTaken: false
        )

        let branches = try await localBranches(repoDir)
        #expect(branches.contains("probe-failed"),
                "cleanup deleted a branch whose pre-existence was unknown: \(branches)")
    }

    /// The `worktreeAddExisting` leg creates no branch and must therefore never
    /// delete one. Not red against the unfixed tree — which deletes no branches
    /// anywhere — so it is mutation-checked instead: routing that leg's `catch`
    /// through `cleanUpFailedWorktreeAdd(branchPreExisted: false,
    /// branchNameWasAlreadyTaken: false)`, the obvious over-eager version of
    /// this fix, makes it fail.
    @Test func preExistingBranchSurvivesAFailedCheckout() async throws {
        let (tempDir, repoDir) = try await createTestRepo()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        try await shell("git branch owned-by-caller", at: repoDir)

        let db = try TBDDatabase(inMemory: true)
        let lifecycle = makeLifecycle(db: db)
        let repo = try await makeTestRepo(db: db, tempDir: tempDir, repoDir: repoDir)

        // Fail the checkout by occupying the reserved path. Deliberately NOT by
        // checking the branch out in a second worktree: git refuses to delete a
        // checked-out branch all by itself, which would mask an over-eager
        // cleanup instead of exposing it. Here nothing holds `owned-by-caller`,
        // so only the pre-existence gate keeps it alive.
        let pending = try await lifecycle.beginCreateWorktree(
            repoID: repo.id, branch: "owned-by-caller", skipClaude: true
        )
        try FileManager.default.createDirectory(
            atPath: pending.localPath, withIntermediateDirectories: true
        )
        try Data("occupied".utf8).write(
            to: URL(fileURLWithPath: pending.localPath).appendingPathComponent("stray.txt")
        )

        await #expect(throws: WorktreeLifecycleError.self) {
            _ = try await lifecycle.completeCreateWorktree(
                worktreeID: pending.id, skipClaude: true, userSpecifiedBranch: true
            )
        }

        let branches = try await localBranches(repoDir)
        #expect(branches.contains("owned-by-caller"),
                "cleanup deleted a branch the caller brought: \(branches)")
    }

    /// The name-collision retry must keep working — otherwise the new
    /// classification could silently turn retrying off. Doubles as the second
    /// half of the deletion guard: the colliding branch belongs to somebody
    /// else and must survive the attempt that tripped over it.
    ///
    /// Also not red against the unfixed tree — it asserts preserved behavior —
    /// so it is mutation-checked twice: classifying `already exists` as
    /// `.repoLevel` makes the create throw instead of retrying, and dropping
    /// the `branchPreExisted == false` guard in `cleanUpFailedWorktreeAdd`
    /// makes the cleanup delete the colliding branch.
    @Test func nameCollisionStillRetriesUnderAFreshName() async throws {
        let (tempDir, repoDir) = try await createTestRepo()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let db = try TBDDatabase(inMemory: true)
        let lifecycle = makeLifecycle(db: db)
        let repo = try await makeTestRepo(db: db, tempDir: tempDir, repoDir: repoDir)

        // Reserve the name first, then plant a branch on it — the only way to
        // collide with an auto-generated `tbd/<name>` whose name nobody knows
        // until it is generated.
        let pending = try await lifecycle.beginCreateWorktree(repoID: repo.id, skipClaude: true)
        try await shell("git branch '\(pending.branch)'", at: repoDir)

        let completion = try await lifecycle.completeCreateWorktree(
            worktreeID: pending.id, skipClaude: true
        )
        if case .preSessionPending(let phase3) = completion {
            await phase3.value
        }

        // A fresh name was generated and the worktree exists on it.
        let listed = try await GitManager().worktreeList(repoPath: repoDir.path)
        let created = listed.filter { $0.branch.hasPrefix("tbd/") }
        #expect(created.count == 1, "expected exactly one tbd/ worktree: \(listed)")
        #expect(created.first?.branch != pending.branch,
                "retry reused the colliding branch name")

        // And the branch that caused the collision is untouched.
        let branches = try await localBranches(repoDir)
        #expect(branches.contains(pending.branch),
                "cleanup deleted the pre-existing colliding branch: \(branches)")
    }
}
