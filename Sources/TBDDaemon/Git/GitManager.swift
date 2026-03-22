import Foundation

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
                return String(trimmed[trimmed.index(after: lastSlash)...])
            }
        }

        // Fall back to local HEAD branch
        let result = try await run(arguments: ["symbolic-ref", "--short", "HEAD"], at: repoPath)
        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Returns the URL of the `origin` remote, or `nil` if none is configured.
    public func getRemoteURL(repoPath: String) async -> String? {
        guard let result = try? await run(arguments: ["remote", "get-url", "origin"], at: repoPath) else {
            return nil
        }
        let trimmed = result.trimmingCharacters(in: .whitespacesAndNewlines)
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

    /// Rebases the current branch onto the given target. Returns (success, output).
    public func rebase(repoPath: String, onto: String) async -> (success: Bool, output: String) {
        do {
            let output = try await run(arguments: ["rebase", onto], at: repoPath)
            return (true, output)
        } catch let error as GitError {
            return (false, error.stderr)
        } catch {
            return (false, error.localizedDescription)
        }
    }

    /// Aborts an in-progress rebase.
    public func rebaseAbort(repoPath: String) async throws {
        _ = try await run(arguments: ["rebase", "--abort"], at: repoPath)
    }

    /// Checks out the given branch.
    public func checkout(repoPath: String, branch: String) async throws {
        _ = try await run(arguments: ["checkout", branch], at: repoPath)
    }

    /// Performs a fast-forward-only merge of the given branch.
    public func mergeFFOnly(repoPath: String, branch: String) async throws {
        _ = try await run(arguments: ["merge", "--ff-only", branch], at: repoPath)
    }

    /// Performs a squash merge of the given branch (stages all changes, no commit).
    public func mergeSquash(repoPath: String, branch: String) async throws {
        _ = try await run(arguments: ["merge", "--squash", branch], at: repoPath)
    }

    /// Commits staged changes with the given message.
    public func commit(repoPath: String, message: String) async throws {
        _ = try await run(arguments: ["commit", "-m", message], at: repoPath)
    }

    /// Returns `true` if there are uncommitted changes (staged or unstaged).
    public func hasUncommittedChanges(repoPath: String) async throws -> Bool {
        let output = try await run(arguments: ["status", "--porcelain"], at: repoPath)
        return !output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// Returns the number of commits in the range `from..to`.
    public func commitCount(repoPath: String, from: String, to: String) async throws -> Int {
        let output = try await run(arguments: ["rev-list", "--count", "\(from)..\(to)"], at: repoPath)
        return Int(output.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0
    }

    /// Creates a new worktree at `worktreePath` on a new branch based on `baseBranch`.
    public func worktreeAdd(repoPath: String, worktreePath: String, branch: String, baseBranch: String) async throws {
        _ = try await run(arguments: ["worktree", "add", worktreePath, "-b", branch, baseBranch], at: repoPath)
    }

    /// Adds a worktree at `worktreePath` using an existing branch (no -b flag).
    public func worktreeAddExisting(repoPath: String, worktreePath: String, branch: String) async throws {
        _ = try await run(arguments: ["worktree", "add", worktreePath, branch], at: repoPath)
    }

    /// Removes a worktree at the given path.
    public func worktreeRemove(repoPath: String, worktreePath: String) async throws {
        _ = try await run(arguments: ["worktree", "remove", worktreePath, "--force"], at: repoPath)
    }

    /// Prunes stale worktree tracking entries.
    public func worktreePrune(repoPath: String) async throws {
        _ = try await run(arguments: ["worktree", "prune"], at: repoPath)
    }

    /// Lists all worktrees, returning their path and branch name.
    public func worktreeList(repoPath: String) async throws -> [(path: String, branch: String)] {
        let output = try await run(arguments: ["worktree", "list", "--porcelain"], at: repoPath)
        return parseWorktreeList(output)
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

            process.terminationHandler = { _ in
                let stdoutData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
                let stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
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
