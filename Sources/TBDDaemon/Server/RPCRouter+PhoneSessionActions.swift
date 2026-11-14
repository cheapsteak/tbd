import Foundation
import TBDShared

/// The router behind the phone bridge's one door (`PhoneSessionActions`).
///
/// Every method is one call to an existing core function or handler. It adds
/// only five things: the params a phone may set, rebuilt from those fields
/// alone; the encoding of params for a handler that decodes them, with the
/// router's own `encoder` to match the router's own `decoder`; the phone's
/// identity, built from the one `deviceID` it is given; in
/// `phoneSessionStates`, the removal of every report on a shell; and, in
/// `phoneWake`, `phoneCreateWorktree`, `phoneRemoteCreate` and
/// `phoneRemoteSendMessage`, the phone message rule the send rail applies
/// (`PhoneMessageText`) to the phone's message, whose refusal answers before
/// the handler runs, with its code (`CodedRefusal.response`). Past that, each
/// runs the checks of the RPC it mirrors, in that RPC's order, and returns that
/// RPC's response.
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
    /// `session.states` over every worktree, less every report on a shell.
    ///
    /// The handler keeps every kindless row, because the app's reader would
    /// rather see a real agent than lose one, and a kindless row with no
    /// Claude session id is a shell to the send core and to the send rail
    /// (`effectiveKind(kind:claudeSessionID:)`). A report carries neither the
    /// kind nor the session id, so the terminal rows are read once, in one
    /// query, and a report is kept only when its terminal's row is there and
    /// is not a shell by that reading. The handler is left as it is: the app
    /// reads it too.
    func phoneSessionStates() async throws -> RPCResponse {
        let response = try await handleSessionStates(encoder.encode(SessionStatesParams()))
        guard response.success else { return response }
        let reports = try response.decodeResult(SessionStatesResult.self).reports
        let agentTerminalIDs = Set(try await db.terminals.list()
            .filter { Self.effectiveKind(kind: $0.kind, claudeSessionID: $0.claudeSessionID) != .shell }
            .map(\.id))
        return try RPCResponse(result: SessionStatesResult(
            reports: reports.filter { agentTerminalIDs.contains($0.terminalID) }))
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

    /// A wake from a phone. A message it carries is held to the phone message
    /// rule first (`PhoneMessageText.vettedFirstMessage`), and a refused one
    /// wakes nothing. A wake with no message, a nil or empty prompt, is not a
    /// phone message and goes to the handler as it came.
    func phoneWake(_ p: TerminalWakeParams, deviceID: UUID) async throws -> RPCResponse {
        let narrowed = Self.phoneWakeParams(p)
        switch PhoneMessageText.vettedFirstMessage(narrowed.prompt) {
        case .refused(let refusal):
            return refusal.response
        case .deliver(let prompt):
            return try await handleTerminalWake(
                encoder.encode(TerminalWakeParams(terminalID: narrowed.terminalID, prompt: prompt)),
                actor: .phone(deviceID: deviceID))
        }
    }

    func phoneSwapProfile(_ p: TerminalSwapProfileParams, deviceID: UUID) async throws -> RPCResponse {
        try await handleTerminalSwapProfile(
            encoder.encode(Self.phoneSwapProfileParams(p)), actor: .phone(deviceID: deviceID))
    }

    /// A worktree create from a phone. Its first message rides the spawn
    /// command of the worktree's first agent, so it is held to the phone
    /// message rule first (`phoneWorktreeCreateVetted`), and a refused one
    /// creates nothing. A create with no first message goes to the handler as
    /// it came.
    func phoneCreateWorktree(_ p: WorktreeCreateParams, deviceID: UUID) async throws -> RPCResponse {
        switch Self.phoneWorktreeCreateVetted(p) {
        case .refused(let refusal):
            return refusal.response
        case .deliver(let params):
            return try await handleWorktreeCreate(encoder.encode(params), actor: .phone(deviceID: deviceID))
        }
    }

    func phoneRemoteProviders() async throws -> RPCResponse {
        try await handleRemoteProviders()
    }

    func phoneCachedRemoteProviders() async throws -> RPCResponse {
        try await handleRemoteProviders(refreshingRegistry: false)
    }

    func phoneRemoteSessions() async throws -> RPCResponse {
        try await handleRemoteSessions()
    }

    /// A remote session create from a phone. A first message in its form
    /// values is pasted by the provider into the new session, so it is held
    /// to the phone message rule first (`phoneRemoteCreateVetted`), and a
    /// refused one creates nothing. A create with no first message goes to
    /// the handler as it came. The form's other values are the phone app
    /// service's to vet, which alone knows which of them the phone set.
    func phoneRemoteCreate(_ p: RemoteCreateParams, deviceID: UUID) async throws -> RPCResponse {
        switch Self.phoneRemoteCreateVetted(p) {
        case .refused(let refusal):
            return refusal.response
        case .deliver(let params):
            return try await handleRemoteCreate(encoder.encode(params), actor: .phone(deviceID: deviceID))
        }
    }

    /// A message from a phone to a remote session, held to the phone message
    /// rule first (`PhoneMessageText.vetted`). The provider pastes the text
    /// into its own session, so an ESC sequence such as the bracketed-paste
    /// end marker would end the paste early and reach the agent as keys; a
    /// refused message reaches no provider.
    func phoneRemoteSendMessage(_ p: RemoteSendMessageParams, deviceID: UUID) async throws -> RPCResponse {
        let params = Self.phoneRemoteSendMessageParams(p)
        switch PhoneMessageText.vetted(params.text) {
        case .refused(let refusal):
            return refusal.response
        case .deliver(let text):
            return try await handleRemoteSendMessage(
                encoder.encode(RemoteSendMessageParams(
                    provider: params.provider, sessionID: params.sessionID, text: text)),
                actor: .phone(deviceID: deviceID))
        }
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

    /// A worktree a phone creates, as the handler gets it: the repo and the
    /// first message (`phoneWorktreeCreateParams`), with the first message
    /// held to the phone message rule (`PhoneMessageText.vettedFirstMessage`).
    /// A nil or empty first message is no message and is kept as it came.
    /// Either the params with the message's CRLFs made bare LFs, or the
    /// refusal that answers in place of the create.
    static func phoneWorktreeCreateVetted(
        _ p: WorktreeCreateParams
    ) -> PhoneMessageText.Vetted<WorktreeCreateParams> {
        let narrowed = phoneWorktreeCreateParams(p)
        switch PhoneMessageText.vettedFirstMessage(narrowed.prompt) {
        case .refused(let refusal):
            return .refused(refusal)
        case .deliver(let prompt):
            return .deliver(WorktreeCreateParams(repoID: narrowed.repoID, prompt: prompt))
        }
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

    /// A remote session a phone creates, as the handler gets it: the provider
    /// and its form values (`phoneRemoteCreateParams`), with the first
    /// message, the form's `prompt` value
    /// (`PhoneMessageText.remoteCreatePromptField`), held to the phone
    /// message rule (`PhoneMessageText.vetted`).
    ///
    /// **Only the first message is vetted here.** The form also holds values
    /// the laptop filled in: the repo's and the laptop's stored create
    /// defaults, the repo's remote and a generated slug. The router cannot
    /// tell those from the values the phone set, and holding a laptop value to
    /// the phone message rule would let one stored default refuse every phone
    /// create. The phone app service knows which values the phone set: it
    /// allows only keys the provider's form asks for and holds every one of
    /// them to the rule (`PhoneAppService.vettedFormStrings`) before it calls
    /// here.
    ///
    /// - **A `prompt` that is there and is not a string** (a number, an
    ///   array, an object, a null) is refused with
    ///   `RemoteCreateRefusal.promptNotString`. The provider would paste
    ///   whatever text it makes of the value, which the rule never saw.
    /// - **Form values that are not a JSON object, and a `prompt` that is
    ///   absent or empty,** carry no phone message and are kept as they came,
    ///   for the handler to judge.
    /// - **When the rule changes the message,** its CRLFs made bare LFs, the
    ///   form values are written out again with it, every other value as it
    ///   came; otherwise they pass byte for byte.
    ///
    /// Either the params, or the refusal that answers in place of the create:
    /// `RemoteCreateRefusal`'s or `PhoneMessageText`'s, each with its code,
    /// which reach the phone as they are.
    static func phoneRemoteCreateVetted(
        _ p: RemoteCreateParams
    ) -> PhoneMessageText.Vetted<RemoteCreateParams> {
        let narrowed = phoneRemoteCreateParams(p)
        let field = PhoneMessageText.remoteCreatePromptField
        guard let data = narrowed.paramsJSON.data(using: .utf8),
              var form = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let value = form[field] else {
            return .deliver(narrowed)
        }
        guard let prompt = value as? String else {
            return .refused(RemoteCreateRefusal.promptNotString)
        }
        guard !prompt.isEmpty else {
            return .deliver(narrowed)
        }
        switch PhoneMessageText.vetted(prompt) {
        case .refused(let refusal):
            return .refused(refusal)
        case .deliver(let normalized):
            guard normalized != prompt else { return .deliver(narrowed) }
            form[field] = normalized
            // A form that came out of `JSONSerialization` always goes back in.
            guard let written = try? JSONSerialization.data(withJSONObject: form),
                  let json = String(data: written, encoding: .utf8) else {
                return .refused(RemoteCreateRefusal.formNotWritable)
            }
            return .deliver(RemoteCreateParams(provider: narrowed.provider, paramsJSON: json))
        }
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
