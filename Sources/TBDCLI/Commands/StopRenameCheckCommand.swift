import ArgumentParser
import Foundation
import TBDShared

/// `tbd hooks stop-rename-check` — a `Stop` hook that prompts the agent to
/// rename its worktree/branch at end-of-turn, when context is highest and the
/// work is freshly visible.
///
/// Behavior (any error path = exit 0 silent so the agent is never wedged):
/// 1. Read the Stop hook JSON payload from stdin.
/// 2. Resolve the worktree for `cwd` via the daemon.
/// 3. Skip if status is .main, displayName != name (already customized),
///    branch doesn't start with `tbd/`, or we've already fired > 2 times
///    this session.
/// 4. Otherwise emit `{"decision":"block","reason":"<directive>"}` so
///    the agent stays in-turn and sees the directive.
struct StopRenameCheckCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "stop-rename-check",
        abstract: "Stop-hook directive prompting the agent to rename its worktree/branch"
    )

    mutating func run() async throws {
        let stdin = FileHandle.standardInput.readDataToEndOfFile()
        let output = StopRenameCheckCore.decide(
            stdinData: stdin,
            dependencies: .production()
        )
        if let output {
            print(output)
        }
    }
}

// MARK: - Pure core (testable)

/// Pure decision logic for `stop-rename-check`. Factored out so unit tests
/// can exercise every branch without spinning up the daemon or git.
///
/// Returns the JSON string to print on stdout, or nil for the silent exit.
enum StopRenameCheckCore {

    /// Injectable side-effects so unit tests can stand in for the daemon,
    /// git, and the filesystem counter.
    struct Dependencies {
        /// Look up the worktree for the cwd. Return nil for "skip silently"
        /// (daemon down, cwd not inside a worktree).
        var fetchWorktree: (_ cwd: String) -> WorktreeSummary?

        /// Resolve the current git branch. Return nil for "skip silently".
        var fetchBranch: (_ cwd: String) -> String?

        /// Resolve the worktree's top-level folder basename. Used in the
        /// directive text. Return nil for "skip silently".
        var fetchFolder: (_ cwd: String) -> String?

        /// Path of the per-session counter file. Production wires this to
        /// `/tmp/tbd-stop-rename-<session_id>`.
        var counterPath: (_ sessionID: String) -> String

        /// Production wiring — talks to the daemon, shells out to git.
        static func production() -> Dependencies {
            Dependencies(
                fetchWorktree: { cwd in
                    let client = SocketClient()
                    guard client.isDaemonRunning else { return nil }
                    do {
                        let resolver = PathResolver(client: client)
                        let resolved = try resolver.resolve(path: cwd)
                        guard let worktreeID = resolved.worktreeID else { return nil }
                        let worktrees: [Worktree] = try client.call(
                            method: RPCMethod.worktreeList,
                            params: WorktreeListParams(),
                            resultType: [Worktree].self
                        )
                        guard let wt = worktrees.first(where: { $0.id == worktreeID }) else {
                            return nil
                        }
                        return WorktreeSummary(
                            name: wt.name,
                            displayName: wt.displayName,
                            status: wt.status
                        )
                    } catch {
                        return nil
                    }
                },
                fetchBranch: { cwd in
                    runGit(["-C", cwd, "branch", "--show-current"])
                },
                fetchFolder: { cwd in
                    guard let topLevel = runGit(["-C", cwd, "rev-parse", "--show-toplevel"]) else {
                        return nil
                    }
                    return (topLevel as NSString).lastPathComponent
                },
                counterPath: { sessionID in
                    // Sanitize against forward slashes so the cap guarantee doesn't rely on
                    // the agent's session-id format (UUIDs today, but an external contract).
                    let safe = sessionID.replacingOccurrences(of: "/", with: "-")
                    return "/tmp/tbd-stop-rename-\(safe)"
                }
            )
        }
    }

    /// Minimal subset of `Worktree` fields the decision logic needs.
    struct WorktreeSummary {
        var name: String
        var displayName: String
        var status: WorktreeStatus
    }

    /// Maximum number of times we'll fire the directive in one session
    /// before giving up so we never trap the agent in a stop loop.
    static let maxFireCount = 2

    /// Run the decision. Returns the JSON `{"decision":"block",...}` string
    /// to print, or nil for the silent exit.
    static func decide(stdinData: Data, dependencies: Dependencies) -> String? {
        // 1. Parse stdin. Malformed → silent exit.
        guard
            let payload = try? JSONSerialization.jsonObject(with: stdinData) as? [String: Any]
        else {
            return nil
        }

        let sessionID = (payload["session_id"] as? String) ?? ""
        let cwd = (payload["cwd"] as? String) ?? ""
        // `stop_hook_active` is intentionally ignored: it also flips when *other*
        // Stop hooks block, so it's not a reliable "this hook is re-entering"
        // signal. We use the on-disk counter for loop protection instead.

        guard !sessionID.isEmpty, !cwd.isEmpty else {
            return nil
        }

        // 2. Resolve worktree.
        guard let worktree = dependencies.fetchWorktree(cwd) else {
            return nil
        }

        // 3a. Main worktree → skip.
        if worktree.status == .main {
            return nil
        }

        // 3b. Already customized → skip.
        if worktree.displayName != worktree.name {
            return nil
        }

        // 3c. Branch must be tbd/<...> for us to suggest renaming it.
        guard let branch = dependencies.fetchBranch(cwd), branch.hasPrefix("tbd/") else {
            return nil
        }

        // 3d. Folder for the `tbd worktree rename` example. Fetched before
        // the counter bump so the "fire count = times directive was shown"
        // invariant holds even if folder resolution silently fails.
        guard let folder = dependencies.fetchFolder(cwd) else {
            return nil
        }

        // 3e. Counter check. Bump first; if the new value exceeds the cap,
        // give up so we don't trap the agent in a stop loop.
        let counterPath = dependencies.counterPath(sessionID)
        let newCount = bumpCounter(at: counterPath)
        if newCount > maxFireCount {
            return nil
        }

        // 4. Build the directive and encode it as a Stop-hook block response.
        let reason = buildDirective(branch: branch, folder: folder)
        return encodeBlock(reason: reason)
    }

    /// Read the counter file (treat absence as 0), increment, and persist
    /// the new value. Returns the new value. Best-effort — IO failures fall
    /// back to returning the post-bump value we tracked in memory.
    static func bumpCounter(at path: String) -> Int {
        let current: Int
        if let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
           let text = String(data: data, encoding: .utf8),
           let parsed = Int(text.trimmingCharacters(in: .whitespacesAndNewlines)) {
            current = parsed
        } else {
            current = 0
        }
        let next = current + 1
        try? String(next).write(toFile: path, atomically: true, encoding: .utf8)
        return next
    }

    /// Build the directive shown to the agent. Mirrors the spec verbatim
    /// except for branch/folder substitution.
    static func buildDirective(branch: String, folder: String) -> String {
        """
        Before stopping: this worktree is still named \(branch). Now that the work is done, rename it to reflect what was accomplished:

          git branch -m <kebab-case-name>
          tbd worktree rename \(folder) "<emoji> <Title Case>"

        Format:
          Branch: kebab-case, under 30 chars, specific.
          Display: a relevant emoji + the branch name in Title Case.

        Examples:
          fix-login-timeout  →  ⏱ Fix Login Timeout
          add-export-csv     →  📊 Add Export CSV

        Then you may stop.
        """
    }

    /// Serialize `{"decision":"block","reason":"..."}` using JSONEncoder so
    /// quoting/escaping is correct. Both failure paths are unreachable
    /// (encoding two `String` fields can't fail and JSONEncoder always
    /// produces valid UTF-8), so the return type is non-optional.
    static func encodeBlock(reason: String) -> String {
        struct StopBlock: Encodable {
            let decision: String
            let reason: String
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try! encoder.encode(StopBlock(decision: "block", reason: reason))
        return String(data: data, encoding: .utf8)!
    }
}

/// Run `git <args>` and return trimmed stdout, or nil if it fails or has
/// no output. Best-effort — used by hook code where any failure should
/// fall through to the silent exit path.
private func runGit(_ args: [String]) -> String? {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
    process.arguments = ["git"] + args
    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = Pipe()
    do {
        try process.run()
    } catch {
        return nil
    }
    process.waitUntilExit()
    guard process.terminationStatus == 0 else { return nil }
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    guard let text = String(data: data, encoding: .utf8) else { return nil }
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? nil : trimmed
}
