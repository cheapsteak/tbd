import Foundation

/// The Session object's optional `pending_prompt`
/// (`docs/remote-provider-contract.md` § Pending prompt) — the Claude Code
/// dialog, a question picker or a tool permission prompt, that a
/// `waiting_input` session is blocked on, with enough detail to answer it.
///
/// Like `RemotePendingQuestion` it is display detail layered on `agent_state`
/// and decoded leniently: a prompt TBD cannot read decodes as absent and costs
/// the explanation, never the session. See
/// `docs/specs/2026-10-09-transcript-prompt-answer-design.md`.
public struct RemotePendingPrompt: Codable, Sendable, Equatable {
    /// Stable for the prompt's life; the operand of the `answer` verb.
    public let id: String
    public let kind: PendingPromptKind
    /// The tool call this dialog belongs to, when the provider could pair
    /// them. Never null on the wire: absent means unpaired.
    public let toolUseID: String?
    /// Present for `.question`.
    public let questions: [RemotePendingQuestionItem]?
    public let toolName: String?
    /// Verbatim `tool_input` object re-serialized with sorted keys; nil when
    /// the provider left it out.
    public let toolInputJSON: String?
    /// The provider cut long strings or left `tool_input` out for size.
    public let toolInputTruncated: Bool
    /// Verbatim `suggestions` array (Claude Code's `permission_suggestions`)
    /// as JSON; nil when absent.
    public let suggestionsJSON: String?

    public init(id: String, kind: PendingPromptKind, toolUseID: String? = nil,
                questions: [RemotePendingQuestionItem]? = nil, toolName: String? = nil,
                toolInputJSON: String? = nil, toolInputTruncated: Bool = false,
                suggestionsJSON: String? = nil) {
        self.id = id
        self.kind = kind
        self.toolUseID = toolUseID
        self.questions = questions
        self.toolName = toolName
        self.toolInputJSON = toolInputJSON
        self.toolInputTruncated = toolInputTruncated
        self.suggestionsJSON = suggestionsJSON
    }

    enum CodingKeys: String, CodingKey {
        case id, kind, questions, suggestions
        case toolUseID = "tool_use_id"
        case toolName = "tool_name"
        case toolInput = "tool_input"
        case toolInputTruncated = "tool_input_truncated"
    }

    /// Throws on a blank id, an unknown kind, or a question prompt with no
    /// decodable question; the enclosing session reads that as absent.
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let rawID = try c.decode(String.self, forKey: .id)
        guard !rawID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw DecodingError.dataCorruptedError(
                forKey: .id, in: c, debugDescription: "pending_prompt id is blank")
        }
        id = rawID
        kind = try c.decode(PendingPromptKind.self, forKey: .kind)
        toolUseID = (try? c.decodeIfPresent(String.self, forKey: .toolUseID))
            .flatMap { $0 }.flatMap { $0.isEmpty ? nil : $0 }
        toolName = (try? c.decodeIfPresent(String.self, forKey: .toolName)).flatMap { $0 }
        toolInputTruncated =
            (try? c.decodeIfPresent(Bool.self, forKey: .toolInputTruncated)).flatMap { $0 } ?? false
        toolInputJSON = Self.jsonText(
            (try? c.decodeIfPresent(JSONValue.self, forKey: .toolInput)).flatMap { $0 },
            requiring: .object)
        suggestionsJSON = Self.jsonText(
            (try? c.decodeIfPresent(JSONValue.self, forKey: .suggestions)).flatMap { $0 },
            requiring: .array)
        if kind == .question {
            let decoded: [LenientQuestion] =
                (try? c.decodeIfPresent([LenientQuestion].self, forKey: .questions)).flatMap { $0 } ?? []
            let items = decoded.compactMap(\.item)
            guard !items.isEmpty else {
                throw DecodingError.dataCorruptedError(
                    forKey: .questions, in: c,
                    debugDescription: "pending_prompt of kind question carried no decodable question")
            }
            questions = items
        } else {
            questions = nil
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(kind, forKey: .kind)
        try c.encodeIfPresent(toolUseID, forKey: .toolUseID)
        try c.encodeIfPresent(questions, forKey: .questions)
        try c.encodeIfPresent(toolName, forKey: .toolName)
        if let value = Self.jsonValue(toolInputJSON) {
            try c.encode(value, forKey: .toolInput)
        }
        try c.encode(toolInputTruncated, forKey: .toolInputTruncated)
        if let value = Self.jsonValue(suggestionsJSON) {
            try c.encode(value, forKey: .suggestions)
        }
    }

    private struct LenientQuestion: Decodable {
        let item: RemotePendingQuestionItem?
        init(from decoder: any Decoder) throws {
            item = try? RemotePendingQuestionItem(from: decoder)
        }
    }

    private enum Shape { case object, array }

    /// Sorted-key JSON text for `value`, or nil when it is absent or not the
    /// expected container shape.
    private static func jsonText(_ value: JSONValue?, requiring shape: Shape) -> String? {
        guard let value else { return nil }
        switch (shape, value) {
        case (.object, .object), (.array, .array): break
        default: return nil
        }
        let object = value.foundationObject
        guard JSONSerialization.isValidJSONObject(object),
              let data = try? JSONSerialization.data(
                withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes]) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private static func jsonValue(_ text: String?) -> JSONValue? {
        guard let text, let data = text.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data, options: []) else { return nil }
        return JSONValue(foundation: object)
    }
}

extension RemoteSessionPayload {
    /// `pending_prompt` when present; else a `pending_question` projected to
    /// kind `.question`. A question without an id yields nil: it renders only
    /// through `pendingQuestion` and can never be answered.
    public var effectivePendingPrompt: RemotePendingPrompt? {
        if let pendingPrompt { return pendingPrompt }
        guard let question = pendingQuestion, let id = question.id,
              !id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return RemotePendingPrompt(id: id, kind: .question, questions: question.questions)
    }
}

/// An arbitrary JSON value, so `tool_input` and `suggestions` survive a decode
/// without TBD interpreting them.
private enum JSONValue: Codable {
    case null
    case bool(Bool)
    case int(Int64)
    case double(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    init(from decoder: any Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() {
            self = .null
        } else if let v = try? c.decode(Bool.self) {
            self = .bool(v)
        } else if let v = try? c.decode(Int64.self) {
            self = .int(v)
        } else if let v = try? c.decode(Double.self) {
            self = .double(v)
        } else if let v = try? c.decode(String.self) {
            self = .string(v)
        } else if let v = try? c.decode([JSONValue].self) {
            self = .array(v)
        } else {
            self = .object(try c.decode([String: JSONValue].self))
        }
    }

    func encode(to encoder: any Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .null: try c.encodeNil()
        case .bool(let v): try c.encode(v)
        case .int(let v): try c.encode(v)
        case .double(let v): try c.encode(v)
        case .string(let v): try c.encode(v)
        case .array(let v): try c.encode(v)
        case .object(let v): try c.encode(v)
        }
    }

    var foundationObject: Any {
        switch self {
        case .null: return NSNull()
        case .bool(let v): return v
        case .int(let v): return v
        case .double(let v): return v
        case .string(let v): return v
        case .array(let v): return v.map(\.foundationObject)
        case .object(let v): return v.mapValues(\.foundationObject)
        }
    }

    init?(foundation object: Any) {
        switch object {
        case is NSNull: self = .null
        case let v as NSNumber:
            if CFGetTypeID(v) == CFBooleanGetTypeID() {
                self = .bool(v.boolValue)
            } else if ["f", "d"].contains(String(cString: v.objCType)) {
                self = .double(v.doubleValue)
            } else {
                self = .int(v.int64Value)
            }
        case let v as String: self = .string(v)
        case let v as [Any]: self = .array(v.compactMap { JSONValue(foundation: $0) })
        case let v as [String: Any]: self = .object(v.compactMapValues { JSONValue(foundation: $0) })
        default: return nil
        }
    }
}
