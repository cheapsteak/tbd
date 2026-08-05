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

    /// Leading SF Symbol, or nil for a row that renders no icon at all. Nil
    /// collapses the icon column entirely so the title sits at the row's leading
    /// inset — it does NOT leave an empty gutter.
    let iconSystemName: String?
    /// Ordered runs composing the one-line title.
    let titleSegments: [ActivityRowSegment]
    let timestamp: Date?
    let isError: Bool
    let badges: [ActivityRowBadge]
    /// `openTranscriptOverlay(id)` target — most kinds.
    let openTargetID: String?
    /// Title truncation: `.byTruncatingMiddle` for Read (file path),
    /// `.byTruncatingHead` for injected file paths (keep the whole filename),
    /// else tail.
    let titleTruncation: NSLineBreakMode
    /// `NSView.toolTip` for the title field — set only where the visible title
    /// hides something (a middle-truncated path). Nil elsewhere: a tooltip that
    /// merely repeats a fully-visible short title is noise.
    let titleTooltip: String?
    let style: RowStyle
    /// Optional trailing disclosure accessory. Ordinary activity rows keep the
    /// hover-only scope glyph; group summaries show a persistent chevron.
    let accessorySystemName: String?
    let accessoryAlwaysVisible: Bool
    let accessibilityLabel: String?

    init(
        iconSystemName: String?,
        titleSegments: [ActivityRowSegment],
        timestamp: Date?,
        isError: Bool,
        badges: [ActivityRowBadge],
        openTargetID: String?,
        titleTruncation: NSLineBreakMode = .byTruncatingTail,
        titleTooltip: String? = nil,
        style: RowStyle = .chrome,
        accessorySystemName: String? = nil,
        accessoryAlwaysVisible: Bool = false,
        accessibilityLabel: String? = nil
    ) {
        self.iconSystemName = iconSystemName
        self.titleSegments = titleSegments
        self.timestamp = timestamp
        self.isError = isError
        self.badges = badges
        self.openTargetID = openTargetID
        self.titleTruncation = titleTruncation
        self.titleTooltip = titleTooltip
        self.style = style
        self.accessorySystemName = accessorySystemName
        self.accessoryAlwaysVisible = accessoryAlwaysVisible
        self.accessibilityLabel = accessibilityLabel
    }
}

/// Pure formatter mapping a `TranscriptRenderNode` to its native-cell
/// presentation. Ports each SwiftUI card's header (icon + summary string + badge
/// logic + open target) EXACTLY. Returns `nil` for kinds that stay
/// SwiftUI-hosted: `.chatBubble` (already native via `TranscriptBubbleCellView`)
/// and `.toolCall` named `AskUserQuestion` (a full multi-bubble card). (#129)
enum ActivityRowFormatter {
    private static let decoder = JSONDecoder()

    @MainActor
    static func presentation(for node: TranscriptRenderNode) -> ActivityRowPresentation? {
        switch node.kind {
        case .chatBubble:
            return nil
        case let .systemReminder(id, kind, text, ts, source, truncatedTo):
            return systemReminder(id: id, kind: kind, text: text, timestamp: ts,
                                  source: source, truncatedTo: truncatedTo)
        case let .skillBody(id, text, ts):
            return skillBody(id: id, text: text, timestamp: ts)
        case let .toolCall(id, name, inputJSON, inputTruncatedTo, result, ts):
            return toolCall(
                id: id, name: name, inputJSON: inputJSON,
                inputTruncatedTo: inputTruncatedTo, result: result, timestamp: ts)
        case let .activityGroupSummary(summary):
            return activityGroup(summary)
        case let .subagentSummary(_, count, agentType):
            return subagentSummary(count: count, agentType: agentType)
        }
    }

    private static func activityGroup(_ summary: ActivityGroupSummary) -> ActivityRowPresentation {
        // The whole title is one sentence built by `ActivityGroupSummary`, so
        // this renderer and `ActivityGroupSummaryRow` cannot phrase it
        // differently. One `.secondary` run: the summary is chrome describing
        // work that already happened, so it recedes from the assistant prose it
        // sits between rather than competing with it. `.secondary` (subheadline
        // + `secondaryLabelColor`) is the right weight — `.tertiary` would also
        // drop to caption2, shrinking the row's only text below a glanceable
        // size and drifting from `ActivityGroupSummaryRow`'s subheadline.
        let segments = [ActivityRowSegment(text: summary.activityPhrase, style: .secondary)]
        // Attention badges only. Successful groups say nothing (a "complete"
        // capsule was redundant chrome) and running groups say it in the title's
        // tense — "Running 2 shell commands…" — so no "active" capsule either.
        var badges: [ActivityRowBadge] = []
        if let status = summary.statusLabel {
            badges.append(ActivityRowBadge(
                text: summary.requiresResponse ? "needs response" : status.lowercased(),
                kind: .error
            ))
        }
        return ActivityRowPresentation(
            // No icon: the group summary already announces itself with the
            // persistent disclosure chevron, and a second glyph on the same row
            // was redundant chrome. The title takes the row's leading inset.
            iconSystemName: nil,
            titleSegments: segments,
            timestamp: nil,
            isError: summary.errorCount > 0 || summary.requiresResponse,
            badges: badges,
            openTargetID: summary.id,
            accessorySystemName: summary.isExpanded ? "chevron.down" : "chevron.right",
            accessoryAlwaysVisible: true,
            accessibilityLabel: "\(summary.isExpanded ? "Collapse" : "Expand") "
                + summary.activityPhrase
                + (summary.statusLabel.map { ", \($0)" } ?? "")
        )
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
        case "WebFetch":
            return webTool(id: id, label: "WebFetch", icon: "globe",
                           inputJSON: inputJSON, result: result, timestamp: timestamp)
        case "WebSearch":
            return webTool(id: id, label: "WebSearch", icon: "magnifyingglass",
                           inputJSON: inputJSON, result: result, timestamp: timestamp)
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
            openTargetID: id
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
            openTargetID: id
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
            openTargetID: id
        )
    }

    // MARK: Grep / Glob (GrepCard / GlobCard)

    private struct PatternInput: Decodable {
        let pattern: String
        let path: String?
    }

    /// `WebFetch` carries `url`, `WebSearch` carries `query`. Both optional so a
    /// malformed or unexpected payload degrades to the bare label rather than
    /// dropping the row.
    private struct WebInput: Decodable {
        let url: String?
        let query: String?
    }

    /// Web tools used to fall through to `genericTool`, which never receives
    /// `inputJSON` — so the row rendered as a bare "WebFetch" with no indication
    /// of what was fetched, even though the session index reads the target from
    /// this same payload. Surfacing it here keeps the transcript and the index
    /// telling the same story.
    private static func webTool(
        id: String, label: String, icon: String, inputJSON: String,
        result: ToolResult?, timestamp: Date?
    ) -> ActivityRowPresentation {
        let parsed = decode(WebInput.self, inputJSON)
        let target = parsed?.url ?? parsed?.query
        var segments: [ActivityRowSegment] = [
            ActivityRowSegment(text: label, style: .primary)
        ]
        if let target, !target.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            segments.append(ActivityRowSegment(text: target, style: .secondary))
        }
        var badges: [ActivityRowBadge] = []
        if result?.isError == true {
            badges.append(ActivityRowBadge(text: "error", kind: .error))
        }
        return ActivityRowPresentation(
            iconSystemName: icon,
            titleSegments: segments,
            timestamp: timestamp,
            isError: result?.isError == true,
            badges: badges,
            openTargetID: id,
            titleTruncation: .byTruncatingMiddle,
            titleTooltip: target
        )
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
            openTargetID: id
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
            openTargetID: id
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
            openTargetID: id
        )
    }

    // MARK: System reminder (SystemReminderRow)

    private static func systemReminder(
        id: String, kind: SystemKind, text: String, timestamp: Date?,
        source: String?, truncatedTo: Int?
    ) -> ActivityRowPresentation {
        // Background-task notifications get a richer presentation: a
        // "Background · <summary>" title with the status surfaced as a badge.
        if kind == .taskNotification {
            return taskNotification(id: id, text: text, timestamp: timestamp)
        }

        let label: String = {
            switch kind {
            case .toolReminder: return "system-reminder"
            case .hookOutput: return "hook"
            case .environmentDetails: return "env"
            case .slashEnvelope: return "command"
            case .skillBody: return "skill"
            case .taskNotification: return "background"
            // Covers both an injected CLAUDE.md and an @-mentioned file body;
            // the source segment below carries the path that tells them apart.
            case .nestedMemory: return "file"
            case .other: return "info"
            }
        }()

        // Injected-context rows (hooks, CLAUDE.md) are otherwise near-identical
        // re-injections of the same rule: the source name disambiguates them
        // and the size is the whole point — one 15-line Read can pull 88 KB.
        var segments: [ActivityRowSegment] = []
        if let source, !source.isEmpty {
            segments = [
                ActivityRowSegment(text: source, style: .secondary),
                ActivityRowSegment(text: "·", style: .tertiary),
                ActivityRowSegment(text: injectedSize(text: text, truncatedTo: truncatedTo), style: .tertiary)
            ]
        }

        return ActivityRowPresentation(
            iconSystemName: "info.circle",
            titleSegments: segments,
            timestamp: timestamp,
            isError: false,
            badges: [ActivityRowBadge(text: label, kind: .neutral)],
            openTargetID: id,
            // Path sources head-truncate: the whole filename must survive, and
            // middle truncation kept a short tail that cut into it
            // (`/private/tmp/claude-5…pr-body.md` for `iam-pr-body.md`).
            // Non-path sources keep middle truncation — head-truncating
            // `PostToolUse:Read` would eat the informative front.
            titleTruncation: (kind == .nestedMemory) ? .byTruncatingHead : .byTruncatingMiddle,
            // Truncated paths need hovering to reveal the whole thing. Hook
            // names are short and fully visible — no tooltip for those.
            titleTooltip: (kind == .nestedMemory) ? source.flatMap { $0.isEmpty ? nil : $0 } : nil
        )
    }

    /// Human-readable size of an injected-context payload. `truncatedTo` holds
    /// the ORIGINAL length when `text` was capped, so it wins when present.
    ///
    /// Both numbers are `String.count` — grapheme clusters, not bytes — so the
    /// unit is spelled "chars". Feeding them to `ByteCountFormatter` understated
    /// smart-quote / box-drawing / emoji-heavy CLAUDE.md bodies by up to 4x,
    /// which defeats the badge's whole purpose.
    static func injectedSize(text: String, truncatedTo: Int?) -> String {
        let count = truncatedTo ?? text.count
        if count < 1000 {
            return "\(count) chars"
        }
        // Cascade smallest → largest, picking the first unit whose ROUNDED
        // mantissa stays under 1000 — checking the raw count against a fixed
        // threshold (the old `count >= 1_000_000` shape) lets values like
        // 999_950 round up to "1000.0K" instead of bumping to "1.0M".
        let units: [(divisor: Double, suffix: String)] = [
            (1_000, "K"), (1_000_000, "M"), (1_000_000_000, "G"),
        ]
        for (index, unit) in units.enumerated() {
            let mantissa = (Double(count) / unit.divisor * 10).rounded() / 10
            if mantissa < 1000 || index == units.count - 1 {
                return String(format: "%.1f\(unit.suffix) chars", mantissa)
            }
        }
        return "\(count) chars" // unreachable: loop always returns on its last iteration
    }

    // MARK: Task notification (background-task activity row)

    /// Builds the activity-row presentation for a background-task notification.
    /// Surfaces the `<summary>` as the row title and the `<status>` as a badge;
    /// the full original text remains available via the click-to-open overlay.
    private static func taskNotification(
        id: String, text: String, timestamp: Date?
    ) -> ActivityRowPresentation {
        let (summary, status) = parseTaskNotification(text)
        let titleSegments: [ActivityRowSegment] = [
            ActivityRowSegment(text: "Background", style: .primary),
            ActivityRowSegment(text: "·", style: .tertiary),
            ActivityRowSegment(text: summary, style: .secondary)
        ]
        var badges: [ActivityRowBadge] = []
        if !status.isEmpty {
            let lower = status.lowercased()
            let kind: ActivityRowBadge.Kind =
                (lower.contains("fail") || lower.contains("error")) ? .error : .neutral
            badges.append(ActivityRowBadge(text: status, kind: kind))
        }
        return ActivityRowPresentation(
            iconSystemName: "clock.arrow.circlepath",
            titleSegments: titleSegments,
            timestamp: timestamp,
            isError: false,
            badges: badges,
            openTargetID: id,
            titleTruncation: .byTruncatingTail
        )
    }

    /// Extracts `(summary, status)` from a `<task-notification>` envelope using
    /// plain string scanning (no regex). Returns the substrings between
    /// `<summary>…</summary>` and `<status>…</status>`, trimmed. When `<summary>`
    /// is absent, falls back to the status (or "Background task" if neither is
    /// present). The status component is "" when absent.
    static func parseTaskNotification(_ text: String) -> (summary: String, status: String) {
        let summary = extractTagBody(in: text, tag: "summary") ?? ""
        let status = extractTagBody(in: text, tag: "status") ?? ""
        let resolvedSummary: String
        if !summary.isEmpty {
            resolvedSummary = summary
        } else if !status.isEmpty {
            resolvedSummary = status
        } else {
            resolvedSummary = "Background task"
        }
        return (resolvedSummary, status)
    }

    /// Returns the trimmed substring between `<tag>` and `</tag>`, or nil.
    private static func extractTagBody(in text: String, tag: String) -> String? {
        let open = "<\(tag)>"
        let close = "</\(tag)>"
        guard
            let openRange = text.range(of: open),
            let closeRange = text.range(of: close, range: openRange.upperBound..<text.endIndex)
        else { return nil }
        return text[openRange.upperBound..<closeRange.lowerBound]
            .trimmingCharacters(in: .whitespacesAndNewlines)
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
            openTargetID: id
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
            style: .plainSummary
        )
    }

    // MARK: Decode helper

    private static func decode<T: Decodable>(_ type: T.Type, _ json: String) -> T? {
        guard let data = json.data(using: .utf8) else { return nil }
        return try? decoder.decode(type, from: data)
    }
}
