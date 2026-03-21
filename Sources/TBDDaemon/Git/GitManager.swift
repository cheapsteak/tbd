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
            _ = try await run(command: "git rev-parse --git-dir", at: path)
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
        if let result = try? await run(command: "git symbolic-ref refs/remotes/origin/HEAD", at: repoPath) {
            let trimmed = result.trimmingCharacters(in: .whitespacesAndNewlines)
            // refs/remotes/origin/main -> main
            if let lastSlash = trimmed.lastIndex(of: "/") {
                return String(trimmed[trimmed.index(after: lastSlash)...])
            }
        }

        // Fall back to local HEAD branch
        let result = try await run(command: "git symbolic-ref --short HEAD", at: repoPath)
        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Returns the URL of the `origin` remote, or `nil` if none is configured.
    public func getRemoteURL(repoPath: String) async -> String? {
        guard let result = try? await run(command: "git remote get-url origin", at: repoPath) else {
            return nil
        }
        let trimmed = result.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// Fetches from origin for the given branch.
    public func fetch(repoPath: String, branch: String) async throws {
        _ = try await run(command: "git fetch origin \(branch)", at: repoPath)
    }

    /// Creates a new worktree at `worktreePath` on a new branch based on `baseBranch`.
    public func worktreeAdd(repoPath: String, worktreePath: String, branch: String, baseBranch: String) async throws {
        _ = try await run(command: "git worktree add \(worktreePath) -b \(branch) \(baseBranch)", at: repoPath)
    }

    /// Removes a worktree at the given path.
    public func worktreeRemove(repoPath: String, worktreePath: String) async throws {
        _ = try await run(command: "git worktree remove \(worktreePath) --force", at: repoPath)
    }

    /// Lists all worktrees, returning their path and branch name.
    public func worktreeList(repoPath: String) async throws -> [(path: String, branch: String)] {
        let output = try await run(command: "git worktree list --porcelain", at: repoPath)
        return parseWorktreeList(output)
    }

    // MARK: - Private

    /// Runs a shell command at the given directory and returns stdout.
    /// Throws `GitError` on non-zero exit.
    private func run(command: String, at directory: String) async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            let process = Process()
            let stdoutPipe = Pipe()
            let stderrPipe = Pipe()

            process.executableURL = URL(fileURLWithPath: "/bin/bash")
            process.arguments = ["-c", command]
            process.currentDirectoryURL = URL(fileURLWithPath: directory)
            process.standardOutput = stdoutPipe
            process.standardError = stderrPipe

            process.terminationHandler = { _ in
                let stdoutData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
                let stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
                let stdout = String(data: stdoutData, encoding: .utf8) ?? ""
                let stderr = String(data: stderrData, encoding: .utf8) ?? ""

                if process.terminationStatus != 0 {
                    continuation.resume(throwing: GitError(
                        command: command,
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
