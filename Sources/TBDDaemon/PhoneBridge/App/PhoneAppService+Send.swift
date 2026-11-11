import Foundation
import os
import TBDShared

/// What a phone's text is for. It names the capability a remote session
/// needs for it: `send` for a message, `model` for `/model`.
enum PhoneSendPurpose: Sendable {
    case message
    case model
}

/// `message.send` and `session.setModel` (spec section 4.4, and section 5's
/// "Send" and "Model").
///
/// Both type into a live agent session, so both go through one path,
/// `sendText(_:to:deviceID:)`, and through nothing else. It adds no
/// authority: every call is a `PhoneSessionActions` method under the device
/// of the verified pairing, `context.peer.deviceID`, never a value from the
/// request. The send rail behind `phoneSend` keeps its own refusals (a shell,
/// a part that is not text, an empty message, a control character) and
/// forces the composer's options whatever this file asks for; nothing here
/// loosens them.
///
/// Both methods are in the request memory (`remembersReplies(of:)`), so a
/// resent request types once and gets the first reply.
extension PhoneAppService {
    static let emptyMessageReason = "Write a message first."
    static let messageTooLongReason = "That message is too long to send from a phone."
    /// A message over `PhoneAppConstants.firstPromptMaxBytes`, once
    /// shell-quoted (`fitsTmuxFirstPrompt(_:)`), that would start a session
    /// on the tmux transport.
    static let firstMessageTooLongReason =
        "That message is too long to start the session with. Shorten it, or open the session on the laptop first."
    /// The sessions list says the same when it marks `send` unavailable.
    static let cannotTakeMessagesReason = PhoneSessionStatus.cannotTakeMessagesReason
    static let alreadyRunningReason =
        "This session was already running, so the message was not delivered. Send it again."
    static let notAModelNameReason = "That is not a model name."
    static let noSuchSessionReason = "That session is no longer on this laptop."
    static let noSuchProviderReason = "That remote session's provider is not registered on this laptop."
    static let refusedFallbackReason = "The laptop refused the message."
    /// What a phone hears when a remote call is refused with no code, so in
    /// words TBD may not have written (`remoteRefusal(_:method:)`).
    static let remoteRefusedReason = "The remote provider refused this. Check the laptop."
    /// The most UTF-8 bytes of a refusal the laptop's text is cut to, so an
    /// error reply always fits one frame however long the daemon's reason is.
    static let refusalLimit = PhoneAppConstants.promptTextCap
    /// The longest model name `session.setModel` accepts, in characters.
    static let modelNameMaxLength = 100

    // MARK: - Handlers

    nonisolated func messageSend(_ params: MessageSendParams, _ context: DeviceContext) async throws -> ActionOutcomeResult {
        try await sendText(params.text, to: params.session, deviceID: context.peer.deviceID)
    }

    /// `/model <name>` through the send path. The name is checked against
    /// `isModelName(_:)` first, since that check is all that stands between
    /// the phone and a slash command typed into the session. A remote
    /// session needs `send-submit` for it, as its `model` capability says.
    nonisolated func sessionSetModel(_ params: SessionSetModelParams, _ context: DeviceContext) async throws -> ActionOutcomeResult {
        guard Self.isModelName(params.model) else {
            throw PhoneAppError(code: .badRequest, message: Self.notAModelNameReason)
        }
        return try await sendText(
            "/model \(params.model)", to: params.session, deviceID: context.peer.deviceID, purpose: .model)
    }

    /// Whether `name` is a model name: 1 to 100 characters, each an ASCII
    /// letter or digit, `.`, `_`, `:`, `[`, `]` or `-`. This is
    /// `^[A-Za-z0-9._:\[\]-]{1,100}$` over the whole string, written as a
    /// check of every Unicode scalar so no anchor can match short of the end:
    /// a newline, a space, a `;` or any character outside the set fails it.
    static func isModelName(_ name: String) -> Bool {
        let scalars = name.unicodeScalars
        var count = 0
        for scalar in scalars {
            count += 1
            guard count <= modelNameMaxLength else { return false }
            switch scalar {
            case "A"..."Z", "a"..."z", "0"..."9", ".", "_", ":", "[", "]", "-":
                continue
            default:
                return false
            }
        }
        return count >= 1
    }

    /// Whether `text`, as a first prompt on the tmux transport, fits
    /// `PhoneAppConstants.firstPromptMaxBytes` in the form the spawn command
    /// carries it: shell-quoted (`shellQuotedByteCount(_:)`). The limit is on
    /// that form, since each `'` grows to four bytes there, so a message of
    /// many apostrophes would otherwise pass the cap and still overrun tmux.
    static func fitsTmuxFirstPrompt(_ text: String) -> Bool {
        shellQuotedByteCount(text) <= PhoneAppConstants.firstPromptMaxBytes
    }

    /// The UTF-8 bytes `text` takes once quoted as one shell argument. It
    /// mirrors `shellEscape(_:)` (`Base/ShellEscape.swift`), with which both
    /// spawn builders quote a first prompt: two outer `'`, and each `'` in
    /// the text replaced by the four bytes `'\''`, three more than it had.
    /// Counted rather than built, so checking a long message copies nothing.
    ///
    /// `shellEscape` replaces every U+0027 scalar, including one a combining
    /// mark follows, and counting the byte `'` counts exactly those: UTF-8
    /// encodes U+0027 as that one byte, and no other scalar's encoding
    /// contains it.
    static func shellQuotedByteCount(_ text: String) -> Int {
        var apostrophes = 0
        for byte in text.utf8 where byte == UInt8(ascii: "'") {
            apostrophes += 1
        }
        return text.utf8.count + 3 * apostrophes + 2
    }

    // MARK: - Sending

    /// Sends `text` to `session` as the phone `deviceID`, the way the laptop's
    /// transcript composer would, and says how it ended: `sent`, `woken` or
    /// `unknown`.
    ///
    /// Blank text (`PhoneMessageText.isBlank`: empty, or only whitespace and
    /// invisible format characters such as a zero-width space) is
    /// `bad_request`, on every path, before anything is looked up or sent;
    /// so is text over `PhoneAppConstants.messageMaxBytes`.
    ///
    /// **A local session** is looked up with its worktree, `not_found` when
    /// the phone cannot see it (`phoneVisibleTerminal`), and
    /// `ComposerState.resolve` decides, with the worktree's real location:
    /// - **hidden or unavailable** (a Codex or shell tab, a tab in a remote
    ///   lane): `unsupported`;
    /// - **blocked** (a prompt on screen): `refused` with its reason, before
    ///   anything is sent;
    /// - **running**: `phoneSend` with the composer's options – the message
    ///   as one text part, submitted, the dispatch marker suppressed, gated on
    ///   awaiting input. Success is `sent`; a refusal is `refused` with the
    ///   daemon's reason;
    /// - **not running** (parked or exited): `phoneWake` with the text as the
    ///   wake's prompt. `woken` when the wake respawned the session; a wake
    ///   that found it running delivered nothing, so it is `refused` and the
    ///   phone is asked to send again. On the tmux transport, text over
    ///   `PhoneAppConstants.firstPromptMaxBytes` once shell-quoted
    ///   (`fitsTmuxFirstPrompt(_:)`) is `bad_request`
    ///   (`firstMessageTooLongReason`) before anything is woken.
    ///
    /// **`woken` means the wake respawned the session with the message as its
    /// first prompt, and no more.** It does not confirm that Claude received
    /// the message: the laptop's composer holds a woken message until the
    /// respawned session's own SessionStart reports in, because a session
    /// that cannot resume exits with the prompt lost while the respawn still
    /// succeeds, and the phone does not wait. On the tmux transport the
    /// prompt rides the respawn command, which tmux refuses past about 16 KB
    /// with "command too long", so the wake path holds its quoted form to
    /// `PhoneAppConstants.firstPromptMaxBytes`. A session keeps the
    /// transport it was born on, so the terminal row says which one the wake
    /// respawns onto; a pty-holder session takes up to `messageMaxBytes`.
    ///
    /// **A remote session** needs the capability `purpose` names, as the
    /// sessions list shows it (`PhoneSessionStatus.remoteCapabilities`), or
    /// it is `unsupported` with the same reason; a provider that is not
    /// registered, and a session the phone cannot see, are `not_found`
    /// (`checkPhoneCapableRemoteSession`). Then `phoneRemoteSendMessage`: the
    /// provider's `sent` is `sent` and its `unknown` is `unknown`. A refusal's
    /// words reach the phone only when it carries a code
    /// (`remoteRefusal(_:method:)`).
    ///
    /// A response that does not decode as its method's result is `internal`,
    /// never a success. A revoke noticed before the send stops it.
    nonisolated func sendText(
        _ text: String, to session: PhoneSessionRef, deviceID: UUID, purpose: PhoneSendPurpose = .message
    ) async throws -> ActionOutcomeResult {
        guard !PhoneMessageText.isBlank(text) else {
            throw PhoneAppError(code: .badRequest, message: Self.emptyMessageReason)
        }
        guard text.utf8.count <= PhoneAppConstants.messageMaxBytes else {
            throw PhoneAppError(code: .badRequest, message: Self.messageTooLongReason)
        }
        switch session {
        case .local(let terminalID):
            return try await sendLocal(text, terminalID: terminalID, deviceID: deviceID)
        case .remote(let provider, let sessionID):
            return try await sendRemote(text, provider: provider, sessionID: sessionID, deviceID: deviceID, purpose: purpose)
        }
    }

    private nonisolated func sendLocal(_ text: String, terminalID: UUID, deviceID: UUID) async throws -> ActionOutcomeResult {
        let (terminal, worktree) = try await phoneVisibleTerminal(terminalID)
        switch ComposerState.resolve(terminal: terminal, isRemoteWorktree: !worktree.location.isLocal) {
        case .hidden, .unavailable:
            throw PhoneAppError(code: .unsupported, message: Self.cannotTakeMessagesReason)
        case .blocked(let message):
            throw Self.refusal(message)
        case .running:
            try Task.checkCancellation()
            let response = try await actions.phoneSend(TerminalSendParams(
                terminalID: terminalID,
                submit: true,
                parts: [.text(text)],
                envelope: .suppressed,
                gateOnAwaitingInput: true), deviceID: deviceID)
            guard response.success else { throw Self.refusal(response.error) }
            return ActionOutcomeResult(outcome: "sent")
        case .notRunning:
            guard terminal.transport == .holder || Self.fitsTmuxFirstPrompt(text) else {
                throw PhoneAppError(code: .badRequest, message: Self.firstMessageTooLongReason)
            }
            try Task.checkCancellation()
            let response = try await actions.phoneWake(
                TerminalWakeParams(terminalID: terminalID, prompt: text), deviceID: deviceID)
            let result = try Self.succeeded(TerminalWakeResult.self, from: response, method: "terminal.wake")
            guard result.woken else {
                throw PhoneAppError(code: .refused, message: Self.alreadyRunningReason)
            }
            return ActionOutcomeResult(outcome: "woken")
        }
    }

    private nonisolated func sendRemote(
        _ text: String, provider: String, sessionID: String, deviceID: UUID, purpose: PhoneSendPurpose
    ) async throws -> ActionOutcomeResult {
        try await checkPhoneCapableRemoteSession(
            provider: provider, sessionID: sessionID,
            needing: { capabilities in
                switch purpose {
                case .message:
                    return capabilities.send
                case .model:
                    return capabilities.model
                }
            },
            orElse: Self.cannotTakeMessagesReason)
        try Task.checkCancellation()
        let response = try await actions.phoneRemoteSendMessage(
            RemoteSendMessageParams(provider: provider, sessionID: sessionID, text: text), deviceID: deviceID)
        switch try Self.remoteSucceeded(RemoteSendMessageResult.self, from: response, method: "remote.sendMessage").outcome {
        case .sent:
            return ActionOutcomeResult(outcome: "sent")
        case .unknown:
            return ActionOutcomeResult(outcome: "unknown")
        }
    }

    /// The capabilities of `provider`'s sessions among `providers`, from
    /// what it declares, under the setting for answering prompts
    /// `promptAnswerEnabled`, as the sessions list reads them: `not_found`
    /// for a provider missing from them. An action on a remote session reads
    /// them through `checkPhoneCapableRemoteSession`.
    static func remoteCapabilities(
        ofProvider provider: String, in providers: [RemoteProviderStatus], promptAnswerEnabled: Bool
    ) throws -> PhoneCapabilities {
        guard let declared = PhoneSessionStatus.declaredCapabilities(providers)[provider] else {
            throw PhoneAppError(code: .notFound, message: Self.noSuchProviderReason)
        }
        return PhoneSessionStatus.remoteCapabilities(declared: declared, promptAnswerEnabled: promptAnswerEnabled)
    }

    /// Throws `unsupported` unless `capability` is available, with the
    /// capability's reason, as the sessions list shows it, or `fallback` when
    /// it gives none.
    static func requireCapability(_ capability: PhoneCapability, orElse fallback: String) throws {
        guard capability.available else {
            throw PhoneAppError(code: .unsupported, message: capability.reason ?? fallback)
        }
    }

    // MARK: - Replies

    /// A `refused` error carrying the laptop's reason, cut to
    /// `refusalLimit` bytes, or a fixed line when it gave none.
    static func refusal(_ reason: String?) -> PhoneAppError {
        let text = reason.flatMap { $0.isEmpty ? nil : $0 } ?? Self.refusedFallbackReason
        return PhoneAppError(code: .refused, message: PhoneText.capped(text, limit: Self.refusalLimit))
    }

    /// `response`'s result as `R`, once it succeeded: a refusal is `refused`
    /// with the laptop's reason (`refusal(_:)`), and a result that does not
    /// decode is `internal` (`decoded(_:from:method:)`).
    static func succeeded<R: Decodable>(_ type: R.Type, from response: RPCResponse, method: String) throws -> R {
        guard response.success else { throw Self.refusal(response.error) }
        return try Self.decoded(type, from: response, method: method)
    }

    /// `response`'s result as `R`, as `succeeded(_:from:method:)` reads it,
    /// for a remote call whose refusal can be a provider's own words: a
    /// refusal is `remoteRefusal(_:method:)`.
    static func remoteSucceeded<R: Decodable>(
        _ type: R.Type, from response: RPCResponse, method: String
    ) throws -> R {
        guard response.success else {
            throw Self.remoteRefusal(response, method: method)
        }
        return try Self.decoded(type, from: response, method: method)
    }

    /// The `refused` error for a remote call the daemon refused with
    /// `response`, on every remote path: a create, a message, an answer, a
    /// transcript sync and an earlier history load.
    ///
    /// **It decides from the response's code, never from its words.** A code
    /// goes only on a refusal whose whole text TBD wrote (`RPCErrorCode`):
    /// - `answerDoesNotFit`, `promptAnswerOff` and `promptAnswerSettingUnread`
    ///   get the phone's own sentences (`answerCodeReason(_:)`);
    /// - any other code gets the response's text, as `refusal(_:)` sends it;
    /// - no code gets `remoteRefusedReason`, and the text goes to the log as
    ///   private data. A refusal with no code can be a provider's own error
    ///   message, or its raw stderr, which can quote a URL with an access
    ///   token in it, and cutting it short does not make it safe. A code this
    ///   build does not know counts as none.
    static func remoteRefusal(_ response: RPCResponse, method: String) -> PhoneAppError {
        guard let code = Self.refusalCode(response) else {
            Self.logger.notice(
                "Phone \(method, privacy: .public): refused with no code, in words the phone is not sent: \(response.error ?? "<none>", privacy: .private)")
            return PhoneAppError(code: .refused, message: Self.remoteRefusedReason)
        }
        if let reason = Self.answerCodeReason(code) {
            return Self.refusal(reason)
        }
        return Self.refusal(response.error)
    }

    /// The code `response` carries (`RPCResponse.errorCode`), or nil when it
    /// carries none or one this build does not know.
    static func refusalCode(_ response: RPCResponse) -> RPCErrorCode? {
        guard let raw = response.errorCode else { return nil }
        return RPCErrorCode(rawValue: raw)
    }

    /// `response`'s result as `R`. One that does not decode is `internal`:
    /// the handler catches the decoding error itself, so it never reads as
    /// the phone's `bad_request`, and never as a success. Every action
    /// handler reads its `RPCResponse` through this.
    static func decoded<R: Decodable>(_ type: R.Type, from response: RPCResponse, method: String) throws -> R {
        do {
            return try response.decodeResult(R.self)
        } catch {
            Self.logger.error(
                "Phone send: \(method, privacy: .public) answered a result that does not decode: \(Self.errorType(error), privacy: .public)")
            throw PhoneAppError(code: .internalError, message: Self.internalErrorReason)
        }
    }
}
