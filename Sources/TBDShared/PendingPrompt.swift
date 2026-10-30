import Foundation

// A "pending prompt" here is a Claude Code dialog — an `AskUserQuestion`
// picker or a tool permission prompt — that is open and waiting for an
// answer. It is unrelated to `worktree.pending_prompt` and
// `PendingPromptCoordinator`, which park a new worktree's queued first
// message. Design: `docs/specs/2026-10-09-transcript-prompt-answer-design.md`;
// the session mod that feeds it:
// `docs/specs/2026-10-20-mod-channel-prompt-answer-design.md`.

/// Which kind of dialog a pending prompt is.
public enum PendingPromptKind: String, Codable, Sendable, Hashable {
    /// An `AskUserQuestion` picker.
    case question
    /// A tool permission dialog.
    case permission
}

/// One option of a `PromptQuestion`.
public struct PromptQuestionOption: Codable, Sendable, Hashable {
    public let label: String
    public let description: String?

    public init(label: String, description: String? = nil) {
        self.label = label
        self.description = description
    }
}

/// One question of a question prompt, in the shape both delivery paths share.
public struct PromptQuestion: Codable, Sendable, Hashable {
    /// The text Claude Code keys `answers` on. Never truncated.
    public let text: String
    public let header: String?
    public let multiSelect: Bool
    public let options: [PromptQuestionOption]

    public init(text: String, header: String? = nil, multiSelect: Bool = false,
                options: [PromptQuestionOption] = []) {
        self.text = text
        self.header = header
        self.multiSelect = multiSelect
        self.options = options
    }
}

/// Reads questions out of the two shapes they arrive in.
public enum PromptQuestionParser {
    /// Parses an `AskUserQuestion` `tool_input`:
    /// `{"questions":[{"question","header","multiSelect","options":[{"label","description"}]}]}`.
    ///
    /// A question without text is skipped, since `answers` is keyed on that
    /// text. Returns nil when the JSON is not that shape or holds no usable
    /// question.
    public static func questions(fromAskUserQuestionInput json: String) -> [PromptQuestion]? {
        guard let object = try? JSONSerialization.jsonObject(with: Data(json.utf8)),
              let root = object as? [String: Any],
              let rawQuestions = root["questions"] as? [Any] else {
            return nil
        }
        let questions: [PromptQuestion] = rawQuestions.compactMap { raw in
            guard let q = raw as? [String: Any],
                  let text = q["question"] as? String, !text.isEmpty else {
                return nil
            }
            let options: [PromptQuestionOption] = ((q["options"] as? [Any]) ?? []).compactMap { rawOption in
                guard let o = rawOption as? [String: Any],
                      let label = o["label"] as? String else {
                    return nil
                }
                return PromptQuestionOption(label: label, description: o["description"] as? String)
            }
            return PromptQuestion(
                text: text,
                header: q["header"] as? String,
                multiSelect: (q["multiSelect"] as? Bool) ?? false,
                options: options)
        }
        return questions.isEmpty ? nil : questions
    }

    /// Maps the provider contract's `pending_question` items
    /// (`prompt`, `label`, `multi`, `options`) to the shared shape.
    public static func questions(fromRemote items: [RemotePendingQuestionItem]) -> [PromptQuestion] {
        items.map { item in
            PromptQuestion(
                text: item.prompt,
                header: item.label,
                multiSelect: item.multi,
                options: item.options.map {
                    PromptQuestionOption(label: $0.label, description: $0.description)
                })
        }
    }
}

/// One pending prompt as the daemon publishes it to the app.
///
/// Not to be confused with `PendingPromptCoordinator`, which parks a
/// worktree's queued first message.
public struct PendingPromptPayload: Codable, Sendable, Equatable, Hashable {
    /// The dialog's tool call id, so stable for the prompt's life, including
    /// across a daemon restart the session mod re-posts it through.
    public let id: String
    public let kind: PendingPromptKind
    /// The tool call this dialog belongs to; the same value as `id`. Optional
    /// only so payloads from an older daemon still decode.
    public let toolUseID: String?
    public let toolName: String
    /// Verbatim `tool_input`, re-serialized with sorted keys.
    public let toolInputJSON: String
    /// Claude Code's `permission_suggestions`, a verbatim JSON array; nil when
    /// absent.
    public let suggestionsJSON: String?
    public let createdAt: Date

    public init(id: String, kind: PendingPromptKind, toolUseID: String?, toolName: String,
                toolInputJSON: String, suggestionsJSON: String?, createdAt: Date) {
        self.id = id
        self.kind = kind
        self.toolUseID = toolUseID
        self.toolName = toolName
        self.toolInputJSON = toolInputJSON
        self.suggestionsJSON = suggestionsJSON
        self.createdAt = createdAt
    }
}
