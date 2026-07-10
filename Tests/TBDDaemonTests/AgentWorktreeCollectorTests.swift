import Testing
import Foundation
@testable import TBDDaemonLib
import TBDShared
import TestSupport

/// Test fixtures must canonicalize paths before comparing against collector
/// output (git's `worktree list --porcelain` paths are always realpath'd).
/// Uses the collector's own `canon(_:)` — reachable via `@testable import` —
/// so both sides of every comparison share one resolution implementation.
private func canon(_ path: String) -> String {
    AgentWorktreeCollector.canon(path)
}

@Suite("AgentWorktreeCollector")
struct AgentWorktreeCollectorTests {
    // MARK: - Helpers

    private func makeCollector(
        liveCWDs: @escaping @Sendable () async -> [String] = { [] },
        now: @escaping @Sendable () -> Date = { Date() }
    ) -> AgentWorktreeCollector {
        let git = GitManager()
        return AgentWorktreeCollector(git: git, snapshot: ReapSnapshot(git: git), liveCWDs: liveCWDs, now: now)
    }

    /// Builds `<repo>/.claude/worktrees/<name>` as a real linked git
    /// worktree on its own branch (named after `name` unless `branch` is
    /// given) and returns its canonicalized path.
    @discardableResult
    private func makeAgentWorktree(repo: URL, name: String, branch: String? = nil) async throws -> String {
        try await shell("mkdir -p .claude/worktrees", at: repo)
        try await shell("git worktree add .claude/worktrees/\(name) -b \(branch ?? name)", at: repo)
        return canon(repo.path + "/.claude/worktrees/" + name)
    }

    // MARK: - candidates(repoPath:)

    @Test func candidatesEnumeratesOnlyLinkedDirsUnderClaudeWorktrees() async throws {
        let (tmp, repo) = try await createTestRepoResolvingSymlinks()
        defer { try? FileManager.default.removeItem(at: tmp) }

        try await shell("mkdir -p .claude/worktrees", at: repo)
        // Decoy 1: plain `mkdir`'d dir, no `.git` at all — fails linkage proof.
        try await shell("mkdir -p .claude/worktrees/decoy", at: repo)
        // Decoy 2: a symlink to the repo root itself — its `.git` resolves to
        // a *directory*, not a `gitdir:`-pointer file, so linkage proof
        // rejects it too (the "repo root" exclusion case).
        try await shell("ln -s '\(repo.path)' .claude/worktrees/reporoot", at: repo)

        let wtPath = try await makeAgentWorktree(repo: repo, name: "agent-t1")

        let collector = makeCollector()
        let candidates = await collector.candidates(repoPath: repo.path)

        #expect(candidates.count == 1)
        let c = try #require(candidates.first)
        #expect(c.path == wtPath)
        #expect(c.repoPath == repo.path)
        #expect(c.branch == "agent-t1")
        #expect(c.headSHA.count == 40)
        #expect(c.locked == false)
    }

    // MARK: - Gate 1: locked

    @Test func lockedIsKept() async throws {
        let (tmp, repo) = try await createTestRepoResolvingSymlinks()
        defer { try? FileManager.default.removeItem(at: tmp) }

        try await makeAgentWorktree(repo: repo, name: "agent-t1")
        try await shell("git worktree lock .claude/worktrees/agent-t1", at: repo)

        let collector = makeCollector()
        let c = try #require(await collector.candidates(repoPath: repo.path).first)
        #expect(c.locked == true)

        let decision = await collector.decide(c, liveCWDs: [], graceSeconds: 0)
        #expect(decision == .keep(reason: "locked"))
    }

    // MARK: - Gate 2: live-cwd (exact, subdir, and sibling-prefix negative)

    @Test func liveCwdIsKept() async throws {
        let (tmp, repo) = try await createTestRepoResolvingSymlinks()
        defer { try? FileManager.default.removeItem(at: tmp) }

        try await makeAgentWorktree(repo: repo, name: "agent-t1")
        try await makeAgentWorktree(repo: repo, name: "agent-t1x")

        let collector = makeCollector()
        let candidates = await collector.candidates(repoPath: repo.path)
        let c1 = try #require(candidates.first { $0.path.hasSuffix("agent-t1") })
        let c1x = try #require(candidates.first { $0.path.hasSuffix("agent-t1x") })

        // Exact match keeps.
        let exact = await collector.decide(c1, liveCWDs: [c1.path], graceSeconds: 0)
        #expect(exact == .keep(reason: "live-cwd"))

        // A cwd strictly below the worktree root also keeps.
        let subdir = await collector.decide(c1, liveCWDs: [c1.path + "/subdir"], graceSeconds: 0)
        #expect(subdir == .keep(reason: "live-cwd"))

        // The sibling `agent-t1x`'s cwd must NOT match `agent-t1` via a bare
        // prefix check (the #41010 prefix-collision case: `agent-t1x` starts
        // with `agent-t1` as a *string*, but is not a path strictly below
        // it once the `/` separator is required).
        let siblingDecision = await collector.decide(c1, liveCWDs: [c1x.path], graceSeconds: 0)
        guard case .reap = siblingDecision else {
            Issue.record("expected .reap when only a sibling worktree's cwd is live, got \(siblingDecision)")
            return
        }
    }

    // MARK: - Gate 3: grace (HEAD/index activity)

    @Test func graceKeepsRecentlyTouched() async throws {
        let (tmp, repo) = try await createTestRepoResolvingSymlinks()
        defer { try? FileManager.default.removeItem(at: tmp) }

        let wtPath = try await makeAgentWorktree(repo: repo, name: "agent-t1")
        let git = GitManager()
        let snap = ReapSnapshot(git: git)

        let entries = try await git.worktreeListDetailed(repoPath: repo.path)
        let entry = try #require(entries.first { $0.path == wtPath })
        let candidate = AgentWorktreeCandidate(
            path: wtPath, repoPath: repo.path, branch: entry.branch, headSHA: entry.headSHA, locked: entry.locked
        )

        let baseline = AgentWorktreeCollector.lastActivity(worktreePath: wtPath)

        // Well within a 1-hour grace window: kept.
        let recentCollector = AgentWorktreeCollector(
            git: git, snapshot: snap, liveCWDs: { [] }, now: { baseline.addingTimeInterval(100) }
        )
        let keepDecision = await recentCollector.decide(candidate, liveCWDs: [], graceSeconds: 3600)
        #expect(keepDecision == .keep(reason: "grace"))

        // Well past a 1-hour grace window: reaps.
        let staleCollector = AgentWorktreeCollector(
            git: git, snapshot: snap, liveCWDs: { [] }, now: { baseline.addingTimeInterval(7200) }
        )
        let reapDecision = await staleCollector.decide(candidate, liveCWDs: [], graceSeconds: 3600)
        guard case .reap = reapDecision else {
            Issue.record("expected .reap once past the grace window, got \(reapDecision)")
            return
        }
    }

    // MARK: - Reap: clean orphan

    @Test func cleanOrphanReaped() async throws {
        let (tmp, repo) = try await createTestRepoResolvingSymlinks()
        defer { try? FileManager.default.removeItem(at: tmp) }

        try await makeAgentWorktree(repo: repo, name: "agent-t1")

        let collector = makeCollector()
        let c = try #require(await collector.candidates(repoPath: repo.path).first)

        let decision = await collector.decide(c, liveCWDs: [], graceSeconds: 0)
        guard case .reap(let reapCandidate) = decision else {
            Issue.record("expected .reap for a clean, unlocked, non-live, out-of-grace worktree, got \(decision)")
            return
        }

        let record = try #require(await collector.reap(reapCandidate))
        #expect(record.kind == .agentWorktree)
        #expect(record.snapshotRef == nil)
        #expect(record.worktreePath == c.path)
        #expect(!FileManager.default.fileExists(atPath: c.path))

        let git = GitManager()
        let remaining = try await git.worktreeListDetailed(repoPath: repo.path)
        #expect(!remaining.contains { $0.path == c.path })

        // The branch itself must survive — only the worktree dir + its git
        // registration are removed, never the branch/history.
        try await shell("git rev-parse --verify refs/heads/agent-t1", at: repo)
    }

    // MARK: - Reap: dirty orphan snapshots first

    @Test func dirtyOrphanSnapshotThenReaped() async throws {
        let (tmp, repo) = try await createTestRepoResolvingSymlinks()
        defer { try? FileManager.default.removeItem(at: tmp) }

        let wtPath = try await makeAgentWorktree(repo: repo, name: "agent-t1")
        try await shell("echo dirty > untracked.txt", at: URL(fileURLWithPath: wtPath))

        let collector = makeCollector()
        let c = try #require(await collector.candidates(repoPath: repo.path).first)

        let decision = await collector.decide(c, liveCWDs: [], graceSeconds: 0)
        guard case .reap(let reapCandidate) = decision else {
            Issue.record("expected .reap for a dirty-but-idle worktree, got \(decision)")
            return
        }

        let record = try #require(await collector.reap(reapCandidate))
        let ref = try #require(record.snapshotRef)
        #expect(!FileManager.default.fileExists(atPath: c.path))

        let git = GitManager()
        let refs = try await git.listRefs(repoPath: repo.path, prefix: "refs/tbd/snapshots")
        #expect(refs.contains(ref))
    }

    // MARK: - Reap: snapshot failure keeps

    @Test func snapshotFailureKeeps() async throws {
        let (tmp, repo) = try await createTestRepoResolvingSymlinks()
        defer { try? FileManager.default.removeItem(at: tmp) }

        try await makeAgentWorktree(repo: repo, name: "agent-t1")
        // Dirty, so snapshotIfNeeded takes the commit-tree path, which uses
        // headSHA as the new commit's parent.
        let entriesBefore = try await GitManager().worktreeListDetailed(repoPath: repo.path)
        let realEntry = try #require(entriesBefore.first { $0.path.hasSuffix("agent-t1") })
        try await shell("echo dirty > untracked.txt", at: URL(fileURLWithPath: realEntry.path))

        let collector = makeCollector()
        let real = try #require(await collector.candidates(repoPath: repo.path).first)

        // A candidate identical to the real one except for a headSHA that
        // names no object in the repo — forces `commit-tree -p <bogus>` to
        // fail *inside* `snapshotIfNeeded`, proving the failure happens there
        // and not earlier in `candidates()` (which already succeeded above).
        let bogusSHA = String(repeating: "0", count: 39) + "1"
        let bogus = AgentWorktreeCandidate(
            path: real.path, repoPath: real.repoPath, branch: real.branch, headSHA: bogusSHA, locked: real.locked
        )

        let record = await collector.reap(bogus)
        #expect(record == nil)
        #expect(FileManager.default.fileExists(atPath: real.path))
    }

    // MARK: - Symlinked parent path robustness

    @Test func symlinkedPathsStillMatch() async throws {
        // Deliberately the RAW (non-realpath'd) temp dir — on macOS this sits
        // under `/var/folders/...`, itself a symlink to `/private/var/folders/...`.
        let (tmp, repo) = try await createTestRepo()
        defer { try? FileManager.default.removeItem(at: tmp) }

        try await makeAgentWorktree(repo: repo, name: "agent-t1")

        let collector = makeCollector()
        // Pass the unresolved `repo.path` straight through — linkage proof
        // and the byPath cross-reference must still line up even though the
        // directory listing side and git's own (always-canonical) worktree
        // list only meet in the middle via `canon(_:)`.
        let candidates = await collector.candidates(repoPath: repo.path)
        #expect(candidates.count == 1)
        let c = try #require(candidates.first)

        // `candidates()` always returns an already-canonicalized path (git
        // itself realpath()s worktree paths when recording them), matching
        // what a real `lsof`-based live-cwd provider reports. A liveCWDs
        // entry built from that same canonical path must still keep it.
        let decision = await collector.decide(c, liveCWDs: [c.path], graceSeconds: 0)
        #expect(decision == .keep(reason: "live-cwd"))
    }
}
