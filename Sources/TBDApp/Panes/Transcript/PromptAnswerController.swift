import Foundation
import Observation
import TBDShared

/// Sends a prompt card's answer and owns what happens while it travels.
///
/// The interactive cards (`AskUserQuestionCard` in pending mode and
/// `PermissionPromptCard`) keep nothing in view `@State`: the table recycles
/// and rebuilds its cells, so the draft a user is composing and the delivery
/// progress live here, keyed by prompt id. Design:
/// `docs/specs/2026-10-09-transcript-prompt-answer-design.md`, "The cards" and
/// "States".
///
/// Holding an answered card on screen until its tool result lands is
/// `PromptCardRetention`'s job; a delivery reports there through `onDelivered`.
@MainActor
@Observable
final class PromptAnswerController {
    /// Delivery progress for one card. `waiting` is the absence of any other.
    enum CardState: Equatable {
        case waiting
        case sending
        case answered(summary: String)
        /// The daemon or provider answered `already_resolved`.
        case answeredElsewhere
        /// The call threw. `retryable` is false for refusals a retry cannot
        /// change: the flag being off, or an answer that does not fit.
        case failed(message: String, retryable: Bool)
        /// A remote call ended without a verdict; the answer may have arrived.
        case unknownOutcome
    }

    /// What a user has chosen on a card so far. Keyed by question text, which
    /// is what `PromptAnswer.question(answers:)` is keyed on.
    struct Draft: Equatable {
        /// Question text → chosen option labels.
        var selections: [String: Set<String>] = [:]
        /// Question text → text typed into "Other".
        var otherText: [String: String] = [:]
        /// Questions whose "Other" row is chosen.
        var otherChosen: Set<String> = []
        /// Whether the permission card's "Deny…" field is showing.
        var denyReasonOpen = false
        var denyReason = ""
    }

    /// The permission card's three decisions.
    enum PermissionChoice: Equatable {
        case allow
        case allowForSession
        case deny
    }

    typealias LocalSender = @MainActor (UUID, String, PromptAnswer) async throws -> PromptAnswerResult
    typealias RemoteSender = @MainActor (String, String, String, PromptAnswer) async throws -> PromptAnswerResult

    private var states: [String: CardState] = [:]
    private var drafts: [String: Draft] = [:]
    /// The last answer sent per prompt, for `retry`.
    @ObservationIgnored private var lastAnswers: [String: PromptAnswer] = [:]

    @ObservationIgnored private let local: LocalSender
    @ObservationIgnored private let remote: RemoteSender
    @ObservationIgnored private let onDelivered: @MainActor (PendingPromptPresentation, String) -> Void
    @ObservationIgnored private let onRemoteDelivered: @MainActor (RemoteSessionSelection) -> Void

    /// - Parameters:
    ///   - onDelivered: called with the prompt and its summary once a delivery
    ///     succeeds; production marks the card answered in `PromptCardRetention`.
    ///   - onRemoteDelivered: called after a remote delivery; production asks
    ///     the session's pane to sync its transcript now, as the composer does
    ///     after a send.
    ///
    /// The two callbacks default to `nil` rather than to an empty closure
    /// literal: a `@MainActor` closure as a default argument is itself
    /// main-actor isolated, and Swift 6.3 refuses such a default at a call
    /// site whose own isolation differs (`AppState`'s lazy initializer).
    init(local: @escaping LocalSender,
         remote: @escaping RemoteSender,
         onDelivered: (@MainActor (PendingPromptPresentation, String) -> Void)? = nil,
         onRemoteDelivered: (@MainActor (RemoteSessionSelection) -> Void)? = nil) {
        self.local = local
        self.remote = remote
        self.onDelivered = onDelivered ?? { _, _ in }
        self.onRemoteDelivered = onRemoteDelivered ?? { _ in }
    }

    // MARK: - Reads

    func state(for promptID: String) -> CardState {
        states[promptID] ?? .waiting
    }

    func draft(for promptID: String) -> Draft {
        drafts[promptID] ?? Draft()
    }

    func updateDraft(for promptID: String, _ mutate: (inout Draft) -> Void) {
        var draft = drafts[promptID] ?? Draft()
        mutate(&draft)
        drafts[promptID] = draft
    }

    /// Drops everything kept for prompts whose tool result reached the
    /// transcript. The panes call it with the merge's `settled` set, from
    /// `.onChange`, never during a body evaluation.
    func forget(_ promptIDs: Set<String>) {
        for promptID in promptIDs {
            if states[promptID] != nil { states.removeValue(forKey: promptID) }
            if drafts[promptID] != nil { drafts.removeValue(forKey: promptID) }
            lastAnswers.removeValue(forKey: promptID)
        }
    }

    /// Sets a card's state directly. For tests that render a card in a given
    /// state; production moves states only through `submit` and `retry`.
    func setStateForTesting(_ state: CardState, for promptID: String) {
        states[promptID] = state
    }

    // MARK: - Sending

    /// Sends `answer` to wherever `prompt` lives. A card already sending
    /// ignores a second submit.
    func submit(_ prompt: PendingPromptPresentation, answer: PromptAnswer) async {
        let promptID = prompt.promptID
        guard states[promptID] != .sending else { return }
        lastAnswers[promptID] = answer
        states[promptID] = .sending
        do {
            let result: PromptAnswerResult
            switch prompt.target {
            case .local(let terminalID):
                result = try await local(terminalID, promptID, answer)
            case .remote(let provider, let sessionID):
                result = try await remote(provider, sessionID, promptID, answer)
            }
            apply(result.outcome, prompt: prompt, answer: answer)
        } catch {
            let message = Self.message(for: error)
            states[promptID] = .failed(message: message, retryable: Self.isRetryable(message))
        }
    }

    /// Resends the last answer sent for `prompt`. A retry of an answer that
    /// did arrive the first time comes back `already_resolved`, which reads
    /// "Answered elsewhere".
    func retry(_ prompt: PendingPromptPresentation) async {
        guard let answer = lastAnswers[prompt.promptID] else { return }
        await submit(prompt, answer: answer)
    }

    private func apply(_ outcome: PromptAnswerOutcome, prompt: PendingPromptPresentation,
                       answer: PromptAnswer) {
        switch outcome {
        case .delivered:
            let summary = Self.summary(for: answer, questions: prompt.questions)
            states[prompt.promptID] = .answered(summary: summary)
            onDelivered(prompt, summary)
            if case .remote(let provider, let sessionID) = prompt.target {
                onRemoteDelivered(RemoteSessionSelection(provider: provider, sessionID: sessionID))
            }
        case .alreadyResolved:
            states[prompt.promptID] = .answeredElsewhere
        case .unknown:
            states[prompt.promptID] = .unknownOutcome
        }
    }

    // MARK: - Answer assembly (pure)

    /// The answer a question card's draft makes, or nil until every question
    /// has a value.
    ///
    /// - Single-select: the chosen label, or the "Other" text when "Other" is
    ///   chosen — "Other" wins for its question.
    /// - Multi-select: the chosen labels in option order, then the "Other"
    ///   text when chosen, joined with ", ".
    static func questionAnswer(questions: [PromptQuestion], draft: Draft) -> PromptAnswer? {
        guard !questions.isEmpty else { return nil }
        var answers: [String: String] = [:]
        for question in questions {
            guard let value = value(for: question, draft: draft) else { return nil }
            answers[question.text] = value
        }
        return .question(answers: answers)
    }

    static func value(for question: PromptQuestion, draft: Draft) -> String? {
        let chosen = draft.selections[question.text] ?? []
        let other = (draft.otherText[question.text] ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let otherCounts = draft.otherChosen.contains(question.text) && !other.isEmpty
        if question.multiSelect {
            var parts = question.options.map(\.label).filter { chosen.contains($0) }
            if otherCounts { parts.append(other) }
            return parts.isEmpty ? nil : parts.joined(separator: ", ")
        }
        if otherCounts { return other }
        return question.options.map(\.label).first { chosen.contains($0) }
    }

    /// The answer a permission card's button makes. A deny reason that is
    /// blank after trimming is sent as no message.
    static func permissionAnswer(_ choice: PermissionChoice, denyReason: String = "") -> PromptAnswer {
        switch choice {
        case .allow:
            return .permission(decision: .allow, message: nil)
        case .allowForSession:
            return .permission(decision: .allowAlways, message: nil)
        case .deny:
            let trimmed = denyReason.trimmingCharacters(in: .whitespacesAndNewlines)
            return .permission(decision: .deny, message: trimmed.isEmpty ? nil : trimmed)
        }
    }

    /// What an answered card shows: question values in question order joined
    /// with "; ", or the permission decision.
    static func summary(for answer: PromptAnswer, questions: [PromptQuestion]) -> String {
        switch answer {
        case .question(let answers):
            let ordered = questions.compactMap { answers[$0.text] }
            let values = ordered.isEmpty ? answers.keys.sorted().compactMap { answers[$0] } : ordered
            return values.joined(separator: "; ")
        case .permission(let decision, _):
            switch decision {
            case .allow: return "Allowed"
            case .allowAlways: return "Allowed for this session"
            case .deny: return "Denied"
            }
        }
    }

    // MARK: - Errors

    static func message(for error: any Error) -> String {
        if let clientError = error as? DaemonClientError,
           case .rpcError(let message, _) = clientError {
            return message
        }
        return error.localizedDescription
    }

    /// False for refusals a retry cannot change: the flag being off and an
    /// answer that does not fit the prompt. Everything else — the hook
    /// reconnecting, a dropped connection, a provider failure — may succeed
    /// on a second try.
    static func isRetryable(_ message: String) -> Bool {
        if message.hasPrefix("invalid_params") { return false }
        if message.contains("transcript_prompt_answer_enabled") { return false }
        return true
    }
}

extension PromptAnswerController.Draft {
    /// A tap on an option row. Single-select: that option alone, and "Other"
    /// unchosen. Multi-select: toggles it.
    mutating func choose(_ label: String, in question: PromptQuestion) {
        if question.multiSelect {
            var chosen = selections[question.text] ?? []
            if chosen.contains(label) { chosen.remove(label) } else { chosen.insert(label) }
            selections[question.text] = chosen
        } else {
            selections[question.text] = [label]
            otherChosen.remove(question.text)
        }
    }

    /// A tap on the "Other" row's marker. Single-select: chooses "Other" and
    /// clears the options. Multi-select: toggles it.
    mutating func chooseOther(in question: PromptQuestion) {
        if question.multiSelect {
            if otherChosen.contains(question.text) {
                otherChosen.remove(question.text)
            } else {
                otherChosen.insert(question.text)
            }
        } else {
            otherChosen.insert(question.text)
            selections[question.text] = []
        }
    }

    /// Typing into "Other" chooses it (single-select: instead of any option).
    mutating func setOtherText(_ text: String, in question: PromptQuestion) {
        otherText[question.text] = text
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        otherChosen.insert(question.text)
        if !question.multiSelect { selections[question.text] = [] }
    }

    func isChosen(_ label: String, in question: PromptQuestion) -> Bool {
        selections[question.text]?.contains(label) ?? false
    }

    func isOtherChosen(in question: PromptQuestion) -> Bool {
        otherChosen.contains(question.text)
    }
}

/// What a card's reserved footer row shows, from its presentation and the
/// controller's state. Pure, so the precedence is testable without a view.
enum PromptCardFooter: Equatable {
    /// Live controls: Submit, or the permission buttons.
    case controls
    case sending
    case answered(summary: String)
    case answeredElsewhere
    case failed(message: String, retryable: Bool)
    case unknownOutcome
    /// No controls. `note` is "Attach to answer" for a remote provider without
    /// `answer`; nil when the flag is off.
    case readOnly(note: String?)

    static let answeredElsewhereText = "Answered elsewhere"
    static let unknownOutcomeText = "May not have arrived"

    static func resolve(_ presentation: PendingPromptPresentation,
                        state: PromptAnswerController.CardState) -> PromptCardFooter {
        if case .answered(let summary) = state { return .answered(summary: summary) }
        if case .readOnly(let note) = presentation.answerability { return .readOnly(note: note) }
        switch presentation.phase {
        case .answered(let summary): return .answered(summary: summary)
        case .closed: return .answeredElsewhere
        case .open: break
        }
        switch state {
        case .waiting: return .controls
        case .sending: return .sending
        case .answered(let summary): return .answered(summary: summary)
        case .answeredElsewhere: return .answeredElsewhere
        case .failed(let message, let retryable): return .failed(message: message, retryable: retryable)
        case .unknownOutcome: return .unknownOutcome
        }
    }
}
