import Foundation
import TestSupport
import Testing
@testable import TBDDaemonLib

/// Tests for `GitManager.listBranches` — exercises the `for-each-ref` output
/// parser, the symbolic-ref (`origin/HEAD`) skip, the local-vs-remote dedupe
/// rule, and the "already checked out" worktree filter.
struct GitManagerBranchesTests {
    let tempDir: URL
    let repoDir: URL
    let remoteDir: URL
    let git: GitManager

    init() async throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("tbd-branches-test-\(UUID().uuidString)")
        repoDir = tempDir.appendingPathComponent("repo")
        remoteDir = tempDir.appendingPathComponent("remote.git")
        try FileManager.default.createDirectory(at: repoDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: remoteDir, withIntermediateDirectories: true)

        // Init a fake "remote" bare repo with a `main` branch.
        try await shell("git init --bare -b main", at: remoteDir)

        // Init the local repo and seed a commit on `main`.
        try await shell("git init -b main && git commit --allow-empty -m 'init'", at: repoDir)

        // Push to the bare remote so we have an `origin/main` ref.
        try await shell("git remote add origin '\(remoteDir.path)'", at: repoDir)
        try await shell("git push -u origin main", at: repoDir)

        git = GitManager()
    }

    private func cleanup() {
        try? FileManager.default.removeItem(at: tempDir)
    }

    // MARK: - Tests

    @Test func listBranchesReturnsLocalBranches() async throws {
        defer { cleanup() }
        try await shell("git branch local-only", at: repoDir)

        let refs = try await git.listBranches(repoPath: repoDir.path)
        let names = refs.map(\.name)
        #expect(names.contains("local-only"))
        #expect(refs.first { $0.name == "local-only" }?.isRemote == false)
        #expect(refs.first { $0.name == "local-only" }?.localName == "local-only")
        // `main` is the main worktree's checked-out branch, so the
        // already-in-use filter drops it.
        #expect(!names.contains("main"))
    }

    @Test func listBranchesIncludesOriginButSkipsOriginHEAD() async throws {
        defer { cleanup() }
        // Create a remote-only branch (delete the local after pushing).
        try await shell("git checkout -b remote-only", at: repoDir)
        try await shell("git push -u origin remote-only", at: repoDir)
        try await shell("git checkout main", at: repoDir)
        try await shell("git branch -D remote-only", at: repoDir)

        // Establish origin/HEAD so the skip is exercised.
        try await shell("git remote set-head origin main", at: repoDir)

        let refs = try await git.listBranches(repoPath: repoDir.path)
        let names = refs.map(\.name)
        #expect(names.contains("origin/remote-only"))
        // origin/HEAD must be filtered out. Note: `git for-each-ref` short-names
        // `refs/remotes/origin/HEAD` to bare "origin" (not "origin/HEAD"), so
        // the filter has to recognize symbolic refs rather than match by name.
        #expect(!names.contains("origin/HEAD"))
        #expect(!names.contains("origin"))

        let remote = refs.first { $0.name == "origin/remote-only" }
        #expect(remote?.isRemote == true)
        #expect(remote?.localName == "remote-only")
    }

    @Test func listBranchesDedupesLocalOverRemote() async throws {
        defer { cleanup() }
        // Create a branch that exists both locally and as `origin/<name>` —
        // the remote duplicate should be dropped. `feature` isn't checked out
        // anywhere, so it survives the in-use filter.
        try await shell("git branch feature", at: repoDir)
        try await shell("git push -u origin feature", at: repoDir)

        let refs = try await git.listBranches(repoPath: repoDir.path)
        let featureEntries = refs.filter { $0.localName == "feature" }
        #expect(featureEntries.count == 1, "Expected exactly one entry for 'feature', got \(featureEntries.map(\.name))")
        #expect(featureEntries.first?.name == "feature", "Local entry should win over origin/feature")
        #expect(featureEntries.first?.isRemote == false)
    }

    @Test func listBranchesExcludesBranchesCheckedOutInLinkedWorktree() async throws {
        defer { cleanup() }
        // Create a branch and check it out into a linked worktree — it should
        // be omitted from the picker, since git rejects a second checkout.
        try await shell("git branch checked-out-elsewhere", at: repoDir)
        try await shell("git branch never-checked-out", at: repoDir)
        let linkedPath = tempDir.appendingPathComponent("linked-wt").path
        try await shell("git worktree add '\(linkedPath)' checked-out-elsewhere", at: repoDir)

        let refs = try await git.listBranches(repoPath: repoDir.path)
        let names = refs.map(\.name)
        #expect(!names.contains("checked-out-elsewhere"))
        #expect(names.contains("never-checked-out"))
    }

}
