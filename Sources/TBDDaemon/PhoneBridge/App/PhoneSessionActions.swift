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
/// **Each method is an existing RPC, minus its socket edge**, except
/// `phoneSpawnsOnHolder`, which answers the question every spawn path asks.
/// It returns the
/// `RPCResponse` that RPC returns, refusal text included, so the phone hears a
/// refusal in the words the app hears. It runs exactly the checks the matching
/// core function or handler runs, in the same order. The only checks it adds
/// keep shells, which spec section 6 hides from the phone, out of its reach,
/// and keep its messages to text: `phoneSessionStates` drops every report on
/// a shell; the send rail refuses a shell, a message part that is not text,
/// an empty message and a message holding a control character, inside the
/// send core, on the terminal row the core sends to (see `phoneSend`); and
/// `phoneWake`, `phoneCreateWorktree`, `phoneRemoteCreate` and
/// `phoneRemoteSendMessage` hold the message they carry to the same rule
/// (`PhoneMessageText`) before their handler runs.
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
    /// check, which refuses while the setting is off or cannot be read, then
    /// no socket check.
    func phoneAnswerPrompt(_ p: PromptAnswerParams, deviceID: UUID) async throws -> RPCResponse

    /// The `remote.answer` core under the phone's pairing, with the provider,
    /// the session, the prompt and the answer: every gate the socket handler
    /// runs, except the socket check.
    func phoneAnswerRemotePrompt(_ p: RemoteAnswerParams, deviceID: UUID) async throws -> RPCResponse

    /// The paired-phone send rail: the terminal, the message (`text` or
    /// `parts`) and `submit`, with no dispatch marker, always gated on
    /// awaiting input, never verified and never keys, whatever `p` asks for.
    /// Every CRLF in the message becomes LF. A shell terminal, a part that is
    /// not text, an empty message (one of only whitespace and invisible format
    /// characters, such as a zero-width space) or a message holding a control
    /// character (a scalar below U+0020 other than LF and tab, DEL, or a C1
    /// control) is refused before anything is typed.
    ///
    /// The phone's refusals run inside the send core and the terminal's send
    /// lane, on the terminal row the core itself read, so the row they judge
    /// is the row the paste is addressed by. The order:
    /// the core's shape check, the core's terminal and worktree lookup, the
    /// phone's refusals, then the rest of the send core. A malformed payload
    /// gets the shape error `terminal.send` gives, with no actuation row,
    /// whatever its target. A terminal with no row, or one whose worktree is
    /// not local, gets the send core's own not-found error, with no actuation
    /// row, whatever its message. Only a well-formed payload aimed at a
    /// terminal with a row in a local worktree meets the phone's refusals: a
    /// shell, then a part that is not text, then an empty message, then a
    /// control character. Each is recorded as a refused `terminal.send`.
    func phoneSend(_ p: TerminalSendParams, deviceID: UUID) async throws -> RPCResponse

    /// `terminal.wake` with only the terminal and the message the wake
    /// carries. A `TerminalWakeResult`.
    ///
    /// A message that is not empty is held to the phone message rule
    /// (`PhoneMessageText.vetted`) first: every CRLF becomes LF, then a blank
    /// message is refused with `PhoneMessageText.emptyRefusal` and one
    /// holding a control character with
    /// `PhoneMessageText.controlCharacterRefusal`. These refusals return
    /// before the handler runs, so they record no actuation row; the phone
    /// action recorder has already logged the action. A nil or empty prompt
    /// is no message and goes to the handler as it came.
    func phoneWake(_ p: TerminalWakeParams, deviceID: UUID) async throws -> RPCResponse

    /// `terminal.swapProfile` with only the terminal, the new profile and the
    /// mode `p` names. The window size takes its default.
    func phoneSwapProfile(_ p: TerminalSwapProfileParams, deviceID: UUID) async throws -> RPCResponse

    /// `worktree.create` with only the repo and the first message. The
    /// pending `Worktree`.
    ///
    /// A first message that is not empty is held to the phone message rule
    /// (`PhoneMessageText.vetted`) first, because it rides the first agent's
    /// spawn command: every CRLF becomes LF, then a blank message is refused
    /// with `PhoneMessageText.emptyRefusal` and one holding a control
    /// character with `PhoneMessageText.controlCharacterRefusal`. These
    /// refusals return before the handler runs, so they create nothing and
    /// record no actuation row; the phone action recorder has already logged
    /// the action. A nil or empty first message is no message and goes to the
    /// handler as it came.
    func phoneCreateWorktree(_ p: WorktreeCreateParams, deviceID: UUID) async throws -> RPCResponse

    /// Whether a session spawned now goes onto the pty-holder transport, as
    /// every spawn path decides it (`TerminalSpawnTransport.decide`): the
    /// holder flag is on and a holder can be started. A config that cannot
    /// be read means tmux, as it does for a spawn. Not an RPC: the phone app
    /// service reads it to hold a new worktree's first message to
    /// `PhoneAppConstants.firstPromptMaxBytes` on tmux alone.
    func phoneSpawnsOnHolder() async -> Bool

    /// `remote.providers`. A `RemoteProvidersResult`. Like the RPC, it first
    /// re-reads the provider registry file, registering and enrolling a
    /// provider added since, so the phone app service calls it only from its
    /// debounced sessions gather.
    func phoneRemoteProviders() async throws -> RPCResponse

    /// `remote.providers` without re-reading the registry file: the
    /// providers as the registry was last read, by the sessions gather, the
    /// app or the daemon's start. A `RemoteProvidersResult`. The phone app
    /// service reads it for every check one action makes, so an action costs
    /// no file read.
    func phoneCachedRemoteProviders() async throws -> RPCResponse

    /// `remote.sessions`. A `RemoteSessionsResult`.
    func phoneRemoteSessions() async throws -> RPCResponse

    /// `remote.create` with only the provider and its form values. The new
    /// session's `RemoteSessionPayload`.
    ///
    /// A first message in the form values, a `prompt` string that is not
    /// empty, is held to the phone message rule (`PhoneMessageText.vetted`)
    /// first, because the provider pastes it into the new session: every
    /// CRLF becomes LF, then a blank message is refused with
    /// `PhoneMessageText.emptyRefusal` and one holding a control character
    /// with `PhoneMessageText.controlCharacterRefusal`. These refusals return
    /// before the handler runs, so they create nothing, reach no provider and
    /// record no actuation row; the phone action recorder has already logged
    /// the action. Form values with no such `prompt` go to the handler as
    /// they came.
    func phoneRemoteCreate(_ p: RemoteCreateParams, deviceID: UUID) async throws -> RPCResponse

    /// `remote.sendMessage` with only the provider, the session and the text.
    /// It refuses a session waiting on a prompt.
    ///
    /// The text is held to the phone message rule (`PhoneMessageText.vetted`)
    /// first, because the provider pastes it into its session: every CRLF
    /// becomes LF, then a blank message is refused with
    /// `PhoneMessageText.emptyRefusal` and one holding a control character
    /// with `PhoneMessageText.controlCharacterRefusal`. These refusals return
    /// before the handler runs, so they reach no provider and record no
    /// actuation row; the phone action recorder has already logged the
    /// action.
    func phoneRemoteSendMessage(_ p: RemoteSendMessageParams, deviceID: UUID) async throws -> RPCResponse

    /// `remote.transcriptSync` with only the provider and the session.
    func phoneRemoteTranscriptSync(_ p: RemoteTranscriptSyncParams) async throws -> RPCResponse

    /// `remote.transcriptLoadEarlier` with only the provider and the session.
    /// A `RemoteTranscriptLoadEarlierResult`.
    func phoneRemoteTranscriptLoadEarlier(_ p: RemoteTranscriptLoadEarlierParams) async throws -> RPCResponse
}
