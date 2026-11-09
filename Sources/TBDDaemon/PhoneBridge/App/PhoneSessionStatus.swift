import Foundation
import TBDShared

/// The one conversion from a `Date` to the app protocol's timestamps, integer
/// Unix milliseconds. Every `…At` field the service writes goes through it.
enum PhoneTime {
    /// `date` in whole Unix milliseconds, rounded down. A date outside what
    /// an `Int64` holds is clamped to its end.
    static func ms(_ date: Date) -> Int64 {
        let millis = (date.timeIntervalSince1970 * 1_000).rounded(.down)
        guard millis.isFinite else { return 0 }
        if millis <= -9.2e18 { return Int64.min }
        if millis >= 9.2e18 { return Int64.max }
        return Int64(millis)
    }
}

/// Short text fields of the sessions list, kept short.
enum PhoneText {
    /// The most UTF-8 bytes a name, a tab name or a reason keeps.
    static let fieldLimit = 256

    /// `text` cut to at most `limit` UTF-8 bytes, at a character boundary, so
    /// no character is split.
    static func capped(_ text: String, limit: Int = fieldLimit) -> String {
        guard text.utf8.count > limit else { return text }
        var result = ""
        var bytes = 0
        for character in text {
            let width = character.utf8.count
            if bytes + width > limit { break }
            result.append(character)
            bytes += width
        }
        return result
    }
}

/// A session's chip and capabilities as the phone shows them (spec section
/// 4.4, "Sessions list"). Pure functions of what the daemon already knows.
enum PhoneSessionStatus {
    static let errorReason = "The agent reported an error."
    static let needsAuthReason = "The agent needs you to sign in."

    // MARK: - Status

    /// A local session's status.
    ///
    /// An open prompt, or an `awaitingInput` state, is `waitingForYou`. Its
    /// `changedAt` is the prompt's `createdAt`, or the state's `observedAt`,
    /// and its reason is `AwaitingInputReason.displayMessage`: the state's
    /// own reason when it has one, else the generic line for the prompt's
    /// kind. Every reason is cut to `PhoneText.fieldLimit` bytes.
    static func local(_ state: SessionState, openPrompt: PendingPromptPayload?) -> PhoneStatus {
        if let openPrompt {
            let reason: String
            if case .awaitingInput(let awaiting?) = state.value {
                reason = awaiting.displayMessage
            } else {
                reason = promptReason(openPrompt.kind)
            }
            return status(.waitingForYou, at: openPrompt.createdAt, reason: reason)
        }
        let at = state.observedAt
        switch state.value {
        case .awaitingInput(let awaiting):
            return status(.waitingForYou, at: at, reason: (awaiting ?? AwaitingInputReason(message: "")).displayMessage)
        case .working:
            return status(.working, at: at)
        case .idle, .done:
            return status(.idle, at: at)
        case .parked:
            return status(.parked, at: at)
        case .rateLimited(let until):
            return PhoneStatus(chip: .rateLimited, changedAt: PhoneTime.ms(at), reason: nil, untilAt: until.map(PhoneTime.ms))
        case .error:
            return status(.error, at: at, reason: errorReason)
        case .needsAuth:
            return status(.error, at: at, reason: needsAuthReason)
        case .gone:
            return status(.exited, at: at)
        case .unknown(let why):
            return status(.unknown, at: at, reason: why)
        }
    }

    /// A remote session's status, from what its provider last reported.
    ///
    /// Gone, a process state of `exited` or an agent state of `exited` is
    /// `exited`; `waiting_input`, or a prompt waiting for an answer, is
    /// `waitingForYou`; `working` and `idle` are themselves; anything else is
    /// `unknown`. `changedAt` is the provider's `agent_state_at` when it
    /// parses, else when TBD last saw the session.
    static func remote(_ session: RemoteSessionInfo) -> PhoneStatus {
        let payload = session.payload
        let at = RemoteTimestamp.parse(payload.agentStateAt) ?? session.lastSeen
        let chip: PhoneStatusChip
        if session.gone || payload.state == .exited || payload.agentState == .exited {
            chip = .exited
        } else if payload.agentState == .waitingInput || payload.effectivePendingPrompt != nil {
            chip = .waitingForYou
        } else {
            switch payload.agentState {
            case .working:
                chip = .working
            case .idle:
                chip = .idle
            case .waitingInput, .exited, .unknown:
                chip = .unknown
            }
        }
        return status(chip, at: at)
    }

    /// The generic waiting line for a prompt of `kind`, the one the laptop
    /// shows when the agent reported no text of its own.
    private static func promptReason(_ kind: PendingPromptKind) -> String {
        let block: ProgramStatusBlockKind
        switch kind {
        case .permission:
            block = .permission
        case .question:
            block = .question
        }
        return AwaitingInputReason(message: "", programStatusBlock: ProgramStatusBlock(kind: block, taskID: nil))
            .displayMessage
    }

    private static func status(_ chip: PhoneStatusChip, at date: Date, reason: String? = nil) -> PhoneStatus {
        PhoneStatus(chip: chip, changedAt: PhoneTime.ms(date), reason: reason.map { PhoneText.capped($0) }, untilAt: nil)
    }

    // MARK: - Capabilities

    static let codexTranscriptReason = "Codex transcripts arrive in a later TBD release"
    static let codexStatusOnlyReason = "Codex sessions show status only."
    static let remoteLaneTabReason = "This tab belongs to a remote lane. Use its remote session."
    static let remoteOnlyReason = "Not available for remote sessions."
    static let cannotTakeMessagesReason = "This session cannot take messages."
    static let parkedForkReason = "This session is parked. Send it a message to wake it, then fork it."
    static let answerTurnedOffReason = "Answering prompts is turned off in TBD's settings on the laptop."
    static let answerSettingUnreadReason = "TBD could not read its setting for answering prompts."

    /// A local session's capabilities. A Claude session has all six; a Codex
    /// session shows its status only. A tab in a remote lane's row has none,
    /// since the lane's remote session stands for it.
    ///
    /// `send` and `model` follow the laptop's composer, because both go
    /// through the send path, which asks `ComposerState.resolve` with the
    /// same two inputs: where the composer is hidden (a row saved before
    /// terminals recorded their kind, say), both are unavailable, so the list
    /// never offers what every send would refuse.
    ///
    /// `fork` is unavailable on a parked session, with `parkedForkReason`:
    /// the profile swap moves a parked row in place whatever its mode, so
    /// `session.fork` refuses one. Parking is the only reason `fork` and
    /// `switchProfile` differ.
    ///
    /// `answer` also follows the laptop's setting for answering prompts,
    /// `promptAnswerEnabled`, nil when it could not be read
    /// (`answerCapability(_:promptAnswerEnabled:)`).
    ///
    /// Every terminal that is neither Codex nor in a remote lane reads as
    /// Claude here, a shell included. The sessions list builds sessions only
    /// for agent tabs (`PhoneSnapshotBuilder.agent(of:)`), so it never shows
    /// a shell, and an action refuses a shell as not Claude before it looks
    /// at the setting (`PhoneAppService.phoneCapableClaudeTerminal`).
    static func localCapabilities(
        terminal: TBDShared.Terminal, isRemoteWorktree: Bool, promptAnswerEnabled: Bool?
    ) -> PhoneCapabilities {
        if isRemoteWorktree {
            let none = unavailable(remoteLaneTabReason)
            return PhoneCapabilities(
                transcript: none, send: none, answer: answerCapability(none, promptAnswerEnabled: promptAnswerEnabled),
                switchProfile: none, fork: none, model: none)
        }
        if terminal.isCodexTerminal {
            let statusOnly = unavailable(codexStatusOnlyReason)
            return PhoneCapabilities(
                transcript: unavailable(codexTranscriptReason), send: statusOnly,
                answer: answerCapability(statusOnly, promptAnswerEnabled: promptAnswerEnabled),
                switchProfile: statusOnly, fork: statusOnly, model: statusOnly)
        }
        let messages: PhoneCapability
        switch ComposerState.resolve(terminal: terminal, isRemoteWorktree: isRemoteWorktree) {
        case .hidden, .unavailable:
            messages = unavailable(cannotTakeMessagesReason)
        case .running, .notRunning, .blocked:
            messages = available
        }
        return PhoneCapabilities(
            transcript: available, send: messages,
            answer: answerCapability(available, promptAnswerEnabled: promptAnswerEnabled),
            switchProfile: available, fork: terminal.isParked ? unavailable(parkedForkReason) : available,
            model: messages)
    }

    /// A session's `answer` under the laptop's setting for answering prompts
    /// (`config.transcriptPromptAnswerEnabled`, which the laptop's prompt
    /// card and the core of `prompt.answer` and `remote.answer` obey):
    /// `session`, what the session itself allows, while the setting is on;
    /// while it is off, unavailable with `answerTurnedOffReason` in place of
    /// an available one; and while it could not be read (nil), unavailable
    /// with `answerSettingUnreadReason`, since `prompt.answer` reads the
    /// setting again before it answers and would fail the same way.
    ///
    /// **A session that cannot answer anyway keeps its own reason** while the
    /// setting is off or unread: a tab in a remote lane, a Codex session, a
    /// provider that does not declare `answer`. That reason stays true when
    /// the setting is turned on again, so it is the one that tells the phone
    /// what would have to change; the setting's reason shows only where the
    /// setting is all that stands in the way.
    ///
    /// Only `answer` follows the setting. It gates answering prompts and
    /// nothing else the phone does, so `send`, `model`, `fork`,
    /// `switchProfile` and `transcript` ignore it.
    private static func answerCapability(_ session: PhoneCapability, promptAnswerEnabled: Bool?) -> PhoneCapability {
        guard session.available else { return session }
        switch promptAnswerEnabled {
        case .some(true):
            return session
        case .some(false):
            return unavailable(answerTurnedOffReason)
        case .none:
            return unavailable(answerSettingUnreadReason)
        }
    }

    /// Each provider's declared capabilities, by provider name, from its
    /// `describe`; none for a provider that has not described itself. A name
    /// listed twice keeps its first entry. The sessions list and the send
    /// path both read capabilities through this, so they cannot disagree.
    static func declaredCapabilities(_ providers: [RemoteProviderStatus]) -> [String: Set<String>] {
        var declared: [String: Set<String>] = [:]
        for provider in providers where declared[provider.config.name] == nil {
            declared[provider.config.name] = Set(provider.describe?.capabilities ?? [])
        }
        return declared
    }

    /// A remote session's capabilities, from the capabilities its provider
    /// declares in `describe`: `transcript` needs `transcript.read`, `send`
    /// and `model` need `send-submit`, `answer` needs `answer` and the
    /// laptop's setting for answering prompts, `promptAnswerEnabled`, on
    /// (`answerCapability(_:promptAnswerEnabled:)`, where nil is a setting
    /// that could not be read), as a local session's does. A remote session
    /// never switches profiles or forks.
    static func remoteCapabilities(declared: Set<String>, promptAnswerEnabled: Bool?) -> PhoneCapabilities {
        func needs(_ capability: String, _ action: String) -> PhoneCapability {
            declared.contains(capability)
                ? PhoneSessionStatus.available
                : PhoneSessionStatus.unavailable("This provider does not support \(action).")
        }
        let remoteOnly = unavailable(remoteOnlyReason)
        return PhoneCapabilities(
            transcript: needs(RemoteCapability.transcriptRead, "reading transcripts"),
            send: needs(RemoteCapability.sendSubmit, "sending messages"),
            answer: answerCapability(
                needs(RemoteCapability.answer, "answering prompts"), promptAnswerEnabled: promptAnswerEnabled),
            switchProfile: remoteOnly,
            fork: remoteOnly,
            model: needs(RemoteCapability.sendSubmit, "changing the model"))
    }

    private static let available = PhoneCapability(available: true, reason: nil)

    private static func unavailable(_ reason: String) -> PhoneCapability {
        PhoneCapability(available: false, reason: reason)
    }
}
