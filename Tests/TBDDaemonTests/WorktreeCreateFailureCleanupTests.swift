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
    ///
    /// `remoteOnlyBranches` are pushed to the remote and then deleted from the
    /// source, so the clone sees `origin/<name>` with no local counterpart —
    /// the shape that makes `--track -b <name>` create a branch.
    /// `pullRequestHeads` plant `refs/pull/<n>/head` on the remote, which is
    /// what a fork-PR checkout fetches.
    private func makeClonedTestRepo(
        remoteOnlyBranches: [String] = [],
        pullRequestHeads: [Int] = []
    ) async throws -> (parentDir: URL, hostDir: URL, repoDir: URL) {
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

        for branch in remoteOnlyBranches {
            try await shell(
                "git checkout -b '\(branch)' && git commit --allow-empty -m '\(branch)'"
                + " && git push origin '\(branch)' && git checkout main",
                at: sourceDir
            )
        }
        for number in pullRequestHeads {
            try await shell(
                "git update-ref refs/pull/\(number)/head refs/heads/main", at: remoteDir
            )
        }

        try await shell("git clone '\(remoteDir.path)' '\(repoDir.path)'", at: hostDir)
        return (parentDir, hostDir, repoDir)
    }

    /// Occupies `path` with a stray file, so the next `git worktree add`
    /// targeting it fails with `fatal: '<path>' already exists`.
    private func occupy(_ path: String) throws {
        try FileManager.default.createDirectory(
            atPath: path, withIntermediateDirectories: true
        )
        try Data("occupied".utf8).write(
            to: URL(fileURLWithPath: path).appendingPathComponent("stray.txt")
        )
    }

    /// Jams the repo so `git worktree add -b … origin/main` fails *after*
    /// creating the branch. No process holds this lock; it is exactly the
    /// residue a crashed git leaves.
    ///
    /// It jams only the *remote* base by default, and that asymmetry is the
    /// point: `-b <new> origin/main` writes upstream tracking configuration,
    /// while `-b <new> main` writes none and therefore never touches
    /// `.git/config`. Pass `includingTheLocalBase: true` to set
    /// `branch.autoSetupMerge = always`, which makes a local base configure
    /// upstream too — the way to build one cause that both bases hit. Both
    /// halves verified against git 2.50.
    private func jamConfigLock(
        _ repoDir: URL, includingTheLocalBase: Bool = false
    ) async throws {
        if includingTheLocalBase {
            try await shell("git config branch.autoSetupMerge always", at: repoDir)
        }
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

    /// Jammed for BOTH bases: a lock that stops only the remote base is now
    /// recovered by the local one (see `remoteBaseFailureRecoversOnTheLocalBase`),
    /// so making the create fail at all takes a cause neither base escapes.
    @Test func failedCreateLeavesNothingBehind() async throws {
        let (parentDir, hostDir, repoDir) = try await makeClonedTestRepo()
        defer { try? FileManager.default.removeItem(at: parentDir) }
        try await jamConfigLock(repoDir, includingTheLocalBase: true)

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

    // MARK: - Bug 2: a repo-level failure earns the other base, but never a name

    /// The two bases are not interchangeable, so a repo-level failure on the
    /// remote one is not the end of the road: `origin/main` makes `-b` write
    /// upstream configuration, and a stale `.git/config.lock` fails exactly that
    /// write, while the plain local `main` writes no configuration at all and
    /// succeeds with the lock still sitting there.
    ///
    /// What makes continuing safe is the branch cleanup this suite's first test
    /// covers: attempt 1 leaves `tbd/<name>` standing, cleanup removes it, and
    /// attempt 2 finds the name free. Failing fast here spent that cleanup for
    /// nothing.
    @Test func remoteBaseFailureRecoversOnTheLocalBase() async throws {
        let (parentDir, hostDir, repoDir) = try await makeClonedTestRepo()
        defer { try? FileManager.default.removeItem(at: parentDir) }
        try await jamConfigLock(repoDir)

        let db = try TBDDatabase(inMemory: true)
        let lifecycle = makeLifecycle(db: db)
        let repo = try await makeTestRepo(db: db, tempDir: hostDir, repoDir: repoDir)

        let created = try await lifecycle.createWorktree(repoID: repo.id, skipClaude: true)

        let listed = try await GitManager().worktreeList(repoPath: repoDir.path)
        #expect(listed.contains { $0.branch == created.branch },
                "the local base did not recover the create: \(listed)")
        #expect(FileManager.default.fileExists(atPath: created.localPath),
                "the create reported success without a checkout at \(created.localPath)")

        // Exactly the branch the create started with — a fresh name would show
        // up here as a second `tbd/…`, and an uncleaned attempt 1 as a leftover.
        let branches = try await localBranches(repoDir)
        #expect(branches.filter { $0.hasPrefix("tbd/") } == [created.branch],
                "the recovery burned a second name or leaked a branch: \(branches)")
    }

    /// The second verified shape of the same thing, and the one that regressed
    /// outright: a local branch literally named `origin/main` makes base 1 fatal
    /// on `fatal: ambiguous object name: 'origin/main'` — creating nothing at
    /// all, so there is not even a branch to clean up — while base 2 resolves
    /// the unambiguous local `main` and succeeds.
    ///
    /// Distinct from the config-lock shape above because its stderr is a
    /// *reference* complaint that the base-unresolvable whitelist deliberately
    /// does not match ("ambiguous object name" is not "not a valid object
    /// name"), so it lands in `.repoLevel` and depends on that case continuing.
    @Test func aShadowingLocalBranchStillResolvesOnTheLocalBase() async throws {
        let (parentDir, hostDir, repoDir) = try await makeClonedTestRepo()
        defer { try? FileManager.default.removeItem(at: parentDir) }
        try await shell("git branch origin/main", at: repoDir)

        let db = try TBDDatabase(inMemory: true)
        let lifecycle = makeLifecycle(db: db)
        let repo = try await makeTestRepo(db: db, tempDir: hostDir, repoDir: repoDir)

        let created = try await lifecycle.createWorktree(repoID: repo.id, skipClaude: true)

        let listed = try await GitManager().worktreeList(repoPath: repoDir.path)
        #expect(listed.contains { $0.branch == created.branch },
                "the local base did not resolve past the shadowing branch: \(listed)")
        let branches = try await localBranches(repoDir)
        #expect(branches.filter { $0.hasPrefix("tbd/") } == [created.branch],
                "the recovery burned a second name or leaked a branch: \(branches)")
    }

    /// Once BOTH bases hit the same repo-level cause the create is over: git's
    /// own words reach the user, with the one hint they can act on.
    ///
    /// Asserts preserved behavior, so it is mutation-checked: deleting the
    /// `.repoLevel` fast-exit from both loops drops the create through to the
    /// generic "after all attempts" message, which carries no
    /// `.git/config.lock` hint.
    @Test func repoLevelFailureOnBothBasesSurfacesGitStderr() async throws {
        let (parentDir, hostDir, repoDir) = try await makeClonedTestRepo()
        defer { try? FileManager.default.removeItem(at: parentDir) }
        try await jamConfigLock(repoDir, includingTheLocalBase: true)

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

    /// A fresh name genuinely cannot help a repo-level cause, so spending the
    /// other base must not turn into spending a second name too.
    ///
    /// The read-only worktree base is chosen over a jammed config lock because
    /// it makes the answer *directly* observable: git names the path it could
    /// not create, so the surfaced message says which folder the create died
    /// on. A jammed lock cannot settle this — its stderr names no folder, and
    /// the retry leg's own `.repoLevel` exit produces a byte-identical message,
    /// so both outcomes read the same.
    ///
    /// Preserved behavior, so it is mutation-checked: deleting the FIRST loop's
    /// post-loop `.repoLevel` throw makes the create generate a second folder
    /// and branch, and the reported path becomes that second folder's.
    @Test func repoLevelFailureOnBothBasesKeepsTheOriginalName() async throws {
        let (parentDir, hostDir, repoDir) = try await makeClonedTestRepo()
        defer { try? FileManager.default.removeItem(at: parentDir) }

        let db = try TBDDatabase(inMemory: true)
        let lifecycle = makeLifecycle(db: db)
        let repo = try await makeTestRepo(db: db, tempDir: hostDir, repoDir: repoDir)

        let pending = try await lifecycle.beginCreateWorktree(repoID: repo.id, skipClaude: true)
        let base = WorktreeLayout().basePath(for: repo)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o555], ofItemAtPath: base
        )
        // Registered after the temp-dir cleanup above, so it runs BEFORE it —
        // a read-only directory cannot be emptied.
        defer {
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o755], ofItemAtPath: base
            )
        }

        do {
            _ = try await lifecycle.completeCreateWorktree(
                worktreeID: pending.id, skipClaude: true
            )
            Issue.record("expected the read-only worktree base to fail the create")
        } catch {
            let text = String(describing: error)
            #expect(text.contains("could not create leading directories"),
                    "the real cause was masked: \(text)")
            // The folder git died on is the one the create started with. A
            // fresh name would put a different folder in this message.
            #expect(text.contains("/\(pending.name)/.git"),
                    "a second folder name was generated: \(text)")
            // "after all attempts" is produced ONLY by the name-retry leg, so
            // its absence is direct evidence that no second folder/branch name
            // was generated for a cause no name can fix.
            #expect(!text.contains("after all attempts"),
                    "a second name was attempted for a repo-level failure: \(text)")
            #expect(!text.contains("already exists"),
                    "a second name was attempted and collided: \(text)")
        }

        // Both attempts created `tbd/<name>` before dying on the mkdir, and both
        // were cleaned up.
        let branches = try await localBranches(repoDir)
        #expect(branches.filter { $0.hasPrefix("tbd/") }.isEmpty,
                "a repo-level failure leaked branches: \(branches)")
        let survivors = (try? FileManager.default.contentsOfDirectory(atPath: base)) ?? []
        #expect(survivors.isEmpty, "second name left a directory: \(survivors)")
    }

    /// The other side of that split. A failure git never reported — the
    /// subprocess timed out or could not be spawned — says nothing about the
    /// base, and buying a second opinion costs another full
    /// `GitManager.commandTimeout` (120 s in production), so it fails fast where
    /// `.repoLevel` continues.
    ///
    /// Driven end to end through a real killed `git worktree add`: the
    /// lifecycle's own `GitManager` carries a 1 ms subprocess timeout, which no
    /// fork+exec of git survives. The message is what discriminates the branch —
    /// only the `.gitUnusable` arm says "did not complete", while every
    /// `.repoLevel` exit says "git worktree add failed" — so classifying a
    /// non-`GitError` as `.repoLevel` again fails this test.
    @Test func aTimedOutGitFailsFastInsteadOfSpendingTheOtherBase() async throws {
        let (parentDir, hostDir, repoDir) = try await makeClonedTestRepo()
        defer { try? FileManager.default.removeItem(at: parentDir) }

        let db = try TBDDatabase(inMemory: true)
        let lifecycle = WorktreeLifecycle(
            db: db,
            git: GitManager(subprocessTimeout: .milliseconds(1)),
            tmux: TmuxManager(dryRun: true),
            hooks: HookResolver()
        )
        let repo = try await makeTestRepo(db: db, tempDir: hostDir, repoDir: repoDir)

        do {
            _ = try await lifecycle.createWorktree(repoID: repo.id, skipClaude: true)
            Issue.record("expected a timed-out git subprocess to fail the create")
        } catch {
            let text = String(describing: error)
            #expect(text.contains("did not complete"),
                    "a timeout was reported as an ordinary git failure: \(text)")
            #expect(text.contains("timed out after"),
                    "the timeout's own words did not reach the user: \(text)")
            #expect(!text.contains("after all attempts"),
                    "a second name was attempted for a wedged git: \(text)")
        }

        let branches = try await localBranches(repoDir)
        #expect(branches.filter { $0.hasPrefix("tbd/") }.isEmpty,
                "a timed-out attempt leaked a branch: \(branches)")
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
            // Both bases, in the order they were tried. Asserting the joined
            // list rather than each name separately: "origin/no-such-base"
            // contains "no-such-base", so a per-name check would pass on a
            // message that named only the remote one.
            #expect(text.contains("tried origin/no-such-base, no-such-base"),
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
        try occupy(pending.localPath)

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
        try occupy(pending.localPath)

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

    // MARK: - The existing-branch flow leaks the same way

    /// `--track -b <local> <path> origin/<name>` has the same shape as the
    /// fresh-create path: git creates the local branch, then writes upstream
    /// tracking configuration, and a jammed `.git/config.lock` fails only the
    /// second half. Reproduced by hand against git 2.50:
    /// `git worktree add --track -b tracked ../wt origin/tracked` leaves
    /// `tracked` standing and creates no directory.
    @Test func failedTrackingCheckoutLeavesNoBranchBehind() async throws {
        let (parentDir, hostDir, repoDir) = try await makeClonedTestRepo(
            remoteOnlyBranches: ["feature"]
        )
        defer { try? FileManager.default.removeItem(at: parentDir) }
        try await jamConfigLock(repoDir)

        let db = try TBDDatabase(inMemory: true)
        let lifecycle = makeLifecycle(db: db)
        let repo = try await makeTestRepo(db: db, tempDir: hostDir, repoDir: repoDir)

        await #expect(throws: WorktreeLifecycleError.self) {
            _ = try await lifecycle.createWorktree(
                repoID: repo.id, branch: "origin/feature", skipClaude: true,
                useExistingBranch: true
            )
        }

        let branches = try await localBranches(repoDir)
        #expect(!branches.contains("feature"),
                "the tracking checkout leaked the branch it created: \(branches)")
    }

    /// The fork-PR leg creates a fresh local branch of its own (the fetch's
    /// `+refs/pull/<n>/head:refs/heads/<name>` refspec), so a failure in the
    /// checkout that follows leaks it just the same. The name comes from
    /// `uniqueLocalBranchName`, so it is never one the caller brought.
    @Test func failedPullRequestCheckoutLeavesNoBranchBehind() async throws {
        let (parentDir, hostDir, repoDir) = try await makeClonedTestRepo(
            pullRequestHeads: [7]
        )
        defer { try? FileManager.default.removeItem(at: parentDir) }

        let db = try TBDDatabase(inMemory: true)
        let lifecycle = makeLifecycle(db: db)
        let repo = try await makeTestRepo(db: db, tempDir: hostDir, repoDir: repoDir)

        let pending = try await lifecycle.beginCreateWorktree(
            repoID: repo.id, branch: "pr-7", skipClaude: true,
            useExistingBranch: true, prNumber: 7
        )
        // Fail the checkout that follows the fetch, so the failure lands with
        // the fetched branch already created.
        try occupy(pending.localPath)

        await #expect(throws: WorktreeLifecycleError.self) {
            _ = try await lifecycle.completeCreateWorktree(
                worktreeID: pending.id, skipClaude: true,
                existingBranchRef: "pr-7", checkoutPRHead: true
            )
        }

        let branches = try await localBranches(repoDir)
        #expect(!branches.contains("pr-7"),
                "the PR-head checkout leaked the branch it fetched: \(branches)")
    }

    /// The third leg of the same `catch` creates NOTHING — it checks out a
    /// branch the caller owns — so it must delete nothing. The hard constraint
    /// of this fix, and the one whose failure destroys a user's work.
    ///
    /// Not red against the unfixed tree, which deletes no branches on this path
    /// at all; it is mutation-checked instead: routing this leg's failure
    /// through `cleanUpFailedWorktreeAdd(branchPreExisted: false,
    /// branchNameWasAlreadyTaken: false)` — treating all three legs alike —
    /// makes it fail.
    @Test func failedExistingBranchCheckoutKeepsTheCallersBranch() async throws {
        let (tempDir, repoDir) = try await createTestRepo()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        try await shell("git branch owned-by-caller", at: repoDir)

        let db = try TBDDatabase(inMemory: true)
        let lifecycle = makeLifecycle(db: db)
        let repo = try await makeTestRepo(db: db, tempDir: tempDir, repoDir: repoDir)

        let pending = try await lifecycle.beginCreateWorktree(
            repoID: repo.id, branch: "owned-by-caller", skipClaude: true,
            useExistingBranch: true
        )
        try occupy(pending.localPath)

        await #expect(throws: WorktreeLifecycleError.self) {
            _ = try await lifecycle.completeCreateWorktree(
                worktreeID: pending.id, skipClaude: true,
                existingBranchRef: "owned-by-caller"
            )
        }

        let branches = try await localBranches(repoDir)
        #expect(branches.contains("owned-by-caller"),
                "the existing-branch checkout deleted the caller's branch: \(branches)")
    }

    // MARK: - Bug 2, continued: don't retry what the retry keeps

    /// A user-specified branch is carried across the folder-rename retry
    /// unchanged, so when the BRANCH NAME is what stands in the way the retry
    /// re-attempts it against both bases and fails identically twice, ending on
    /// the generic "after all attempts".
    ///
    /// Reached without a race by putting the main checkout on an unborn orphan
    /// branch: `refs/heads/pending` does not exist — so the pre-existence probe
    /// answers "absent" and the check-out-the-existing-branch path is skipped —
    /// while git still reports the name as used by that worktree. Verified
    /// against git 2.50: attempt 1 says "'pending' is already used by worktree
    /// at …", and every later attempt says "a branch named 'pending' already
    /// exists".
    @Test func aTakenBranchNameFailsFastInsteadOfRetryingTheSameName() async throws {
        let (parentDir, hostDir, repoDir) = try await makeClonedTestRepo()
        defer { try? FileManager.default.removeItem(at: parentDir) }
        try await shell("git checkout --orphan pending", at: repoDir)

        let db = try TBDDatabase(inMemory: true)
        let lifecycle = makeLifecycle(db: db)
        let repo = try await makeTestRepo(db: db, tempDir: hostDir, repoDir: repoDir)

        do {
            _ = try await lifecycle.createWorktree(
                repoID: repo.id, branch: "pending", skipClaude: true
            )
            Issue.record("expected a taken branch name to fail the create")
        } catch {
            let text = String(describing: error)
            #expect(text.contains("could not create branch 'pending'"),
                    "the collision was not attributed to the branch name: \(text)")
            #expect(!text.contains("after all attempts"),
                    "the same branch name was retried under a fresh folder: \(text)")
        }

        let base = WorktreeLayout().basePath(for: repo)
        let survivors = (try? FileManager.default.contentsOfDirectory(atPath: base)) ?? []
        #expect(survivors.isEmpty, "failed create left worktree directories: \(survivors)")
    }

    /// The other arm of that gate: when the FOLDER is what collided, a fresh
    /// folder is exactly the remedy — even though git reports it as an
    /// "already exists" collision too. Widening the fast-fail to the whole
    /// `.nameCollision` classification passes the test above and breaks this
    /// one, which is the mutation it is here to catch.
    @Test func aTakenFolderStillRetriesKeepingTheCallersBranch() async throws {
        let (parentDir, hostDir, repoDir) = try await makeClonedTestRepo()
        defer { try? FileManager.default.removeItem(at: parentDir) }

        let db = try TBDDatabase(inMemory: true)
        let lifecycle = makeLifecycle(db: db)
        let repo = try await makeTestRepo(db: db, tempDir: hostDir, repoDir: repoDir)

        // A cloned repo so `origin/main` resolves and the FIRST attempt is the
        // one that trips over the occupied path (see the occupied-path test
        // above for why an origin-less repo dissolves the setup).
        let pending = try await lifecycle.beginCreateWorktree(
            repoID: repo.id, branch: "mine", skipClaude: true
        )
        try occupy(pending.localPath)

        let completion = try await lifecycle.completeCreateWorktree(
            worktreeID: pending.id, skipClaude: true, userSpecifiedBranch: true
        )
        if case .preSessionPending(let phase3) = completion {
            await phase3.value
        }

        let listed = try await GitManager().worktreeList(repoPath: repoDir.path)
        #expect(listed.contains { $0.branch == "mine" },
                "the retry never happened for an occupied folder: \(listed)")
    }

    // MARK: - The retry leg's own fail-fast guard

    /// Every other test here jams the repo before the FIRST attempt, so the
    /// first loop always throws and the retry leg's copy of the `.repoLevel`
    /// handling never runs. This one reaches it: the canonical folder is
    /// occupied (attempt 1 → collision → out of the first loop) and the worktree
    /// base directory is read-only, so the retry's fresh folder gets past the
    /// existence check and dies creating its directory — on both of the retry
    /// leg's own bases, since a read-only parent is not something a base ref
    /// changes.
    ///
    /// Asserts preserved behavior rather than a fix, so it is mutation-checked:
    /// deleting the retry loop's post-loop `.repoLevel` throw makes it report
    /// the generic "after all attempts" instead of git's own words.
    @Test func repoLevelFailureInsideTheRetryLegAlsoFailsFast() async throws {
        let (parentDir, hostDir, repoDir) = try await makeClonedTestRepo()
        defer { try? FileManager.default.removeItem(at: parentDir) }

        let db = try TBDDatabase(inMemory: true)
        let lifecycle = makeLifecycle(db: db)
        let repo = try await makeTestRepo(db: db, tempDir: hostDir, repoDir: repoDir)

        let pending = try await lifecycle.beginCreateWorktree(repoID: repo.id, skipClaude: true)
        try occupy(pending.localPath)

        let base = WorktreeLayout().basePath(for: repo)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o555], ofItemAtPath: base
        )
        // Registered after the temp-dir cleanup above, so it runs BEFORE it —
        // a read-only directory cannot be emptied.
        defer {
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o755], ofItemAtPath: base
            )
        }

        do {
            _ = try await lifecycle.completeCreateWorktree(
                worktreeID: pending.id, skipClaude: true
            )
            Issue.record("expected the read-only worktree base to fail the create")
        } catch {
            let text = String(describing: error)
            // Only the retry leg can produce this: attempt 1's path exists, so
            // it fails on the existence check long before any mkdir.
            #expect(text.contains("could not create leading directories"),
                    "the retry leg's real cause was not surfaced: \(text)")
            #expect(!text.contains("after all attempts"),
                    "the retry leg fell through to the generic message: \(text)")
        }

        let branches = try await localBranches(repoDir)
        #expect(branches.filter { $0.hasPrefix("tbd/") }.isEmpty,
                "the retry leg leaked a branch: \(branches)")
    }
}
