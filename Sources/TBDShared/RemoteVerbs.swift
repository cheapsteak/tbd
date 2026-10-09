import Foundation

/// Capability strings a provider declares in `describe`
/// (`docs/remote-provider-contract.md` § `describe`), for the operations whose
/// spelling is not simply the verb's own name.
///
/// The four transcript operations share the `transcript` verb, each admitted by
/// its own `transcript.<sub>` string, because each has different prerequisites:
/// a provider may snapshot its own sessions without accepting foreign blobs, or
/// serve live transcripts without a durable store. `send-submit` gates a flag
/// on `send` rather than admitting a verb.
///
/// A caller ignores capability strings it does not recognize, so the bare
/// pre-namespace spellings (`transcript`, `retain`, `import`, `recall`) admit
/// nothing here.
public enum RemoteCapability {
    /// `transcript read <id> [--since <cursor>]` — a live session's conversation.
    public static let transcriptRead = "transcript.read"
    /// `--tail` and `--before` on `transcript read`. Gates flags, not a verb:
    /// there is no `transcript tail` subcommand.
    public static let transcriptTail = "transcript.tail"
    /// `transcript retain <id>`, and `delete <id> --retain`.
    public static let transcriptRetain = "transcript.retain"
    /// `transcript import` — Claude Code JSONL on stdin into the provider's store.
    public static let transcriptImport = "transcript.import"
    /// `transcript recall <key>` — a retained conversation read back.
    public static let transcriptRecall = "transcript.recall"
    /// The `--submit` flag on `send`: stdin is a message, pasted and submitted.
    public static let sendSubmit = "send-submit"
}

/// The argv (after the provider's own `exec` and `args`) for the verbs
/// `RemoteCapability` admits.
///
/// Operands are placed positionally and passed verbatim: a session id, cursor
/// or key is opaque by contract, so nothing here parses, trims or escapes one.
public enum RemoteVerb {
    /// `transcript read <id>`, or `transcript read <id> --since <cursor>` when
    /// a cursor is held. Without one the provider answers from the beginning,
    /// which a caller treats as a reset.
    public static func transcriptRead(sessionID: String, since cursor: String? = nil) -> [String] {
        var argv = ["transcript", "read", sessionID]
        if let cursor {
            argv += ["--since", cursor]
        }
        return argv
    }

    /// `transcript read <id> --tail <n>` — the end of the current conversation.
    /// Always a reset. Only for a provider that declared
    /// `RemoteCapability.transcriptTail`; never combined with `--since`.
    public static func transcriptReadTail(sessionID: String, count: Int) -> [String] {
        ["transcript", "read", sessionID, "--tail", String(count)]
    }

    /// `transcript read <id> --before <cursor> --tail <n>` — the page of
    /// history ending immediately before `before`. Never carries `--since`.
    /// Only for a provider that declared `RemoteCapability.transcriptTail`.
    public static func transcriptReadBefore(sessionID: String, before: String, count: Int) -> [String] {
        ["transcript", "read", sessionID, "--before", before, "--tail", String(count)]
    }

    /// `transcript retain <id>`.
    public static func transcriptRetain(sessionID: String) -> [String] {
        ["transcript", "retain", sessionID]
    }

    /// `transcript import` — the JSONL travels on stdin.
    public static let transcriptImport = ["transcript", "import"]

    /// `transcript recall <key>`.
    public static func transcriptRecall(key: String) -> [String] {
        ["transcript", "recall", key]
    }

    /// `send <id> --submit` — the message travels on stdin as UTF-8 text.
    /// Only for a provider that declared `RemoteCapability.sendSubmit`.
    public static func sendSubmit(sessionID: String) -> [String] {
        ["send", sessionID, "--submit"]
    }
}
