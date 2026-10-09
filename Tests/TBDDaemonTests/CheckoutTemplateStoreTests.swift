import Darwin
import Foundation
import Testing
@testable import TBDDaemonLib
@testable import TBDShared

/// Tier 2: temporary repositories and the real Git executable.
///
/// The clone-backed checkout must produce the worktree `git worktree add`
/// would — own branch, HEAD and index, clean status, `post-checkout` run once
/// with the same arguments — while sharing unchanged files' blocks with the
/// template on a volume that can clone. Each fallback must still produce that
/// worktree.
@Suite("CheckoutTemplateStore")
struct CheckoutTemplateStoreTests {

    /// A repository with two commits. `older` has `keep.bin` (64 KiB, never
    /// changes), `edit.txt`, `gone.txt`; `newer` edits `edit.txt`, deletes
    /// `gone.txt` and adds `dir/new.txt`.
    struct Fixture {
        let root: URL
        let repo: URL
        let reposDir: URL
        let older: String
        let newer: String
        let repoID = UUID()

        func worktreePath(_ name: String) -> String {
            root.appendingPathComponent("worktrees").appendingPathComponent(name).path
        }
    }

    private func makeFixture() throws -> Fixture {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("clone-checkout-\(UUID().uuidString)")
        let repo = root.appendingPathComponent("repo")
        try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("worktrees"), withIntermediateDirectories: true)
        try git(["init", "-b", "main"], at: repo)
        try git(["config", "commit.gpgSign", "false"], at: repo)
        try git(["config", "user.name", "Test"], at: repo)
        try git(["config", "user.email", "test@example.com"], at: repo)

        try Data(repeating: 0x5A, count: 64 * 1024).write(to: repo.appendingPathComponent("keep.bin"))
        try write("first\n", to: repo.appendingPathComponent("edit.txt"))
        try write("bye\n", to: repo.appendingPathComponent("gone.txt"))
        try git(["add", "-A"], at: repo)
        try git(["commit", "-m", "older"], at: repo)
        let older = try git(["rev-parse", "HEAD"], at: repo)

        try write("second\n", to: repo.appendingPathComponent("edit.txt"))
        try FileManager.default.removeItem(at: repo.appendingPathComponent("gone.txt"))
        try FileManager.default.createDirectory(
            at: repo.appendingPathComponent("dir"), withIntermediateDirectories: true)
        try write("hello\n", to: repo.appendingPathComponent("dir/new.txt"))
        try git(["add", "-A"], at: repo)
        try git(["commit", "-m", "newer"], at: repo)
        let newer = try git(["rev-parse", "HEAD"], at: repo)

        return Fixture(
            root: root, repo: repo, reposDir: root.appendingPathComponent("repos"),
            older: older, newer: newer)
    }

    private func volumeCanClone(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.volumeSupportsFileCloningKey]))?
            .volumeSupportsFileCloning == true
    }

    // MARK: - Clone path

    @Test func clonedWorktreeMatchesAPlainCheckout() async throws {
        let f = try makeFixture()
        defer { try? FileManager.default.removeItem(at: f.root) }
        let store = CheckoutTemplateStore(reposDir: f.reposDir)
        await store.refresh(git: GitManager(), repoID: f.repoID, repoPath: f.repo.path, toCommit: f.older)

        let path = f.worktreePath("cloned")
        let outcome = try await store.addWorktree(
            git: GitManager(), repoID: f.repoID, repoPath: f.repo.path,
            worktreePath: path, branch: "tbd/cloned", baseBranch: f.newer)

        if volumeCanClone(f.root) {
            #expect(outcome == .cloned(templateCommit: f.older))
        }
        let wt = URL(fileURLWithPath: path)
        #expect(try git(["rev-parse", "--abbrev-ref", "HEAD"], at: wt) == "tbd/cloned")
        #expect(try git(["rev-parse", "HEAD"], at: wt) == f.newer)
        #expect(try git(["status", "--porcelain", "--ignored"], at: wt).isEmpty)
        #expect(try git(["rev-parse", "--git-path", "index"], at: wt).contains("worktrees/cloned"))
        #expect(try String(contentsOf: wt.appendingPathComponent("edit.txt"), encoding: .utf8) == "second\n")
        #expect(!FileManager.default.fileExists(atPath: wt.appendingPathComponent("gone.txt").path))
        #expect(try String(contentsOf: wt.appendingPathComponent("dir/new.txt"), encoding: .utf8) == "hello\n")
        // No upstream, exactly as `worktreeAdd`'s `--no-track`.
        #expect(throws: Error.self) {
            try git(["rev-parse", "--abbrev-ref", "tbd/cloned@{upstream}"], at: wt)
        }
    }

    /// The point of the feature, measured the way the field report measured
    /// it: the unchanged file's first block is the template's block.
    @Test func unchangedFileSharesItsBlocksWithTheTemplate() async throws {
        let f = try makeFixture()
        defer { try? FileManager.default.removeItem(at: f.root) }
        guard volumeCanClone(f.root) else { return }
        let store = CheckoutTemplateStore(reposDir: f.reposDir)
        await store.refresh(git: GitManager(), repoID: f.repoID, repoPath: f.repo.path, toCommit: f.older)

        let path = f.worktreePath("shared")
        _ = try await store.addWorktree(
            git: GitManager(), repoID: f.repoID, repoPath: f.repo.path,
            worktreePath: path, branch: "tbd/shared", baseBranch: f.newer)

        let template = store.paths(repoID: f.repoID).tree.appendingPathComponent("keep.bin").path
        let cloned = (path as NSString).appendingPathComponent("keep.bin")
        let templateBlock = try #require(firstPhysicalOffset(template))
        #expect(firstPhysicalOffset(cloned) == templateBlock)
        let rewritten = (path as NSString).appendingPathComponent("edit.txt")
        let templateEdit = store.paths(repoID: f.repoID).tree.appendingPathComponent("edit.txt").path
        #expect(firstPhysicalOffset(rewritten) != firstPhysicalOffset(templateEdit))
    }

    // MARK: - Fallbacks

    @Test func noTemplateWritesEveryFileAndRefreshBuildsOne() async throws {
        let f = try makeFixture()
        defer { try? FileManager.default.removeItem(at: f.root) }
        let store = CheckoutTemplateStore(reposDir: f.reposDir)

        let path = f.worktreePath("first")
        let outcome = try await store.addWorktree(
            git: GitManager(), repoID: f.repoID, repoPath: f.repo.path,
            worktreePath: path, branch: "tbd/first", baseBranch: f.newer)
        #expect(outcome == .materialized(reason: "no template"))
        #expect(try git(["status", "--porcelain", "--ignored"], at: URL(fileURLWithPath: path)).isEmpty)

        // The store never builds a template on a volume that cannot clone.
        guard volumeCanClone(f.root) else { return }
        await store.refresh(git: GitManager(), repoID: f.repoID, repoPath: f.repo.path, toCommit: f.newer)
        let paths = store.paths(repoID: f.repoID)
        #expect(CheckoutTemplateStore.readCommit(paths.commitFile) == f.newer)
        #expect(FileManager.default.fileExists(atPath: paths.tree.appendingPathComponent("dir/new.txt").path))
        #expect(!FileManager.default.fileExists(atPath: paths.tree.appendingPathComponent(".git").path))
    }

    /// A template carrying a file its commit does not track (a torn refresh,
    /// a stray write) would leave that file untracked in the worktree. The
    /// status check catches it and the worktree is written in full instead.
    @Test func strayFileInTemplateFallsBackToAFullCheckout() async throws {
        let f = try makeFixture()
        defer { try? FileManager.default.removeItem(at: f.root) }
        guard volumeCanClone(f.root) else { return }
        let store = CheckoutTemplateStore(reposDir: f.reposDir)
        await store.refresh(git: GitManager(), repoID: f.repoID, repoPath: f.repo.path, toCommit: f.older)
        try write("stray\n", to: store.paths(repoID: f.repoID).tree.appendingPathComponent("stray.txt"))

        let path = f.worktreePath("stray")
        let outcome = try await store.addWorktree(
            git: GitManager(), repoID: f.repoID, repoPath: f.repo.path,
            worktreePath: path, branch: "tbd/stray", baseBranch: f.newer)
        guard case .materialized = outcome else {
            Issue.record("expected a full checkout, got \(outcome)")
            return
        }
        let wt = URL(fileURLWithPath: path)
        #expect(try git(["status", "--porcelain", "--ignored"], at: wt).isEmpty)
        #expect(!FileManager.default.fileExists(atPath: wt.appendingPathComponent("stray.txt").path))
        #expect(try git(["rev-parse", "HEAD"], at: wt) == f.newer)

        // The bad template no longer reads as present, and the next refresh
        // rebuilds it without the stray file.
        let paths = store.paths(repoID: f.repoID)
        #expect(CheckoutTemplateStore.readCommit(paths.commitFile) == nil)
        await store.refresh(git: GitManager(), repoID: f.repoID, repoPath: f.repo.path, toCommit: f.newer)
        #expect(CheckoutTemplateStore.readCommit(paths.commitFile) == f.newer)
        #expect(!FileManager.default.fileExists(atPath: paths.tree.appendingPathComponent("stray.txt").path))
    }

    /// A gitignored stray (`.DS_Store` and friends) must not ride along into
    /// worktrees either.
    @Test func ignoredStrayFileInTemplateAlsoFallsBack() async throws {
        let f = try makeFixture()
        defer { try? FileManager.default.removeItem(at: f.root) }
        guard volumeCanClone(f.root) else { return }
        try write(".DS_Store\n", to: f.repo.appendingPathComponent(".git/info/exclude"))
        let store = CheckoutTemplateStore(reposDir: f.reposDir)
        await store.refresh(git: GitManager(), repoID: f.repoID, repoPath: f.repo.path, toCommit: f.older)
        try write("x", to: store.paths(repoID: f.repoID).tree.appendingPathComponent(".DS_Store"))

        let path = f.worktreePath("ignored")
        let outcome = try await store.addWorktree(
            git: GitManager(), repoID: f.repoID, repoPath: f.repo.path,
            worktreePath: path, branch: "tbd/ignored", baseBranch: f.newer)
        guard case .materialized = outcome else {
            Issue.record("expected a full checkout, got \(outcome)")
            return
        }
        #expect(!FileManager.default.fileExists(atPath: (path as NSString).appendingPathComponent(".DS_Store")))
    }

    /// A tracked top-level symlink is cloned as a link, even when it dangles.
    @Test func topLevelSymlinkIsClonedAsALink() async throws {
        let f = try makeFixture()
        defer { try? FileManager.default.removeItem(at: f.root) }
        guard volumeCanClone(f.root) else { return }
        try FileManager.default.createSymbolicLink(
            atPath: f.repo.appendingPathComponent("dangling").path, withDestinationPath: "nowhere")
        try git(["add", "dangling"], at: f.repo)
        try git(["commit", "-m", "link"], at: f.repo)
        let head = try git(["rev-parse", "HEAD"], at: f.repo)
        let store = CheckoutTemplateStore(reposDir: f.reposDir)
        await store.refresh(git: GitManager(), repoID: f.repoID, repoPath: f.repo.path, toCommit: head)

        let path = f.worktreePath("link")
        let outcome = try await store.addWorktree(
            git: GitManager(), repoID: f.repoID, repoPath: f.repo.path,
            worktreePath: path, branch: "tbd/link", baseBranch: head)
        #expect(outcome == .cloned(templateCommit: head))
        let link = (path as NSString).appendingPathComponent("dangling")
        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: link) == "nowhere")
    }

    // MARK: - Template refresh

    @Test func refreshRewritesOnlyChangedPaths() async throws {
        let f = try makeFixture()
        defer { try? FileManager.default.removeItem(at: f.root) }
        guard volumeCanClone(f.root) else { return }
        let store = CheckoutTemplateStore(reposDir: f.reposDir)
        await store.refresh(git: GitManager(), repoID: f.repoID, repoPath: f.repo.path, toCommit: f.older)
        let tree = store.paths(repoID: f.repoID).tree
        let keepInode = try inode(tree.appendingPathComponent("keep.bin").path)

        await store.refresh(git: GitManager(), repoID: f.repoID, repoPath: f.repo.path, toCommit: f.newer)
        #expect(CheckoutTemplateStore.readCommit(store.paths(repoID: f.repoID).commitFile) == f.newer)
        #expect(try inode(tree.appendingPathComponent("keep.bin").path) == keepInode)
        #expect(try String(contentsOf: tree.appendingPathComponent("edit.txt"), encoding: .utf8) == "second\n")
        #expect(!FileManager.default.fileExists(atPath: tree.appendingPathComponent("gone.txt").path))
        #expect(FileManager.default.fileExists(atPath: tree.appendingPathComponent("dir/new.txt").path))
    }

    // MARK: - Hooks

    @Test func postCheckoutRunsOnceWithWorktreeAddArguments() async throws {
        let f = try makeFixture()
        defer { try? FileManager.default.removeItem(at: f.root) }
        let log = f.root.appendingPathComponent("hook.log")
        try installHook(in: f.repo, body: "echo \"$1 $2 $3\" >> '\(log.path)'")
        let store = CheckoutTemplateStore(reposDir: f.reposDir)
        await store.refresh(git: GitManager(), repoID: f.repoID, repoPath: f.repo.path, toCommit: f.older)

        _ = try await store.addWorktree(
            git: GitManager(), repoID: f.repoID, repoPath: f.repo.path,
            worktreePath: f.worktreePath("cloned"), branch: "tbd/cloned", baseBranch: f.newer)
        try await GitManager().worktreeAdd(
            repoPath: f.repo.path, worktreePath: f.worktreePath("plain"),
            branch: "tbd/plain", baseBranch: f.newer)

        let lines = try String(contentsOf: log, encoding: .utf8)
            .split(separator: "\n").map(String.init)
        let expected = "\(String(repeating: "0", count: 40)) \(f.newer) 1"
        #expect(lines == [expected, expected])
    }

    @Test func failingPostCheckoutFailsTheCreate() async throws {
        let f = try makeFixture()
        defer { try? FileManager.default.removeItem(at: f.root) }
        try installHook(in: f.repo, body: "exit 1")
        let store = CheckoutTemplateStore(reposDir: f.reposDir)
        await store.refresh(git: GitManager(), repoID: f.repoID, repoPath: f.repo.path, toCommit: f.older)

        await #expect(throws: GitError.self) {
            _ = try await store.addWorktree(
                git: GitManager(), repoID: f.repoID, repoPath: f.repo.path,
                worktreePath: f.worktreePath("hooked"), branch: "tbd/hooked", baseBranch: f.newer)
        }
    }

    // MARK: - The flag's two branches

    @Test func flagOffTakesThePlainPathAndBuildsNoTemplate() async throws {
        let f = try makeFixture()
        defer { try? FileManager.default.removeItem(at: f.root) }
        let db = try TBDDatabase(inMemory: true)
        let repo = try await db.repos.create(path: f.repo.path, displayName: "acme", defaultBranch: "main")
        let store = CheckoutTemplateStore(reposDir: f.reposDir)
        let lifecycle = WorktreeLifecycle(
            db: db, git: GitManager(), tmux: TmuxManager(dryRun: true), hooks: HookResolver(),
            checkoutTemplates: store)

        let outcome = try await lifecycle.addFreshWorktree(
            repo: repo, worktreePath: f.worktreePath("off"), branch: "tbd/off", baseBranch: "main")
        #expect(outcome == nil)
        #expect(!FileManager.default.fileExists(atPath: store.paths(repoID: repo.id).root.path))
        #expect(try git(["status", "--porcelain"], at: URL(fileURLWithPath: f.worktreePath("off"))).isEmpty)
    }

    @Test func flagOnRoutesThroughTheStore() async throws {
        let f = try makeFixture()
        defer { try? FileManager.default.removeItem(at: f.root) }
        let db = try TBDDatabase(inMemory: true)
        try await db.config.setCloneCheckoutEnabled(true)
        let repo = try await db.repos.create(path: f.repo.path, displayName: "acme", defaultBranch: "main")
        let lifecycle = WorktreeLifecycle(
            db: db, git: GitManager(), tmux: TmuxManager(dryRun: true), hooks: HookResolver(),
            checkoutTemplates: CheckoutTemplateStore(reposDir: f.reposDir))

        let outcome = try await lifecycle.addFreshWorktree(
            repo: repo, worktreePath: f.worktreePath("on"), branch: "tbd/on", baseBranch: "main")
        // A repo created this test has no template yet, so the store reports
        // the full write; the point is that the store, not `worktreeAdd`, ran.
        #expect(outcome == .materialized(reason: "no template"))
        #expect(try git(["status", "--porcelain"], at: URL(fileURLWithPath: f.worktreePath("on"))).isEmpty)
    }

    // MARK: - Helpers

    private func installHook(in repo: URL, body: String) throws {
        let hook = repo.appendingPathComponent(".git/hooks/post-checkout")
        try write("#!/bin/sh\n\(body)\n", to: hook)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: hook.path)
    }

    private func write(_ text: String, to url: URL) throws {
        try Data(text.utf8).write(to: url)
    }

    private func inode(_ path: String) throws -> UInt64 {
        let attributes = try FileManager.default.attributesOfItem(atPath: path)
        return (attributes[.systemFileNumber] as? NSNumber)?.uint64Value ?? 0
    }

    /// The device offset of a file's first block (`F_LOG2PHYS`), after an
    /// `fsync` so delayed allocation has placed it.
    private func firstPhysicalOffset(_ path: String) -> Int64? {
        let fd = open(path, O_RDONLY)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        _ = fsync(fd)
        var info = log2phys()
        guard fcntl(fd, F_LOG2PHYS, &info) != -1 else { return nil }
        return info.l2p_devoffset
    }

    @discardableResult
    private func git(_ arguments: [String], at directory: URL) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = arguments
        process.currentDirectoryURL = directory
        process.environment = ProcessInfo.processInfo.environment.merging(["LC_ALL": "C"]) { _, new in new }
        let stdout = Pipe()
        process.standardOutput = stdout
        process.standardError = Pipe()
        try process.run()
        let data = stdout.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw NSError(domain: "CheckoutTemplateStoreTests", code: Int(process.terminationStatus))
        }
        return String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
