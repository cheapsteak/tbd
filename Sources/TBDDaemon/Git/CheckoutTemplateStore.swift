import Darwin
import Foundation
import TBDShared
import os

private let logger = Logger(subsystem: "com.tbd.daemon", category: "cloneCheckout")

/// Clone-backed worktree checkout: a fresh worktree whose unchanged files share
/// disk blocks with a per-repo template checkout instead of each holding its
/// own copy.
///
/// `git worktree add` writes every tracked file, and on APFS those bytes are
/// shared with nothing — a large repository pays its full checkout size per
/// worktree. This store keeps one template per repo (the tracked files of one
/// commit, under `~/tbd/repos/<repoID>/checkout-template/`) and builds a
/// worktree in five steps:
///
/// 1. `git worktree add --no-checkout` — branch, HEAD and `.git` file, no files.
/// 2. `clonefile(2)` each top-level entry of the template into the worktree.
/// 3. `read-tree <template commit>` then `update-index --refresh`, which hashes
///    the cloned files (reads only) and records their stat data.
/// 4. `reset --hard` to HEAD: git rewrites, creates and deletes only the paths
///    that differ between the template's commit and the new base.
/// 5. `post-checkout`, with the arguments `git worktree add` would have used.
///
/// Every step after the first falls back to an ordinary checkout of the same
/// worktree: the directory is emptied (keeping `.git`) and `reset --hard`
/// writes every file. A clone that does not leave `git status` empty takes the
/// same fallback, so a torn or stale template costs time, never correctness.
/// The fallback is the only thing a non-APFS volume ever sees.
///
/// The template follows the bases worktrees are created from: after each
/// create, `refresh(…)` moves it to the new worktree's HEAD, writing only what
/// changed. Clones and refreshes of one repo exclude each other without
/// waiting — a create that finds a refresh running materializes normally, and
/// a refresh that finds a clone running is skipped until the next create.
///
/// Orphans: `OrphanGC.reclaimCheckoutTemplates` removes a template whose repo
/// row is gone, or every template while `clone_checkout_enabled` is off.
///
/// Design: docs/specs/2026-10-09-clone-backed-worktree-checkout-design.md.
public actor CheckoutTemplateStore {

    /// How a create populated its worktree.
    public enum Outcome: Equatable, Sendable {
        /// Cloned from the template at `templateCommit`; git wrote only the
        /// paths that differ from it.
        case cloned(templateCommit: String)
        /// Every file written by git, as `git worktree add` would.
        case materialized(reason: String)
    }

    struct TemplatePaths: Sendable {
        let root: URL
        let tree: URL
        let index: URL
        let commitFile: URL
    }

    enum CloneError: Error, LocalizedError, CustomStringConvertible {
        case cloneFailed(entry: String, code: Int32)
        case notClean

        var errorDescription: String? { description }

        var description: String {
            switch self {
            case let .cloneFailed(entry, code):
                return "clonefile failed for \(entry): \(String(cString: strerror(code)))"
            case .notClean:
                return "git status was not empty after the clone"
            }
        }
    }

    /// Fixed override of `~/tbd/repos` for tests; nil resolves
    /// `TBDConstants.reposDir` (which honors `TBD_HOME`) at each use.
    private let reposDir: URL?

    /// Clones in flight per repo. A refresh never starts while this is non-zero.
    private var activeClones: [UUID: Int] = [:]
    /// Repos whose template is being written. A clone never starts during one.
    private var refreshing: Set<UUID> = []
    /// Repos where `clonefile` reported the volume cannot clone (`ENOTSUP`) or
    /// the template and worktree are on different volumes (`EXDEV`). Neither
    /// clones nor refreshes are attempted for them until the daemon restarts.
    private var unsupported: Set<UUID> = []

    /// The daemon's instance. Resolves `~/tbd/repos` per use, so it honors
    /// `TBD_HOME` set by the test fence.
    public static let shared = CheckoutTemplateStore()

    public init(reposDir: URL? = nil) {
        self.reposDir = reposDir
    }

    nonisolated func paths(repoID: UUID) -> TemplatePaths {
        let root: URL
        if let reposDir {
            root = reposDir
                .appendingPathComponent(repoID.uuidString)
                .appendingPathComponent(TBDConstants.checkoutTemplateDirName, isDirectory: true)
        } else {
            root = TBDConstants.checkoutTemplateDir(
                repoID: repoID, environment: ProcessInfo.processInfo.environment)
        }
        return TemplatePaths(
            root: root,
            tree: root.appendingPathComponent("tree", isDirectory: true),
            index: root.appendingPathComponent("index"),
            commitFile: root.appendingPathComponent("commit"))
    }

    // MARK: - Create

    /// Creates a worktree on a new branch from `baseBranch`, populated from the
    /// template where possible. Throws only when `git worktree add
    /// --no-checkout` itself fails, when the fallback checkout fails, or when
    /// the `post-checkout` hook fails — the failures a plain `worktreeAdd`
    /// would also have reported, so the caller's cleanup applies unchanged.
    public nonisolated func addWorktree(
        git: GitManager, repoID: UUID, repoPath: String,
        worktreePath: String, branch: String, baseBranch: String
    ) async throws -> Outcome {
        try await git.worktreeAddNoCheckout(
            repoPath: repoPath, worktreePath: worktreePath, branch: branch, baseBranch: baseBranch)

        let outcome: Outcome
        do {
            outcome = try await populateFromTemplate(
                git: git, repoID: repoID, worktreePath: worktreePath)
        } catch {
            logger.info("""
            clone checkout fell back for \(worktreePath, privacy: .public): \
            \(String(describing: error), privacy: .public)
            """)
            try Self.emptyWorktree(worktreePath)
            // An index of HEAD with no stat data: `reset --hard` then writes
            // every file, exactly as an ordinary checkout would.
            try await git.readTree(worktreePath: worktreePath, treeish: "HEAD")
            try await git.resetHardToHead(worktreePath: worktreePath)
            outcome = .materialized(reason: String(describing: error))
        }

        let head = try await git.headSHA(worktreePath: worktreePath)
        try await git.runPostCheckoutHook(worktreePath: worktreePath, newHead: head)
        return outcome
    }

    private nonisolated func populateFromTemplate(
        git: GitManager, repoID: UUID, worktreePath: String
    ) async throws -> Outcome {
        guard let template = await beginClone(repoID: repoID) else {
            return try await materializeWithoutTemplate(git: git, worktreePath: worktreePath)
        }
        do {
            try Self.cloneTree(from: template.tree, into: worktreePath)
        } catch CloneError.cloneFailed(let entry, let code) where code == ENOTSUP || code == EXDEV {
            await endClone(repoID: repoID, unsupported: true)
            throw CloneError.cloneFailed(entry: entry, code: code)
        } catch {
            await endClone(repoID: repoID, unsupported: false)
            throw error
        }
        await endClone(repoID: repoID, unsupported: false)

        try await git.readTree(worktreePath: worktreePath, treeish: template.commit)
        try await git.refreshIndex(worktreePath: worktreePath)
        try await git.resetHardToHead(worktreePath: worktreePath)
        guard try await git.isStatusEmpty(worktreePath: worktreePath) else {
            // The template holds something its commit does not track. The
            // fast refresh path would carry it forward forever, so drop the
            // commit file: the next refresh rebuilds from scratch.
            await invalidate(repoID: repoID)
            throw CloneError.notClean
        }
        return .cloned(templateCommit: template.commit)
    }

    /// No usable template: an ordinary checkout into the empty worktree.
    private nonisolated func materializeWithoutTemplate(
        git: GitManager, worktreePath: String
    ) async throws -> Outcome {
        try await git.readTree(worktreePath: worktreePath, treeish: "HEAD")
        try await git.resetHardToHead(worktreePath: worktreePath)
        return .materialized(reason: "no template")
    }

    private func beginClone(repoID: UUID) -> (tree: String, commit: String)? {
        guard !refreshing.contains(repoID), !unsupported.contains(repoID) else { return nil }
        let paths = self.paths(repoID: repoID)
        guard let commit = Self.readCommit(paths.commitFile),
              FileManager.default.fileExists(atPath: paths.tree.path)
        else { return nil }
        activeClones[repoID, default: 0] += 1
        return (paths.tree.path, commit)
    }

    private func endClone(repoID: UUID, unsupported isUnsupported: Bool) {
        let remaining = (activeClones[repoID] ?? 1) - 1
        activeClones[repoID] = remaining > 0 ? remaining : nil
        if isUnsupported {
            unsupported.insert(repoID)
            // A template nothing can clone from is a full checkout of waste.
            try? FileManager.default.removeItem(at: paths(repoID: repoID).root)
            logger.info("clone checkout: volume cannot clone for repo \(repoID.uuidString, privacy: .public)")
        }
    }

    /// Makes the repo's template read as absent until a refresh rebuilds it.
    private func invalidate(repoID: UUID) {
        guard !refreshing.contains(repoID) else { return }
        try? FileManager.default.removeItem(at: paths(repoID: repoID).commitFile)
        logger.info("clone checkout: template invalidated for repo \(repoID.uuidString, privacy: .public)")
    }

    // MARK: - Template refresh

    /// Moves the repo's template to `commit`, building it if absent. A no-op
    /// when the template is already there, when a clone or another refresh of
    /// the repo is in flight, or when the repo's volume cannot clone. Never
    /// throws: a failed refresh leaves no template, and creates materialize
    /// normally until a later refresh succeeds.
    public func refresh(git: GitManager, repoID: UUID, repoPath: String, toCommit commit: String) async {
        guard !unsupported.contains(repoID),
              !refreshing.contains(repoID),
              (activeClones[repoID] ?? 0) == 0
        else { return }
        let paths = self.paths(repoID: repoID)
        guard Self.readCommit(paths.commitFile) != commit else { return }
        refreshing.insert(repoID)
        do {
            try await Self.writeTemplate(git: git, paths: paths, repoPath: repoPath, commit: commit)
        } catch CloneError.cloneFailed(_, let code) where code == ENOTSUP {
            unsupported.insert(repoID)
            logger.info("clone checkout: volume cannot clone for repo \(repoID.uuidString, privacy: .public)")
        } catch {
            logger.warning("""
            clone checkout: template refresh failed for repo \(repoID.uuidString, privacy: .public): \
            \(String(describing: error), privacy: .public)
            """)
        }
        refreshing.remove(repoID)
    }

    private static func writeTemplate(
        git: GitManager, paths: TemplatePaths, repoPath: String, commit: String
    ) async throws {
        let fm = FileManager.default
        try fm.createDirectory(at: paths.root, withIntermediateDirectories: true)
        // A template on a volume that cannot clone would cost a full checkout
        // and save nothing.
        let canClone = (try? paths.root.resourceValues(forKeys: [.volumeSupportsFileCloningKey]))?
            .volumeSupportsFileCloning
        guard canClone == true else {
            try? fm.removeItem(at: paths.root)
            throw CloneError.cloneFailed(entry: paths.root.path, code: ENOTSUP)
        }
        let previous = readCommit(paths.commitFile)
        // Removed first, so a crash mid-write leaves a template that reads as
        // absent and is rebuilt, never one that names the wrong commit.
        try? fm.removeItem(at: paths.commitFile)
        let common = try await git.commonGitDir(repoPath: repoPath)

        var advanced = false
        if previous != nil, fm.fileExists(atPath: paths.tree.path), fm.fileExists(atPath: paths.index.path) {
            do {
                try await git.checkoutTemplate(
                    commonGitDir: common, treePath: paths.tree.path, indexPath: paths.index.path,
                    commit: commit, fromScratch: false)
                advanced = true
            } catch {
                logger.info("clone checkout: rebuilding template: \(String(describing: error), privacy: .public)")
            }
        }
        if !advanced {
            try? fm.removeItem(at: paths.tree)
            try? fm.removeItem(at: paths.index)
            try fm.createDirectory(at: paths.tree, withIntermediateDirectories: true)
            try await git.checkoutTemplate(
                commonGitDir: common, treePath: paths.tree.path, indexPath: paths.index.path,
                commit: commit, fromScratch: true)
        }
        try Data((commit + "\n").utf8).write(to: paths.commitFile, options: .atomic)
    }

    // MARK: - Filesystem

    static func readCommit(_ url: URL) -> String? {
        guard let data = try? Data(contentsOf: url),
              let text = String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines),
              !text.isEmpty
        else { return nil }
        return text
    }

    /// Clones each top-level entry of `source` into `destination`, which must
    /// already exist and hold nothing but `.git`. `clonefile(2)` clones a
    /// directory hierarchy in one call, sharing every file's data blocks.
    static func cloneTree(from source: String, into destination: String) throws {
        let names = try FileManager.default.contentsOfDirectory(atPath: source)
        for name in names.sorted() where name != ".git" {
            let from = (source as NSString).appendingPathComponent(name)
            let to = (destination as NSString).appendingPathComponent(name)
            // CLONE_NOFOLLOW: a tracked symlink is cloned as the link, not
            // as whatever it points at.
            guard clonefile(from, to, UInt32(CLONE_NOFOLLOW)) == 0 else {
                throw CloneError.cloneFailed(entry: name, code: errno)
            }
        }
    }

    /// Removes everything in a worktree except its `.git` file.
    static func emptyWorktree(_ path: String) throws {
        let fm = FileManager.default
        for name in try fm.contentsOfDirectory(atPath: path) where name != ".git" {
            try fm.removeItem(atPath: (path as NSString).appendingPathComponent(name))
        }
    }
}
