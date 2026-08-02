import Testing
import Foundation
@testable import TBDDaemonLib
import TBDShared
import TestSupport

/// A fixed, deterministic instant for all `now:` parameters in this suite —
/// `ReapSnapshot` must never call the argless `Date()` internally, so tests
/// always pass an explicit value and never assert on wall-clock timing.
private let fixedNow = Date(timeIntervalSince1970: 1_700_000_000)

@Suite("ReapSnapshot")
struct ReapSnapshotTests {
    @Test func advisoryRuntimeResidueIsSnapshottedWithoutTrustedRegistry() async throws {
        let (tmp, repo, wt, _) = try await makeRepoWithExternalWorktree(
            branch: "runtime", folder: "runtimewt"
        )
        defer { try? FileManager.default.removeItem(at: tmp) }
        let root = URL(fileURLWithPath: wt)
        // The overlay is left untracked rather than gitignored. Ignored paths
        // are outside the classifier's boundary entirely, so an ignored
        // overlay would prove nothing about advisory-manifest handling.
        try Data("build-cache/\n".utf8).write(to: root.appendingPathComponent(".gitignore"))
        try await shell("git add .gitignore && git commit -m ignore-build-cache", at: root)
        try writeRuntimeOverlay(root: root, contents: Data("generated".utf8))

        let git = GitManager()
        let ref = try #require(try await ReapSnapshot(git: git).snapshotIfNeeded(
            worktreePath: wt,
            repoPath: repo.path,
            headSHA: try await git.headSHA(worktreePath: wt),
            worktreeName: "runtime",
            now: fixedNow
        ))

        let paths = try await runGit(["ls-tree", "-r", "--name-only", ref], at: repo)
        #expect(paths.contains(".agents/skills/demo/SKILL.md"))
    }

    @Test func divergentBootstrapRuntimeIsSnapshotted() async throws {
        let (tmp, repo, wt, _) = try await makeRepoWithExternalWorktree(
            branch: "divergent", folder: "divergentwt"
        )
        defer { try? FileManager.default.removeItem(at: tmp) }
        let root = URL(fileURLWithPath: wt)
        try writeRuntimeOverlay(root: root, contents: Data("generated".utf8))
        try Data("build-cache/\n".utf8).write(to: root.appendingPathComponent(".gitignore"))
        try await shell("git add .gitignore && git commit -m ignore-build-cache", at: root)
        try Data("user-edited".utf8).write(to: root.appendingPathComponent(".agents/skills/demo/SKILL.md"))
        let indexBefore = try await runGit(["diff", "--cached", "--name-only"], at: root)

        let git = GitManager()
        let ref = try #require(try await ReapSnapshot(git: git).snapshotIfNeeded(
            worktreePath: wt,
            repoPath: repo.path,
            headSHA: try await git.headSHA(worktreePath: wt),
            worktreeName: "divergent",
            now: fixedNow
        ))

        let paths = try await runGit(["ls-tree", "-r", "--name-only", ref], at: repo)
        #expect(paths.contains(".agents/skills/demo/SKILL.md"))
        #expect(paths.contains(ArchiveSafetyClassifier.manifestRelativePath))
        let indexAfter = try await runGit(["diff", "--cached", "--name-only"], at: root)
        #expect(indexAfter == indexBefore)
    }

    // MARK: (a) Dirty worktree -> ref preserves untracked and ignored bytes.

    @Test func dirtyWorktreeCreatesVerifiedSnapshotRef() async throws {
        let (tmp, repo, wt, _) = try await makeRepoWithExternalWorktree(branch: "dirty", folder: "dirtywt")
        defer { try? FileManager.default.removeItem(at: tmp) }
        let wtURL = URL(fileURLWithPath: wt)

        try await shell("echo untracked-content > untracked.txt", at: wtURL)
        try await shell("echo ignored-content > ignored.txt && echo ignored.txt > .gitignore", at: wtURL)

        let git = GitManager()
        let headSHA = try await git.headSHA(worktreePath: wt)
        let snap = ReapSnapshot(git: git)

        let ref = try await snap.snapshotIfNeeded(
            worktreePath: wt, repoPath: repo.path, headSHA: headSHA, worktreeName: "dirty", now: fixedNow
        )
        let resolvedRef = try #require(ref)

        let refs = try await git.listRefs(repoPath: repo.path, prefix: "refs/tbd/snapshots")
        #expect(refs.contains(resolvedRef))

        let lsTree = try await runGit(["ls-tree", "-r", "--name-only", resolvedRef], at: repo)
        #expect(lsTree.contains("untracked.txt"))
        // A snapshot ref is permanently reachable, so ignored bytes stay out
        // of it — otherwise every reap would commit the worktree's build tree.
        #expect(!lsTree.contains("ignored.txt"))
    }

    // MARK: (b) Clean + branch-reachable -> nil, no ref.

    @Test func cleanAndReachableReturnsNilAndWritesNoRef() async throws {
        let (tmp, repo, wt, _) = try await makeRepoWithExternalWorktree(branch: "clean", folder: "cleanwt")
        defer { try? FileManager.default.removeItem(at: tmp) }

        let git = GitManager()
        let headSHA = try await git.headSHA(worktreePath: wt)
        let snap = ReapSnapshot(git: git)

        let ref = try await snap.snapshotIfNeeded(
            worktreePath: wt, repoPath: repo.path, headSHA: headSHA, worktreeName: "clean", now: fixedNow
        )
        #expect(ref == nil)

        let refs = try await git.listRefs(repoPath: repo.path, prefix: "refs/tbd/snapshots")
        #expect(refs.isEmpty)
    }

    // MARK: (c) Clean but detached-unreachable HEAD -> anchor ref AT headSHA, no new commit.

    @Test func cleanDetachedUnreachableHeadCreatesAnchorRef() async throws {
        let (tmp, repo, wt, branch) = try await makeRepoWithExternalWorktree(branch: "det", folder: "detwt")
        defer { try? FileManager.default.removeItem(at: tmp) }
        let wtURL = URL(fileURLWithPath: wt)

        // Commit an extra commit, then detach HEAD at it, then rewind the
        // branch pointer so the detached commit is no longer reachable from
        // any branch — mirrors GitManagerGCTests' reachability fixture but
        // inside a worktree so isDirty/headSHA read from the worktree path.
        try await shell("echo extra > extra.txt && git add extra.txt && git commit -m extra", at: wtURL)
        let git = GitManager()
        let orphanSHA = try await git.headSHA(worktreePath: wt)
        try await shell("git checkout --detach", at: wtURL)
        try await shell("git branch -f \(branch) HEAD~1", at: wtURL)

        #expect(await git.isDirty(worktreePath: wt) == false)
        #expect(await git.isReachableFromAnyBranch(repoPath: repo.path, sha: orphanSHA) == false)

        let snap = ReapSnapshot(git: git)
        let ref = try await snap.snapshotIfNeeded(
            worktreePath: wt, repoPath: repo.path, headSHA: orphanSHA, worktreeName: "det", now: fixedNow
        )
        let resolvedRef = try #require(ref)

        // The ref must point directly AT headSHA (a pure anchor, `update-ref`
        // only) — not a new commit created via commit-tree.
        let pointee = try await runGit(["rev-parse", resolvedRef], at: repo)
        #expect(pointee.trimmingCharacters(in: .whitespacesAndNewlines) == orphanSHA)
    }

    // MARK: (d) Full round-trip: snapshot -> simulated reap -> restore.

    @Test func fullRoundTripSnapshotReapRestore() async throws {
        let (tmp, repo, wt, branch) = try await makeRepoWithExternalWorktree(branch: "round", folder: "roundwt")
        defer { try? FileManager.default.removeItem(at: tmp) }
        let wtURL = URL(fileURLWithPath: wt)

        try await shell(
            "echo tracked-change > tracked.txt && git add tracked.txt && git commit -m 'add tracked'", at: wtURL
        )
        try await shell("echo tracked-modified > tracked.txt", at: wtURL)
        try await shell("echo untracked-content > untracked.txt", at: wtURL)

        let git = GitManager()
        let headSHA = try await git.headSHA(worktreePath: wt)
        let snap = ReapSnapshot(git: git)

        let ref = try await snap.snapshotIfNeeded(
            worktreePath: wt, repoPath: repo.path, headSHA: headSHA, worktreeName: "round", now: fixedNow
        )
        let resolvedRef = try #require(ref)

        // Simulate the GC sweep deleting the worktree.
        try await shell("rm -rf '\(wt)'", at: repo)
        try await shell("git worktree prune", at: repo)
        #expect(!FileManager.default.fileExists(atPath: wt))

        let record = ReapRecord(
            kind: .agentWorktree, repoPath: repo.path, worktreePath: wt,
            branch: branch, headSHA: headSHA, snapshotRef: resolvedRef
        )
        try await snap.restore(record: record)

        let restoredBranch = try await runGit(["rev-parse", "--abbrev-ref", "HEAD"], at: URL(fileURLWithPath: wt))
        #expect(restoredBranch.trimmingCharacters(in: .whitespacesAndNewlines) == branch)

        let restoredTracked = try String(contentsOfFile: wt + "/tracked.txt", encoding: .utf8)
        let restoredUntracked = try String(contentsOfFile: wt + "/untracked.txt", encoding: .utf8)
        #expect(restoredTracked.trimmingCharacters(in: .whitespacesAndNewlines) == "tracked-modified")
        #expect(restoredUntracked.trimmingCharacters(in: .whitespacesAndNewlines) == "untracked-content")
    }

    // MARK: (e) Restore refuses when the target path already exists.

    @Test func restoreRefusesWhenTargetPathExists() async throws {
        let (tmp, repo, wt, branch) = try await makeRepoWithExternalWorktree(branch: "exists", folder: "existswt")
        defer { try? FileManager.default.removeItem(at: tmp) }

        let git = GitManager()
        let headSHA = try await git.headSHA(worktreePath: wt)
        let snap = ReapSnapshot(git: git)

        // The worktree at `wt` was never reaped — it's still on disk.
        let record = ReapRecord(
            kind: .agentWorktree, repoPath: repo.path, worktreePath: wt,
            branch: branch, headSHA: headSHA, snapshotRef: nil
        )

        try await #require(throws: ReapSnapshotError.self) {
            try await snap.restore(record: record)
        }
    }

    // MARK: - Bonus: timestamp determinism (never argless Date() inside)

    @Test func refTimestampIsDeterministicUTCFormat() {
        // 2023-11-14T22:13:20Z
        #expect(ReapSnapshot.refTimestamp(fixedNow) == "20231114-221320")
        // Calling again with the same instant must yield the identical string —
        // guards against any hidden reliance on the ambient clock/locale/TZ.
        #expect(ReapSnapshot.refTimestamp(fixedNow) == ReapSnapshot.refTimestamp(fixedNow))
    }

    // MARK: - Helpers

    /// Runs a raw git command and returns trimmed stdout — used only to assert
    /// on plumbing state (`ls-tree`, `rev-parse`) that GitManager itself
    /// doesn't expose.
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

    private func writeRuntimeOverlay(root: URL, contents: Data) throws {
        let artifact = root.appendingPathComponent(".agents/skills/demo/SKILL.md")
        try FileManager.default.createDirectory(
            at: artifact.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try contents.write(to: artifact)

        let manifest = root.appendingPathComponent(ArchiveSafetyClassifier.manifestRelativePath)
        try FileManager.default.createDirectory(
            at: manifest.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        let json: [String: Any] = [
            "schemaVersion": 1,
            "producer": "agent-bootstrap",
            "producerVersion": "test-v1",
            "artifacts": [[
                "path": ".agents/skills/demo/SKILL.md",
                "kind": "runtime",
                "sha256": ArchiveSafetyClassifier.sha256(contents),
            ]],
        ]
        try JSONSerialization.data(withJSONObject: json, options: [.sortedKeys]).write(to: manifest)
    }
}
