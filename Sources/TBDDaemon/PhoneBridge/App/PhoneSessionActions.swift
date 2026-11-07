import Foundation
import TBDShared

/// Everything the phone bridge asks of the daemon's RPC layer, through one
/// door.
///
/// `PhoneBridge` sits below `Server` in `scripts/daemon-layers.txt`, so the
/// bridge never names the router. The router conforms in
/// `Server/RPCRouter+PhoneSessionActions.swift`, the daemon's root hands it to
/// the bridge, and the bridge's tests use a fake.
///
/// **Each method is an existing RPC, minus its socket edge.** It returns the
/// `RPCResponse` that RPC returns, refusal text included, so the phone hears a
/// refusal in the words the app hears. It runs exactly the checks the matching
/// core function or handler runs, in the same order. The only checks it adds
/// keep shells, which spec section 6 hides from the phone, out of its reach,
/// and keep its messages to text: `phoneSessionStates` drops every report on
/// a shell, and the send rail refuses a shell, a message part that is not
/// text and an empty message, after the core's shape check and before the
/// rest of the send core (see `phoneSend`).
///
/// **A method that acts takes `deviceID`**, the device of the verified pairing
/// the request came through. The actuation record names it, and an answer
/// takes its authority from it, both built from that one value so they cannot
/// disagree. Take it from the bridge's verified peer, never from anything the
/// phone sent. The read-only methods take none: their RPCs record nothing.
///
/// **The conformance keeps only the fields a phone may set.** It builds fresh
/// params for every call, field by field from the fields a phone may set, and
/// everything else takes TBD's defaults, whatever the bridge passed (spec
/// section 5). It does so even where a phone may set every field a params
/// struct has today. It names the fields it keeps, never the ones it drops, so
/// a field added to a params struct later stays off the phone by default.
protocol PhoneSessionActions: Sendable {
    /// `session.states` over every worktree. A `SessionStatesResult`, which
    /// never reports a plain shell.
    func phoneSessionStates() async throws -> RPCResponse

    /// The `prompt.answer` core under the phone's pairing, with the terminal,
    /// the prompt and the answer: the `transcript_prompt_answer_enabled`
    /// check, then no socket check.
    func phoneAnswerPrompt(_ p: PromptAnswerParams, deviceID: UUID) async throws -> RPCResponse

    /// The `remote.answer` core under the phone's pairing, with the provider,
    /// the session, the prompt and the answer: every gate the socket handler
    /// runs, except the socket check.
    func phoneAnswerRemotePrompt(_ p: RemoteAnswerParams, deviceID: UUID) async throws -> RPCResponse

    /// The paired-phone send rail: the terminal, the message (`text` or
    /// `parts`) and `submit`, with no dispatch marker, always gated on
    /// awaiting input, never verified and never keys, whatever `p` asks for.
    /// A shell terminal, a part that is not text or an empty message is
    /// refused before anything is typed.
    ///
    /// The order, all inside the terminal's send lane: the core's shape
    /// check, then the phone's refusals, then the send core. A malformed
    /// payload gets the shape error `terminal.send` gives, with no actuation
    /// row, whatever its target, and only a well-formed one meets the
    /// phone's refusals: a shell, then a part that is not text, then an
    /// empty message.
    func phoneSend(_ p: TerminalSendParams, deviceID: UUID) async throws -> RPCResponse

    /// `terminal.wake` with only the terminal and the message the wake
    /// carries. A `TerminalWakeResult`.
    func phoneWake(_ p: TerminalWakeParams, deviceID: UUID) async throws -> RPCResponse

    /// `terminal.swapProfile` with only the terminal, the new profile and the
    /// mode `p` names. The window size takes its default.
    func phoneSwapProfile(_ p: TerminalSwapProfileParams, deviceID: UUID) async throws -> RPCResponse

    /// `worktree.create` with only the repo and the first message.
    func phoneCreateWorktree(_ p: WorktreeCreateParams, deviceID: UUID) async throws -> RPCResponse

    /// `remote.providers`. A `RemoteProvidersResult`.
    func phoneRemoteProviders() async throws -> RPCResponse

    /// `remote.sessions`. A `RemoteSessionsResult`.
    func phoneRemoteSessions() async throws -> RPCResponse

    /// `remote.create` with only the provider and its form values. The new
    /// session's `RemoteSessionPayload`.
    func phoneRemoteCreate(_ p: RemoteCreateParams, deviceID: UUID) async throws -> RPCResponse

    /// `remote.sendMessage` with only the provider, the session and the text.
    /// It refuses a session waiting on a prompt.
    func phoneRemoteSendMessage(_ p: RemoteSendMessageParams, deviceID: UUID) async throws -> RPCResponse

    /// `remote.transcriptSync` with only the provider and the session.
    func phoneRemoteTranscriptSync(_ p: RemoteTranscriptSyncParams) async throws -> RPCResponse

    /// `remote.transcriptLoadEarlier` with only the provider and the session.
    /// A `RemoteTranscriptLoadEarlierResult`.
    func phoneRemoteTranscriptLoadEarlier(_ p: RemoteTranscriptLoadEarlierParams) async throws -> RPCResponse
}
