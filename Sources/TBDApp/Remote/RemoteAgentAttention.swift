import Foundation
import TBDShared

/// One mirror row, read for the question "does a human need to do something,
/// and what?" — the attention axis, stated in words.
///
/// Pure policy with no SwiftUI or `AppState` dependency, like
/// `RemoteAttachExitClass` and `RemoteSessionDetailGates` beside it.
///
/// Two rules it never breaks, both from the provider contract:
///
/// - **Blockage is read off `agent_state`, never off `pending_question`.**
///   The contract says so normatively, so every path here checks
///   `waitingInput` first and reaches for the question block second, as
///   detail. A provider that leaves a stale question block behind can make
///   TBD's explanation wrong; it can never make TBD claim a session is
///   blocked that the agent axis says is working.
/// - **`state: running` with `agent_state: unknown` is not progress.** It
///   means the terminal exists and nothing machine-readable reported what the
///   agent is doing. It is a distinct, named reading here for exactly that
///   reason: it used to render as the same green as real work.
enum RemoteAgentAttention {
    /// Why a human is being asked to look, in one sentence, or nil when
    /// nothing about this row asks for a human.
    ///
    /// Ordered most specific source first: the structured question block, the
    /// provider's own reason string, then the bare state.
    static func explanation(for session: RemoteSessionInfo) -> String? {
        guard !session.gone else { return nil }
        switch session.payload.agentState {
        case .waitingInput:
            if let permission = permissionSummary(session.payload.effectivePendingPrompt) {
                return permission
            }
            if let question = promptQuestionSummary(session.payload.effectivePendingPrompt) { return question }
            if let question = questionSummary(session.payload.pendingQuestion) { return question }
            if let reason = humanizedReason(session.payload.agentStateReason) { return reason }
            return "Waiting for input."
        case .unknown where session.payload.state == .running:
            return unattributedRunningExplanation
        case .idle where session.payload.state == .running:
            return "Agent is idle — it reported no work in progress."
        case .working, .idle, .exited, .unknown:
            return nil
        }
    }

    /// The sentence for a live terminal whose agent says nothing. Named
    /// rather than inlined because the desk states it both per row and once
    /// in aggregate, and the two must not drift into saying different things.
    static let unattributedRunningExplanation =
        "Terminal is running and no agent state was reported — terminal liveness is not agent progress."

    /// Rows a human has to act on. The agent axis alone decides this; a
    /// terminal that happens to be running or exited underneath does not
    /// change whether the agent is blocked.
    static func needsAttention(_ session: RemoteSessionInfo) -> Bool {
        !session.gone && session.payload.agentState == .waitingInput
    }

    /// Rows with a live terminal and no reported agent state — counted
    /// separately from both "working" and "waiting" because it is neither.
    static func isUnattributedRunning(_ session: RemoteSessionInfo) -> Bool {
        !session.gone && session.payload.state == .running && session.payload.agentState == .unknown
    }

    /// The provider's free-form `agent_state_reason`, made readable.
    ///
    /// Exactly one value is translated: `permission_prompt`, the contract's
    /// own worked example. Everything else is passed through verbatim rather
    /// than pattern-matched — the field is provider-defined, and a caller
    /// that invents meanings for strings it was never promised will
    /// eventually put a confident sentence over a value that meant something
    /// else.
    static func humanizedReason(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if trimmed == "permission_prompt" { return "Blocked on a permission prompt." }
        return trimmed
    }

    /// A pending permission prompt as one line: "Blocked on permission: <tool>
    /// <short input>". The short input is a Bash command's first line or a
    /// file tool's path; any other tool shows its name only. Nil for anything
    /// but a permission prompt. Capped at 80 characters of input.
    static func permissionSummary(_ prompt: RemotePendingPrompt?) -> String? {
        guard let prompt, prompt.kind == .permission else { return nil }
        let tool = prompt.toolName.flatMap { $0.isEmpty ? nil : $0 } ?? "tool"
        var line = "Blocked on permission: \(tool)"
        if let input = shortToolInput(toolName: tool, json: prompt.toolInputJSON) {
            line += " \(input)"
        }
        return line
    }

    private static let maxInputCharacters = 80

    private static func shortToolInput(toolName: String, json: String?) -> String? {
        guard let json, let data = json.data(using: .utf8),
              let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        else { return nil }
        let raw: String?
        switch toolName {
        case "Bash":
            raw = (object["command"] as? String)?
                .split(separator: "\n", omittingEmptySubsequences: true).first.map(String.init)
        case "Write", "Edit", "MultiEdit", "NotebookEdit":
            raw = object["file_path"] as? String
        default:
            raw = nil
        }
        guard let text = raw?.trimmingCharacters(in: .whitespaces), !text.isEmpty else { return nil }
        guard text.count > maxInputCharacters else { return text }
        return String(text.prefix(maxInputCharacters)) + "…"
    }

    /// The structured question block as one line: the first question's
    /// prompt, plus its option labels when it has any, plus a count when more
    /// than one question is pending.
    static func questionSummary(_ question: RemotePendingQuestion?) -> String? {
        guard let question, let first = question.questions.first else { return nil }
        return questionLine(
            text: first.prompt, optionLabels: first.options.map(\.label), count: question.questions.count)
    }

    /// The same line for a question-kind pending prompt, read from the
    /// questions its card draws (`effectiveQuestions`), so a provider that
    /// sends `pending_prompt` without the legacy `pending_question` still gets
    /// its question quoted. Nil for a permission prompt or one with no usable
    /// question.
    static func promptQuestionSummary(_ prompt: RemotePendingPrompt?) -> String? {
        guard let prompt, prompt.kind == .question else { return nil }
        let questions = prompt.effectiveQuestions
        guard let first = questions.first else { return nil }
        return questionLine(
            text: first.text, optionLabels: first.options.map(\.label), count: questions.count)
    }

    private static func questionLine(text: String, optionLabels: [String], count: Int) -> String {
        var line = "Blocked on a question: \(text)"
        let options = optionLabels.filter { !$0.isEmpty }
        if !options.isEmpty {
            line += " (\(options.joined(separator: " / ")))"
        }
        if count > 1 {
            line += " — and \(count - 1) more."
        }
        return line
    }
}
