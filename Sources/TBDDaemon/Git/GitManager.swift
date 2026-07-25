import Foundation
import os

private let logger = Logger(subsystem: "com.tbd.daemon", category: "GitManager")

/// Error thrown when a git subprocess outlives its timeout and is killed.
/// Distinct from `GitError` (which represents a clean non-zero exit) so the
/// exit-code-1 catch sites don't accidentally swallow a wedged-command kill.
public struct GitTimeoutError: Error, CustomStringConvertible {
    public let command: String
    public let timeout: Duration
    public var description: String {
        "Git command timed out after \(timeout): \(command)"
    }
}

/// A single entry from `git worktree list --porcelain`, parsed with full
/// detail (lock state, detached-HEAD detection) for the orphan-GC sweep.
/// Bare-repository entries (no `HEAD` line) are dropped by the parser since
/// they aren't worktrees a GC pass would ever act on.
public struct WorktreeListEntry: Sendable, Equatable {
    /// Canonical path as git reports it (git itself `realpath()`s worktree
    /// paths when recording them, so no extra resolution is needed here).
    public var path: String
    public var headSHA: String
    /// `nil` when the worktree's HEAD is detached.
    public var branch: String?
    public var locked: Bool

    public init(path: String, headSHA: String, branch: String?, locked: Bool) {
        self.path = path
        self.headSHA = headSHA
        self.branch = branch
        self.locked = locked
    }
}

/// A branch reference returned by `GitManager.listBranches`.
///
/// Includes both `refs/heads/*` (local) and `refs/remotes/origin/*` (remote
/// tracking) entries. `localName` strips the `origin/` prefix for remote
/// entries — it's the name the new local branch will receive when the user
/// picks a remote ref to create a worktree from.
public struct BranchRef: Sendable, Equatable {
    /// e.g. `main` or `origin/feature/x`.
    public let name: String
    public let isRemote: Bool
    /// For remote: stripped of the `origin/` prefix. For local: same as `name`.
    public let localName: String

    public init(name: String, isRemote: Bool, localName: String) {
        self.name = name
        self.isRemote = isRemote
        self.localName = localName
    }
}

/// Error thrown when a git command fails.
public struct GitError: Error, CustomStringConvertible {
    public let command: String
    public let exitCode: Int32
    public let stderr: String

    public var description: String {
        "Git command failed (\(exitCode)): \(command)\n\(stderr)"
    }
}

/// Manages git operations by shelling out to the `git` CLI.
public struct GitManager: Sendable {

    /// Hard ceiling on any single `git` subprocess. Network git ops (fetch,
    /// clone) can legitimately run for tens of seconds, so this is far more
    /// generous than tmux's ceiling — but it is still bounded. A daemon-child
    /// `git fetch origin main` was once found stuck for 95 minutes, holding a
    /// continuation open forever; this converts that into a catchable failure.
    public static let commandTimeout: Duration = .seconds(120)

    /// Per-instance timeout; tests inject a tiny value to exercise the kill path.
    let subprocessTimeout: Duration

    /// Behavior seam for the subprocess deadline (`Tests/CLAUDE.md`, "Clock and
    /// date seams"). Tests pass a `TestClock` to fire — or never fire — the
    /// timeout in virtual time instead of racing a real one on a loaded runner.
    let clock: any Clock<Duration>

    public init(subprocessTimeout: Duration = GitManager.commandTimeout,
                clock: any Clock<Duration> = ContinuousClock()) {
        self.subprocessTimeout = subprocessTimeout
        self.clock = clock
    }

    // MARK: - Public API

    /// Returns `true` if the given path is inside a git repository.
    public func isGitRepo(path: String) async -> Bool {
        do {
            _ = try await run(arguments: ["rev-parse", "--git-dir"], at: path)
            return true
        } catch {
            return false
        }
    }

    /// Detects the default branch for the repository.
    ///
    /// First tries `git symbolic-ref refs/remotes/origin/HEAD` (which gives the
    /// remote's default branch), then falls back to the local HEAD branch name.
    public func detectDefaultBranch(repoPath: String) async throws -> String {
        // Try remote default branch first
        if let result = try? await run(arguments: ["symbolic-ref", "refs/remotes/origin/HEAD"], at: repoPath) {
            let trimmed = result.trimmingCharacters(in: .whitespacesAndNewlines)
            // refs/remotes/origin/main -> main
            if let lastSlash = trimmed.lastIndex(of: "/") {
                let branch = String(trimmed[trimmed.index(after: lastSlash)...])
                if !branch.isEmpty {
                    return branch
                }
            }
        }

        // Fall back to local HEAD branch
        let result = try await run(arguments: ["symbolic-ref", "--short", "HEAD"], at: repoPath)
        let trimmed = result.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            throw GitError(
                command: "git symbolic-ref --short HEAD",
                exitCode: 0,
                stderr: "git symbolic-ref --short HEAD succeeded but returned empty output (likely a pipe-drain race upstream)"
            )
        }
        return trimmed
    }

    /// Returns the URL of the `origin` remote, or `nil` if none is configured.
    public func getRemoteURL(repoPath: String) async -> String? {
        guard let result = try? await run(arguments: ["remote", "get-url", "origin"], at: repoPath) else {
            return nil
        }
        let trimmed = result.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// Returns the upstream head branch name configured for the current worktree branch.
    public func upstreamBranchName(worktreePath: String, branch: String) async -> String? {
        guard let mergeRef = try? await run(
            arguments: ["config", "--get", "branch.\(branch).merge"],
            at: worktreePath
        ) else {
            return nil
        }

        let trimmed = mergeRef.trimmingCharacters(in: .whitespacesAndNewlines)
        let prefix = "refs/heads/"
        if trimmed.hasPrefix(prefix) {
            let branchName = String(trimmed.dropFirst(prefix.count))
            return branchName.isEmpty ? nil : branchName
        }

        return trimmed.isEmpty ? nil : trimmed
    }

    /// Fetches from origin for the given branch, with optional timeout override.
    public func fetch(repoPath: String, branch: String, timeout: Duration? = nil) async throws {
        _ = try await run(arguments: ["fetch", "origin", branch], at: repoPath, timeout: timeout)
    }

    /// Fetches all refs from origin, with optional timeout override.
    public func fetch(repoPath: String, timeout: Duration? = nil) async throws {
        _ = try await run(arguments: ["fetch", "origin"], at: repoPath, timeout: timeout)
    }

    /// True if `refs/heads/<name>` exists locally. Used to pick a
    /// non-clobbering local branch name before force-fetching a pull ref.
    ///
    /// Fails closed, unlike the read-only `refExists`: this result gates
    /// whether `fetchPullRequestHead`'s `+refs/pull/<n>/head:refs/heads/<name>`
    /// force-refspec is safe to run against `name`. Only the benign "ref
    /// missing" case (`show-ref --quiet` exits 1) is treated as absent — any
    /// other failure (timeout, spawn failure, other exit codes) is rethrown so
    /// a bad answer here can't let the force-fetch silently clobber a branch.
    public func localBranchExists(repoPath: String, name: String) async throws -> Bool {
        do {
            _ = try await run(arguments: ["show-ref", "--verify", "--quiet", "refs/heads/\(name)"], at: repoPath)
            return true
        } catch let error as GitError where error.exitCode == 1 {
            return false
        }
    }

    /// Fetches a PR head (same-repo or fork — `refs/pull/<n>/head` exists for
    /// both) into a local branch. The `+` force-updates, so callers MUST pass a
    /// branch name verified free via `localBranchExists` / uniquification, or an
    /// unrelated same-named branch is silently rewritten.
    public func fetchPullRequestHead(repoPath: String, number: Int, localBranch: String) async throws {
        _ = try await run(
            arguments: ["fetch", "origin", "+refs/pull/\(number)/head:refs/heads/\(localBranch)"],
            at: repoPath
        )
    }

    /// Returns the HEAD SHA for a branch or ref.
    public func headSHA(repoPath: String, ref: String = "HEAD") async throws -> String {
        let output = try await run(arguments: ["rev-parse", ref], at: repoPath)
        let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            throw GitError(
                command: "git rev-parse \(ref)",
                exitCode: 0,
                stderr: "git rev-parse \(ref) succeeded but returned empty output (likely a pipe-drain race upstream)"
            )
        }
        return trimmed
    }

    /// Returns `true` if the repo at `path` has at least one commit (HEAD resolves).
    public func hasCommits(path: String) async -> Bool {
        (try? await run(arguments: ["rev-parse", "--verify", "HEAD"], at: path)) != nil
    }

    /// Returns `true` if there are uncommitted changes (staged or unstaged).
    public func hasUncommittedChanges(repoPath: String) async throws -> Bool {
        let output = try await run(arguments: ["status", "--porcelain"], at: repoPath)
        return !output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// Returns a map of short ref name → tip SHA covering all local branches
    /// and `origin/*` remote-tracking branches, in a single subprocess.
    ///
    /// Used by the periodic conflict sweep's dirty gate: one `for-each-ref`
    /// per repo resolves every worktree branch tip plus the
    /// `origin/<defaultBranch>` tip, replacing per-worktree probes.
    public func refTips(repoPath: String) async throws -> [String: String] {
        let output = try await run(
            arguments: [
                "for-each-ref",
                "--format=%(objectname) %(refname:short)",
                "refs/heads",
                "refs/remotes/origin",
            ],
            at: repoPath
        )
        var tips: [String: String] = [:]
        for line in output.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { continue }
            // "<sha> <short-name>" — the SHA can't contain spaces, so split on
            // the first space and keep the remainder as the name.
            guard let sep = trimmed.firstIndex(of: " ") else { continue }
            let sha = String(trimmed[..<sep])
            let name = String(trimmed[trimmed.index(after: sep)...])
            guard !sha.isEmpty, !name.isEmpty else { continue }
            tips[name] = sha
        }
        return tips
    }

    /// Returns true if `base` is an ancestor of `branch` (i.e., branch is ahead or equal, no divergence).
    /// Returns nil if the git command fails for reasons other than "not an ancestor" (e.g., unknown ref).
    public func isMergeBaseAncestor(repoPath: String, base: String, branch: String) async -> Bool? {
        do {
            _ = try await run(arguments: ["merge-base", "--is-ancestor", base, branch], at: repoPath)
            return true  // exit code 0 means base IS an ancestor
        } catch let error as GitError where error.exitCode == 1 {
            return false  // exit code 1 means it's NOT an ancestor
        } catch {
            return nil  // real error (bad ref, corrupt repo, etc.)
        }
    }

    /// Creates a new worktree at `worktreePath` on a new branch based on `baseBranch`.
    /// Enables parallel checkout for faster working-tree setup.
    public func worktreeAdd(repoPath: String, worktreePath: String, branch: String, baseBranch: String) async throws {
        _ = try await run(arguments: ["-c", "checkout.workers=0", "worktree", "add", worktreePath, "-b", branch, baseBranch], at: repoPath)
    }

    /// Adds a worktree at `worktreePath` using an existing branch (no -b flag).
    /// Enables parallel checkout for faster working-tree setup.
    public func worktreeAddExisting(repoPath: String, worktreePath: String, branch: String) async throws {
        _ = try await run(arguments: ["-c", "checkout.workers=0", "worktree", "add", worktreePath, branch], at: repoPath)
    }

    /// Adds a worktree at `worktreePath` tracking an existing remote branch.
    /// Creates a local branch named `localBranch` from `remoteRef`
    /// (e.g. `origin/foo`) with upstream tracking configured.
    /// Enables parallel checkout for faster working-tree setup.
    public func worktreeAddTrackingRemote(repoPath: String, worktreePath: String, localBranch: String, remoteRef: String) async throws {
        _ = try await run(
            arguments: ["-c", "checkout.workers=0", "worktree", "add", "--track", "-b", localBranch, worktreePath, remoteRef],
            at: repoPath
        )
    }

    /// Adds a worktree at `worktreePath`, creating a new branch pointing at the given SHA.
    /// Used as a fallback when the original branch was renamed/deleted but we have the
    /// archived HEAD SHA to recover the commit.
    /// Enables parallel checkout for faster working-tree setup.
    public func worktreeAddNewBranch(repoPath: String, worktreePath: String, branch: String, sha: String) async throws {
        _ = try await run(
            arguments: ["-c", "checkout.workers=0", "worktree", "add", "-b", branch, worktreePath, sha],
            at: repoPath
        )
    }

    /// Returns the HEAD SHA of a worktree directory.
    public func headSHA(worktreePath: String) async throws -> String {
        let output = try await run(arguments: ["rev-parse", "HEAD"], at: worktreePath)
        let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            throw GitError(
                command: "git rev-parse HEAD",
                exitCode: 0,
                stderr: "git rev-parse HEAD succeeded but returned empty output (likely a pipe-drain race upstream)"
            )
        }
        return trimmed
    }

    /// Returns true if the given branch / ref name resolves in the repo.
    public func refExists(repoPath: String, ref: String) async -> Bool {
        do {
            _ = try await run(arguments: ["rev-parse", "--verify", "--quiet", ref], at: repoPath)
            return true
        } catch {
            return false
        }
    }

    /// Returns the raw output of `git log -g --all --pretty=%H %gs` for reflog mining.
    /// Used by the archived-worktree backfill to discover branch renames.
    public func reflogAll(repoPath: String) async throws -> String {
        return try await run(arguments: ["log", "-g", "--all", "--pretty=%H %gs"], at: repoPath)
    }

    /// Removes a worktree at the given path.
    public func worktreeRemove(repoPath: String, worktreePath: String) async throws {
        _ = try await run(arguments: ["worktree", "remove", worktreePath, "--force"], at: repoPath)
    }

    /// Prunes stale worktree tracking entries.
    public func worktreePrune(repoPath: String) async throws {
        _ = try await run(arguments: ["worktree", "prune"], at: repoPath)
    }

    /// Lists local branches and `origin/*` remote tracking branches that are
    /// available to check out into a new worktree.
    ///
    /// Filtering:
    /// - Symbolic refs like `origin/HEAD` are skipped (they're aliases).
    /// - Branches already checked out in any worktree are skipped — git refuses
    ///   to check the same branch out twice, and for a remote ref `origin/foo`
    ///   we'd `-b foo` which would also collide.
    /// - When a local `foo` and `origin/foo` both exist, the remote duplicate
    ///   is dropped — the local is directly usable via `git worktree add <path> <branch>`.
    public func listBranches(repoPath: String) async throws -> [BranchRef] {
        // %(symref) is non-empty for symbolic refs (e.g. refs/remotes/origin/HEAD,
        // which short-names to bare "origin"). Filtering by symref catches it
        // regardless of how the short name renders.
        let output = try await run(
            arguments: [
                "for-each-ref",
                "--format=%(refname:short)|%(symref)",
                "refs/heads",
                "refs/remotes/origin",
            ],
            at: repoPath
        )

        // Branches already checked out in any worktree (main repo + linked
        // worktrees) — git rejects a second checkout of the same branch.
        // Errors propagate: a silent failure here would leak in-use branches
        // and the user would see a confusing `git worktree add` failure later.
        let inUse = Set(
            try await worktreeList(repoPath: repoPath)
                .map(\.branch)
                .filter { !$0.isEmpty }
        )

        var refs: [BranchRef] = []
        var localNames = Set<String>()

        for line in output.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty { continue }
            // for-each-ref format: "<name>|<symref>" where symref is the target
            // ref for symbolic refs (empty for normal branches).
            let parts = trimmed.split(separator: "|", maxSplits: 1, omittingEmptySubsequences: false)
            guard let nameSlice = parts.first else { continue }
            let name = String(nameSlice)
            if name.isEmpty { continue }
            let symref = parts.count > 1 ? String(parts[1]).trimmingCharacters(in: .whitespaces) : ""
            if !symref.isEmpty { continue }
            let isRemote = name.hasPrefix("origin/")
            let localName: String
            if isRemote {
                localName = String(name.dropFirst("origin/".count))
            } else {
                localName = name
                localNames.insert(name)
            }
            // Drop branches already checked out somewhere — applies to local
            // refs directly, and to remote refs whose local counterpart is taken.
            if inUse.contains(localName) { continue }
            refs.append(BranchRef(
                name: name,
                isRemote: isRemote,
                localName: localName
            ))
        }

        // Drop remote entries that have a matching local branch — the local
        // is more directly usable.
        return refs.filter { ref in
            !(ref.isRemote && localNames.contains(ref.localName))
        }
    }

    /// Lists all worktrees, returning their path and branch name.
    public func worktreeList(repoPath: String) async throws -> [(path: String, branch: String)] {
        let output = try await run(arguments: ["worktree", "list", "--porcelain"], at: repoPath)
        return parseWorktreeList(output)
    }

    /// Checks for merge conflicts between two branches using `git merge-tree`.
    ///
    /// Uses the three-way merge-tree command to detect conflicts without modifying
    /// the working directory. Falls back to `(false, [])` if the command fails.
    ///
    /// - Parameters:
    ///   - repoPath: Path to the repository.
    ///   - branch: The source branch (e.g. worktree branch).
    ///   - targetBranch: The target branch (e.g. main).
    /// - Returns: A tuple of whether conflicts exist and the list of conflicting file paths.
    public func checkMergeConflicts(repoPath: String, branch: String, targetBranch: String) async -> (hasConflicts: Bool, conflictFiles: [String]) {
        do {
            // Find merge base
            let mergeBase = try await run(
                arguments: ["merge-base", targetBranch, branch],
                at: repoPath
            ).trimmingCharacters(in: .whitespacesAndNewlines)

            // Run merge-tree with the merge base
            let output = try await run(
                arguments: ["merge-tree", mergeBase, targetBranch, branch],
                at: repoPath
            )

            // Parse conflict markers from merge-tree output
            // merge-tree outputs sections starting with lines like:
            // changed in both
            //   base   100644 <hash> <file>
            //   our    100644 <hash> <file>
            //   their  100644 <hash> <file>
            // followed by conflict content with <<<<<<< markers
            var conflictFiles: [String] = []
            let lines = output.components(separatedBy: "\n")
            var inConflict = false

            for line in lines {
                if line.contains("changed in both") {
                    inConflict = true
                    continue
                }
                if inConflict, line.hasPrefix("  base") || line.hasPrefix("  our") || line.hasPrefix("  their") {
                    // Extract filename from "  base   100644 <hash> <filename>"
                    let components = line.split(whereSeparator: { $0.isWhitespace })
                    if components.count >= 4 {
                        let fileName = String(components[3...].joined(separator: " "))
                        if !conflictFiles.contains(fileName) {
                            conflictFiles.append(fileName)
                        }
                    }
                    continue
                }
                if line.contains("<<<<<<<") {
                    inConflict = false
                }
            }

            return (hasConflicts: !conflictFiles.isEmpty, conflictFiles: conflictFiles)
        } catch {
            // If merge-tree isn't available or fails, assume no conflicts
            return (hasConflicts: false, conflictFiles: [])
        }
    }

    // MARK: - Orphan-GC primitives

    /// Lists all worktrees with full detail (HEAD SHA, branch or detached,
    /// lock state) for the orphan-GC sweep. Unlike `worktreeList`, this
    /// parses the `HEAD`, `detached`, and `locked[ reason]` lines that the
    /// legacy parser ignores.
    public func worktreeListDetailed(repoPath: String) async throws -> [WorktreeListEntry] {
        let output = try await run(arguments: ["worktree", "list", "--porcelain"], at: repoPath)
        return parseWorktreeListDetailed(output)
    }

    /// Returns `true` iff `candidatePath` is a bona fide linked worktree of
    /// the repo at `repoPath` — i.e. `<candidatePath>/.git` is a *file*
    /// (not the repo root's `.git` directory) containing a `gitdir:` pointer
    /// that resolves under `<repoPath>/.git/worktrees/`.
    ///
    /// This is the proof-of-linkage check the orphan-GC sweep uses before
    /// ever touching a directory: any read/parse failure returns `false`
    /// (not proven linked → untouchable), which is the safe direction since
    /// callers only act on directories proven to be linked worktrees.
    ///
    /// Foundation's `URL.resolvingSymlinksInPath()` does NOT follow macOS's
    /// `/var` → `/private/var` symlink; POSIX `realpath()` does (see the
    /// same trap documented in `WorktreeCommands.swift`), so resolution here
    /// goes through `realpath()` directly.
    public func isLinkedWorktree(candidatePath: String, repoPath: String) async -> Bool {
        let gitFilePath = candidatePath + "/.git"
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: gitFilePath, isDirectory: &isDirectory),
              !isDirectory.boolValue else {
            return false
        }
        guard let contents = try? String(contentsOfFile: gitFilePath, encoding: .utf8) else {
            return false
        }
        let trimmed = contents.trimmingCharacters(in: .whitespacesAndNewlines)
        let prefix = "gitdir: "
        guard trimmed.hasPrefix(prefix) else {
            return false
        }
        let gitdirPath = String(trimmed.dropFirst(prefix.count))
        guard let resolvedGitdir = Self.resolveRealPath(gitdirPath),
              let resolvedWorktreesDir = Self.resolveRealPath(repoPath + "/.git/worktrees") else {
            return false
        }
        return resolvedGitdir.hasPrefix(resolvedWorktreesDir + "/")
    }

    /// Returns `true` if `git status --porcelain` reports any changes
    /// (tracked or untracked) in the worktree. A thrown error (e.g. the path
    /// isn't a git worktree at all) is treated as `true` — fail toward
    /// keeping the worktree rather than reaping something we couldn't
    /// actually verify was clean.
    public func isDirty(worktreePath: String) async -> Bool {
        guard let output = try? await run(arguments: ["status", "--porcelain"], at: worktreePath) else {
            return true
        }
        return !output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// Returns `true` if `sha` is an ancestor of (contained in) any local
    /// branch. A thrown error is treated as `false` — the orphan-GC caller
    /// treats `false` as "no branch protects this commit, create an anchor
    /// ref", so failing to `false` here fails toward MORE protection, not
    /// less.
    public func isReachableFromAnyBranch(repoPath: String, sha: String) async -> Bool {
        guard let output = try? await run(
            arguments: ["branch", "--contains", sha, "--format=%(refname)"],
            at: repoPath
        ) else {
            return false
        }
        return !output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// Stages every change in the worktree (`git add -A`) and writes the
    /// resulting index as a tree object, returning its SHA.
    ///
    /// This intentionally mutates the worktree's real index rather than
    /// using a scratch `GIT_INDEX_FILE` — the worktree is orphaned and about
    /// to be deleted by the GC sweep, so there's no working state left to
    /// preserve.
    public func stageAllAndWriteTree(worktreePath: String) async throws -> String {
        _ = try await run(arguments: ["add", "-A"], at: worktreePath)
        let output = try await run(arguments: ["write-tree"], at: worktreePath)
        return output.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Creates a commit object from an existing tree with a single parent,
    /// without touching any ref. Returns the new commit's SHA.
    public func commitTree(repoPath: String, tree: String, parent: String, message: String) async throws -> String {
        let output = try await run(
            arguments: ["commit-tree", tree, "-p", parent, "-m", message],
            at: repoPath
        )
        return output.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Points `ref` at `sha`, creating it if it doesn't exist.
    public func updateRef(repoPath: String, ref: String, sha: String) async throws {
        _ = try await run(arguments: ["update-ref", ref, sha], at: repoPath)
    }

    /// Deletes `ref`.
    public func deleteRef(repoPath: String, ref: String) async throws {
        _ = try await run(arguments: ["update-ref", "-d", ref], at: repoPath)
    }

    /// Lists all ref names under `prefix` (e.g. `refs/tbd/snapshots`).
    public func listRefs(repoPath: String, prefix: String) async throws -> [String] {
        let output = try await run(
            arguments: ["for-each-ref", "--format=%(refname)", prefix],
            at: repoPath
        )
        return output
            .components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    /// Restores every path in the worktree to its content in `ref`.
    ///
    /// Known limitation: this only restores content present in the ref's
    /// tree — files that were *deleted* in the pre-snapshot dirty state are
    /// not re-deleted (git's `restore` doesn't replay deletions for paths it
    /// wasn't asked about). Acceptable for the GC use case, where the goal
    /// is recovering lost work, not exact working-tree reconstruction.
    public func restoreFromRef(worktreePath: String, ref: String) async throws {
        _ = try await run(arguments: ["restore", "--source", ref, "--worktree", "--", "."], at: worktreePath)
    }

    /// Adds a worktree either on an existing `branch` or detached at `sha`.
    /// At least one of `branch`/`sha` must be non-nil (both nil throws
    /// `GitError`); when both are given, `branch` wins and `sha` is ignored.
    public func worktreeAdd(repoPath: String, path: String, branch: String?, detachAt sha: String?) async throws {
        if let branch {
            _ = try await run(arguments: ["worktree", "add", path, branch], at: repoPath)
        } else if let sha {
            _ = try await run(arguments: ["worktree", "add", "--detach", path, sha], at: repoPath)
        } else {
            throw GitError(
                command: "git worktree add \(path)",
                exitCode: -1,
                stderr: "worktreeAdd requires either a branch or a detachAt sha"
            )
        }
    }

    // MARK: - Private

    /// Runs a git command with the given arguments at the given directory and returns stdout.
    /// Throws `GitError` on non-zero exit.
    /// Package-internal test seam: drives `run()`'s timeout/kill wrapper against
    /// an arbitrary executable so the SIGTERM→SIGKILL path (and `GitTimeoutError`)
    /// is unit-testable deterministically, without relying on a real git operation
    /// hanging (which it does not reliably do across environments).
    func runForTimeoutTesting(executable: String, arguments: [String], at directory: String) async throws -> String {
        try await run(arguments: arguments, at: directory, executable: executable)
    }

    /// `executable` defaults to git; it is overridable ONLY so the package-internal
    /// `runForTimeoutTesting` seam can drive this exact timeout/kill wrapper against
    /// a slow binary (`/bin/sleep`) deterministically — real git has no reliable
    /// cross-environment hang to exercise the kill path (a post-checkout hook did
    /// not fire on CI). Production callers never pass `executable`.
    private func run(arguments: [String], at directory: String,
                     timeout: Duration? = nil,
                     executable: String = "/usr/bin/git") async throws -> String {
        let resolvedTimeout = timeout ?? subprocessTimeout
        let commandDescription = "git " + arguments.joined(separator: " ")
        // All the mechanism (starvation-proof watchdog thread, authoritative
        // deadline, incremental pipe draining, no-EOF-wait, single-resume
        // guard) lives in the shared `runBoundedProcess`; this only maps the
        // outcome to GitError/GitTimeoutError. A wedged git child (a `git fetch`
        // was once stuck 95 min) is escalated SIGTERM → SIGKILL there and
        // surfaces here as GitTimeoutError.
        switch try await runBoundedProcess(
            executable: executable,
            arguments: arguments,
            currentDirectory: directory,
            timeout: resolvedTimeout,
            clock: clock
        ) {
        case .timedOut:
            logger.warning("git subprocess timed out after \(resolvedTimeout, privacy: .public): \(commandDescription, privacy: .public)")
            throw GitTimeoutError(command: commandDescription, timeout: resolvedTimeout)
        case let .completed(status, stdoutData, stderrData):
            let stdout = String(data: stdoutData, encoding: .utf8) ?? ""
            let stderr = String(data: stderrData, encoding: .utf8) ?? ""
            if status != 0 {
                throw GitError(command: commandDescription, exitCode: status, stderr: stderr)
            }
            return stdout
        }
    }

    /// Parses the porcelain output of `git worktree list`.
    ///
    /// Format:
    /// ```
    /// worktree /path/to/worktree
    /// HEAD abc123
    /// branch refs/heads/main
    ///
    /// worktree /path/to/other
    /// HEAD def456
    /// branch refs/heads/feature
    /// ```
    private func parseWorktreeList(_ output: String) -> [(path: String, branch: String)] {
        var results: [(path: String, branch: String)] = []
        var currentPath: String?
        var currentBranch: String?

        for line in output.components(separatedBy: "\n") {
            if line.hasPrefix("worktree ") {
                // Save previous entry if any
                if let path = currentPath {
                    results.append((path: path, branch: currentBranch ?? ""))
                }
                currentPath = String(line.dropFirst("worktree ".count))
                currentBranch = nil
            } else if line.hasPrefix("branch ") {
                let ref = String(line.dropFirst("branch ".count))
                // refs/heads/main -> main
                if ref.hasPrefix("refs/heads/") {
                    currentBranch = String(ref.dropFirst("refs/heads/".count))
                } else {
                    currentBranch = ref
                }
            }
        }

        // Don't forget the last entry
        if let path = currentPath {
            results.append((path: path, branch: currentBranch ?? ""))
        }

        return results
    }

    /// Parses the porcelain output of `git worktree list --porcelain` into
    /// full-detail entries (HEAD SHA, detached vs. branch, lock state).
    ///
    /// Format (blank-line-separated blocks):
    /// ```
    /// worktree /path/to/worktree
    /// HEAD abc123
    /// branch refs/heads/main
    /// locked optional reason
    ///
    /// worktree /path/to/other
    /// HEAD def456
    /// detached
    /// ```
    /// Entries with no `HEAD` line (bare-repository entries, which report a
    /// `bare` line instead) are dropped — a GC sweep never acts on the bare
    /// source repo itself.
    private func parseWorktreeListDetailed(_ output: String) -> [WorktreeListEntry] {
        var results: [WorktreeListEntry] = []
        var currentPath: String?
        var currentHeadSHA: String?
        var currentBranch: String?
        var currentLocked = false

        func flush() {
            if let path = currentPath, let headSHA = currentHeadSHA {
                results.append(WorktreeListEntry(path: path, headSHA: headSHA, branch: currentBranch, locked: currentLocked))
            }
        }

        for line in output.components(separatedBy: "\n") {
            if line.hasPrefix("worktree ") {
                flush()
                currentPath = String(line.dropFirst("worktree ".count))
                currentHeadSHA = nil
                currentBranch = nil
                currentLocked = false
            } else if line.hasPrefix("HEAD ") {
                currentHeadSHA = String(line.dropFirst("HEAD ".count))
            } else if line.hasPrefix("branch ") {
                let ref = String(line.dropFirst("branch ".count))
                if ref.hasPrefix("refs/heads/") {
                    currentBranch = String(ref.dropFirst("refs/heads/".count))
                } else {
                    currentBranch = ref
                }
            } else if line == "detached" {
                currentBranch = nil
            } else if line == "locked" || line.hasPrefix("locked ") {
                currentLocked = true
            }
        }

        flush()
        return results
    }

    /// Resolves `path` through POSIX `realpath()`, following every symlink
    /// component including macOS's `/var` → `/private/var`, which
    /// `URL.resolvingSymlinksInPath()` does not follow. Returns `nil` if any
    /// path component doesn't exist.
    private static func resolveRealPath(_ path: String) -> String? {
        guard let cString = realpath(path, nil) else { return nil }
        defer { free(cString) }
        return String(cString: cString)
    }
}

/// Thread-safe accumulator for incremental pipe reads.
///
/// Invariant: the readability handler's read and the corresponding append
/// happen under the same lock as `finish`. This prevents `terminationHandler`
/// from snapshotting between a readability handler's read and its append,
/// which would silently drop the in-flight chunk.
///
/// `finish` deliberately never blocks waiting for EOF: if the child forked
/// background grandchildren (a login shell's rc files often do), they inherit
/// the pipe write end and EOF never arrives after the direct child dies. A
/// blocking read-to-EOF would park a thread — and retain the pipe FD and every
/// captured closure — for the grandchildren's lifetime. Instead `finish`
/// drains only what is already buffered in the kernel pipe (non-blocking) and
/// closes the parent's read end, so nothing outlives the call.
///
/// Package-internal (not `private`) so `TmuxManager.runExternalCommand` shares
/// it — same >64KB drain deadlock, same grandchild-holds-write-end leak, same
/// fix (mirrors the shared `ContinuationGuard`).
final class PipeDataAccumulator: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()
    private var finished = false

    /// Reads any available data from `handle` and appends it atomically.
    /// Returns `false` on EOF or after `finish` closed the handle (so the
    /// caller detaches the readability handler), `true` otherwise.
    func readAvailable(from handle: FileHandle) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !finished else { return false }
        let chunk = handle.availableData
        if chunk.isEmpty {
            return false
        }
        data.append(chunk)
        return true
    }

    /// Drains whatever is already buffered in the pipe WITHOUT blocking,
    /// closes the parent's read end, and returns the full accumulated buffer.
    /// On the termination path the direct child is dead, so everything it
    /// wrote is already in the kernel pipe buffer and the non-blocking read
    /// loop loses nothing. On the timeout and spawn-failure paths the child
    /// may still be alive (or wedged, SIGKILL-immune); anything it writes
    /// after this snapshot is intentionally dropped — the call is already
    /// failing, and waiting for EOF is exactly the leak this exists to avoid.
    /// Acquiring the lock blocks until any in-flight `readAvailable` call has
    /// completed its append (and prevents it from touching the closed handle
    /// afterwards). Idempotent: later calls return the buffer untouched.
    func finish(handle: FileHandle) -> Data {
        lock.lock()
        defer { lock.unlock() }
        guard !finished else { return data }
        finished = true
        let fd = handle.fileDescriptor
        let flags = fcntl(fd, F_GETFL)
        if flags >= 0 {
            _ = fcntl(fd, F_SETFL, flags | O_NONBLOCK)
        }
        var chunk = [UInt8](repeating: 0, count: 65_536)
        while true {
            let count = read(fd, &chunk, chunk.count)
            if count > 0 {
                data.append(contentsOf: chunk.prefix(count))
            } else if count < 0 && errno == EINTR {
                continue
            } else {
                // 0 = EOF; -1/EAGAIN = drained all buffered data. Either way
                // the writer can add nothing we are obliged to wait for.
                break
            }
        }
        try? handle.close()
        return data
    }
}
