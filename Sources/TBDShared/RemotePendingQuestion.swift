import Foundation

/// The Session object's optional `pending_question`
/// (`docs/remote-provider-contract.md` § Pending question) — the structured
/// choice an agent is currently blocked on.
///
/// **Display detail layered on `agent_state`, never a substitute for it.**
/// The contract is explicit that a caller MUST NOT conclude a session is
/// blocked from this field's presence: blocking is read off `agent_state`
/// like every other session's, and this field only ever says WHAT the
/// blocked session is blocked on. Every consumer in TBD gates on
/// `agentState == .waitingInput` first and reaches for this second.
///
/// Decoded on the same terms as the rest of the Session object: leniently,
/// and never fatally. A malformed question block costs the explanation, never
/// the session.
public struct RemotePendingQuestion: Codable, Sendable, Equatable {
    /// Stable while the same question is pending, per the contract — so a
    /// caller can tell "still the same question" from "a new one arrived"
    /// without diffing prompt text. Optional here because a provider that
    /// omits it still leaves a question worth showing.
    public let id: String?
    public let questions: [RemotePendingQuestionItem]

    public init(id: String? = nil, questions: [RemotePendingQuestionItem]) {
        self.id = id
        self.questions = questions
    }

    enum CodingKeys: String, CodingKey {
        case id, questions
    }

    /// A block whose every question was undecodable decodes as absent rather
    /// than as an empty question set: an explanation with nothing in it is
    /// not an explanation, and a caller that has to check `questions.isEmpty`
    /// everywhere will eventually forget somewhere.
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = (try? c.decodeIfPresent(String.self, forKey: .id)).flatMap { $0 }
        let decoded: [LenientQuestion] =
            (try? c.decodeIfPresent([LenientQuestion].self, forKey: .questions)).flatMap { $0 } ?? []
        questions = decoded.compactMap(\.item)
        guard !questions.isEmpty else {
            throw DecodingError.dataCorruptedError(
                forKey: .questions, in: c,
                debugDescription: "pending_question carried no decodable question")
        }
    }

    /// One element of `questions`, decoded without the power to fail the
    /// array — the same shape `LenientSessionArray` uses for sessions.
    private struct LenientQuestion: Decodable {
        let item: RemotePendingQuestionItem?
        init(from decoder: any Decoder) throws {
            item = try? RemotePendingQuestionItem(from: decoder)
        }
    }
}

public struct RemotePendingQuestionItem: Codable, Sendable, Equatable {
    /// Required by the contract, and required here: a question with no text
    /// has nothing to explain.
    public let prompt: String
    /// Short form for compact rendering where the full prompt doesn't fit.
    public let label: String?
    public let multi: Bool
    public let options: [RemotePendingQuestionOption]

    public init(prompt: String, label: String? = nil, multi: Bool = false,
                options: [RemotePendingQuestionOption] = []) {
        self.prompt = prompt
        self.label = label
        self.multi = multi
        self.options = options
    }

    enum CodingKeys: String, CodingKey {
        case prompt, label, multi, options
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        prompt = try c.decode(String.self, forKey: .prompt)
        label = (try? c.decodeIfPresent(String.self, forKey: .label)).flatMap { $0 }
        multi = (try? c.decodeIfPresent(Bool.self, forKey: .multi)).flatMap { $0 } ?? false
        let decoded: [LenientOption] =
            (try? c.decodeIfPresent([LenientOption].self, forKey: .options)).flatMap { $0 } ?? []
        options = decoded.compactMap(\.option)
    }

    private struct LenientOption: Decodable {
        let option: RemotePendingQuestionOption?
        init(from decoder: any Decoder) throws {
            option = try? RemotePendingQuestionOption(from: decoder)
        }
    }
}

public struct RemotePendingQuestionOption: Codable, Sendable, Equatable {
    public let label: String
    public let description: String?

    public init(label: String, description: String? = nil) {
        self.label = label
        self.description = description
    }

    enum CodingKeys: String, CodingKey {
        case label, description
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        label = try c.decode(String.self, forKey: .label)
        description = (try? c.decodeIfPresent(String.self, forKey: .description)).flatMap { $0 }
    }
}
