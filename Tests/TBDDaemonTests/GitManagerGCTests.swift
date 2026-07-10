import Testing
import Foundation
@testable import TBDDaemonLib
import TestSupport

/// Resolves symlinks in a path the same way git's `worktree list --porcelain`
/// does: `URL.resolvingSymlinksInPath()` does NOT follow macOS's
/// `/var` → `/private/var` symlink, but C `realpath()` does. Test fixtures
/// must canonicalize before comparing against GitManager output.
private func canonicalPath(_ path: String) -> String {
    guard let cReal = realpath(path, nil) else { return path }
    defer { free(cReal) }
    return String(cString: cReal)
}

@Suite("GitManager GC primitives")
struct GitManagerGCTests {
    @Test func detailedListParsesLockAndDetached() async throws {
        let (tmp, repo, wt, branch) = try await makeRepoWithExternalWorktree(branch: "feat", folder: "wt1")
        defer { try? FileManager.default.removeItem(at: tmp) }

        try await shell("git worktree lock '\(wt)'", at: repo)

        let entries = try await GitManager().worktreeListDetailed(repoPath: repo.path)
        let entry = try #require(entries.first { $0.path == wt })
        #expect(entry.locked == true)
        #expect(entry.branch == branch)
        #expect(entry.headSHA.count == 40)

        // The main worktree (repo root) should be present, unlocked, not detached.
        let mainEntry = try #require(entries.first { $0.path == canonicalPath(repo.path) })
        #expect(mainEntry.locked == false)
    }

    @Test func detailedListParsesDetachedHead() async throws {
        let (tmp, repo, wt, _) = try await makeRepoWithExternalWorktree(branch: "feat2", folder: "wt2")
        defer { try? FileManager.default.removeItem(at: tmp) }

        try await shell("git checkout --detach", at: URL(fileURLWithPath: wt))

        let entries = try await GitManager().worktreeListDetailed(repoPath: repo.path)
        let entry = try #require(entries.first { $0.path == wt })
        #expect(entry.branch == nil)
        #expect(entry.locked == false)
    }

    @Test func linkageProofAcceptsRealWorktreeRejectsRepoRootAndPlainDir() async throws {
        let (tmp, repo, wt, _) = try await makeRepoWithExternalWorktree(branch: "feat3", folder: "wt3")
        defer { try? FileManager.default.removeItem(at: tmp) }

        let git = GitManager()

        // Real linked worktree: accepted.
        let linked = await git.isLinkedWorktree(candidatePath: wt, repoPath: repo.path)
        #expect(linked == true)

        // Repo root itself (its .git is a directory, not a gitdir-file): rejected.
        let repoRootLinked = await git.isLinkedWorktree(candidatePath: repo.path, repoPath: repo.path)
        #expect(repoRootLinked == false)

        // Plain directory with no .git at all: rejected.
        let plainDir = tmp.appendingPathComponent("plain-dir")
        try FileManager.default.createDirectory(at: plainDir, withIntermediateDirectories: true)
        let plainLinked = await git.isLinkedWorktree(candidatePath: plainDir.path, repoPath: repo.path)
        #expect(plainLinked == false)
    }

    @Test func dirtyDetectsUntrackedAndErrorsAreDirty() async throws {
        let (tmp, repo) = try await createTestRepoResolvingSymlinks()
        defer { try? FileManager.default.removeItem(at: tmp) }

        let git = GitManager()

        // Clean repo right after init: not dirty.
        #expect(await git.isDirty(worktreePath: repo.path) == false)

        // Untracked file makes it dirty.
        try await shell("echo dirty > untracked.txt", at: repo)
        #expect(await git.isDirty(worktreePath: repo.path) == true)

        // A path that isn't a git repo at all => `status --porcelain` errors => dirty (fail toward keep).
        let notARepo = tmp.appendingPathComponent("not-a-repo")
        try FileManager.default.createDirectory(at: notARepo, withIntermediateDirectories: true)
        #expect(await git.isDirty(worktreePath: notARepo.path) == true)
    }

    @Test func snapshotPlumbingRoundTrip() async throws {
        let (tmp, repo, wt, _) = try await makeRepoWithExternalWorktree(branch: "snap", folder: "snapwt")
        defer { try? FileManager.default.removeItem(at: tmp) }

        let git = GitManager()
        let wtURL = URL(fileURLWithPath: wt)

        // Tracked change.
        try await shell("echo tracked-change > tracked.txt && git add tracked.txt && git commit -m 'add tracked'", at: wtURL)
        try await shell("echo tracked-modified > tracked.txt", at: wtURL)
        // Untracked file that should be captured by `add -A`.
        try await shell("echo untracked-content > untracked.txt", at: wtURL)
        // Gitignored file that should NOT be captured.
        try await shell("echo ignored-content > ignored.txt && echo ignored.txt > .gitignore", at: wtURL)

        let parent = try await git.headSHA(worktreePath: wt)
        let tree = try await git.stageAllAndWriteTree(worktreePath: wt)
        let commitSHA = try await git.commitTree(repoPath: repo.path, tree: tree, parent: parent, message: "tbd-snapshot")

        let ref = "refs/tbd/snapshots/t1"
        try await git.updateRef(repoPath: repo.path, ref: ref, sha: commitSHA)

        let refs = try await git.listRefs(repoPath: repo.path, prefix: "refs/tbd/snapshots")
        #expect(refs.contains(ref))

        // ls-tree the snapshot ref: untracked file present, ignored file absent.
        let lsTreeOutput = try await runGit(["ls-tree", "-r", "--name-only", ref], at: repo)
        #expect(lsTreeOutput.contains("untracked.txt"))
        #expect(lsTreeOutput.contains("tracked.txt"))
        #expect(!lsTreeOutput.contains("ignored.txt"))

        // Restore into a fresh worktree from main and verify contents.
        let freshWt = tmp.appendingPathComponent("fresh-wt").path
        try await git.worktreeAdd(repoPath: repo.path, path: freshWt, branch: nil, detachAt: parent)
        try await git.restoreFromRef(worktreePath: freshWt, ref: ref)

        let restoredTracked = try String(contentsOfFile: freshWt + "/tracked.txt", encoding: .utf8)
        let restoredUntracked = try String(contentsOfFile: freshWt + "/untracked.txt", encoding: .utf8)
        #expect(restoredTracked.trimmingCharacters(in: .whitespacesAndNewlines) == "tracked-modified")
        #expect(restoredUntracked.trimmingCharacters(in: .whitespacesAndNewlines) == "untracked-content")
        #expect(!FileManager.default.fileExists(atPath: freshWt + "/ignored.txt"))

        try await git.deleteRef(repoPath: repo.path, ref: ref)
        let refsAfterDelete = try await git.listRefs(repoPath: repo.path, prefix: "refs/tbd/snapshots")
        #expect(!refsAfterDelete.contains(ref))
    }

    @Test func reachability() async throws {
        let (tmp, repo) = try await createTestRepoResolvingSymlinks()
        defer { try? FileManager.default.removeItem(at: tmp) }

        let git = GitManager()

        // HEAD on the default branch: reachable.
        let headSHA = try await git.headSHA(repoPath: repo.path)
        #expect(await git.isReachableFromAnyBranch(repoPath: repo.path, sha: headSHA) == true)

        // A commit reachable only via a detached-HEAD commit (no branch points at it): not reachable.
        try await shell("echo orphan > orphan.txt && git add orphan.txt && git commit -m orphan", at: repo)
        let orphanSHA = try await git.headSHA(repoPath: repo.path)
        // Reset the branch back so orphanSHA is no longer reachable from any branch tip.
        try await shell("git reset --hard HEAD~1", at: repo)

        #expect(await git.isReachableFromAnyBranch(repoPath: repo.path, sha: orphanSHA) == false)
    }

    // MARK: - Helpers

    /// Runs a raw git command and returns trimmed stdout — used only to assert
    /// on plumbing state (`ls-tree`) that GitManager itself doesn't expose.
    private func runGit(_ arguments: [String], at dir: URL) async throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = arguments
        process.currentDirectoryURL = dir
        process.environment = [
            "PATH": "/usr/bin:/bin:/usr/sbin:/sbin:/usr/local/bin",
            "HOME": NSHomeDirectory(),
            "GIT_CONFIG_NOSYSTEM": "1",
            "GIT_CONFIG_GLOBAL": "/dev/null",
        ]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(data: data, encoding: .utf8) ?? ""
    }
}
