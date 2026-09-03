import ArgumentParser
import Foundation
import TBDShared

struct RemoteCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "remote",
        // The first three words name the thing, because in a worktree manager
        // "remote" reads as a git remote first and a reader who guesses wrong
        // never reads the fourth word.
        abstract: "Provider-hosted agent sessions: sessions running on a cloud backend",
        discussion: """
            A **remote session** is an agent session a registered provider runs \
            somewhere TBD does not otherwise reach (docs/remote-provider-contract.md). \
            It is unrelated to a git remote.

            What each subcommand can do depends on what the provider declared. A \
            missing capability is refused here, by name, before the provider is \
            ever invoked — the contract forbids a caller from invoking a verb the \
            provider has not declared.
            """,
        subcommands: [
            RemoteList.self, RemoteCreate.self,
            RemoteStop.self, RemoteArchive.self, RemoteUnarchive.self,
            RemoteTranscript.self,
            RemoteRetain.self, RemoteImport.self, RemoteRecall.self, RemoteRetained.self,
            RemoteDelete.self, RemoteDismiss.self, RemoteAllowDelete.self,
        ]
    )
}

// MARK: - Addressing a session

/// Resolves the `<session>` operand every session-addressed `tbd remote`
/// subcommand takes.
///
/// Three forms, tried in this order:
///
/// 1. **`<provider>/<provider-session-id>`** — the compound a human reads off
///    `tbd remote list`. Authoritative and never checked against the inventory:
///    it is an address, so it must keep working against a session TBD has not
///    mirrored (or a provider whose snapshot is stale). Split at the *first*
///    slash, because a provider name cannot contain one and a session id can.
/// 2. **A TBD UUID** — a worktree row's id, or the synthetic id of a mirror row.
/// 3. **A worktree name or display name** — resolved only when exactly one row
///    matches and that row is bound to a provider session. Two matches is
///    ambiguous and resolves to nothing rather than to a guess: acting on the
///    wrong session is worse than being asked to say which.
enum RemoteSessionRef {
    static func resolve(
        _ raw: String, sessions: [RemoteSessionInfo], worktrees: [Worktree]
    ) -> (provider: String, sessionID: String)? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        if let slash = trimmed.firstIndex(of: "/") {
            let provider = String(trimmed[trimmed.startIndex..<slash])
            let sessionID = String(trimmed[trimmed.index(after: slash)...])
            if !provider.isEmpty, !sessionID.isEmpty {
                return (provider, sessionID)
            }
            return nil
        }

        if let uuid = UUID(uuidString: trimmed) {
            if let worktree = worktrees.first(where: { $0.id == uuid }),
               let binding = worktree.providerBinding {
                return binding
            }
            if let session = sessions.first(where: { $0.id == uuid }) {
                return (session.provider, session.payload.id)
            }
            return nil
        }

        let named = worktrees.filter {
            ($0.name == trimmed || $0.displayName == trimmed) && $0.providerBinding != nil
        }
        guard named.count == 1, let binding = named[0].providerBinding else { return nil }
        return binding
    }
}

// MARK: - Shared plumbing

/// The daemon-side facts a `tbd remote` subcommand needs before it calls
/// anything: which providers exist and what they declared, which sessions are
/// mirrored, and which worktrees are bound to one.
struct RemoteFleetSnapshot {
    let providers: [RemoteProviderStatus]
    let sessions: [RemoteSessionInfo]
    let worktrees: [Worktree]

    func capabilities(of provider: String) -> Set<String> {
        Set(providers.first { $0.config.name == provider }?.describe?.capabilities ?? [])
    }

    func isKnown(provider: String) -> Bool {
        providers.contains { $0.config.name == provider }
    }
}

func readRemoteFleet(client: SocketClient) throws -> RemoteFleetSnapshot {
    let providers = try client.call(
        method: RPCMethod.remoteProviders, resultType: RemoteProvidersResult.self)
    let sessions = try client.call(
        method: RPCMethod.remoteSessions, resultType: RemoteSessionsResult.self)
    // Archived rows are included on purpose: a lane that was retired is exactly
    // the one whose transcript somebody wants to keep.
    let worktrees = try client.call(
        method: RPCMethod.worktreeList,
        params: WorktreeListParams(excludeArchived: false, includeSessionCounts: false),
        resultType: [Worktree].self)
    return RemoteFleetSnapshot(
        providers: providers.providers, sessions: sessions.sessions, worktrees: worktrees)
}

/// Write one line to stderr. Everything a key-returning command says that is
/// not the key goes here, so `KEY=$(tbd remote retain my-lane)` captures the
/// key and nothing else.
func remoteNote(_ text: String) {
    FileHandle.standardError.write(Data((text + "\n").utf8))
}

/// The refusal a missing capability gets: one line, on stderr, naming the
/// capability, decided before any provider call. Never a raw provider error —
/// a provider that does not implement a verb fails in whatever way it likes,
/// and "unknown command" tells a reader nothing about what to do next.
func remoteMissingCapability(_ capability: String, provider: String) -> String {
    "Error: provider '\(provider)' has not declared the '\(capability)' capability"
}

/// The `--json` shape every key-returning command prints, per the design's CLI
/// section: `{"provider", "key", "expires_at", "bytes"}`.
///
/// `expires_at` is omitted when the provider stated nothing — its absence means
/// the provider makes no claim, and emitting `null` would invite a reader to
/// treat it as an answer.
struct RetainReceiptOutput: Encodable {
    let provider: String
    let key: String
    let expiresAt: Date?
    let bytes: Int

    enum CodingKeys: String, CodingKey {
        case provider, key, bytes
        case expiresAt = "expires_at"
    }

    init(provider: String, receipt: RetainReceipt) {
        self.provider = provider
        self.key = receipt.key
        self.expiresAt = receipt.expiresAt
        self.bytes = receipt.bytes
    }
}

/// The human sentence a key-returning command writes to stderr.
///
/// Pure, so the wording can be read and tested against the branch actually
/// taken. **An absent expiry is never rendered as permanence** — the contract
/// makes that a MUST NOT for callers, so it says the provider stated nothing.
func retainConfirmation(provider: String, receipt: RetainReceipt) -> String {
    let expiry: String
    if let expiresAt = receipt.expiresAt {
        expiry = "expires \(RetainReceipt.formatTimestamp(expiresAt))"
    } else {
        expiry = "no expiry stated by the provider"
    }
    return "retained \(receipt.bytes) bytes on \(provider) (\(expiry))"
}

// MARK: - remote retain

struct RemoteRetain: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "retain",
        abstract: "Store a provider session's transcript in the provider's own durable store",
        discussion: """
            Prints the bare key on stdout and everything else on stderr, so \
            `KEY=$(tbd remote retain my-lane)` composes.

            The key is opaque and provider-scoped: never parse one, never present \
            one to a different provider. TBD records it, so `tbd remote retained \
            list` can find it again.

            <session> accepts a worktree name, a TBD UUID, or <provider>/<session-id>.
            """
    )

    @Argument(help: "Worktree name, TBD UUID, or <provider>/<session-id>")
    var session: String

    @Flag(name: .long, help: "Output JSON")
    var json = false

    mutating func run() async throws {
        let client = SocketClient()
        let fleet = try readRemoteFleet(client: client)
        guard let target = RemoteSessionRef.resolve(
            session, sessions: fleet.sessions, worktrees: fleet.worktrees) else {
            remoteNote("Error: could not resolve '\(session)' to a remote session")
            throw ExitCode.failure
        }
        guard fleet.capabilities(of: target.provider).contains("retain") else {
            remoteNote(remoteMissingCapability("retain", provider: target.provider))
            throw ExitCode.failure
        }
        let receipt = try client.call(
            method: RPCMethod.remoteRetain,
            params: RemoteRetainParams(provider: target.provider, sessionID: target.sessionID),
            resultType: RetainReceipt.self)
        emitReceipt(receipt, provider: target.provider, json: json)
    }
}

/// Shared by `retain` and `import`, because the contract gives them one receipt
/// and a caller that read two different renderings of it would have to learn
/// two.
func emitReceipt(_ receipt: RetainReceipt, provider: String, json: Bool) {
    if json {
        printJSON(RetainReceiptOutput(provider: provider, receipt: receipt))
        return
    }
    remoteNote(retainConfirmation(provider: provider, receipt: receipt))
    print(receipt.key)
}

// MARK: - remote import

struct RemoteImport: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "import",
        abstract: "Store a transcript from anywhere in a provider's durable store",
        discussion: """
            Reads Claude Code transcript JSONL from <path>, or from stdin when \
            <path> is `-`, and hands it to the provider. No session on the \
            provider is involved — this is how a conversation from somewhere \
            else, including one that ran on this machine, enters the store.

            Prints the bare key on stdout and everything else on stderr.
            """
    )

    @Option(name: .long, help: "Provider name")
    var provider: String

    @Argument(help: "Path to a transcript JSONL file, or - for stdin")
    var path: String

    @Flag(name: .long, help: "Output JSON")
    var json = false

    mutating func run() async throws {
        let client = SocketClient()
        let fleet = try readRemoteFleet(client: client)
        guard fleet.isKnown(provider: provider) else {
            remoteNote("Error: no provider named '\(provider)' is registered")
            throw ExitCode.failure
        }
        guard fleet.capabilities(of: provider).contains("import") else {
            remoteNote(remoteMissingCapability("import", provider: provider))
            throw ExitCode.failure
        }
        let jsonl = try readTranscriptOperand(path)
        let receipt = try client.call(
            method: RPCMethod.remoteImport,
            params: RemoteImportParams(provider: provider, jsonl: jsonl),
            resultType: RetainReceipt.self)
        emitReceipt(receipt, provider: provider, json: json)
    }
}

/// Reads the transcript operand: a file, or stdin for `-`.
///
/// Never prompts. Agents drive this CLI and cannot answer a prompt, so `-`
/// with a terminal on stdin is refused with an explanation rather than left to
/// block forever on a read nobody will satisfy.
func readTranscriptOperand(_ path: String) throws -> String {
    if path == "-" {
        guard isatty(STDIN_FILENO) == 0 else {
            throw CLIError.invalidArgument(
                "reading the transcript from - requires piped input (e.g. < transcript.jsonl)")
        }
        return String(decoding: FileHandle.standardInput.readDataToEndOfFile(), as: UTF8.self)
    }
    let resolved = resolvePath(path)
    guard FileManager.default.fileExists(atPath: resolved) else {
        throw CLIError.invalidArgument("Transcript file not found: \(path)")
    }
    return try String(contentsOfFile: resolved, encoding: .utf8)
}

// MARK: - remote recall

struct RemoteRecall: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "recall",
        abstract: "Read back a transcript a provider retained",
        discussion: """
            Writes Claude Code transcript JSONL to stdout, or to <path> with -o. \
            There is no --json flag: the output is already machine format.

            Works whether or not the session that produced the transcript still \
            exists — that is the point of retaining one. A key TBD has never \
            seen is fine to pass; keys are the provider's, not TBD's.

            An unknown key and one the provider has aged out are reported \
            differently, so a lapsed record is not reported as one that never \
            existed.
            """
    )

    @Option(name: .long, help: "Provider name (keys are provider-scoped)")
    var provider: String

    @Argument(help: "The opaque key from a retain or import receipt")
    var key: String

    @Option(name: .shortAndLong, help: "Write the JSONL to this file instead of stdout")
    var output: String?

    mutating func run() async throws {
        let client = SocketClient()
        let fleet = try readRemoteFleet(client: client)
        guard fleet.isKnown(provider: provider) else {
            remoteNote("Error: no provider named '\(provider)' is registered")
            throw ExitCode.failure
        }
        guard fleet.capabilities(of: provider).contains("recall") else {
            remoteNote(remoteMissingCapability("recall", provider: provider))
            throw ExitCode.failure
        }
        let result = try client.call(
            method: RPCMethod.remoteRecall,
            // The daemon's own `~/tbd/transcripts` copy is a different gesture
            // from `-o`, which writes where the user asked. Asking for both
            // would leave two copies and no way to say which is authoritative.
            params: RemoteRecallParams(provider: provider, key: key, saveLocally: false),
            resultType: RemoteRecallResult.self)
        let jsonl = result.jsonl ?? ""
        guard let output else {
            print(jsonl, terminator: "")
            return
        }
        let resolved = resolvePath(output)
        try jsonl.write(toFile: resolved, atomically: true, encoding: .utf8)
        remoteNote("wrote \(jsonl.utf8.count) bytes to \(resolved)")
    }
}

// MARK: - remote retained

struct RemoteRetained: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "retained",
        abstract: "Transcripts a provider has retained, as TBD recorded them",
        subcommands: [RemoteRetainedList.self]
    )
}

struct RemoteRetainedList: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "list",
        abstract: "List the retain and import receipts TBD holds",
        discussion: """
            Nothing in the provider contract lets a caller enumerate the keys a \
            provider issued, so this lists TBD's own record of them. A key \
            obtained on another machine is not here.

            A blank EXPIRES column means the provider stated nothing. That is \
            not a promise the transcript is kept forever.
            """
    )

    @Option(name: .long, help: "Only this provider's receipts")
    var provider: String?

    @Flag(name: .long, help: "Output JSON")
    var json = false

    mutating func run() async throws {
        let result = try SocketClient().call(
            method: RPCMethod.remoteRetainedList,
            params: RemoteRetainedListParams(provider: provider),
            resultType: RemoteRetainedListResult.self)
        if json {
            guard let output = jsonString(result.transcripts) else {
                remoteNote("Error: could not encode the retained-transcript listing as JSON")
                throw ExitCode.failure
            }
            print(output)
            return
        }
        print(renderRetainedListing(result.transcripts))
    }
}

/// The plain-text table `tbd remote retained list` prints.
///
/// Separated from the call so the rendering can be read and tested without a
/// daemon. An empty listing says so rather than printing a bare header, because
/// a header with no rows reads as a failure to fetch.
func renderRetainedListing(_ transcripts: [RetainedTranscript]) -> String {
    guard !transcripts.isEmpty else {
        return "No retained transcripts recorded."
    }
    var lines = [tableRow([
        (value: "PROVIDER", width: 16), (value: "KEY", width: 30),
        (value: "BYTES", width: 10), (value: "EXPIRES", width: 22),
        (value: "SOURCE", width: 0),
    ])]
    for transcript in transcripts {
        // Blank rather than a word: an absent expiry is the provider declining
        // to say, and any word here would be read as an answer.
        let expires = transcript.expiresAt.map(RetainReceipt.formatTimestamp) ?? ""
        let source = transcript.sourceTitle ?? transcript.sourceSessionID ?? "imported"
        lines.append(tableRow([
            (value: transcript.provider, width: 16),
            (value: transcript.key, width: 30),
            (value: String(transcript.bytes), width: 10),
            (value: expires, width: 22),
            (value: source, width: 0),
        ]))
    }
    return lines.joined(separator: "\n")
}

// MARK: - remote delete

/// The caller-side policy in front of `delete`, as a pure function.
///
/// The contract has no `--force` and deliberately so: "refusing to destroy live
/// or dirty work is caller policy", and a provider that second-guessed an
/// explicit delete would leave the caller no way through. This is that policy,
/// and it lives here rather than in the daemon for the same reason — the daemon
/// serves the app too, and the app asks its own question with a dialog.
///
/// Returns the refusal to print, or nil to proceed.
///
/// **An unmirrored session is not refused.** `<provider>/<session-id>` is an
/// address that must keep working against a session TBD has never listed, and
/// there is then no `state` and no `meta` to read: refusing on absent
/// information would make the address form useless exactly when it is most
/// needed. The provider is still the last word on whether the delete happens.
enum RemoteDeletePrecondition {
    static func refusal(
        state: RemoteProcessState?, workspaceDirty: Bool, force: Bool, address: String
    ) -> String? {
        guard !force else { return nil }
        // Named separately rather than collapsed into one message, because the
        // two have different remedies: one waits or stops the session, the
        // other commits or pushes on the provider's machine.
        if let state, state == .running || state == .starting {
            return "Error: \(address) is still running. "
                + "Stop it first, or re-run with --force to destroy it anyway."
        }
        if workspaceDirty {
            return "Error: \(address) reports uncommitted work in its workspace "
                + "(meta.workspace_dirty), which lives on the provider's machine. "
                + "Re-run with --force to destroy it anyway."
        }
        return nil
    }
}

/// What `--json` prints for a delete: the provider's own response shape with
/// the provider name added, rather than a second shape a reader has to learn.
///
/// `retained` is present exactly when a receipt came back, and carries no
/// `provider` of its own — the enclosing object already names it once, and a
/// key repeated at two nesting levels invites a reader to wonder whether they
/// can differ.
struct RemoteDeleteOutput: Encodable {
    struct Receipt: Encodable {
        let key: String
        let expiresAt: Date?
        let bytes: Int

        enum CodingKeys: String, CodingKey {
            case key, bytes
            case expiresAt = "expires_at"
        }
    }

    let provider: String
    let id: String
    let deleted: Bool
    let retained: Receipt?

    init(provider: String, result: RemoteDeleteResult) {
        self.provider = provider
        self.id = result.id
        self.deleted = result.deleted
        self.retained = result.retained.map {
            Receipt(key: $0.key, expiresAt: $0.expiresAt, bytes: $0.bytes)
        }
    }
}

/// The human sentence a delete prints, pure so the two outcomes can be read
/// side by side.
///
/// They are worded differently on purpose. `deleted: false` means there was
/// nothing to destroy — a success per the contract, and the same answer `rm -f`
/// gives — and reporting it as a deletion would tell the user something
/// happened that did not.
func remoteDeleteConfirmation(address: String, result: RemoteDeleteResult) -> String {
    guard result.deleted else {
        return "\(address) was already gone"
    }
    guard let receipt = result.retained else {
        return "deleted \(address)"
    }
    // An absent expiry is never rendered as permanence — the contract makes
    // that a MUST NOT for callers.
    let expiry = receipt.expiresAt.map { ", expires \(RetainReceipt.formatTimestamp($0))" }
        ?? ", no expiry stated"
    return "deleted \(address) (retained: \(receipt.key)\(expiry))"
}

struct RemoteDelete: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "delete",
        abstract: "Destroy a provider-hosted session: end its compute and remove it permanently",
        discussion: """
            Unlike `dismiss`, this acts on the provider. The session's compute \
            ends and its record is removed from the provider's inventory for \
            good; nothing on this machine can put it back.

            Gated by the daemon's `remote_delete_enabled` flag, which ships off. \
            Turn it on with `tbd remote allow-delete on`.

            With --retain the provider stores the transcript first and the key is \
            printed, so the conversation survives the session. Without it, \
            nothing survives. --retain needs the provider to declare `retain` as \
            well as `delete`.

            Refuses without --force when the session is running or reports \
            uncommitted work, naming which.

            <session> accepts a worktree name, a TBD UUID, or <provider>/<session-id>.
            """
    )

    @Argument(help: "Worktree name, TBD UUID, or <provider>/<session-id>")
    var session: String

    @Flag(name: .long, help: "Retain the transcript before destroying the session")
    var retain = false

    @Flag(name: .long, help: "Destroy a running session, or one with uncommitted work")
    var force = false

    @Flag(name: .long, help: "Output JSON")
    var json = false

    mutating func run() async throws {
        let client = SocketClient()
        let fleet = try readRemoteFleet(client: client)
        guard let target = RemoteSessionRef.resolve(
            session, sessions: fleet.sessions, worktrees: fleet.worktrees) else {
            remoteNote("Error: could not resolve '\(session)' to a remote session")
            throw ExitCode.failure
        }
        let address = "\(target.provider)/\(target.sessionID)"
        let capabilities = fleet.capabilities(of: target.provider)
        guard capabilities.contains("delete") else {
            remoteNote(remoteMissingCapability("delete", provider: target.provider))
            throw ExitCode.failure
        }
        // The contract makes --retain valid only where `retain` is declared, so
        // this is refused here rather than sent and hoped for: a provider that
        // ignored the flag would destroy a session the caller believed was
        // being preserved.
        if retain, !capabilities.contains("retain") {
            remoteNote(remoteMissingCapability("retain", provider: target.provider))
            throw ExitCode.failure
        }
        let mirrored = fleet.sessions.first {
            $0.provider == target.provider && $0.payload.id == target.sessionID
        }
        if let refusal = RemoteDeletePrecondition.refusal(
            state: mirrored?.payload.state,
            workspaceDirty: mirrored?.payload.reportsDirtyWorkspace ?? false,
            force: force, address: address) {
            remoteNote(refusal)
            throw ExitCode.failure
        }
        let result = try client.call(
            method: RPCMethod.remoteDelete,
            params: RemoteDeleteParams(
                provider: target.provider, sessionID: target.sessionID, retain: retain),
            resultType: RemoteDeleteResult.self)
        if json {
            printJSON(RemoteDeleteOutput(provider: target.provider, result: result))
            return
        }
        // The key goes to stdout on its own, as it does for `retain`, so
        // `KEY=$(tbd remote delete my-lane --retain)` composes; everything else
        // is stderr.
        remoteNote(remoteDeleteConfirmation(address: address, result: result))
        if let key = result.retained?.key { print(key) }
    }
}

// MARK: - remote dismiss

struct RemoteDismiss: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "dismiss",
        abstract: "Hide a session from TBD's own lists, changing nothing on the provider",
        discussion: """
            Dismiss is local. It marks TBD's mirror row so the session stops \
            appearing in the sidebar and in `tbd remote list`, and that is all \
            it does: the session, its compute and its record are untouched on \
            the provider, and another machine running TBD still sees it.

            **This is not `delete`.** `tbd remote delete` ends the session's \
            compute and removes it from the provider permanently. Reach for \
            dismiss when a finished session is in your way; reach for delete \
            when you want it gone.

            <session> accepts a worktree name, a TBD UUID, or <provider>/<session-id>.
            """
    )

    @Argument(help: "Worktree name, TBD UUID, or <provider>/<session-id>")
    var session: String

    mutating func run() async throws {
        let client = SocketClient()
        let fleet = try readRemoteFleet(client: client)
        guard let target = RemoteSessionRef.resolve(
            session, sessions: fleet.sessions, worktrees: fleet.worktrees) else {
            remoteNote("Error: could not resolve '\(session)' to a remote session")
            throw ExitCode.failure
        }
        // No capability check: dismiss invokes no provider verb. It is the one
        // removal gesture that works on every provider, which is exactly why
        // its help has to say what it does not do.
        try client.callVoid(
            method: RPCMethod.remoteDismiss,
            params: RemoteDismissParams(provider: target.provider, sessionID: target.sessionID))
        print("Dismissed \(target.provider)/\(target.sessionID) from TBD's lists.")
    }
}

// MARK: - the delete gate

struct RemoteAllowDelete: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "allow-delete",
        abstract: "Enable or disable `tbd remote delete` (default off)",
        discussion: """
            The soak switch for the one verb whose effect nothing on this \
            machine can undo. Off — the shipped default — every delete is \
            refused, on both the CLI and the app's menus.

            Turning it off refuses the next delete. It cannot recall one already \
            made.
            """
    )

    @Argument(help: "on | off")
    var state: String

    mutating func run() async throws {
        let enabled: Bool
        switch state.lowercased() {
        case "on", "true", "enable": enabled = true
        case "off", "false", "disable": enabled = false
        default: throw ValidationError("Expected 'on' or 'off', got: \(state)")
        }
        try SocketClient().callVoid(
            method: RPCMethod.configSetRemoteDeleteEnabled,
            params: ConfigSetRemoteDeleteEnabledParams(enabled: enabled))
        print("Remote session delete \(enabled ? "enabled" : "disabled").")
    }
}

// MARK: - remote create

/// A worktree's git state, reduced to the three facts teleport cares about.
///
/// A struct rather than three loose arguments because the precondition below is
/// pure and this is the whole of its input: reading git is I/O, deciding what
/// to refuse is not, and the split is what makes the decision testable without
/// a repository.
struct TeleportWorkspaceSummary: Equatable {
    /// Paths `git status --porcelain` reports as changed — staged, unstaged or
    /// untracked, deliberately not distinguished. All three stay on this
    /// machine, which is the only thing the refusal is about.
    let uncommittedFiles: Int
    /// Commits on this branch the upstream does not have. Meaningless when
    /// `hasUpstream` is false, where the answer is "all of them".
    let unpushedCommits: Int
    /// Whether the branch tracks anything at all. A branch with no upstream has
    /// nothing on a remote for the new session to check out, which is a
    /// different sentence from "you are two commits ahead".
    let hasUpstream: Bool

    init(uncommittedFiles: Int, unpushedCommits: Int, hasUpstream: Bool) {
        self.uncommittedFiles = uncommittedFiles
        self.unpushedCommits = unpushedCommits
        self.hasUpstream = hasUpstream
    }
}

/// The gate in front of `create --continue`.
///
/// **Teleport moves a branch, never files.** The new session is a checkout on
/// another machine, made from what the remote has; nothing in this repository's
/// working tree travels with the conversation. Carrying the files instead would
/// mean shipping the untracked and ignored ones that make a checkout work —
/// `.env`, local databases, credentials — which is a per-repo policy question
/// and not a transport one, and shipping them by default exfiltrates secrets.
///
/// So the refusal's job is to name what would be left behind, in counts a user
/// can check, rather than to say "the worktree is dirty". `--force` carries the
/// conversation anyway, which is a perfectly reasonable thing to want.
///
/// Pure, mirroring `RemoteDeletePrecondition.refusal`: returns the message to
/// print, or nil to proceed.
enum TeleportPrecondition {
    static func refusal(_ summary: TeleportWorkspaceSummary, force: Bool) -> String? {
        guard !force else { return nil }
        var leftBehind: [String] = []
        if summary.uncommittedFiles > 0 {
            leftBehind.append(
                "\(summary.uncommittedFiles) uncommitted "
                + (summary.uncommittedFiles == 1 ? "file" : "files"))
        }
        if !summary.hasUpstream {
            leftBehind.append("every commit on this branch, which has no upstream")
        } else if summary.unpushedCommits > 0 {
            leftBehind.append(
                "\(summary.unpushedCommits) unpushed "
                + (summary.unpushedCommits == 1 ? "commit" : "commits"))
        }
        guard !leftBehind.isEmpty else { return nil }
        let subject = leftBehind.joined(separator: " and ")
        var message = "Error: \(subject) will stay on this machine. "
            + "A remote session checks the branch out from the remote, so only what is "
            + "pushed travels with the conversation.\n"
        // Named separately because the two have different remedies, and the
        // push one is an offer rather than an instruction to go and read git's
        // manual.
        if summary.uncommittedFiles > 0 {
            message += "Commit or stash the changes first.\n"
        }
        if !summary.hasUpstream || summary.unpushedCommits > 0 {
            message += "Push the branch first (`git push -u origin HEAD`).\n"
        }
        message += "Or re-run with --force to move the conversation and leave them behind."
        return message
    }
}

/// Reads the three facts `TeleportPrecondition` decides on out of a real
/// checkout.
///
/// Every failure degrades toward *refusing*, never toward proceeding: a
/// `git status` that will not run leaves `uncommittedFiles` unknown, and
/// guessing zero there would carry a conversation away from work the user
/// thought was coming with it. `hasUpstream` is false when `@{u}` does not
/// resolve, which is exactly the "never pushed" case.
func readTeleportSummary(worktreePath: String) -> TeleportWorkspaceSummary? {
    guard let status = runGit(["status", "--porcelain"], at: worktreePath) else { return nil }
    let changed = status
        .split(separator: "\n")
        .filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        .count
    guard runGit(["rev-parse", "--abbrev-ref", "--symbolic-full-name", "@{u}"],
                 at: worktreePath) != nil else {
        return TeleportWorkspaceSummary(
            uncommittedFiles: changed, unpushedCommits: 0, hasUpstream: false)
    }
    let ahead = runGit(["rev-list", "--count", "@{u}..HEAD"], at: worktreePath)
        .flatMap { Int($0.trimmingCharacters(in: .whitespacesAndNewlines)) } ?? 0
    return TeleportWorkspaceSummary(
        uncommittedFiles: changed, unpushedCommits: ahead, hasUpstream: true)
}

/// Runs one git command in `path` and returns its stdout, or nil when git
/// exited nonzero. Callers read a nonzero exit as a fact ("no upstream"), never
/// as a reason to carry on regardless.
private func runGit(_ arguments: [String], at path: String) -> String? {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
    process.arguments = ["git", "-C", path] + arguments
    let out = Pipe()
    let err = Pipe()
    process.standardOutput = out
    process.standardError = err
    do {
        try process.run()
    } catch {
        return nil
    }
    let data = out.fileHandleForReading.readDataToEndOfFile()
    _ = err.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    guard process.terminationStatus == 0 else { return nil }
    return String(bytes: data, encoding: .utf8) ?? ""
}

/// Turns repeated `--param key=value` into the JSON object `create` sends.
///
/// The values are the provider's own `create_params` fields and TBD does not
/// interpret them, so everything is carried as a string: the contract's field
/// types are the provider's business, and a CLI that guessed a number from
/// `--param count=3` would be inventing a type the user never wrote.
func remoteCreateParamsJSON(_ pairs: [String]) throws -> String {
    var values: [String: String] = [:]
    for pair in pairs {
        guard let separator = pair.firstIndex(of: "=") else {
            throw CLIError.invalidArgument(
                "--param expects key=value, got: \(pair)")
        }
        let key = String(pair[pair.startIndex..<separator])
        guard !key.isEmpty else {
            throw CLIError.invalidArgument("--param expects key=value, got: \(pair)")
        }
        values[key] = String(pair[pair.index(after: separator)...])
    }
    guard let data = try? JSONSerialization.data(withJSONObject: values, options: [.sortedKeys]),
          let json = String(bytes: data, encoding: .utf8) else {
        throw CLIError.invalidArgument("could not encode --param values as JSON")
    }
    return json
}

struct RemoteCreate: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "create",
        abstract: "Start a provider-hosted agent session, optionally carrying a conversation",
        discussion: """
            --param takes the provider's own create fields, repeated once per \
            field; `tbd remote list` names the provider, and the provider's \
            `describe` names the fields.

            Three ways to give the new session a conversation to begin from, \
            and they are mutually exclusive:

              --continue <terminal-id>  carry a conversation running on THIS \
            machine to the provider. TBD reads that terminal's Claude \
            transcript, stores it on the provider, and creates a session \
            seeded from it.
              --from-key <key>          seed from a transcript already stored \
            on this provider (see `tbd remote retain` and `tbd remote import`).
              --from-file <path|->      seed from a transcript JSONL file.

            **--continue moves the branch, never the files.** The new session \
            checks the branch out from the remote, so anything uncommitted or \
            unpushed stays here. TBD refuses and says what would be left \
            behind; --force moves the conversation anyway.

            Seeding needs the provider to declare `seed`, and the two \
            file-bearing sources need `import` as well. Both are refused here, \
            by name, before anything is created.
            """
    )

    @Option(name: .long, help: "Provider name")
    var provider: String

    @Option(name: .long, parsing: .unconditionalSingleValue,
            help: "A provider create field, as key=value. Repeat for more.")
    var param: [String] = []

    @Option(name: .customLong("continue"),
            help: "Carry this terminal's conversation to the provider (terminal UUID)")
    var continueTerminal: String?

    @Option(name: .customLong("from-key"),
            help: "Seed from a transcript this provider already holds")
    var fromKey: String?

    @Option(name: .customLong("from-file"),
            help: "Seed from a transcript JSONL file, or - for stdin")
    var fromFile: String?

    @Flag(name: .long, help: "Move the conversation even though work would be left behind")
    var force = false

    @Flag(name: .long, help: "Output JSON")
    var json = false

    mutating func run() async throws {
        let sources = [continueTerminal, fromKey, fromFile].compactMap { $0 }
        guard sources.count <= 1 else {
            throw ValidationError(
                "--continue, --from-key and --from-file are mutually exclusive: "
                + "a session begins from one conversation or from none.")
        }
        let paramsJSON = try remoteCreateParamsJSON(param)

        let client = SocketClient()
        let fleet = try readRemoteFleet(client: client)
        guard fleet.isKnown(provider: provider) else {
            remoteNote("Error: no provider named '\(provider)' is registered")
            throw ExitCode.failure
        }
        let capabilities = fleet.capabilities(of: provider)
        // Both capability checks happen before anything is read, imported or
        // created. A `seed` a provider never declared is silently ignored by
        // the contract's own ignore-unknown-fields rule, which would leave the
        // user with an empty session they believed carried their conversation.
        if !sources.isEmpty, !capabilities.contains("seed") {
            remoteNote(remoteMissingCapability("seed", provider: provider))
            throw ExitCode.failure
        }
        if continueTerminal != nil || fromFile != nil, !capabilities.contains("import") {
            remoteNote(remoteMissingCapability("import", provider: provider))
            throw ExitCode.failure
        }

        var seedKey: String?
        if let fromKey {
            seedKey = fromKey
        } else if let fromFile {
            seedKey = try importTranscript(readTranscriptOperand(fromFile), client: client)
        } else if let continueTerminal {
            seedKey = try carryLocalConversation(
                terminalRef: continueTerminal, client: client, fleet: fleet)
        }

        let session = try client.call(
            method: RPCMethod.remoteCreate,
            params: RemoteCreateParams(
                provider: provider, paramsJSON: paramsJSON, seedRetainedKey: seedKey),
            resultType: RemoteSessionPayload.self)
        if json {
            printJSON(session)
            return
        }
        remoteNote(remoteCreateConfirmation(
            provider: provider, session: session, seeded: seedKey != nil))
        print(session.id)
    }

    /// Stores a transcript on the provider and returns its key, noting the
    /// receipt on stderr so a `create` that later fails still leaves the user
    /// holding the key their conversation is under.
    private func importTranscript(_ jsonl: String, client: SocketClient) throws -> String {
        let receipt = try client.call(
            method: RPCMethod.remoteImport,
            params: RemoteImportParams(provider: provider, jsonl: jsonl),
            resultType: RetainReceipt.self)
        remoteNote(retainConfirmation(provider: provider, receipt: receipt))
        remoteNote("seed key: \(receipt.key)")
        return receipt.key
    }

    /// The teleport: read a local terminal's Claude transcript, check what
    /// would be left behind, and store the conversation on the provider.
    private func carryLocalConversation(
        terminalRef: String, client: SocketClient, fleet: RemoteFleetSnapshot
    ) throws -> String {
        guard let terminalID = UUID(uuidString: terminalRef) else {
            throw CLIError.invalidArgument(
                "--continue takes a terminal UUID; `tbd terminal list <worktree>` prints them.")
        }
        let terminals: [Terminal] = try client.call(
            method: RPCMethod.terminalList,
            params: TerminalListParams(),
            resultType: [Terminal].self)
        guard let terminal = terminals.first(where: { $0.id == terminalID }) else {
            throw CLIError.invalidArgument("No terminal found with ID: \(terminalRef)")
        }
        guard let transcriptPath = terminal.transcriptPath else {
            throw CLIError.invalidArgument(
                "Terminal \(terminalRef) has no Claude transcript on record yet — "
                + "nothing has been said in it, or it is not a Claude session.")
        }
        // The precondition runs before the import, so a refusal costs nothing
        // on the provider. An import that succeeded and was then abandoned
        // would leave a retained blob nobody will ever use.
        if let worktree = fleet.worktrees.first(where: { $0.id == terminal.worktreeID }),
           worktree.location.isLocal, !worktree.localPath.isEmpty {
            if let summary = readTeleportSummary(worktreePath: worktree.localPath) {
                if let refusal = TeleportPrecondition.refusal(summary, force: force) {
                    remoteNote(refusal)
                    throw ExitCode.failure
                }
            } else if !force {
                // Unknown is refused rather than assumed clean: guessing zero
                // would carry a conversation away from work the user believed
                // was coming with it. --force still gets through, on the same
                // terms as every other teleport refusal.
                throw CLIError.invalidArgument(
                    "Could not read the git state of \(worktree.localPath), so what would be "
                    + "left behind is unknown. Re-run with --force to move the conversation anyway.")
            }
        }
        guard let jsonl = try? String(contentsOfFile: transcriptPath, encoding: .utf8) else {
            throw CLIError.invalidArgument(
                "Could not read the transcript at \(transcriptPath)")
        }
        return try importTranscript(jsonl, client: client)
    }
}

/// The human sentence a create prints to stderr, pure so the seeded and
/// unseeded wordings can be read side by side.
///
/// The seeded one says so explicitly: a session that silently began with
/// somebody's whole conversation, and one that began empty, look identical from
/// the outside, and the whole point of the flag is which of those happened.
func remoteCreateConfirmation(
    provider: String, session: RemoteSessionPayload, seeded: Bool
) -> String {
    let name = session.title.map { "\($0) (\(session.id))" } ?? session.id
    return seeded
        ? "created \(provider)/\(name), seeded from the retained conversation"
        : "created \(provider)/\(name)"
}

// MARK: - remote list

/// The rows `tbd remote list` shows, decided as a pure function so the display
/// policy can be read next to the sidebar's.
///
/// **Archived sessions are hidden by default, and that is a caller decision
/// rather than a provider one.** The contract requires a provider to keep
/// archived sessions in `list` and assigns the caller the policy about which a
/// human sees; the sidebar drops them, and this drops them too, so the two
/// surfaces cannot disagree about what "the working set" means. `--archived`
/// asks for the complete inventory.
///
/// Dismissed rows are always hidden: dismiss is TBD's own local tombstone, and
/// a row a user removed from their lists reappearing here would make the
/// gesture look broken.
func remoteListRows(
    _ sessions: [RemoteSessionInfo], provider: String?, includeArchived: Bool
) -> [RemoteSessionInfo] {
    sessions
        .filter { !$0.dismissed }
        .filter { includeArchived || !$0.payload.isArchived }
        .filter { provider == nil || $0.provider == provider }
        .sorted {
            $0.provider == $1.provider ? $0.payload.id < $1.payload.id : $0.provider < $1.provider
        }
}

/// The plain-text table `tbd remote list` prints. Separated from the call so
/// the rendering is readable without a daemon.
func renderRemoteListing(_ sessions: [RemoteSessionInfo]) -> String {
    guard !sessions.isEmpty else {
        return "No remote sessions."
    }
    var lines = [tableRow([
        (value: "PROVIDER", width: 16), (value: "SESSION", width: 30),
        (value: "STATE", width: 12), (value: "AGENT", width: 14),
        (value: "TITLE", width: 0),
    ])]
    for session in sessions {
        // `gone` is a TBD-side drift conclusion rather than a provider state,
        // so it is shown in the STATE column instead of being folded into it:
        // a session TBD has stopped seeing is a different fact from one the
        // provider reports as exited.
        let state = session.gone ? "gone" : session.payload.state.rawValue
        lines.append(tableRow([
            (value: session.provider, width: 16),
            (value: session.payload.id, width: 30),
            (value: state, width: 12),
            (value: session.payload.agentState.rawValue, width: 14),
            (value: session.payload.title ?? "", width: 0),
        ]))
    }
    return lines.joined(separator: "\n")
}

struct RemoteList: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "list",
        abstract: "List the provider-hosted sessions TBD is mirroring",
        discussion: """
            Archived sessions are hidden unless --archived is passed, matching \
            what the sidebar shows: the provider keeps them in its inventory by \
            contract, and which of them a human sees is TBD's decision.

            Sessions you have dismissed are always hidden — dismiss is a local \
            tombstone, and this is one of the lists it removes them from.

            The SESSION column is the provider's own id: `<provider>/<session>` \
            is what every other subcommand here takes as an address.
            """
    )

    @Option(name: .long, help: "Only this provider's sessions")
    var provider: String?

    @Flag(name: .long, help: "Include sessions the provider reports as archived")
    var archived = false

    @Flag(name: .long, help: "Output JSON")
    var json = false

    mutating func run() async throws {
        let sessions = try SocketClient().call(
            method: RPCMethod.remoteSessions, resultType: RemoteSessionsResult.self).sessions
        let rows = remoteListRows(sessions, provider: provider, includeArchived: archived)
        if json {
            guard let output = jsonString(rows) else {
                remoteNote("Error: could not encode the remote session list as JSON")
                throw ExitCode.failure
            }
            print(output)
            return
        }
        print(renderRemoteListing(rows))
    }
}

// MARK: - remote stop / archive / unarchive

/// The three session-addressed verbs whose whole body is "resolve, check the
/// capability, call the RPC, say what happened".
///
/// One enum and one runner rather than three near-identical command bodies:
/// they differ only in the verb, the RPC and the past-tense word they print,
/// and three copies of the resolution and refusal logic would be three places
/// for it to drift.
///
/// The raw value is the capability string, which is not a coincidence to be
/// tidied away later — the contract states that every capability except
/// `profile` and `seed` names the verb of the same name.
enum RemoteSessionVerb: String {
    case stop, archive, unarchive

    /// The past-tense word the success line uses.
    var pastTense: String {
        switch self {
        case .stop: return "stopped"
        case .archive: return "archived"
        case .unarchive: return "unarchived"
        }
    }
}

/// Runs one session-addressed verb. The capability is refused here, by name,
/// before the daemon is asked to invoke anything — the contract forbids a
/// caller from invoking a verb the provider has not declared, and a refusal
/// that arrived as a raw provider error would tell a reader nothing about what
/// to do next.
///
/// The three params types are structurally identical today, so one would encode
/// perfectly well as another. They are still named individually, because "it
/// happens to encode the same" is exactly the coincidence a later field on one
/// of them breaks silently.
func runRemoteSessionVerb(
    _ verb: RemoteSessionVerb, session: String, json: Bool
) throws {
    let client = SocketClient()
    let fleet = try readRemoteFleet(client: client)
    guard let target = RemoteSessionRef.resolve(
        session, sessions: fleet.sessions, worktrees: fleet.worktrees) else {
        remoteNote("Error: could not resolve '\(session)' to a remote session")
        throw ExitCode.failure
    }
    guard fleet.capabilities(of: target.provider).contains(verb.rawValue) else {
        remoteNote(remoteMissingCapability(verb.rawValue, provider: target.provider))
        throw ExitCode.failure
    }
    switch verb {
    case .stop:
        try client.callVoid(
            method: RPCMethod.remoteStop,
            params: RemoteStopParams(provider: target.provider, sessionID: target.sessionID))
    case .archive:
        try client.callVoid(
            method: RPCMethod.remoteArchive,
            params: RemoteArchiveParams(provider: target.provider, sessionID: target.sessionID))
    case .unarchive:
        try client.callVoid(
            method: RPCMethod.remoteUnarchive,
            params: RemoteUnarchiveParams(provider: target.provider, sessionID: target.sessionID))
    }
    let address = "\(target.provider)/\(target.sessionID)"
    if json {
        printJSON([
            "provider": target.provider, "session": target.sessionID, "verb": verb.rawValue,
        ])
        return
    }
    print("\(verb.pastTense) \(address)")
}

struct RemoteStop: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "stop",
        abstract: "End a session's compute, leaving its record in the provider's inventory",
        discussion: """
            Stop is not archive and not delete. It ends the compute and leaves \
            the session listed; `tbd remote archive` retires the record without \
            ending compute; `tbd remote delete` does both and removes it for good.

            <session> accepts a worktree name, a TBD UUID, or <provider>/<session-id>.
            """
    )

    @Argument(help: "Worktree name, TBD UUID, or <provider>/<session-id>")
    var session: String

    @Flag(name: .long, help: "Output JSON")
    var json = false

    mutating func run() async throws {
        try runRemoteSessionVerb(.stop, session: session, json: json)
    }
}

struct RemoteArchive: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "archive",
        abstract: "Retire a session from the provider's working set, leaving its compute alone",
        discussion: """
            Archiving does not stop anything. A session still running keeps \
            running; it simply stops appearing in `tbd remote list` and in the \
            sidebar. Stop it first if that is what you meant.

            <session> accepts a worktree name, a TBD UUID, or <provider>/<session-id>.
            """
    )

    @Argument(help: "Worktree name, TBD UUID, or <provider>/<session-id>")
    var session: String

    @Flag(name: .long, help: "Output JSON")
    var json = false

    mutating func run() async throws {
        try runRemoteSessionVerb(.archive, session: session, json: json)
    }
}

struct RemoteUnarchive: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "unarchive",
        abstract: "Return a retired session to the provider's working set",
        discussion: """
            The reverse of `tbd remote archive`. Address a retired session by \
            `<provider>/<session-id>` — `tbd remote list --archived` prints it.
            """
    )

    @Argument(help: "Worktree name, TBD UUID, or <provider>/<session-id>")
    var session: String

    @Flag(name: .long, help: "Output JSON")
    var json = false

    mutating func run() async throws {
        try runRemoteSessionVerb(.unarchive, session: session, json: json)
    }
}

// MARK: - remote transcript

struct RemoteTranscript: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "transcript",
        abstract: "Read a live session's conversation as Claude Code transcript JSONL",
        discussion: """
            Writes JSONL to stdout, or to <path> with -o. There is no --json \
            flag: the output is already machine format.

            This is the conversation, not the terminal. `transcript` returns \
            structured records — user turns, agent responses, tool activity — \
            while a scrollback recording is different data entirely, and the \
            contract forbids substituting one for the other.

            For a session that no longer exists, use `tbd remote recall` with \
            the key its retention produced.

            <session> accepts a worktree name, a TBD UUID, or <provider>/<session-id>.
            """
    )

    @Argument(help: "Worktree name, TBD UUID, or <provider>/<session-id>")
    var session: String

    @Option(name: .shortAndLong, help: "Write the JSONL to this file instead of stdout")
    var output: String?

    mutating func run() async throws {
        let client = SocketClient()
        let fleet = try readRemoteFleet(client: client)
        guard let target = RemoteSessionRef.resolve(
            session, sessions: fleet.sessions, worktrees: fleet.worktrees) else {
            remoteNote("Error: could not resolve '\(session)' to a remote session")
            throw ExitCode.failure
        }
        guard fleet.capabilities(of: target.provider).contains("transcript") else {
            remoteNote(remoteMissingCapability("transcript", provider: target.provider))
            throw ExitCode.failure
        }
        let result = try client.call(
            method: RPCMethod.remoteTranscript,
            params: RemoteTranscriptParams(
                provider: target.provider, sessionID: target.sessionID),
            resultType: RemoteTranscriptResult.self)
        guard let output else {
            print(result.jsonl, terminator: "")
            return
        }
        let resolved = resolvePath(output)
        try result.jsonl.write(toFile: resolved, atomically: true, encoding: .utf8)
        remoteNote("wrote \(result.jsonl.utf8.count) bytes to \(resolved)")
    }
}
