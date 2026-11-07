import Foundation
import TBDShared

/// The router behind the phone bridge's one door (`PhoneSessionActions`).
///
/// Every method is one call to an existing core function or handler. It adds
/// only three things: the params a phone may set, rebuilt from those fields
/// alone; the encoding of params for a handler that decodes them, with the
/// router's own `encoder` to match the router's own `decoder`; and the phone's
/// identity, built from the one `deviceID` it is given. So each runs the
/// checks of the RPC it mirrors, in that RPC's order, and returns that RPC's
/// response.
///
/// **The rebuild names what a phone keeps, never what it loses.** Every params
/// value the bridge passes is rebuilt field by field into fresh params holding
/// only the fields spec section 5 gives a phone, and every other field takes
/// TBD's default. That holds for a struct whose every field a phone may set
/// today, too, so a field added to any of these params structs later stays off
/// the phone until someone adds it here. The send rail rebuilds its params the
/// same way, in `sendFromPairedPhone`.
///
/// None of the handlers called here takes a socket connection, because none is
/// limited to the app at the socket edge. The three RPCs that are,
/// `prompt.answer`, `remote.answer` and a send without the dispatch marker,
/// are reached through the cores split out beneath their socket checks.
extension RPCRouter: PhoneSessionActions {
    func phoneSessionStates() async throws -> RPCResponse {
        try await handleSessionStates(encoder.encode(SessionStatesParams()))
    }

    func phoneAnswerPrompt(_ p: PromptAnswerParams, deviceID: UUID) async throws -> RPCResponse {
        try await answerPrompt(
            Self.phonePromptAnswerParams(p),
            actor: .phone(deviceID: deviceID), authority: .pairedPhone(deviceID: deviceID))
    }

    func phoneAnswerRemotePrompt(_ p: RemoteAnswerParams, deviceID: UUID) async throws -> RPCResponse {
        try await answerRemotePrompt(
            Self.phoneRemoteAnswerParams(p),
            actor: .phone(deviceID: deviceID), authority: .pairedPhone(deviceID: deviceID))
    }

    func phoneSend(_ p: TerminalSendParams, deviceID: UUID) async throws -> RPCResponse {
        try await sendFromPairedPhone(p, deviceID: deviceID)
    }

    func phoneWake(_ p: TerminalWakeParams, deviceID: UUID) async throws -> RPCResponse {
        try await handleTerminalWake(
            encoder.encode(Self.phoneWakeParams(p)), actor: .phone(deviceID: deviceID))
    }

    func phoneSwapProfile(_ p: TerminalSwapProfileParams, deviceID: UUID) async throws -> RPCResponse {
        try await handleTerminalSwapProfile(
            encoder.encode(Self.phoneSwapProfileParams(p)), actor: .phone(deviceID: deviceID))
    }

    func phoneCreateWorktree(_ p: WorktreeCreateParams, deviceID: UUID) async throws -> RPCResponse {
        try await handleWorktreeCreate(
            encoder.encode(Self.phoneWorktreeCreateParams(p)), actor: .phone(deviceID: deviceID))
    }

    func phoneRemoteProviders() async throws -> RPCResponse {
        try await handleRemoteProviders()
    }

    func phoneRemoteSessions() async throws -> RPCResponse {
        try await handleRemoteSessions()
    }

    func phoneRemoteCreate(_ p: RemoteCreateParams, deviceID: UUID) async throws -> RPCResponse {
        try await handleRemoteCreate(
            encoder.encode(Self.phoneRemoteCreateParams(p)), actor: .phone(deviceID: deviceID))
    }

    func phoneRemoteSendMessage(_ p: RemoteSendMessageParams, deviceID: UUID) async throws -> RPCResponse {
        try await handleRemoteSendMessage(
            encoder.encode(Self.phoneRemoteSendMessageParams(p)), actor: .phone(deviceID: deviceID))
    }

    func phoneRemoteTranscriptSync(_ p: RemoteTranscriptSyncParams) async throws -> RPCResponse {
        try await handleRemoteTranscriptSync(encoder.encode(Self.phoneRemoteTranscriptSyncParams(p)))
    }

    func phoneRemoteTranscriptLoadEarlier(_ p: RemoteTranscriptLoadEarlierParams) async throws -> RPCResponse {
        try await handleRemoteTranscriptLoadEarlier(
            encoder.encode(Self.phoneRemoteTranscriptLoadEarlierParams(p)))
    }

    // MARK: - The fields a phone may set

    /// A worktree a phone creates: the repo and the first message. The folder,
    /// branch, name, parent, profile, model, agent, settings, plugin folders,
    /// pull request and window size all take TBD's defaults, as spec section 5
    /// says.
    static func phoneWorktreeCreateParams(_ p: WorktreeCreateParams) -> WorktreeCreateParams {
        WorktreeCreateParams(repoID: p.repoID, prompt: p.prompt)
    }

    /// A wake from a phone: the terminal and the message it carries. The
    /// window size and the default-profile fallback take their defaults, so a
    /// session pinned to a missing profile stays parked rather than resuming
    /// on another account.
    static func phoneWakeParams(_ p: TerminalWakeParams) -> TerminalWakeParams {
        TerminalWakeParams(terminalID: p.terminalID, prompt: p.prompt)
    }

    /// A remote session a phone creates: the provider and its form values. A
    /// seed and a parent worktree take their defaults, none.
    static func phoneRemoteCreateParams(_ p: RemoteCreateParams) -> RemoteCreateParams {
        RemoteCreateParams(provider: p.provider, paramsJSON: p.paramsJSON)
    }

    /// A profile swap from a phone: the terminal, the profile to move it to
    /// (none for the ambient account) and the mode. The window size takes its
    /// default.
    static func phoneSwapProfileParams(_ p: TerminalSwapProfileParams) -> TerminalSwapProfileParams {
        TerminalSwapProfileParams(terminalID: p.terminalID, newProfileID: p.newProfileID, mode: p.mode)
    }

    /// A remote message from a phone: the provider, the session and the text.
    static func phoneRemoteSendMessageParams(_ p: RemoteSendMessageParams) -> RemoteSendMessageParams {
        RemoteSendMessageParams(provider: p.provider, sessionID: p.sessionID, text: p.text)
    }

    /// An answer from a phone: the terminal, the prompt and the answer.
    static func phonePromptAnswerParams(_ p: PromptAnswerParams) -> PromptAnswerParams {
        PromptAnswerParams(terminalID: p.terminalID, promptID: p.promptID, answer: p.answer)
    }

    /// A remote answer from a phone: the provider, the session, the prompt and
    /// the answer.
    static func phoneRemoteAnswerParams(_ p: RemoteAnswerParams) -> RemoteAnswerParams {
        RemoteAnswerParams(
            provider: p.provider, sessionID: p.sessionID, promptID: p.promptID, answer: p.answer)
    }

    /// A remote transcript sync from a phone: the provider and the session.
    static func phoneRemoteTranscriptSyncParams(
        _ p: RemoteTranscriptSyncParams
    ) -> RemoteTranscriptSyncParams {
        RemoteTranscriptSyncParams(provider: p.provider, sessionID: p.sessionID)
    }

    /// Earlier remote history from a phone: the provider and the session.
    static func phoneRemoteTranscriptLoadEarlierParams(
        _ p: RemoteTranscriptLoadEarlierParams
    ) -> RemoteTranscriptLoadEarlierParams {
        RemoteTranscriptLoadEarlierParams(provider: p.provider, sessionID: p.sessionID)
    }
}
