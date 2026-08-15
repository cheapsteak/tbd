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

    /// The SHA a local branch currently points at — what a caller hands the
    /// cleanup as the attempt's `expectedTip` when some *other* gate is what
    /// the test means to put under load. Passing the branch's own tip makes
    /// gate 4 hold, so it neither masks nor manufactures the outcome.
    private func tip(of branch: String, in repoDir: URL) async throws -> String {
        try await GitManager().headSHA(repoPath: repoDir.path, ref: "refs/heads/\(branch)")
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

        // Both branches were cut from the same commit this attempt's `-b` would
        // have used, so gate 4 holds for both and git's refusal is the only
        // thing telling them apart. (The case where it does NOT hold — an
        // interloper cut from somewhere else — is
        // `aBranchAtADifferentSHAIsKeptEvenWhenGitsRefusalGoesUnrecognized`.)
        await lifecycle.cleanUpFailedWorktreeAdd(
            repoPath: repoDir.path,
            worktreePath: tempDir.appendingPathComponent("never-created").path,
            attempted: .init(
                name: "appeared-mid-flight", preExisted: false,
                expectedTip: try await tip(of: "appeared-mid-flight", in: repoDir)
            ),
            branchNameWasAlreadyTaken: true
        )
        await lifecycle.cleanUpFailedWorktreeAdd(
            repoPath: repoDir.path,
            worktreePath: tempDir.appendingPathComponent("never-created").path,
            attempted: .init(
                name: "ours-to-clean-up", preExisted: false,
                expectedTip: try await tip(of: "ours-to-clean-up", in: repoDir)
            ),
            branchNameWasAlreadyTaken: false
        )

        let branches = try await localBranches(repoDir)
        #expect(branches.contains("appeared-mid-flight"),
                "cleanup deleted a branch git had refused to create: \(branches)")
        #expect(!branches.contains("ours-to-clean-up"),
                "cleanup left behind a branch it did create: \(branches)")
    }

    // MARK: - Gate 4: the branch must point where this attempt would have put it

    /// The gate that does not read git's stderr, and the one case that needs
    /// it. Every other signal here is either sampled before the attempt
    /// (`preExisted`) or a phrase match (`branchNameWasAlreadyTaken`), so a
    /// branch that appears in the probe→attempt window under a refusal this
    /// build does not recognize — a future git, a non-standard build, a wrapper
    /// reformatting stderr — arrives at the cleanup looking exactly like a
    /// branch we made. Where it *points* is what tells them apart: an
    /// interloper chose its own starting commit.
    ///
    /// Both arms, because a gate that only ever blocks is a synonym for "never
    /// clean up": the branch cut from this attempt's own base is still deleted.
    ///
    /// Red against the tree before gate 4 existed, on the surviving arm:
    ///   ✘ Expectation failed: (branches → ["main"]).contains("theirs-from-elsewhere")
    @Test func aBranchAtADifferentSHAIsKeptEvenWhenGitsRefusalGoesUnrecognized() async throws {
        let (tempDir, repoDir) = try await createTestRepo()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let db = try TBDDatabase(inMemory: true)
        let lifecycle = makeLifecycle(db: db)
        let baseTip = try await tip(of: "main", in: repoDir)

        // What this attempt's `-b <branch> main` would have produced.
        try await shell("git branch ours-from-the-base", at: repoDir)
        // Somebody else's, carrying a commit the base does not have.
        try await shell(
            "git checkout -q -b theirs-from-elsewhere && git commit -q --allow-empty -m theirs"
            + " && git checkout -q main",
            at: repoDir
        )

        let neverCreated = tempDir.appendingPathComponent("never-created").path
        for branch in ["theirs-from-elsewhere", "ours-from-the-base"] {
            await lifecycle.cleanUpFailedWorktreeAdd(
                repoPath: repoDir.path,
                worktreePath: neverCreated,
                attempted: .init(name: branch, preExisted: false, expectedTip: baseTip),
                // The whole premise: git's refusal went unrecognized, so gate 1
                // abstains and every other gate reads as "this attempt made it".
                branchNameWasAlreadyTaken: false
            )
        }

        let branches = try await localBranches(repoDir)
        #expect(branches.contains("theirs-from-elsewhere"),
                "cleanup deleted a branch that does not point where this attempt would have put it: \(branches)")
        #expect(!branches.contains("ours-from-the-base"),
                "cleanup left behind the branch this attempt's own base produced: \(branches)")
    }

    /// The unresolvable arm. A base ref that does not resolve, a `rev-parse`
    /// that could not run — the attempt cannot say where it would have put the
    /// branch, and an answer we do not have is never a licence to delete a ref.
    ///
    /// Red against the tree before gate 4 existed:
    ///   ✘ Expectation failed: (branches → ["main"]).contains("expected-tip-unknown")
    @Test func anUnresolvableExpectedTipNeverDeletes() async throws {
        let (tempDir, repoDir) = try await createTestRepo()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let db = try TBDDatabase(inMemory: true)
        let lifecycle = makeLifecycle(db: db)
        try await shell("git branch expected-tip-unknown", at: repoDir)

        await lifecycle.cleanUpFailedWorktreeAdd(
            repoPath: repoDir.path,
            worktreePath: tempDir.appendingPathComponent("never-created").path,
            // Every other gate says "delete"; only the missing tip stands in
            // the way.
            attempted: .init(
                name: "expected-tip-unknown", preExisted: false, expectedTip: nil
            ),
            branchNameWasAlreadyTaken: false
        )

        let branches = try await localBranches(repoDir)
        #expect(branches.contains("expected-tip-unknown"),
                "cleanup deleted a branch with no expected tip to compare against: \(branches)")
    }

    /// The unreadable arm: git cannot produce a tip it will vouch for. Driven
    /// with a ref whose file names an object that is not in the repository —
    /// what a truncated fetch or a hand-edited ref leaves — so `show-ref
    /// --verify` answers `fatal: bad ref` (exit 128, which `localBranchExists`
    /// rethrows rather than reading as "absent") while `rev-parse` cheerfully
    /// echoes the recorded SHA back.
    ///
    /// It pins gates 3 and 4 together rather than gate 4 alone, and that is a
    /// property of git, not a shortcut: the two reads see the same refs through
    /// the same launcher, and no repository state satisfies one while failing
    /// the other (both directions were tried against git 2.50 — a dangling ref
    /// fails only `show-ref`, a dangling symref fails both). What *is* worth
    /// asserting is the property they share: an answer git could not give never
    /// authorizes a delete.
    ///
    /// Deliberately not driven by a wedged git (a 1 ms subprocess timeout, as
    /// the timeout test above uses). That fixture proves nothing here, because
    /// the `branch -D` at the end of this path is a git subprocess too — it
    /// would fail whether or not the gates blocked, and the test would pass
    /// against any implementation at all.
    ///
    /// Asserts preserved behavior, so it is mutation-checked: making the
    /// unknowns in the read path permissive (`!= false` on the existence probe,
    /// `?? expectedTip` on the tip read) deletes `unvouched-ref` — `git branch
    /// -D` removes a dangling ref quite happily, which is what keeps this
    /// fixture honest.
    @Test func aRefGitCannotVouchForIsNeverDeleted() async throws {
        let (tempDir, repoDir) = try await createTestRepo()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let db = try TBDDatabase(inMemory: true)
        let lifecycle = makeLifecycle(db: db)

        // A syntactically valid object name that no object answers to.
        let absentObject = "0000000000000000000000000000000000000001"
        let refPath = repoDir.appendingPathComponent(".git/refs/heads/unvouched-ref").path
        try Data("\(absentObject)\n".utf8).write(to: URL(fileURLWithPath: refPath))

        await lifecycle.cleanUpFailedWorktreeAdd(
            repoPath: repoDir.path,
            worktreePath: tempDir.appendingPathComponent("never-created").path,
            // The SHA the ref records, so a cleanup that trusted what it could
            // read would find a match and delete.
            attempted: .init(
                name: "unvouched-ref", preExisted: false, expectedTip: absentObject
            ),
            branchNameWasAlreadyTaken: false
        )

        #expect(FileManager.default.fileExists(atPath: refPath),
                "cleanup deleted a ref git would not vouch for: \(refPath)")
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
            attempted: .init(
                name: "probe-failed", preExisted: nil,
                expectedTip: try await tip(of: "probe-failed", in: repoDir)
            ),
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
    /// `refs/pull/<n>/head:refs/heads/<name>` refspec), so a failure in the
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

    /// The same leg's pre-existence answer must be a *measurement of the name it
    /// is about to fetch into*, not an inherited claim about some other name.
    /// `uniqueLocalBranchName` hands back `pr-7-2` here because `pr-7` is taken,
    /// and the probe that gates the delete has to follow it: aimed at
    /// `worktree.branch` instead it answers `true`, blocks the delete, and leaks
    /// the branch the fetch really did create.
    ///
    /// Asserts preserved behavior — the unfixed tree hardcodes `false`, which
    /// cleans up here too — so it is mutation-checked twice: probing
    /// `worktree.branch` rather than `localBranch`, and hardcoding
    /// `createdBranchPreExisted = true`, each leak `pr-7-2`.
    ///
    /// The caller's `pr-7` standing untouched afterwards is the other half. The
    /// fetch never aimed at it because the uniquifier steered around it, and the
    /// cleanup deleted nothing of the caller's because the probe it ran was
    /// about `pr-7-2`.
    @Test func pullRequestLegProbesTheBranchItFetchesInto() async throws {
        let (parentDir, hostDir, repoDir) = try await makeClonedTestRepo(
            pullRequestHeads: [7]
        )
        defer { try? FileManager.default.removeItem(at: parentDir) }

        let db = try TBDDatabase(inMemory: true)
        let lifecycle = makeLifecycle(db: db)
        let repo = try await makeTestRepo(db: db, tempDir: hostDir, repoDir: repoDir)

        // The caller's own `pr-7`, which pushes the fetch onto `pr-7-2`.
        try await shell("git branch pr-7", at: repoDir)

        let pending = try await lifecycle.beginCreateWorktree(
            repoID: repo.id, branch: "pr-7", skipClaude: true,
            useExistingBranch: true, prNumber: 7
        )
        // Fail the checkout that follows the fetch, so cleanup runs with the
        // fetched branch already created.
        try occupy(pending.localPath)

        await #expect(throws: WorktreeLifecycleError.self) {
            _ = try await lifecycle.completeCreateWorktree(
                worktreeID: pending.id, skipClaude: true,
                existingBranchRef: "pr-7", checkoutPRHead: true
            )
        }

        let branches = try await localBranches(repoDir)
        #expect(!branches.contains("pr-7-2"),
                "the uniquified branch this attempt fetched was not cleaned up: \(branches)")
        #expect(branches.contains("pr-7"),
                "cleanup deleted the branch the caller brought: \(branches)")
    }

    /// Writes a `post-checkout` hook that parks inside `git worktree add` until
    /// the test releases it. Git runs that hook as part of `worktree add`
    /// (verified against git 2.50), which is what makes the interlock below
    /// exact instead of a sleep race: while it is parked, the fetch and the
    /// checkout have both succeeded and nothing after them has run yet.
    ///
    /// Capped at ~60 s so a test that never releases it fails inside
    /// `GitManager.commandTimeout` rather than wedging the run.
    private func installCheckoutBarrier(
        in repoDir: URL, marker: URL, release: URL
    ) throws {
        let script = """
        #!/bin/sh
        : > '\(marker.path)'
        i=0
        while [ ! -e '\(release.path)' ] && [ "$i" -lt 600 ]; do
            sleep 0.1
            i=$((i + 1))
        done
        exit 0
        """
        let hook = repoDir.appendingPathComponent(".git/hooks/post-checkout")
        try script.write(to: hook, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755], ofItemAtPath: hook.path
        )
    }

    /// Bounded poll for a file the code under test creates, with the observed
    /// state in the diagnostic (assertion-hygiene rule 4).
    private func waitForFile(_ url: URL, _ what: String) async {
        let deadline = 300
        for _ in 0..<deadline {
            if FileManager.default.fileExists(atPath: url.path) { return }
            try? await Task.sleep(for: .milliseconds(100))
        }
        Issue.record("\(what): \(url.path) never appeared after polling 30 seconds")
    }

    /// The failure this leg's cleanup must NOT answer: one that arrives *after*
    /// the git work succeeded. The fetch wrote `pr-7-2` and the checkout stands
    /// on disk, so nothing is left over to withdraw — but a successful fetch is
    /// also exactly the state that clears all four of
    /// `cleanUpFailedWorktreeAdd`'s gates, so routing a later failure through it
    /// deletes a correct branch and a correct checkout.
    ///
    /// The failure is induced by deleting the worktree row while the checkout is
    /// parked in a `post-checkout` hook, which is the real shape rather than a
    /// contrivance: `forgetWorktree` deletes that row over RPC with no interlock
    /// against an in-flight create, and `updateBranch` throws on a row that is
    /// gone.
    ///
    /// The create must still fail — the row it was building is gone — but it
    /// must fail leaving the repo exactly as the git work left it.
    @Test func aFailureAfterThePullHeadCheckoutKeepsTheBranchAndTheDirectory() async throws {
        let (parentDir, hostDir, repoDir) = try await makeClonedTestRepo(
            pullRequestHeads: [7]
        )
        defer { try? FileManager.default.removeItem(at: parentDir) }

        let db = try TBDDatabase(inMemory: true)
        let lifecycle = makeLifecycle(db: db)
        let repo = try await makeTestRepo(db: db, tempDir: hostDir, repoDir: repoDir)

        // The caller's own `pr-7` pushes the fetch onto `pr-7-2`, which is what
        // makes the create reach the `updateBranch` write that records it.
        try await shell("git branch pr-7", at: repoDir)

        let pending = try await lifecycle.beginCreateWorktree(
            repoID: repo.id, branch: "pr-7", skipClaude: true,
            useExistingBranch: true, prNumber: 7
        )

        let marker = parentDir.appendingPathComponent("checkout-parked")
        let release = parentDir.appendingPathComponent("resume-checkout")
        try installCheckoutBarrier(in: repoDir, marker: marker, release: release)

        let forget = Task {
            await self.waitForFile(marker, "the post-checkout barrier never armed")
            try? await db.worktrees.delete(id: pending.id)
            FileManager.default.createFile(atPath: release.path, contents: nil)
        }

        var thrown: Error?
        do {
            _ = try await lifecycle.completeCreateWorktree(
                worktreeID: pending.id, skipClaude: true,
                existingBranchRef: "pr-7", checkoutPRHead: true
            )
        } catch {
            thrown = error
        }
        await forget.value

        #expect(thrown != nil,
                "the create reported success after its own row was deleted")
        let branches = try await localBranches(repoDir)
        #expect(branches.contains("pr-7-2"),
                "a failure after the checkout deleted the branch the fetch correctly created: \(branches)")
        #expect(branches.contains("pr-7"),
                "the caller's own branch did not survive: \(branches)")
        #expect(FileManager.default.fileExists(atPath: pending.localPath),
                "a failure after the checkout deleted the working tree at \(pending.localPath)")
    }

    /// The two arms of that tri-state which *block* the delete, driven at the
    /// cleanup boundary because neither is reachable end to end on this leg:
    /// `true` needs a branch to appear inside the gap between the probe and the
    /// fetch's ref write, and `nil` needs the probe to fail in that same gap
    /// after `uniqueLocalBranchName`'s identical probe had just succeeded.
    ///
    /// `branchNameWasAlreadyTaken` is pinned `false` in all three cases so the
    /// probe is the only thing under test; the other gate has its own coverage
    /// in `aRefusedPullRequestFetchKeepsTheBranchItDidNotCreate`. All three arms
    /// are asserted — `false` must still delete, or the gate would just be a
    /// synonym for "never clean up".
    ///
    /// Asserts preserved cleanup behavior, so it is mutation-checked: dropping
    /// the `branchPreExisted == false` guard in `cleanUpFailedWorktreeAdd`
    /// deletes both branches this test expects to survive.
    @Test func aPullRequestBranchTheFetchDidNotCreateIsNeverDeleted() async throws {
        let (tempDir, repoDir) = try await createTestRepo()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let db = try TBDDatabase(inMemory: true)
        let lifecycle = makeLifecycle(db: db)
        try await shell("git branch already-standing", at: repoDir)
        try await shell("git branch probe-did-not-answer", at: repoDir)
        try await shell("git branch fetched-by-this-attempt", at: repoDir)

        let neverCreated = tempDir.appendingPathComponent("never-created").path
        for (branch, preExisted) in [
            ("already-standing", true), ("probe-did-not-answer", nil), ("fetched-by-this-attempt", false),
        ] as [(String, Bool?)] {
            await lifecycle.cleanUpFailedWorktreeAdd(
                repoPath: repoDir.path,
                worktreePath: neverCreated,
                // Each branch's own tip, so gate 4 holds and the probe is the
                // only thing under test.
                attempted: .init(
                    name: branch, preExisted: preExisted,
                    expectedTip: try await tip(of: branch, in: repoDir)
                ),
                branchNameWasAlreadyTaken: false
            )
        }

        let branches = try await localBranches(repoDir)
        #expect(branches.contains("already-standing"),
                "cleanup deleted a branch that was standing before the fetch: \(branches)")
        #expect(branches.contains("probe-did-not-answer"),
                "cleanup deleted a branch whose pre-existence was unknown: \(branches)")
        #expect(!branches.contains("fetched-by-this-attempt"),
                "cleanup left behind the branch the fetch created: \(branches)")
    }

    /// Runs `body`, expecting it to fail with a `GitError`, and hands back
    /// git's own error. Real stderr is the point: these tests exist to pin what
    /// `gitRefusedToCreateBranch` reads, and a hand-written string would pin
    /// only the test author's memory of it.
    private func gitErrorFrom(
        _ what: String, _ body: () async throws -> Void
    ) async throws -> GitError {
        do {
            try await body()
        } catch let error as GitError {
            return error
        }
        Issue.record("\(what) was expected to fail with a GitError and did not")
        throw CancellationError()
    }

    /// Gate 1 on the fork-PR leg, which is the whole reason the fetch refspec is
    /// unforced. A branch that appears in the window between the probe and the
    /// fetch's ref write is invisible to the probe — `branchPreExisted` is
    /// `false`, the arm that authorizes deletion — so git's refusal is the only
    /// thing standing between that branch and `branch -D`.
    ///
    /// Red against a `+`-forced refspec twice over: the fetch succeeds, so there
    /// is no refusal to read, and the branch is already rewritten by the time
    /// cleanup runs.
    @Test func aRefusedPullRequestFetchKeepsTheBranchItDidNotCreate() async throws {
        let (parentDir, _, repoDir) = try await makeClonedTestRepo(pullRequestHeads: [7])
        defer { try? FileManager.default.removeItem(at: parentDir) }

        let db = try TBDDatabase(inMemory: true)
        let lifecycle = makeLifecycle(db: db)
        let git = GitManager()

        // Someone else's branch, carrying a commit the pull head does not have,
        // standing under the name this attempt is about to fetch into.
        try await shell(
            "git checkout -q -b raced && git commit --allow-empty -m 'their work'"
            + " && git checkout -q main",
            at: repoDir
        )
        let originalSHA = try await git.headSHA(repoPath: repoDir.path, ref: "refs/heads/raced")

        let refusal = try await gitErrorFrom("the pull-head fetch into an occupied branch name") {
            try await git.fetchPullRequestHead(repoPath: repoDir.path, number: 7, localBranch: "raced")
        }
        #expect(lifecycle.gitRefusedToCreateBranch(refusal),
                "git's refusal was not recognized as one: \(refusal.stderr)")

        await lifecycle.cleanUpFailedWorktreeAdd(
            repoPath: repoDir.path,
            worktreePath: parentDir.appendingPathComponent("never-created").path,
            // The branch's own tip, so gate 4 would permit and git's refusal is
            // the only thing keeping `raced` alive.
            attempted: .init(
                name: "raced", preExisted: false, expectedTip: originalSHA
            ),
            branchNameWasAlreadyTaken: lifecycle.gitRefusedToCreateBranch(refusal)
        )

        let branches = try await localBranches(repoDir)
        #expect(branches.contains("raced"),
                "cleanup deleted a branch git had refused to write: \(branches)")
        let afterSHA = try await git.headSHA(repoPath: repoDir.path, ref: "refs/heads/raced")
        #expect(afterSHA == originalSHA,
                "the refused fetch still moved the branch: \(originalSHA) -> \(afterSHA)")
    }

    /// Every arm of that gate, against stderr git actually produced. Three
    /// phrasings must read as "this attempt did not write the ref", and a
    /// failure about the *path* must not — that one leaves a branch `-b` really
    /// did create, and answering `true` there would resurrect the leak
    /// `cleanUpFailedWorktreeAdd` exists to stop.
    @Test func everyPhrasingOfGitsRefusalToWriteABranchIsRecognized() async throws {
        let (parentDir, _, repoDir) = try await makeClonedTestRepo(pullRequestHeads: [7])
        defer { try? FileManager.default.removeItem(at: parentDir) }

        let db = try TBDDatabase(inMemory: true)
        let lifecycle = makeLifecycle(db: db)
        let git = GitManager()
        let scratch = parentDir.appendingPathComponent("scratch")

        // 1. `worktree add -b <taken>` — "fatal: a branch named 'x' already exists".
        try await shell("git branch taken-branch", at: repoDir)
        let nameTaken = try await gitErrorFrom("worktree add -b onto a taken branch name") {
            try await git.worktreeAdd(
                repoPath: repoDir.path, worktreePath: scratch.appendingPathComponent("a").path,
                branch: "taken-branch", baseBranch: "main"
            )
        }
        #expect(lifecycle.gitRefusedToCreateBranch(nameTaken), "unrecognized: \(nameTaken.stderr)")

        // 2. The fetch's refspec rejection — "! [rejected] … (non-fast-forward)".
        try await shell(
            "git checkout -q -b divergent && git commit --allow-empty -m 'theirs'"
            + " && git checkout -q main",
            at: repoDir
        )
        let rejected = try await gitErrorFrom("the pull-head fetch into a divergent branch") {
            try await git.fetchPullRequestHead(
                repoPath: repoDir.path, number: 7, localBranch: "divergent"
            )
        }
        #expect(lifecycle.gitRefusedToCreateBranch(rejected), "unrecognized: \(rejected.stderr)")

        // 3. The fetch refusing a branch checked out elsewhere — a different
        //    exit code and a different sentence, and (verified against git
        //    2.50) raised whether or not the update would fast-forward.
        try await shell(
            "git worktree add -b checked-out-elsewhere '\(scratch.appendingPathComponent("b").path)' main",
            at: repoDir
        )
        let checkedOut = try await gitErrorFrom("the pull-head fetch into a checked-out branch") {
            try await git.fetchPullRequestHead(
                repoPath: repoDir.path, number: 7, localBranch: "checked-out-elsewhere"
            )
        }
        #expect(lifecycle.gitRefusedToCreateBranch(checkedOut), "unrecognized: \(checkedOut.stderr)")

        // 4. The negative arm: an occupied *path*, where git creates the branch
        //    and then fails. Recognizing this one would leak `made-by-us`.
        let occupied = scratch.appendingPathComponent("c").path
        try occupy(occupied)
        let pathTaken = try await gitErrorFrom("worktree add onto an occupied path") {
            try await git.worktreeAdd(
                repoPath: repoDir.path, worktreePath: occupied,
                branch: "made-by-us", baseBranch: "main"
            )
        }
        #expect(!lifecycle.gitRefusedToCreateBranch(pathTaken),
                "a failure about the path was read as a refusal to write the branch: \(pathTaken.stderr)")

        // And the non-git arm: anything that isn't a `GitError` says nothing
        // about who wrote the ref, so it cannot license a delete either.
        #expect(!lifecycle.gitRefusedToCreateBranch(CancellationError()))
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
        let tipsBefore = try await GitManager().refTips(repoPath: repoDir.path)
        #expect(tipsBefore["pending"] == nil,
                "the unborn-branch setup dissolved — `pending` is a real ref: \(tipsBefore)")

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
            // The premise of everything below: git's stderr carries ONLY the
            // worktree-claim phrasing, which `cleanUpFailedWorktreeAdd`'s first
            // gate deliberately does not match. Were git to say "a branch named
            // …" here instead, that gate would block the delete and this test
            // would be covering a different path than it claims.
            #expect(text.contains("is already used by worktree at"),
                    "git did not report the claim this test exists to cover: \(text)")
            #expect(!text.lowercased().contains("a branch named"),
                    "gate 1 matched, so the delete was blocked before its own gates: \(text)")
        }

        let base = WorktreeLayout().basePath(for: repo)
        let survivors = (try? FileManager.default.contentsOfDirectory(atPath: base)) ?? []
        #expect(survivors.isEmpty, "failed create left worktree directories: \(survivors)")

        // The branch half of the same failure, which the gates above do not
        // guard. `-b` created `refs/heads/pending` at the base tip *before* git
        // discovered the claim, so the ref standing afterwards is this
        // attempt's own — never a branch someone else made. What makes that
        // sound rather than lucky is the phrasing split asserted above:
        // verified against git 2.50, "is already used by worktree at" is
        // reachable only while the ref is absent, because once
        // `refs/heads/pending` exists the same command answers "a branch named
        // 'pending' already exists" instead.
        //
        // It stands rather than being cleaned up because the live main checkout
        // holds it: `git branch -D` answers "cannot delete branch 'pending'
        // used by worktree at …", the cleanup logs that and moves on. The
        // sibling test covers the shape where the delete does go through.
        let tipsAfter = try await GitManager().refTips(repoPath: repoDir.path)
        expectPreExistingRefsSurvived(before: tipsBefore, after: tipsAfter)
        let created = tipsAfter["pending"] ?? "absent"
        let baseTip = tipsBefore["origin/main"] ?? "absent"
        #expect(tipsAfter["pending"] == tipsBefore["origin/main"],
                "`pending` is not the base-tip ref this attempt's `-b` created: \(created) vs base \(baseTip)")
    }

    /// Every ref that predates a failed create must still stand, unchanged.
    /// The whole point of `cleanUpFailedWorktreeAdd`'s gates is that it deletes
    /// only what the attempt itself made.
    private func expectPreExistingRefsSurvived(
        before: [String: String], after: [String: String]
    ) {
        for (name, sha) in before {
            let observed = after[name] ?? "deleted"
            #expect(after[name] == sha,
                    "the failed create disturbed the pre-existing ref \(name): \(observed) (was \(sha))")
        }
    }

    /// The same stderr split, in the shape where the branch delete is not
    /// refused — so what the cleanup deletes, and what it leaves alone, is
    /// directly observable.
    ///
    /// A *stale* registration claims the unborn `pending` (a linked worktree
    /// moved onto an orphan branch, then its directory removed), so `git
    /// worktree add … -b pending origin/main` still fails with "'pending' is
    /// already used by worktree at …" while `refs/heads/pending` does not
    /// exist. All three of `cleanUpFailedWorktreeAdd`'s gates therefore hold,
    /// the prune drops the dead registration, and `git branch -D` succeeds on
    /// the branch `-b` had just created.
    ///
    /// Mutation-checked: widening gate 1 to match "is already used by worktree
    /// at" as well makes the cleanup return early and leaks `pending`.
    @Test func anUnbornBranchClaimDeletesOnlyTheBranchTheAttemptCreated() async throws {
        let (parentDir, hostDir, repoDir) = try await makeClonedTestRepo()
        defer { try? FileManager.default.removeItem(at: parentDir) }

        // A branch off the base tip, so "left alone" is provable against a SHA
        // the failed attempt could not have produced.
        try await shell(
            "git checkout -b keepsake && git commit --allow-empty -m keepsake"
            + " && git checkout main",
            at: repoDir
        )

        let claimer = parentDir.appendingPathComponent("claimer")
        try await shell("git worktree add -b claimed '\(claimer.path)' main", at: repoDir)
        try await shell("git checkout --orphan pending", at: claimer)
        try await shell("git branch -D claimed", at: repoDir)
        // Directory gone, registration kept: git still honours the claim, and
        // the cleanup's prune is what clears it.
        try FileManager.default.removeItem(at: claimer)

        let db = try TBDDatabase(inMemory: true)
        let lifecycle = makeLifecycle(db: db)
        let repo = try await makeTestRepo(db: db, tempDir: hostDir, repoDir: repoDir)
        let tipsBefore = try await GitManager().refTips(repoPath: repoDir.path)
        #expect(tipsBefore["pending"] == nil,
                "the unborn-branch setup dissolved — `pending` is a real ref: \(tipsBefore)")

        do {
            _ = try await lifecycle.createWorktree(
                repoID: repo.id, branch: "pending", skipClaude: true
            )
            Issue.record("expected a claimed branch name to fail the create")
        } catch {
            let text = String(describing: error)
            #expect(text.contains("is already used by worktree at"),
                    "git did not report the claim this test exists to cover: \(text)")
            #expect(!text.lowercased().contains("a branch named"),
                    "gate 1 matched, so the delete was blocked before its own gates: \(text)")
        }

        let tipsAfter = try await GitManager().refTips(repoPath: repoDir.path)
        let leaked = tipsAfter["pending"] ?? "absent"
        #expect(tipsAfter["pending"] == nil,
                "the branch this attempt's `-b` created leaked: pending → \(leaked)")
        expectPreExistingRefsSurvived(before: tipsBefore, after: tipsAfter)

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
