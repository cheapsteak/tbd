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
