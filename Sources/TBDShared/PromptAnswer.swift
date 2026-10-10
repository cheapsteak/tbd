import Foundation

/// The decision a permission prompt can take.
public enum PermissionDecision: String, Codable, Sendable {
    case allow
    /// Allow, and apply every "don't ask again" suggestion Claude Code offered,
    /// scoped to this session only. Valid only when suggestions exist.
    case allowAlways = "allow_always"
    case deny
}

/// The one answer payload for both delivery paths: the local `prompt.answer`
/// RPC and the remote provider's `answer` verb (stdin).
///
/// Wire shapes:
/// - `{"kind":"question","answers":{"<question text>":"<value>"}}`
/// - `{"kind":"permission","decision":"allow"|"allow_always"|"deny","message":"…"}`,
///   `message` omitted when nil.
///
/// A question value is an option label, several labels joined with `", "`, or
/// free text typed into "Other".
public enum PromptAnswer: Codable, Sendable, Equatable {
    case question(answers: [String: String])
    case permission(decision: PermissionDecision, message: String?)

    enum CodingKeys: String, CodingKey {
        case kind, answers, decision, message
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let kind = try c.decode(PendingPromptKind.self, forKey: .kind)
        switch kind {
        case .question:
            self = .question(answers: try c.decode([String: String].self, forKey: .answers))
        case .permission:
            self = .permission(
                decision: try c.decode(PermissionDecision.self, forKey: .decision),
                message: try c.decodeIfPresent(String.self, forKey: .message))
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .question(let answers):
            try c.encode(PendingPromptKind.question, forKey: .kind)
            try c.encode(answers, forKey: .answers)
        case .permission(let decision, let message):
            try c.encode(PendingPromptKind.permission, forKey: .kind)
            try c.encode(decision, forKey: .decision)
            try c.encodeIfPresent(message, forKey: .message)
        }
    }

    /// The kind of prompt this answer is shaped for.
    public var kind: PendingPromptKind {
        switch self {
        case .question: .question
        case .permission: .permission
        }
    }
}

/// Why an answer does not fit its prompt. Every case maps to the contract's
/// `invalid_params` error.
public enum PromptAnswerValidation: LocalizedError, Equatable, Sendable {
    /// A question answer for a permission prompt, or the reverse.
    case kindMismatch
    /// A question has no answer, or an empty one.
    case missingAnswer(question: String)
    /// An answer is keyed on a question text the prompt does not have.
    case unknownQuestion(String)
    /// `allow_always` on a prompt that offered no suggestions.
    case allowAlwaysWithoutSuggestions

    /// Human text, prefixed with the contract's error code.
    public var message: String {
        switch self {
        case .kindMismatch:
            return "invalid_params: the answer's kind does not match the prompt"
        case .missingAnswer(let question):
            return "invalid_params: no answer for the question \"\(question)\""
        case .unknownQuestion(let question):
            return "invalid_params: the prompt has no question \"\(question)\""
        case .allowAlwaysWithoutSuggestions:
            return "invalid_params: allow_always needs suggestions, and this prompt offered none"
        }
    }

    public var errorDescription: String? { message }
}

extension PromptAnswer {
    /// Checks that this answer fits a prompt of `kind`.
    ///
    /// - A question answer needs one non-empty value per question in
    ///   `questions`, and no value for a question the prompt does not have.
    ///   Claude Code silently drops an unanswered question, so a missing one
    ///   is refused here rather than delivered short.
    /// - `allow_always` needs `hasSuggestions`.
    public func validate(kind: PendingPromptKind, questions: [PromptQuestion],
                         hasSuggestions: Bool) throws(PromptAnswerValidation) {
        guard self.kind == kind else { throw PromptAnswerValidation.kindMismatch }
        switch self {
        case .question(let answers):
            for question in questions {
                let value = answers[question.text]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                if value.isEmpty { throw PromptAnswerValidation.missingAnswer(question: question.text) }
            }
            let known = Set(questions.map(\.text))
            if let stray = answers.keys.sorted().first(where: { !known.contains($0) }) {
                throw PromptAnswerValidation.unknownQuestion(stray)
            }
            if answers.isEmpty { throw PromptAnswerValidation.missingAnswer(question: "") }
        case .permission(let decision, _):
            if decision == .allowAlways && !hasSuggestions {
                throw PromptAnswerValidation.allowAlwaysWithoutSuggestions
            }
        }
    }
}

/// How an answer ended.
/// - `delivered` – the decision reached the waiting hook (local) or the
///   agent's dialog (remote).
/// - `already_resolved` – the prompt was no longer pending: answered in the
///   terminal, answered from another card, or moved past.
/// - `unknown` – the call ended without a verdict (a remote timeout or
///   signal, or a local hook that never acknowledged delivery). Never retried
///   automatically.
///
/// Decoding is forward-compatible: a raw value this build does not know reads
/// as `unknown`, the only reading that never invites a duplicate answer.
public enum PromptAnswerOutcome: String, Codable, Sendable, Equatable {
    case delivered
    case alreadyResolved = "already_resolved"
    case unknown

    public init(from decoder: any Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = PromptAnswerOutcome(rawValue: raw) ?? .unknown
    }
}

/// Result of `prompt.answer` and `remote.answer`. Errors that the caller can
/// act on — invalid params, the hook reconnecting — are RPC errors instead.
public struct PromptAnswerResult: Codable, Sendable, Equatable {
    public let outcome: PromptAnswerOutcome
    public init(outcome: PromptAnswerOutcome) { self.outcome = outcome }
}
