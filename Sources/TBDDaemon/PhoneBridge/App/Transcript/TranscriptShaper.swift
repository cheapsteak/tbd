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
    /// pager calls it only for the subagent rows a page keeps, and measures
    /// rows with a copy that answers the largest count instead.
    var subagentItemCount: @Sendable (String) -> Int?
    /// The session's worktree, so a file edit's path is sent relative to it.
    /// Nil sends every path as the call wrote it.
    let worktreeRoot: String?
    /// A slash command's item ID → the output Claude Code wrote for it
    /// (`TranscriptParser.localCommandOutput(fromLine:)`), from any line seen.
    let slashOutputs: [String: String]
    /// A line's ID → its API error class (`TranscriptParser.apiErrorClass(fromLine:)`).
    /// An assistant item's ID is its line's ID followed by `#<block>`.
    let apiErrors: [String: String]

    init(
        showDetails: Bool = false,
        fileEdits: [String: FileEditStats] = [:],
        subagentAgentIDs: [String: String] = [:],
        joinedResults: [String: ToolResult] = [:],
        subagentItemCount: @escaping @Sendable (String) -> Int? = { _ in nil },
        worktreeRoot: String? = nil,
        slashOutputs: [String: String] = [:],
        apiErrors: [String: String] = [:]
    ) {
        self.showDetails = showDetails
        self.fileEdits = fileEdits
        self.subagentAgentIDs = subagentAgentIDs
        self.joinedResults = joinedResults
        self.subagentItemCount = subagentItemCount
        self.worktreeRoot = worktreeRoot
        self.slashOutputs = slashOutputs
        self.apiErrors = apiErrors
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
    /// The most encoded bytes an API error class keeps.
    static let apiErrorLimit = PhoneText.fieldLimit
    /// Ends a slash command's output that was cut.
    static let cutMark = "\u{2026}"
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
    ///   newline, else `user`. Both carry the text's preview. A slash row
    ///   carries `output` from `ctx.slashOutputs` when it holds the row's ID,
    ///   cut to `PhoneAppConstants.slashOutputBytes` (`slashOutput(_:)`).
    /// - `.assistantText` – `assistant`, with the preview. When
    ///   `ctx.apiErrors` names the item's line, the row is an API error and
    ///   carries its class as `apiError`.
    /// - `.toolCall` named Edit, Write or MultiEdit – `fileEdit`: the file's
    ///   last path component as `target`, its path as `path`
    ///   (`fileEditPath(_:root:)`), and `added` and `removed` from
    ///   `ctx.fileEdits`.
    /// - `.toolCall` named Agent or Task – `subagent`: the call's description
    ///   as `target`, the input's `subagent_type` as `agentType`, and
    ///   `itemCount` from `ctx.subagentItemCount`, at most
    ///   `PhoneAppConstants.subagentCountLimit`, once the agent's ID is known.
    /// - any other `.toolCall` – `tool`: `target` is
    ///   `TranscriptParser.toolInputSummary` without the tool name.
    /// - `.peerMessage` – `peer`, with the sender label and the preview.
    /// - `.thinking` – `thinking`, and `.systemReminder` – `systemNote`, with
    ///   the preview. A reminder the parser already cut is `truncated` too. A
    ///   system note carries its `SystemKind` raw value as `noteKind`.
    ///
    /// Every tool row carries `toolName` and `toolStatus`: `running` with no
    /// result, `error` when the result is an error, else `ok`. An error result
    /// that names an exit code adds it as `exitCode` (`exitCode(of:)`). The
    /// result is the item's own, or `ctx.joinedResults` for its ID. `id` is
    /// the item's own, and `at` its timestamp in Unix milliseconds.
    static func shape(_ item: TranscriptItem, _ ctx: ShapingContext) -> PhoneItem? {
        guard isShown(item, showDetails: ctx.showDetails) else { return nil }
        let at = item.timestamp.map(PhoneTime.ms)
        switch item {
        case .userPrompt(let id, let text, _):
            guard text.hasPrefix("/"), !text.contains(where: \.isNewline) else {
                return message(id, .user, at: at, text)
            }
            return message(id, .slash, at: at, text, output: ctx.slashOutputs[id].map(slashOutput))
        case .assistantText(let id, let text, _, _):
            let apiError = ctx.apiErrors[lineID(ofItem: id)].map { capped($0, apiErrorLimit) }
            return message(id, .assistant, at: at, text, apiError: apiError)
        case .toolCall(let id, let name, let inputJSON, _, let result, _, _, _):
            return toolRow(id: id, name: name, inputJSON: inputJSON, result: result ?? ctx.joinedResults[id], at: at, ctx: ctx)
        case .peerMessage(let id, let sender, let text, _, _):
            return message(id, .peer, at: at, text, sender: senderLabel(sender))
        case .thinking(let id, let text, _):
            return message(id, .thinking, at: at, text)
        case .systemReminder(let id, let kind, let text, _, _, let truncatedTo):
            return message(
                id, .systemNote, at: at, text, alreadyCut: truncatedTo != nil, noteKind: kind.rawValue)
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

    /// The exit code on the first line of a failed tool's result. Claude Code
    /// starts the result of a Bash call whose command exits non-zero with
    /// `Exit code <n>` on a line of its own. Nil when the result is not an
    /// error, or its first line is not exactly that, `n` a whole number of at
    /// most 10 digits, optionally negative.
    static func exitCode(of result: ToolResult) -> Int? {
        guard result.isError else { return nil }
        let prefix = "Exit code "
        let firstLine = result.text.prefix(while: { !$0.isNewline })
        guard firstLine.hasPrefix(prefix) else { return nil }
        let number = firstLine.dropFirst(prefix.count)
        let digits = number.hasPrefix("-") ? number.dropFirst() : number
        guard !digits.isEmpty, digits.count <= 10,
              digits.allSatisfy({ ("0"..."9").contains($0) }) else { return nil }
        return Int(number)
    }

    /// A slash command's output as its row carries it: whole when it takes
    /// at most `PhoneAppConstants.slashOutputBytes` encoded bytes, else cut
    /// at a `Character` boundary and ended with `cutMark`, the two together
    /// within that limit.
    static func slashOutput(_ output: String) -> String {
        let limit = PhoneAppConstants.slashOutputBytes
        guard preview(output, limit: limit).truncated else { return output }
        let room = limit - PhoneFrameBudget.escapedLength(cutMark[...].unicodeScalars)
        return preview(output, limit: room).text + cutMark
    }

    /// A file edit's `file_path` as its row carries it: relative to `root`
    /// when the file lies inside it (`relativePath(_:root:)`), else as the
    /// call wrote it. Nil when there is none, or when it takes more than
    /// `targetLimit` encoded bytes, since a path cut short would name another
    /// file; the row's `target` still names the file.
    static func fileEditPath(_ input: [String: Any], root: String?) -> String? {
        guard let path = input["file_path"] as? String, !path.isEmpty else { return nil }
        let shown = relativePath(path, root: root) ?? path
        return preview(shown, limit: targetLimit).truncated ? nil : shown
    }

    /// `path` relative to `root`, or nil when it does not lie inside it. The
    /// two are compared as written, whole components at a time, trailing `/`
    /// on `root` ignored. A path that climbs out with a `..` component counts
    /// as outside, and so does every path when `root` is empty or `/`.
    static func relativePath(_ path: String, root: String?) -> String? {
        guard var root else { return nil }
        while root.count > 1, root.hasSuffix("/") { root.removeLast() }
        guard !root.isEmpty, root != "/", path.hasPrefix(root + "/") else { return nil }
        let relative = String(path.dropFirst(root.count + 1))
        let components = relative.split(separator: "/")
        guard !components.isEmpty, !components.contains("..") else { return nil }
        return relative
    }

    // MARK: - Rows

    private static func message(
        _ id: String, _ kind: PhoneItemKind, at: Int64?, _ text: String,
        alreadyCut: Bool = false, sender: String? = nil,
        output: String? = nil, apiError: String? = nil, noteKind: String? = nil
    ) -> PhoneItem {
        let cut = preview(text)
        return PhoneItem(
            id: id, kind: kind, at: at, text: cut.text, truncated: cut.truncated || alreadyCut,
            toolName: nil, target: nil, toolStatus: nil, added: nil, removed: nil,
            agentType: nil, itemCount: nil, sender: sender,
            output: output, apiError: apiError, noteKind: noteKind)
    }

    private static func toolRow(
        id: String, name: String, inputJSON: String, result: ToolResult?, at: Int64?, ctx: ShapingContext
    ) -> PhoneItem {
        let input = decodedInput(inputJSON)
        let status = result.map { $0.isError ? errorStatus : okStatus } ?? runningStatus
        let code = result.flatMap(Self.exitCode(of:))
        let toolName = name.isEmpty ? nil : capped(name, toolNameLimit)

        if fileEditTools.contains(name) {
            let stats = ctx.fileEdits[id]
            return PhoneItem(
                id: id, kind: .fileEdit, at: at, text: nil, truncated: false,
                toolName: toolName, target: fileName(input), toolStatus: status,
                added: stats?.added, removed: stats?.removed,
                agentType: nil, itemCount: nil, sender: nil,
                exitCode: code, path: fileEditPath(input, root: ctx.worktreeRoot))
        }
        if subagentTools.contains(name) {
            let agentType = (input["subagent_type"] as? String).flatMap { $0.isEmpty ? nil : capped($0, targetLimit) }
            let count = ctx.subagentAgentIDs[id].flatMap { ctx.subagentItemCount($0) }
            return PhoneItem(
                id: id, kind: .subagent, at: at, text: nil, truncated: false,
                toolName: toolName, target: summaryTarget(name: name, input: input), toolStatus: status,
                added: nil, removed: nil,
                agentType: agentType, itemCount: count.map(boundedItemCount),
                sender: nil, exitCode: code)
        }
        return PhoneItem(
            id: id, kind: .tool, at: at, text: nil, truncated: false,
            toolName: toolName, target: summaryTarget(name: name, input: input), toolStatus: status,
            added: nil, removed: nil, agentType: nil, itemCount: nil, sender: nil, exitCode: code)
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

    /// The ID of the line an item came from: the item's ID before its last
    /// `#`, or the whole ID when it has none.
    static func lineID(ofItem id: String) -> String {
        id.lastIndex(of: "#").map { String(id[..<$0]) } ?? id
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
