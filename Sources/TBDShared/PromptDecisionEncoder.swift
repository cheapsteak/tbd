import Foundation

/// Turns an answer into what a `PermissionRequest` hook prints so Claude Code
/// applies it to the open dialog.
///
/// The shapes were measured against the real TUI (design
/// `docs/specs/2026-10-09-transcript-prompt-answer-design.md`, "Facts this
/// design rests on"):
/// - question: `{"behavior":"allow","updatedInput":{…original input…,"answers":{…}}}`.
///   `allow` without `updatedInput` is ignored and the dialog stays.
/// - allow: `{"behavior":"allow"}`.
/// - allow_always: `{"behavior":"allow","updatedPermissions":[…suggestions, destination "session"…]}`.
/// - deny: `{"behavior":"deny","message":"…"}`. Never `interrupt`, which
///   throws the message away and stops the turn.
public enum PromptDecisionEncoder {
    /// The message a deny carries when the person gave no reason.
    public static let defaultDenyMessage = "The user declined this from TBD."

    /// The complete one-line stdout a `PermissionRequest` hook prints:
    /// `{"hookSpecificOutput":{"hookEventName":"PermissionRequest","decision":{…}}}`.
    ///
    /// Throws `PromptAnswerValidation` when the answer does not fit the prompt.
    public static func hookOutput(
        answer: PromptAnswer, kind: PendingPromptKind, toolInputJSON: String, suggestionsJSON: String?
    ) throws -> String {
        let decision = try decisionObject(
            answer: answer, kind: kind, toolInputJSON: toolInputJSON, suggestionsJSON: suggestionsJSON)
        let root: [String: Any] = [
            "hookSpecificOutput": [
                "hookEventName": "PermissionRequest",
                "decision": decision,
            ] as [String: Any],
        ]
        guard JSONSerialization.isValidJSONObject(root) else {
            throw EncodingError.invalidValue(root, .init(
                codingPath: [], debugDescription: "decision is not serializable"))
        }
        let data = try JSONSerialization.data(withJSONObject: root, options: [.sortedKeys, .withoutEscapingSlashes])
        guard let line = String(bytes: data, encoding: .utf8) else {
            throw EncodingError.invalidValue(root, .init(
                codingPath: [], debugDescription: "decision is not UTF-8"))
        }
        return line
    }

    /// The inner `decision` object alone.
    static func decisionObject(
        answer: PromptAnswer, kind: PendingPromptKind, toolInputJSON: String, suggestionsJSON: String?
    ) throws -> [String: Any] {
        let scoped = PermissionSuggestionSummary.sessionScoped(fromJSON: suggestionsJSON)
        let questions = kind == .question
            ? (PromptQuestionParser.questions(fromAskUserQuestionInput: toolInputJSON) ?? [])
            : []
        try answer.validate(kind: kind, questions: questions, hasSuggestions: scoped != nil)

        switch answer {
        case .question(let answers):
            // Validation guarantees the input parsed to an object with
            // questions; the whole original input is carried through, with
            // `answers` added.
            var updated = (try? JSONSerialization.jsonObject(with: Data(toolInputJSON.utf8))) as? [String: Any] ?? [:]
            updated["answers"] = answers
            return ["behavior": "allow", "updatedInput": updated]
        case .permission(let decision, let message):
            switch decision {
            case .allow:
                return ["behavior": "allow"]
            case .allowAlways:
                return ["behavior": "allow", "updatedPermissions": scoped ?? []]
            case .deny:
                let trimmed = message?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                return ["behavior": "deny", "message": trimmed.isEmpty ? defaultDenyMessage : trimmed]
            }
        }
    }
}
