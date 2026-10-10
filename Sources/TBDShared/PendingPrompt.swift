import CryptoKit
import Foundation

// A "pending prompt" here is a Claude Code dialog — an `AskUserQuestion`
// picker or a tool permission prompt — that is open and waiting for an
// answer. It is unrelated to `worktree.pending_prompt` and
// `PendingPromptCoordinator`, which park a new worktree's queued first
// message. Design: `docs/specs/2026-10-09-transcript-prompt-answer-design.md`.

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
    /// Stable for the prompt's life, including across a daemon restart that
    /// the waiting hook re-registers through.
    public let id: String
    public let kind: PendingPromptKind
    /// The tool call this dialog belongs to, when the daemon paired it with a
    /// `PreToolUse` note. Nil for an unpaired prompt.
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

/// The hash that pairs a `PermissionRequest` with the `PreToolUse` note of the
/// same tool call.
///
/// `PermissionRequest` carries no `tool_use_id`, so two calls to one tool in a
/// single assistant message are told apart by their input. Both payloads hash
/// `tool_input` re-serialized with sorted keys, so key order in either payload
/// does not matter.
///
/// The hook paths hash through ``of(toolName:toolInput:)``, which picks the
/// part of the input that stays the same across the call's life. For
/// `AskUserQuestion` that is `questions` alone: the `PostToolUse` input
/// carries the merged `answers` too, and a whole-input hash would never let
/// the post close an unpaired question.
public enum PromptInputHash {
    /// The tool whose `tool_input` hashes by `questions` alone.
    public static let askUserQuestionToolName = "AskUserQuestion"

    /// The hash the pre and post notes and the register all carry: of the
    /// part of `toolInput` that ``hashedSubset(toolName:toolInput:)`` picks.
    public static func of(toolName: String, toolInput: Any) -> String {
        of(toolInput: hashedSubset(toolName: toolName, toolInput: toolInput))
    }

    /// As `of(toolName:toolInput:)`, from JSON text. Text that is not JSON
    /// hashes as its raw bytes.
    public static func of(toolName: String, toolInputJSON: String) -> String {
        guard let object = try? JSONSerialization.jsonObject(
            with: Data(toolInputJSON.utf8), options: [.fragmentsAllowed]) else {
            return of(toolInputJSON: toolInputJSON)
        }
        return of(toolName: toolName, toolInput: object)
    }

    /// `questions` for an `AskUserQuestion` input that has it; the whole
    /// input otherwise.
    public static func hashedSubset(toolName: String, toolInput: Any) -> Any {
        if toolName == askUserQuestionToolName,
           let object = toolInput as? [String: Any],
           let questions = object["questions"] {
            return questions
        }
        return toolInput
    }

    /// SHA-256 hex of `toolInput` (a `JSONSerialization` object) re-serialized
    /// with sorted keys.
    public static func of(toolInput: Any) -> String {
        // Wrapped in an array so a scalar input is still a valid top-level
        // object; `JSONSerialization` raises an uncatchable exception on an
        // invalid one, hence the explicit check.
        let wrapped: [Any] = [toolInput]
        guard JSONSerialization.isValidJSONObject(wrapped),
              let data = try? JSONSerialization.data(
                withJSONObject: wrapped, options: [.sortedKeys, .withoutEscapingSlashes]) else {
            return hex(Data("null".utf8))
        }
        return hex(data)
    }

    /// As `of(toolInput:)`, from JSON text. Text that is not JSON hashes as
    /// its raw bytes.
    public static func of(toolInputJSON: String) -> String {
        guard let object = try? JSONSerialization.jsonObject(
            with: Data(toolInputJSON.utf8), options: [.fragmentsAllowed]) else {
            return hex(Data(toolInputJSON.utf8))
        }
        return of(toolInput: object)
    }

    private static func hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
