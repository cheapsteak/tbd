import Foundation
import TBDShared

/// What shaping a transcript item needs beyond the item: whether details are
/// shown, and facts that sit on other lines than the item's own.
struct ShapingContext: Sendable {
    /// "Show details": thinking and system notes are shown only when true.
    let showDetails: Bool
    /// `tool_use` id → the lines an Edit, Write or MultiEdit call adds and
    /// removes, from the untruncated input.
    let fileEdits: [String: FileEditStats]
    /// `tool_use` id → the subagent's `agentId`, for each subagent call whose
    /// result has been seen.
    let subagentAgentIDs: [String: String]
    /// `tool_use` id → its result, for results that are not on the item: ones
    /// in a newer window the phone already holds, or ones that arrived live.
    let joinedResults: [String: ToolResult]
    /// A subagent's item count by its `agentId`, or nil when unknown. The
    /// pager calls it only for the subagent rows a page keeps.
    let subagentItemCount: @Sendable (String) -> Int?

    init(
        showDetails: Bool = false,
        fileEdits: [String: FileEditStats] = [:],
        subagentAgentIDs: [String: String] = [:],
        joinedResults: [String: ToolResult] = [:],
        subagentItemCount: @escaping @Sendable (String) -> Int? = { _ in nil }
    ) {
        self.showDetails = showDetails
        self.fileEdits = fileEdits
        self.subagentAgentIDs = subagentAgentIDs
        self.joinedResults = joinedResults
        self.subagentItemCount = subagentItemCount
    }
}

/// Turns a `TranscriptItem` into the summary row the phone shows (spec
/// section 7, "Shaping").
///
/// Every text field is cut by the bytes it takes in the encoded JSON
/// (`PhoneFrameBudget.escapedLength`), not by its raw UTF-8 length, so a field
/// full of quotes or control characters still fits the sizes page fitting
/// relies on. A cut never splits a `Character`.
enum TranscriptShaper {
    /// The most encoded bytes a tool's target, a file name or a subagent type
    /// keeps, so one long command cannot fill a page.
    static let targetLimit = 512
    /// The most encoded bytes a peer message's sender label keeps.
    static let senderLimit = PhoneText.fieldLimit
    /// The most encoded bytes a tool name keeps.
    static let toolNameLimit = PhoneText.fieldLimit
    /// Follows a sender the receiving harness did not verify, the same mark
    /// the laptop's transcript draws (`PeerHeaderChrome.displayName`): an
    /// asserted name is never shown bare.
    static let unverifiedSuffix = " (unverified)"

    /// A tool row whose call has no result yet.
    static let runningStatus = "running"
    /// A tool row whose result is an error.
    static let errorStatus = "error"
    /// A tool row whose result is not an error.
    static let okStatus = "ok"

    private static let fileEditTools: Set<String> = ["Edit", "Write", "MultiEdit"]
    /// The subagent tool is `Agent`; older transcripts call it `Task`.
    private static let subagentTools: Set<String> = ["Agent", "Task"]

    /// Whether the phone shows `item` at all. Thinking and system reminders
    /// show only with details on. `.slashCommand` never shows: the parser no
    /// longer emits it, and a slash command arrives as a `.userPrompt`.
    static func isShown(_ item: TranscriptItem, showDetails: Bool) -> Bool {
        switch item {
        case .thinking, .systemReminder:
            return showDetails
        case .slashCommand:
            return false
        case .userPrompt, .assistantText, .toolCall, .peerMessage:
            return true
        }
    }

    /// `item` as a phone row, or nil for an item the phone does not show
    /// (`isShown`).
    ///
    /// - `.userPrompt` – `slash` when the text starts with `/` and holds no
    ///   newline, else `user`. Both carry the text's preview.
    /// - `.assistantText` – `assistant`, with the preview.
    /// - `.toolCall` named Edit, Write or MultiEdit – `fileEdit`: the file's
    ///   last path component as `target`, and `added` and `removed` from
    ///   `ctx.fileEdits`.
    /// - `.toolCall` named Agent or Task – `subagent`: the call's description
    ///   as `target`, the input's `subagent_type` as `agentType`, and
    ///   `itemCount` from `ctx.subagentItemCount`, at most
    ///   `PhoneAppConstants.subagentCountLimit`, once the agent's ID is known.
    /// - any other `.toolCall` – `tool`: `target` is
    ///   `TranscriptParser.toolInputSummary` without the tool name.
    /// - `.peerMessage` – `peer`, with the sender label and the preview.
    /// - `.thinking` – `thinking`, and `.systemReminder` – `systemNote`, with
    ///   the preview. A reminder the parser already cut is `truncated` too.
    ///
    /// Every tool row carries `toolName` and `toolStatus`: `running` with no
    /// result, `error` when the result is an error, else `ok`. The result is
    /// the item's own, or `ctx.joinedResults` for its ID. `id` is the item's
    /// own, and `at` its timestamp in Unix milliseconds.
    static func shape(_ item: TranscriptItem, _ ctx: ShapingContext) -> PhoneItem? {
        guard isShown(item, showDetails: ctx.showDetails) else { return nil }
        let at = item.timestamp.map(PhoneTime.ms)
        switch item {
        case .userPrompt(let id, let text, _):
            let isSlash = text.hasPrefix("/") && !text.contains(where: \.isNewline)
            return message(id, isSlash ? .slash : .user, at: at, text)
        case .assistantText(let id, let text, _, _):
            return message(id, .assistant, at: at, text)
        case .toolCall(let id, let name, let inputJSON, _, let result, _, _, _):
            return toolRow(id: id, name: name, inputJSON: inputJSON, result: result ?? ctx.joinedResults[id], at: at, ctx: ctx)
        case .peerMessage(let id, let sender, let text, _, _):
            return message(id, .peer, at: at, text, sender: senderLabel(sender))
        case .thinking(let id, let text, _):
            return message(id, .thinking, at: at, text)
        case .systemReminder(let id, _, let text, _, _, let truncatedTo):
            return message(id, .systemNote, at: at, text, alreadyCut: truncatedTo != nil)
        case .slashCommand:
            return nil
        }
    }

    /// `text` cut at a `Character` boundary so that it takes at most `limit`
    /// bytes as a JSON string body, without its quotes
    /// (`PhoneFrameBudget.escapedLength`), and whether anything was cut. The
    /// UTF-8 length is never more than the encoded length, so it is at most
    /// `limit` too. Only the characters up to the cut are measured.
    static func preview(_ text: String, limit: Int = PhoneAppConstants.messagePreviewBytes) -> (text: String, truncated: Bool) {
        var used = 0
        var index = text.startIndex
        while index < text.endIndex {
            let next = text.index(after: index)
            used += PhoneFrameBudget.escapedLength(text[index..<next].unicodeScalars)
            if used > limit {
                return (String(text[..<index]), true)
            }
            index = next
        }
        return (text, false)
    }

    /// The label a peer message shows: the verified peer's name, or the
    /// asserted `from` followed by `unverifiedSuffix`. The label is at most
    /// `senderLimit` encoded bytes, and the mark always survives the cut.
    static func senderLabel(_ sender: PeerSender) -> String {
        if sender.verified, let name = sender.name, !name.isEmpty {
            return capped(name, senderLimit)
        }
        let room = senderLimit - PhoneFrameBudget.escapedLength(unverifiedSuffix[...].unicodeScalars)
        return capped(sender.from, room) + unverifiedSuffix
    }

    // MARK: - Rows

    private static func message(
        _ id: String, _ kind: PhoneItemKind, at: Int64?, _ text: String,
        alreadyCut: Bool = false, sender: String? = nil
    ) -> PhoneItem {
        let cut = preview(text)
        return PhoneItem(
            id: id, kind: kind, at: at, text: cut.text, truncated: cut.truncated || alreadyCut,
            toolName: nil, target: nil, toolStatus: nil, added: nil, removed: nil,
            agentType: nil, itemCount: nil, sender: sender)
    }

    private static func toolRow(
        id: String, name: String, inputJSON: String, result: ToolResult?, at: Int64?, ctx: ShapingContext
    ) -> PhoneItem {
        let input = decodedInput(inputJSON)
        let status = result.map { $0.isError ? errorStatus : okStatus } ?? runningStatus
        let toolName = name.isEmpty ? nil : capped(name, toolNameLimit)

        if fileEditTools.contains(name) {
            let stats = ctx.fileEdits[id]
            return PhoneItem(
                id: id, kind: .fileEdit, at: at, text: nil, truncated: false,
                toolName: toolName, target: fileName(input), toolStatus: status,
                added: stats?.added, removed: stats?.removed,
                agentType: nil, itemCount: nil, sender: nil)
        }
        if subagentTools.contains(name) {
            let agentType = (input["subagent_type"] as? String).flatMap { $0.isEmpty ? nil : capped($0, targetLimit) }
            let count = ctx.subagentAgentIDs[id].flatMap { ctx.subagentItemCount($0) }
            return PhoneItem(
                id: id, kind: .subagent, at: at, text: nil, truncated: false,
                toolName: toolName, target: summaryTarget(name: name, input: input), toolStatus: status,
                added: nil, removed: nil,
                agentType: agentType, itemCount: count.map(boundedItemCount),
                sender: nil)
        }
        return PhoneItem(
            id: id, kind: .tool, at: at, text: nil, truncated: false,
            toolName: toolName, target: summaryTarget(name: name, input: input), toolStatus: status,
            added: nil, removed: nil, agentType: nil, itemCount: nil, sender: nil)
    }

    // MARK: - Fields

    /// The input object of a tool call, or an empty one when the JSON is not
    /// an object.
    private static func decodedInput(_ inputJSON: String) -> [String: Any] {
        ((try? JSONSerialization.jsonObject(with: Data(inputJSON.utf8))) as? [String: Any]) ?? [:]
    }

    /// The last path component of the input's `file_path`, cut to
    /// `targetLimit`, or nil when there is none.
    private static func fileName(_ input: [String: Any]) -> String? {
        guard let path = input["file_path"] as? String, !path.isEmpty else { return nil }
        let name = (path as NSString).lastPathComponent
        return name.isEmpty ? nil : capped(name, targetLimit)
    }

    /// `toolInputSummary` without the tool name in front, cut to
    /// `targetLimit`, or nil when the summary names nothing but the tool.
    private static func summaryTarget(name: String, input: [String: Any]) -> String? {
        let summary = TranscriptParser.toolInputSummary(name: name, input: input)
        let detail: Substring
        if name.isEmpty {
            detail = summary[...]
        } else if summary.hasPrefix(name + " ") {
            detail = summary.dropFirst(name.count + 1)
        } else {
            return nil
        }
        return detail.isEmpty ? nil : capped(String(detail), targetLimit)
    }

    /// A subagent row's item count, held to `0...subagentCountLimit`
    /// (`PhoneAppConstants.subagentCountLimit`).
    static func boundedItemCount(_ count: Int) -> Int {
        min(max(count, 0), PhoneAppConstants.subagentCountLimit)
    }

    private static func capped(_ text: String, _ limit: Int) -> String {
        preview(text, limit: limit).text
    }
}
