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
