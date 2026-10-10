import Foundation

/// What the transcript merger needs from one pending prompt: enough to find
/// its row, and enough to draw a row of its own when the transcript does not
/// hold one yet.
///
/// Built app-side from a local `PendingPromptPayload` or a remote
/// `RemotePendingPrompt`. See
/// `docs/specs/2026-10-09-transcript-prompt-answer-design.md`, "Placement in
/// the transcript".
public struct PromptCardSeed: Sendable, Equatable {
    public let promptID: String
    /// The tool call the dialog belongs to; nil for an unpaired prompt.
    public let toolUseID: String?
    public let toolName: String
    public let toolInputJSON: String
    public let timestamp: Date

    public init(promptID: String, toolUseID: String?, toolName: String,
                toolInputJSON: String, timestamp: Date) {
        self.promptID = promptID
        self.toolUseID = toolUseID
        self.toolName = toolName
        self.toolInputJSON = toolInputJSON
        self.timestamp = timestamp
    }
}

/// Joins transcript items with pending prompts on `tool_use_id`, at view time,
/// before `TranscriptPresentation.build()` runs, so the table always receives
/// one consistent list.
///
/// Pure and total. It never decides what a card looks like; it only decides
/// which row is a card and where a card with no row goes:
/// - **The transcript holds the tool call, with no result yet.** That row is
///   the card, in place; the file decides its position.
/// - **The transcript holds the tool call and its result.** No card. The
///   prompt is reported in `settledPromptIDs`, so a caller holding an
///   answered card can let it go.
/// - **The transcript does not hold it yet.** A tool-call row is appended at
///   the end under the same `tool_use_id`. When the real row lands, it takes
///   the same id, so the table sees an update in place rather than a new row.
/// - **No `tool_use_id`.** The row is appended under `prompt-<id>`.
///
/// Appended rows keep seed order. No emitted id starts with `line-` or
/// `tail-`, which the table's prepend anchoring treats as unstable.
///
/// `AskUserQuestionMerger` stays beside this with a different job: it drops a
/// captured question once its `tool_use` reaches the file, while this keeps a
/// prompt attached to that row until the prompt resolves.
public enum PendingPromptMerger {
    public struct Result: Equatable, Sendable {
        public let items: [TranscriptItem]
        /// Transcript item id → prompt id, for every row that renders as a card.
        public let cardItemIDs: [String: String]
        /// Prompts whose tool call already has a result on disk.
        public let settledPromptIDs: Set<String>

        public init(items: [TranscriptItem], cardItemIDs: [String: String],
                    settledPromptIDs: Set<String>) {
            self.items = items
            self.cardItemIDs = cardItemIDs
            self.settledPromptIDs = settledPromptIDs
        }
    }

    /// The prefix of an unpaired prompt's row id.
    public static let fallbackIDPrefix = "prompt-"

    /// Id prefixes the table's prepend anchoring treats as unstable; a card id
    /// never uses one.
    public static let unstableIDPrefixes = ["line-", "tail-"]

    /// The row id of a prompt with no `tool_use_id`.
    public static func fallbackItemID(promptID: String) -> String {
        "\(fallbackIDPrefix)\(promptID)"
    }

    public static func merge(items: [TranscriptItem], seeds: [PromptCardSeed]) -> Result {
        guard !seeds.isEmpty else {
            return Result(items: items, cardItemIDs: [:], settledPromptIDs: [])
        }

        // Tool call id → whether its result has landed.
        var toolCallHasResult: [String: Bool] = [:]
        var itemIDs = Set<String>()
        for item in items {
            itemIDs.insert(item.id)
            if case .toolCall(let id, _, _, _, let result, _, _, _) = item {
                toolCallHasResult[id] = result != nil
            }
        }

        var merged = items
        var cards: [String: String] = [:]
        var settled = Set<String>()

        for seed in seeds {
            if let toolUseID = seed.toolUseID, let hasResult = toolCallHasResult[toolUseID] {
                if hasResult {
                    settled.insert(seed.promptID)
                } else if cards[toolUseID] == nil {
                    cards[toolUseID] = seed.promptID
                }
                continue
            }

            let rowID = appendedRowID(for: seed)
            // A second seed for one row (or a row id the transcript already
            // uses for something that is not a tool call) never appends twice.
            guard cards[rowID] == nil, !itemIDs.contains(rowID) else { continue }
            assert(!unstableIDPrefixes.contains { rowID.hasPrefix($0) },
                   "a card id must never use an unstable prefix: \(rowID)")
            merged.append(.toolCall(
                id: rowID,
                name: seed.toolName,
                inputJSON: seed.toolInputJSON,
                inputTruncatedTo: nil,
                result: nil,
                subagent: nil,
                timestamp: seed.timestamp,
                usage: nil))
            itemIDs.insert(rowID)
            cards[rowID] = seed.promptID
        }

        return Result(items: merged, cardItemIDs: cards, settledPromptIDs: settled)
    }

    /// The id an appended row takes: the `tool_use_id` when there is one, so
    /// the real row replaces it in place, else `prompt-<id>`. A `tool_use_id`
    /// that happens to carry an unstable prefix falls back too — Claude Code's
    /// are `toolu_…`, so that is a malformed id, and the table must never see
    /// it on an appended row.
    private static func appendedRowID(for seed: PromptCardSeed) -> String {
        if let toolUseID = seed.toolUseID, !toolUseID.isEmpty,
           !unstableIDPrefixes.contains(where: { toolUseID.hasPrefix($0) }) {
            return toolUseID
        }
        return fallbackItemID(promptID: seed.promptID)
    }
}
