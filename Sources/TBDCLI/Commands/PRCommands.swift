import ArgumentParser
import Foundation
import TBDShared

/// `tbd pr list|attach|detach|bind` — inspect and manage the PRs bound to a
/// worktree. Discovery is automatic (a `gh pr create` hook, branch matching);
/// these commands are for reading that list and correcting it by hand.
struct PRCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "pr",
        abstract: "Manage the pull requests bound to a worktree",
        subcommands: [
            PRListCommand.self, PRAttachCommand.self, PRDetachCommand.self, PRBindCommand.self,
        ]
    )

    /// Parse a user-typed PR reference: a full GitHub PR URL, a bare number
    /// (`412`), or a `#`-prefixed number (`#412`). A bare number has no known
    /// owner/repo yet — the daemon fills those in from the worktree's own repo
    /// — so it comes back with empty `owner`/`repo`/`url` and only `number` set.
    /// Returns nil for anything else.
    static func parseReference(_ raw: String) -> ParsedPRURL? {
        if let url = PRBindingExtractor.parsePRURLs(in: raw).first {
            return url
        }
        var digits = Substring(raw)
        if digits.hasPrefix("#") { digits.removeFirst() }
        guard !digits.isEmpty, let number = Int(digits), number > 0 else { return nil }
        return ParsedPRURL(host: "", owner: "", repo: "", number: number, url: "")
    }
}

/// Shared worktree resolution: an explicit `--worktree` (name, display name,
/// or UUID) wins; otherwise fall back to the ambient `TBD_WORKTREE_ID` that
/// every TBD-spawned terminal inherits, the same source `tbd link` and
/// `tbd scratch promote` already trust.
struct WorktreeOption: ParsableArguments {
    @Option(name: .long, help: "Worktree name, display name, or UUID (defaults to the current worktree)")
    var worktree: String?

    func resolve(client: SocketClient) throws -> UUID {
        if let worktree {
            return try resolveWorktreeNameOrID(worktree, client: client)
        }
        guard
            let envValue = ProcessInfo.processInfo.environment["TBD_WORKTREE_ID"],
            let id = UUID(uuidString: envValue)
        else {
            throw CLIError.invalidArgument(
                "not inside a TBD terminal; pass --worktree with a name or UUID"
            )
        }
        return id
    }
}

// MARK: - pr list

struct PRListCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "list",
        abstract: "List the PRs bound to a worktree"
    )

    @OptionGroup var worktreeOption: WorktreeOption

    mutating func run() async throws {
        let client = SocketClient()
        let worktreeID = try worktreeOption.resolve(client: client)
        let result: PRBindingsResult = try client.call(
            method: RPCMethod.prBindings,
            params: PRBindingsParams(worktreeID: worktreeID),
            resultType: PRBindingsResult.self)

        guard !result.bindings.isEmpty else {
            print("No PRs bound to this worktree.")
            return
        }
        for binding in result.bindings {
            print(Self.renderLine(binding))
        }
    }

    /// One line per binding: `#412  Checks failing  fix-login-timeout  (hook)`.
    /// Pure and static so tests exercise the format without a daemon.
    static func renderLine(_ binding: PRBinding) -> String {
        let reason = binding.status?.reason ?? binding.status?.state.displayReason ?? "unknown"
        let branch = binding.headBranch ?? "—"
        return "#\(binding.number)  \(reason)  \(branch)  (\(binding.source.rawValue))"
    }
}

// MARK: - pr attach / detach

/// Shared plumbing for `pr attach` and `pr detach`: both take one
/// `<number|url>` positional, resolve it against the worktree's own repo when
/// it is a bare number, and both fail loudly on an unparseable reference.
struct PRRefArgument: ParsableArguments {
    @Argument(help: "PR number, #number, or full GitHub PR URL")
    var reference: String

    func params(worktreeID: UUID, source: PRBindingSource? = nil) throws -> PRBindingRefParams {
        guard let parsed = PRCommand.parseReference(reference) else {
            throw CLIError.invalidArgument(
                "'\(reference)' is not a PR number or a GitHub PR URL")
        }
        if parsed.url.isEmpty {
            return PRBindingRefParams(worktreeID: worktreeID, number: parsed.number,
                                      source: source?.rawValue)
        }
        return PRBindingRefParams(worktreeID: worktreeID, url: parsed.url,
                                  source: source?.rawValue)
    }
}

struct PRAttachCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "attach",
        abstract: "Bind a PR to this worktree"
    )

    @OptionGroup var worktreeOption: WorktreeOption
    @OptionGroup var refArgument: PRRefArgument

    mutating func run() async throws {
        let client = SocketClient()
        let worktreeID = try worktreeOption.resolve(client: client)
        let params = try refArgument.params(worktreeID: worktreeID)
        let result: PRAttachResult = try client.call(
            method: RPCMethod.prAttach, params: params, resultType: PRAttachResult.self)
        print(Self.describe(result))
    }

    static func describe(_ result: PRAttachResult) -> String {
        switch result.outcome {
        case "bound":
            guard let binding = result.binding else { return "Bound." }
            return "Bound PR #\(binding.number) (\(binding.url))."
        case "alreadyBound":
            return "Already bound."
        case "rejectedWrongRepo":
            let other = result.detail ?? "another repo"
            return "PR belongs to \(other), not this worktree's repo."
        case "deferredUnknownRepo":
            return "Could not resolve this worktree's repo yet; try again shortly."
        case "tombstoned":
            return "This PR was detached; attach it again explicitly to revive it."
        case "capFull":
            return "This worktree already has the maximum number of bound PRs."
        default:
            return "Unknown outcome: \(result.outcome)"
        }
    }
}

struct PRDetachCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "detach",
        abstract: "Unbind a PR from this worktree"
    )

    @OptionGroup var worktreeOption: WorktreeOption
    @OptionGroup var refArgument: PRRefArgument

    mutating func run() async throws {
        let client = SocketClient()
        let worktreeID = try worktreeOption.resolve(client: client)
        let params = try refArgument.params(worktreeID: worktreeID)
        let result: PRDetachResult = try client.call(
            method: RPCMethod.prDetach, params: params, resultType: PRDetachResult.self)
        if result.detached {
            print("Detached.")
        } else {
            print("Not bound; nothing to detach.")
        }
    }
}

// MARK: - pr bind (hook entry point)

/// `tbd pr bind --from-hook` — the `PostToolUse`/`Bash` hook entry point. Reads
/// the raw hook payload from stdin and binds any PR a `gh pr create` in it
/// reported. This runs on the hot path of every matching Bash tool call across
/// the whole fleet, so it must be silent on the (overwhelmingly common) empty
/// case and must never fail the tool call it observes — hence the blanket exit
/// 0 regardless of what goes wrong downstream.
struct PRBindCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "bind",
        abstract: "Bind PRs found in a Claude Code hook payload (internal; used by the PostToolUse hook)"
    )

    @Flag(name: .long, help: "Read a PostToolUse hook payload from stdin")
    var fromHook = false

    mutating func run() async {
        guard fromHook else { return }
        let payload = FileHandle.standardInput.readDataToEndOfFile()
        let refs = Self.references(fromPayload: payload)
        guard !refs.isEmpty else { return }

        guard
            let envValue = ProcessInfo.processInfo.environment["TBD_WORKTREE_ID"],
            let worktreeID = UUID(uuidString: envValue)
        else { return }

        let client = SocketClient()
        guard client.isDaemonRunning else { return }

        for ref in refs {
            _ = try? client.call(
                method: RPCMethod.prAttach,
                params: PRBindingRefParams(worktreeID: worktreeID, url: ref.url,
                                           source: PRBindingSource.hook.rawValue),
                resultType: PRAttachResult.self)
        }
    }

    /// Thin static wrapper over `PRBindingExtractor.extract(fromHookPayload:)`,
    /// exposed so the test can exercise extraction without stdin or a daemon.
    static func references(fromPayload data: Data) -> [ParsedPRURL] {
        PRBindingExtractor.extract(fromHookPayload: data)
    }
}
