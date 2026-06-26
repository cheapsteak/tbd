import AppKit
import Foundation
import TBDShared

/// A styled run of text composing part of an activity row's one-line title.
/// Mirrors the per-`Text` styling the SwiftUI activity cards apply inside
/// `ActivityRowChrome` (primary/secondary/tertiary foreground, monospace runs,
/// `·` separators) so the native cell reproduces them exactly. (#129)
struct ActivityRowSegment: Equatable {
    enum Style: Equatable {
        /// `.foregroundStyle(.primary)`, subheadline — the leading "Read"/"Skill" token.
        case primary
        /// `.foregroundStyle(.secondary)`, subheadline — the default chrome style.
        case secondary
        /// `.foregroundStyle(.tertiary)`, caption2 — trailing detail (line ranges, "in path").
        case tertiary
        /// `.font(.system(.callout, design: .monospaced))`, secondary — Grep/Glob pattern.
        case monospace
    }

    let text: String
    let style: Style
}

/// A small capsule badge ("all", "failed", "error", "hook", …) attached to a
/// row title. Neutral capsules reuse the SwiftUI cards' `quaternaryLabelColor`
/// 0.5 fill; error capsules use red 0.2 fill + red text. (#129)
struct ActivityRowBadge: Equatable {
    enum Kind: Equatable {
        /// Neutral capsule: quaternaryLabelColor 0.5 background, secondary text.
        case neutral
        /// Error capsule: red 0.2 background, red text.
        case error
    }

    let text: String
    let kind: Kind
}

/// A flattened, AppKit-renderable description of a non-bubble activity row
/// (tool call header, system reminder, skill body, subagent summary). Computed
/// once by `ActivityRowFormatter` from a `TranscriptRenderNode` and consumed by
/// `ActivityRowCellView`, replacing the per-row SwiftUI hosting cost with a
/// single native cell behind the table-transcript gate. (#129)
struct ActivityRowPresentation: Equatable {
    /// Visual variant: the standard rounded "chrome" header, or the plain
    /// indented subagent-summary line (no background, no timestamp, no
    /// hover/scope, not clickable — matches `SubagentSummaryRow`).
    enum RowStyle: Equatable {
        case chrome
        case plainSummary
    }

    let iconSystemName: String
    /// Ordered runs composing the one-line title.
    let titleSegments: [ActivityRowSegment]
    let timestamp: Date?
    let isError: Bool
    let badges: [ActivityRowBadge]
    /// `openTranscriptOverlay(id)` target — most kinds.
    let openTargetID: String?
    /// `navigateToThread(id)` target — Agent/Task only.
    let navigateTargetID: String?
    /// Title truncation: `.byTruncatingMiddle` for Read (file path), else tail.
    let titleTruncation: NSLineBreakMode
    let style: RowStyle

    init(
        iconSystemName: String,
        titleSegments: [ActivityRowSegment],
        timestamp: Date?,
        isError: Bool,
        badges: [ActivityRowBadge],
        openTargetID: String?,
        navigateTargetID: String?,
        titleTruncation: NSLineBreakMode = .byTruncatingTail,
        style: RowStyle = .chrome
    ) {
        self.iconSystemName = iconSystemName
        self.titleSegments = titleSegments
        self.timestamp = timestamp
        self.isError = isError
        self.badges = badges
        self.openTargetID = openTargetID
        self.navigateTargetID = navigateTargetID
        self.titleTruncation = titleTruncation
        self.style = style
    }
}

/// Pure formatter mapping a `TranscriptRenderNode` to its native-cell
/// presentation. Ports each SwiftUI card's header (icon + summary string + badge
/// logic + open/navigate target) EXACTLY. Returns `nil` for kinds that stay
/// SwiftUI-hosted: `.chatBubble` (already native via `TranscriptBubbleCellView`)
/// and `.toolCall` named `AskUserQuestion` (a full multi-bubble card). (#129)
enum ActivityRowFormatter {
    private static let decoder = JSONDecoder()

    @MainActor
    static func presentation(for node: TranscriptRenderNode) -> ActivityRowPresentation? {
        switch node.kind {
        case .chatBubble:
            return nil
        case let .systemReminder(id, kind, _, ts):
            return systemReminder(id: id, kind: kind, timestamp: ts)
        case let .skillBody(id, text, ts):
            return skillBody(id: id, text: text, timestamp: ts)
        case let .toolCall(id, name, inputJSON, inputTruncatedTo, result, ts):
            return toolCall(
                id: id, name: name, inputJSON: inputJSON,
                inputTruncatedTo: inputTruncatedTo, result: result, timestamp: ts)
        case let .subagentSummary(_, count, agentType):
            return subagentSummary(count: count, agentType: agentType)
        }
    }

    // MARK: - Tool call dispatch (mirrors TranscriptRow.toolCard)

    private static func toolCall(
        id: String, name: String, inputJSON: String,
        inputTruncatedTo: Int?, result: ToolResult?, timestamp: Date?
    ) -> ActivityRowPresentation? {
        switch name {
        case "Read":
            return readTool(id: id, inputJSON: inputJSON, timestamp: timestamp)
        case "Edit", "MultiEdit":
            return editTool(id: id, name: name, inputJSON: inputJSON, result: result, timestamp: timestamp)
        case "Write":
            return writeTool(id: id, inputJSON: inputJSON, inputTruncatedTo: inputTruncatedTo, timestamp: timestamp)
        case "Bash":
            return bashTool(id: id, inputJSON: inputJSON, result: result, timestamp: timestamp)
        case "Grep":
            return patternTool(id: id, label: "Grep", icon: "magnifyingglass", inputJSON: inputJSON, timestamp: timestamp)
        case "Glob":
            return patternTool(id: id, label: "Glob", icon: "folder", inputJSON: inputJSON, timestamp: timestamp)
        case "Task", "Agent":
            return agentTool(id: id, inputJSON: inputJSON, result: result, timestamp: timestamp)
        case "AskUserQuestion":
            return nil
        default:
            return genericTool(id: id, name: name, result: result, timestamp: timestamp)
        }
    }

    // MARK: Read (ReadCard)

    private struct ReadInput: Decodable {
        let file_path: String
        let offset: Int?
        let limit: Int?
    }

    private static func readTool(id: String, inputJSON: String, timestamp: Date?) -> ActivityRowPresentation {
        let parsed = decode(ReadInput.self, inputJSON)
        var segments: [ActivityRowSegment] = [
            ActivityRowSegment(text: "Read", style: .primary),
            ActivityRowSegment(text: parsed?.file_path ?? "…", style: .secondary)
        ]
        if let off = parsed?.offset {
            if let lim = parsed?.limit {
                segments.append(ActivityRowSegment(text: "lines \(off)–\(off + lim - 1)", style: .tertiary))
            } else {
                segments.append(ActivityRowSegment(text: "from line \(off)", style: .tertiary))
            }
        }
        return ActivityRowPresentation(
            iconSystemName: "doc.text",
            titleSegments: segments,
            timestamp: timestamp,
            isError: false,
            badges: [],
            openTargetID: id,
            navigateTargetID: nil,
            titleTruncation: .byTruncatingMiddle
        )
    }

    // MARK: Edit / MultiEdit (EditCard)

    private struct EditHunk: Decodable {
        let old_string: String
        let new_string: String
        let replace_all: Bool?
    }

    private struct EditInput: Decodable {
        let file_path: String
        let old_string: String?
        let new_string: String?
        let replace_all: Bool?
        let edits: [EditHunk]?
    }

    private static func editTool(
        id: String, name: String, inputJSON: String, result: ToolResult?, timestamp: Date?
    ) -> ActivityRowPresentation {
        let parsed = decode(EditInput.self, inputJSON)
        let hunks: [EditHunk] = {
            if let multi = parsed?.edits, !multi.isEmpty { return multi }
            if let i = parsed, let oldS = i.old_string, let newS = i.new_string {
                return [EditHunk(old_string: oldS, new_string: newS, replace_all: i.replace_all)]
            }
            return []
        }()

        let segments: [ActivityRowSegment] = [
            ActivityRowSegment(text: name == "MultiEdit" ? "Edit ×\(hunks.count)" : "Edit", style: .secondary),
            ActivityRowSegment(text: parsed?.file_path ?? "…", style: .secondary)
        ]

        var badges: [ActivityRowBadge] = []
        if !hunks.isEmpty && hunks.allSatisfy({ $0.replace_all == true }) {
            badges.append(ActivityRowBadge(text: "all", kind: .neutral))
        }
        if result?.isError == true {
            badges.append(ActivityRowBadge(text: "error", kind: .error))
        }

        return ActivityRowPresentation(
            iconSystemName: "pencil",
            titleSegments: segments,
            timestamp: timestamp,
            isError: result?.isError == true,
            badges: badges,
            openTargetID: id,
            navigateTargetID: nil
        )
    }

    // MARK: Write (WriteCard)

    private struct WriteInput: Decodable {
        let file_path: String
        let content: String
    }

    private static func writeTool(
        id: String, inputJSON: String, inputTruncatedTo: Int?, timestamp: Date?
    ) -> ActivityRowPresentation {
        let parsed = decode(WriteInput.self, inputJSON)
        let count: Int = {
            guard let content = parsed?.content, !content.isEmpty else { return 0 }
            return content.split(separator: "\n", omittingEmptySubsequences: false).count
        }()
        let prefix = (inputTruncatedTo != nil) ? "≥" : ""
        let segments: [ActivityRowSegment] = [
            ActivityRowSegment(text: "Write", style: .secondary),
            ActivityRowSegment(text: parsed?.file_path ?? "…", style: .secondary),
            ActivityRowSegment(text: "\(prefix)\(count) lines", style: .tertiary)
        ]
        return ActivityRowPresentation(
            iconSystemName: "square.and.pencil",
            titleSegments: segments,
            timestamp: timestamp,
            isError: false,
            badges: [],
            openTargetID: id,
            navigateTargetID: nil
        )
    }

    // MARK: Bash (BashCard)

    private struct BashInput: Decodable {
        let command: String
        let description: String?
    }

    private static func bashTool(
        id: String, inputJSON: String, result: ToolResult?, timestamp: Date?
    ) -> ActivityRowPresentation {
        let parsed = decode(BashInput.self, inputJSON)
        let summary: String = {
            if let desc = parsed?.description, !desc.isEmpty { return desc }
            if let cmd = parsed?.command {
                let trimmed = cmd.replacingOccurrences(of: "\n", with: " ")
                if trimmed.count > 60 { return "$(\(String(trimmed.prefix(60)))…)" }
                return "$(\(trimmed))"
            }
            return "…"
        }()
        let segments: [ActivityRowSegment] = [
            ActivityRowSegment(text: "Bash", style: .secondary),
            ActivityRowSegment(text: summary, style: .secondary)
        ]
        var badges: [ActivityRowBadge] = []
        if result?.isError == true {
            badges.append(ActivityRowBadge(text: "failed", kind: .error))
        }
        return ActivityRowPresentation(
            iconSystemName: "terminal",
            titleSegments: segments,
            timestamp: timestamp,
            isError: result?.isError == true,
            badges: badges,
            openTargetID: id,
            navigateTargetID: nil
        )
    }

    // MARK: Grep / Glob (GrepCard / GlobCard)

    private struct PatternInput: Decodable {
        let pattern: String
        let path: String?
    }

    private static func patternTool(
        id: String, label: String, icon: String, inputJSON: String, timestamp: Date?
    ) -> ActivityRowPresentation {
        let parsed = decode(PatternInput.self, inputJSON)
        var segments: [ActivityRowSegment] = [
            ActivityRowSegment(text: label, style: .secondary),
            ActivityRowSegment(text: parsed?.pattern ?? "…", style: .monospace)
        ]
        if let path = parsed?.path {
            segments.append(ActivityRowSegment(text: "in \(path)", style: .tertiary))
        }
        return ActivityRowPresentation(
            iconSystemName: icon,
            titleSegments: segments,
            timestamp: timestamp,
            isError: false,
            badges: [],
            openTargetID: id,
            navigateTargetID: nil
        )
    }

    // MARK: Task / Agent (AgentCard)

    private struct AgentInput: Decodable {
        let description: String?
        let prompt: String?
        let subagent_type: String?
    }

    private static func agentTool(
        id: String, inputJSON: String, result: ToolResult?, timestamp: Date?
    ) -> ActivityRowPresentation {
        let parsed = decode(AgentInput.self, inputJSON)
        let summary: String = {
            if let desc = parsed?.description, !desc.isEmpty { return desc }
            return "(no description)"
        }()
        let segments: [ActivityRowSegment] = [
            ActivityRowSegment(text: "Agent", style: .secondary),
            ActivityRowSegment(text: summary, style: .secondary)
        ]
        var badges: [ActivityRowBadge] = []
        if result?.isError == true {
            badges.append(ActivityRowBadge(text: "error", kind: .error))
        }
        return ActivityRowPresentation(
            iconSystemName: "sparkles",
            titleSegments: segments,
            timestamp: timestamp,
            isError: result?.isError == true,
            badges: badges,
            openTargetID: id,
            navigateTargetID: nil
        )
    }

    // MARK: Generic (GenericToolCard)

    private static func genericTool(
        id: String, name: String, result: ToolResult?, timestamp: Date?
    ) -> ActivityRowPresentation {
        let displayName: String = {
            if name.hasPrefix("mcp__") {
                return name.replacingOccurrences(of: "mcp__", with: "mcp · ")
                    .replacingOccurrences(of: "__", with: " · ")
            }
            return name
        }()
        var badges: [ActivityRowBadge] = []
        if result?.isError == true {
            badges.append(ActivityRowBadge(text: "error", kind: .error))
        }
        return ActivityRowPresentation(
            iconSystemName: "wrench.and.screwdriver",
            titleSegments: [ActivityRowSegment(text: displayName, style: .secondary)],
            timestamp: timestamp,
            isError: result?.isError == true,
            badges: badges,
            openTargetID: id,
            navigateTargetID: nil
        )
    }

    // MARK: System reminder (SystemReminderRow)

    private static func systemReminder(
        id: String, kind: SystemKind, timestamp: Date?
    ) -> ActivityRowPresentation {
        let label: String = {
            switch kind {
            case .toolReminder: return "system-reminder"
            case .hookOutput: return "hook"
            case .environmentDetails: return "env"
            case .slashEnvelope: return "command"
            case .skillBody: return "skill"
            case .other: return "info"
            }
        }()
        return ActivityRowPresentation(
            iconSystemName: "info.circle",
            titleSegments: [],
            timestamp: timestamp,
            isError: false,
            badges: [ActivityRowBadge(text: label, kind: .neutral)],
            openTargetID: id,
            navigateTargetID: nil
        )
    }

    // MARK: Skill body (SkillBodyRow)

    private static func skillBody(id: String, text: String, timestamp: Date?) -> ActivityRowPresentation {
        let name: String = {
            let firstLine = text.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false).first ?? ""
            let prefix = "Base directory for this skill:"
            guard firstLine.hasPrefix(prefix) else { return "skill" }
            let path = firstLine.dropFirst(prefix.count).trimmingCharacters(in: .whitespaces)
            let lastComponent = (path as NSString).lastPathComponent
            return lastComponent.isEmpty ? "skill" : lastComponent
        }()
        let segments: [ActivityRowSegment] = [
            ActivityRowSegment(text: "Skill", style: .primary),
            ActivityRowSegment(text: "·", style: .tertiary),
            ActivityRowSegment(text: name, style: .secondary)
        ]
        return ActivityRowPresentation(
            iconSystemName: "sparkles",
            titleSegments: segments,
            timestamp: timestamp,
            isError: false,
            badges: [],
            openTargetID: id,
            navigateTargetID: nil
        )
    }

    // MARK: Subagent summary (SubagentSummaryRow) — plain, indented, no chrome

    private static func subagentSummary(count: Int, agentType: String?) -> ActivityRowPresentation {
        let plural = count == 1 ? "activity" : "activities"
        let text: String = {
            if let agentType {
                return "\(count) subagent \(plural) · \(agentType)"
            }
            return "\(count) subagent \(plural)"
        }()
        return ActivityRowPresentation(
            iconSystemName: "person.2",
            titleSegments: [ActivityRowSegment(text: text, style: .tertiary)],
            timestamp: nil,
            isError: false,
            badges: [],
            openTargetID: nil,
            navigateTargetID: nil,
            style: .plainSummary
        )
    }

    // MARK: Decode helper

    private static func decode<T: Decodable>(_ type: T.Type, _ json: String) -> T? {
        guard let data = json.data(using: .utf8) else { return nil }
        return try? decoder.decode(type, from: data)
    }
}
