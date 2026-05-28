import Foundation

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
    /// True for the currently checked-out local branch (per `git for-each-ref`'s `%(HEAD)`).
    public let isCurrent: Bool

    public init(name: String, isRemote: Bool, localName: String, isCurrent: Bool) {
        self.name = name
        self.isRemote = isRemote
        self.localName = localName
        self.isCurrent = isCurrent
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

    public init() {}

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

    /// Fetches from origin for the given branch.
    public func fetch(repoPath: String, branch: String) async throws {
        _ = try await run(arguments: ["fetch", "origin", branch], at: repoPath)
    }

    /// Fetches all refs from origin.
    public func fetch(repoPath: String) async throws {
        _ = try await run(arguments: ["fetch", "origin"], at: repoPath)
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

    /// Returns `true` if there are uncommitted changes (staged or unstaged).
    public func hasUncommittedChanges(repoPath: String) async throws -> Bool {
        let output = try await run(arguments: ["status", "--porcelain"], at: repoPath)
        return !output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
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
    public func worktreeAdd(repoPath: String, worktreePath: String, branch: String, baseBranch: String) async throws {
        _ = try await run(arguments: ["worktree", "add", worktreePath, "-b", branch, baseBranch], at: repoPath)
    }

    /// Adds a worktree at `worktreePath` using an existing branch (no -b flag).
    public func worktreeAddExisting(repoPath: String, worktreePath: String, branch: String) async throws {
        _ = try await run(arguments: ["worktree", "add", worktreePath, branch], at: repoPath)
    }

    /// Adds a worktree at `worktreePath` tracking an existing remote branch.
    /// Creates a local branch named `localBranch` from `remoteRef`
    /// (e.g. `origin/foo`) with upstream tracking configured.
    public func worktreeAddTrackingRemote(repoPath: String, worktreePath: String, localBranch: String, remoteRef: String) async throws {
        _ = try await run(
            arguments: ["worktree", "add", "--track", "-b", localBranch, worktreePath, remoteRef],
            at: repoPath
        )
    }

    /// Adds a worktree at `worktreePath`, creating a new branch pointing at the given SHA.
    /// Used as a fallback when the original branch was renamed/deleted but we have the
    /// archived HEAD SHA to recover the commit.
    public func worktreeAddNewBranch(repoPath: String, worktreePath: String, branch: String, sha: String) async throws {
        _ = try await run(
            arguments: ["worktree", "add", "-b", branch, worktreePath, sha],
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
                "--format=%(refname:short)|%(HEAD)|%(symref)",
                "refs/heads",
                "refs/remotes/origin",
            ],
            at: repoPath
        )

        // Branches already checked out in any worktree (main repo + linked
        // worktrees) — git rejects a second checkout of the same branch.
        let inUse = Set(
            (try? await worktreeList(repoPath: repoPath))?
                .map(\.branch)
                .filter { !$0.isEmpty } ?? []
        )

        var refs: [BranchRef] = []
        var localNames = Set<String>()

        for line in output.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty { continue }
            // for-each-ref format: "<name>|<HEAD-marker>|<symref>" where
            // HEAD-marker is "*" for the current branch (space otherwise), and
            // symref is the target ref for symbolic refs (empty for normal branches).
            let parts = trimmed.split(separator: "|", maxSplits: 2, omittingEmptySubsequences: false)
            guard let nameSlice = parts.first else { continue }
            let name = String(nameSlice)
            if name.isEmpty { continue }
            let symref = parts.count > 2 ? String(parts[2]).trimmingCharacters(in: .whitespaces) : ""
            if !symref.isEmpty { continue }
            let headMarker = parts.count > 1 ? String(parts[1]) : ""
            let isCurrent = headMarker.trimmingCharacters(in: .whitespaces) == "*"
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
                localName: localName,
                isCurrent: isCurrent
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

    // MARK: - Private

    /// Runs a git command with the given arguments at the given directory and returns stdout.
    /// Throws `GitError` on non-zero exit.
    private func run(arguments: [String], at directory: String) async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            let process = Process()
            let stdoutPipe = Pipe()
            let stderrPipe = Pipe()

            process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
            process.arguments = arguments
            process.currentDirectoryURL = URL(fileURLWithPath: directory)
            process.standardOutput = stdoutPipe
            process.standardError = stderrPipe

            let commandDescription = "git " + arguments.joined(separator: " ")

            // Drain pipes incrementally to prevent deadlock when output exceeds the
            // OS pipe buffer (~64KB). Without this, the child process blocks on
            // write and `terminationHandler` never fires.
            let stdoutAccumulator = PipeDataAccumulator()
            let stderrAccumulator = PipeDataAccumulator()
            stdoutPipe.fileHandleForReading.readabilityHandler = { handle in
                if !stdoutAccumulator.readAvailable(from: handle) {
                    handle.readabilityHandler = nil
                }
            }
            stderrPipe.fileHandleForReading.readabilityHandler = { handle in
                if !stderrAccumulator.readAvailable(from: handle) {
                    handle.readabilityHandler = nil
                }
            }

            process.terminationHandler = { _ in
                // Detach handlers; `finish` blocks on the same lock the readability
                // handler holds, so any in-flight read+append completes before we snapshot.
                stdoutPipe.fileHandleForReading.readabilityHandler = nil
                stderrPipe.fileHandleForReading.readabilityHandler = nil
                let stdoutData = stdoutAccumulator.finish(handle: stdoutPipe.fileHandleForReading)
                let stderrData = stderrAccumulator.finish(handle: stderrPipe.fileHandleForReading)

                let stdout = String(data: stdoutData, encoding: .utf8) ?? ""
                let stderr = String(data: stderrData, encoding: .utf8) ?? ""

                if process.terminationStatus != 0 {
                    continuation.resume(throwing: GitError(
                        command: commandDescription,
                        exitCode: process.terminationStatus,
                        stderr: stderr
                    ))
                } else {
                    continuation.resume(returning: stdout)
                }
            }

            do {
                try process.run()
            } catch {
                continuation.resume(throwing: error)
            }
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
}

/// Thread-safe accumulator for incremental pipe reads.
///
/// Invariant: `availableData`/`readToEnd` and the corresponding append happen
/// under the same lock as `finish`. This prevents `terminationHandler` from
/// snapshotting between a readability handler's read and its append, which
/// would silently drop the in-flight chunk.
private final class PipeDataAccumulator: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()

    /// Reads any available data from `handle` and appends it atomically.
    /// Returns `false` on EOF (empty read), `true` otherwise.
    func readAvailable(from handle: FileHandle) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        let chunk = handle.availableData
        if chunk.isEmpty {
            return false
        }
        data.append(chunk)
        return true
    }

    /// Drains any remaining buffered data from `handle` and returns the full
    /// accumulated buffer. Acquiring the lock blocks until any in-flight
    /// `readAvailable` call has completed its append.
    func finish(handle: FileHandle) -> Data {
        lock.lock()
        defer { lock.unlock() }
        if let tail = try? handle.readToEnd(), !tail.isEmpty {
            data.append(tail)
        }
        return data
    }
}
