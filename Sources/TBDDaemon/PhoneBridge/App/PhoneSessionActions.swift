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
/// are the send rail's: it refuses a shell, which spec section 6 hides from
/// the phone, and a message part that is not text.
///
/// **A method that acts takes `deviceID`**, the device of the verified pairing
/// the request came through. The actuation record names it, and an answer
/// takes its authority from it, both built from that one value so they cannot
/// disagree. Take it from the bridge's verified peer, never from anything the
/// phone sent. The read-only methods take none: their RPCs record nothing.
///
/// **The conformance keeps only the fields a phone may set.** Where a params
/// struct holds fields a phone may not set, the conformance builds fresh params
/// from the fields it may, and everything else takes TBD's defaults, whatever
/// the bridge passed (spec section 5). It names the fields it keeps, never the
/// ones it drops, so a field added to a params struct later stays off the
/// phone by default.
protocol PhoneSessionActions: Sendable {
    /// `session.states` over every worktree. A `SessionStatesResult`, which
    /// never reports a plain shell.
    func phoneSessionStates() async throws -> RPCResponse

    /// The `prompt.answer` core under the phone's pairing: the
    /// `transcript_prompt_answer_enabled` check, then no socket check.
    func phoneAnswerPrompt(_ p: PromptAnswerParams, deviceID: UUID) async throws -> RPCResponse

    /// The `remote.answer` core under the phone's pairing: every gate the
    /// socket handler runs, except the socket check.
    func phoneAnswerRemotePrompt(_ p: RemoteAnswerParams, deviceID: UUID) async throws -> RPCResponse

    /// The paired-phone send rail: the terminal, the message (`text` or
    /// `parts`) and `submit`, with no dispatch marker, always gated on
    /// awaiting input, never verified and never keys, whatever `p` asks for.
    /// A shell terminal, or a part that is not text, is refused before
    /// anything is typed.
    func phoneSend(_ p: TerminalSendParams, deviceID: UUID) async throws -> RPCResponse

    /// `terminal.wake` with only the terminal and the message the wake
    /// carries. A `TerminalWakeResult`.
    func phoneWake(_ p: TerminalWakeParams, deviceID: UUID) async throws -> RPCResponse

    /// `terminal.swapProfile`, in the mode `p` names.
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

    /// `remote.sendMessage`, which refuses a session waiting on a prompt.
    func phoneRemoteSendMessage(_ p: RemoteSendMessageParams, deviceID: UUID) async throws -> RPCResponse

    /// `remote.transcriptSync`.
    func phoneRemoteTranscriptSync(_ p: RemoteTranscriptSyncParams) async throws -> RPCResponse

    /// `remote.transcriptLoadEarlier`. A `RemoteTranscriptLoadEarlierResult`.
    func phoneRemoteTranscriptLoadEarlier(_ p: RemoteTranscriptLoadEarlierParams) async throws -> RPCResponse
}
