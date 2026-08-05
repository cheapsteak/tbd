import SwiftUI
import TBDShared

/// One row of the transcript. The view shape adapts to whether a usage badge
/// is present: `content` is returned bare for the common badge-less row, and is
/// wrapped in a `VStack` (content above an inlined `ContextUsageBadge`) only
/// when `node.badgeUsage` is non-nil. Dropping the wrapper `VStack` from
/// badge-less rows removes a redundant per-row `StackLayout` node from the
/// measure pass — the dominant symbol in the issue #129 activation freeze.
/// ForEach homogeneity is preserved: the parent `ForEach` still sees a single
/// `SelectableTranscriptRow`/`TranscriptRow` type. Both the internal `switch`
/// on `node.kind` and the badge `_ConditionalContent` live behind this struct's
/// `some View` type boundary — see issue #129 / the transcript-render-node
/// design doc.
struct TranscriptRow: View {
    let node: TranscriptRenderNode
    let terminalID: UUID?

    /// When true, cards in this row render statically (no expand/collapse). Set
    /// by the NSTableView pane via `EnvironmentValues.transcriptStaticCards` so
    /// historic `AskUserQuestionCard`s are non-interactive; the live SwiftUI pane
    /// leaves it false. (#129)
    @Environment(\.transcriptStaticCards) private var staticCards

    var body: some View {
        // Per-row signpost so a hang trace identifies which row was being
        // evaluated when the main thread stalled. Metadata (kind, length, id)
        // is passed on the begin call — see docs/diagnostics-strategy.md
        // ("Capturing a transcript-perf trace") and issue #129.
        let kind = TranscriptSignposts.kindLabel(for: node)
        let len = TranscriptSignposts.contentLength(for: node)
        let state = TranscriptSignposts.signposter.beginInterval(
            "transcript.row.body",
            id: TranscriptSignposts.signposter.makeSignpostID(),
            "id=\(node.id, privacy: .public) kind=\(kind, privacy: .public) len=\(len, privacy: .public)"
        )
        defer { TranscriptSignposts.signposter.endInterval("transcript.row.body", state) }
        return rowBody
    }

    @ViewBuilder
    private var rowBody: some View {
        // Per-row layout-depth flattening (issue #129 / continuing PR #278):
        // the wrapper VStack exists ONLY to stack an optional ContextUsageBadge
        // under the content. The vast majority of rows have no badge
        // (badgeUsage == nil), so returning `content` bare drops a redundant
        // StackLayout node from every badge-less row's measure pass — the
        // dominant symbol in the #129 activation-freeze spindump. Homogeneity
        // of the parent ForEach is unaffected: it still sees a single
        // SelectableTranscriptRow type; this _ConditionalContent lives entirely
        // behind TranscriptRow's `some View` boundary.
        //
        // Trade-off: because the whole body is now a _ConditionalContent, when a
        // node's badgeUsage flips nil↔non-nil (the badge migrates row→row as new
        // usage arrives during streaming) SwiftUI rebuilds the `content` subtree
        // rather than just toggling the badge. This is acceptable because (a) a
        // badgeUsage change also changes the node's digest, so the ForEach already
        // re-realizes that row in the unflattened baseline — the flatten doesn't
        // add re-realization frequency, only changes what's rebuilt within it; and
        // (b) the badge attaches to the latest usage-carrying item (see
        // TranscriptRenderNode.swift), almost always a stateless `.assistantText`
        // chat bubble — and #129 already moved inline expand/collapse @State out to
        // overlays, so no meaningful per-row state is lost on the toggle.
        if let usage = node.badgeUsage {
            VStack(alignment: .leading, spacing: 2) {
                content
                ContextUsageBadge(total: usage.contextTotal)
                    .padding(.leading, 12)
                    .padding(.top, 2)
            }
        } else {
            content
        }
    }

    @ViewBuilder private var content: some View {
        switch node.kind {
        case .chatBubble(let item):
            ChatBubbleView(item: item)
        case .systemReminder(let id, let kind, let text, let ts, let source, let truncatedTo):
            SystemReminderRow(id: id, kind: kind, text: text, timestamp: ts,
                              source: source, truncatedTo: truncatedTo)
        case .skillBody(let id, let text, let ts):
            SkillBodyRow(id: id, text: text, timestamp: ts)
        case .toolCall(let id, let name, let inputJSON, let inputTruncatedTo, let result, let ts):
            toolCard(id: id, name: name, inputJSON: inputJSON,
                     inputTruncatedTo: inputTruncatedTo, result: result, timestamp: ts)
        case .activityGroupSummary(let summary):
            ActivityGroupSummaryRow(summary: summary)
        case .subagentSummary:
            // Subagent summaries are no longer surfaced in the transcript; the
            // enum case is retained for Codable/source compatibility but is
            // never produced by `transcriptRenderNodes(from:)`.
            EmptyView()
        }
    }

    @ViewBuilder
    private func toolCard(id: String, name: String, inputJSON: String,
                          inputTruncatedTo: Int?, result: ToolResult?, timestamp: Date?) -> some View {
        switch name {
        case "Read":
            ReadCard(id: id, inputJSON: inputJSON, result: result, timestamp: timestamp, terminalID: terminalID)
        case "Edit", "MultiEdit":
            EditCard(id: id, name: name, inputJSON: inputJSON, inputTruncatedTo: inputTruncatedTo, result: result, timestamp: timestamp, terminalID: terminalID)
        case "Write":
            WriteCard(id: id, inputJSON: inputJSON, inputTruncatedTo: inputTruncatedTo, result: result, timestamp: timestamp, terminalID: terminalID)
        case "Bash":
            BashCard(id: id, inputJSON: inputJSON, inputTruncatedTo: inputTruncatedTo, result: result, timestamp: timestamp, terminalID: terminalID)
        case "Grep":
            GrepCard(id: id, inputJSON: inputJSON, result: result, timestamp: timestamp, terminalID: terminalID)
        case "Glob":
            GlobCard(id: id, inputJSON: inputJSON, result: result, timestamp: timestamp, terminalID: terminalID)
        case "Task", "Agent":
            AgentCard(id: id, inputJSON: inputJSON, inputTruncatedTo: inputTruncatedTo, result: result, timestamp: timestamp, terminalID: terminalID)
        case "AskUserQuestion":
            AskUserQuestionCard(id: id, inputJSON: inputJSON, inputTruncatedTo: inputTruncatedTo, result: result, timestamp: timestamp, terminalID: terminalID, staticHeight: staticCards)
        default:
            GenericToolCard(id: id, name: name, inputJSON: inputJSON, inputTruncatedTo: inputTruncatedTo, result: result, timestamp: timestamp, terminalID: terminalID)
        }
    }
}

/// SwiftUI fallback for activity-group summaries. The table renderer uses its
/// native activity cell, but overlays and visual harnesses still need a faithful
/// view with the same disclosure semantics.
struct ActivityGroupSummaryRow: View {
    let summary: ActivityGroupSummary
    @Environment(\.toggleTranscriptActivityGroup) private var toggleGroup

    var body: some View {
        Button {
            toggleGroup?(summary.id, !summary.isExpanded)
        } label: {
            // No leading icon: the persistent disclosure chevron already marks
            // this as a group, so the phrase starts at the row's leading padding
            // (matching the native cell, which collapses its icon column).
            HStack(spacing: 7) {
                // The single shared phrase — the native cell renders this exact
                // string, so the two renderers cannot drift.
                Text(summary.activityPhrase)
                    .font(.system(.subheadline, design: .rounded, weight: .medium))
                    .lineLimit(1)
                Spacer(minLength: 8)
                // Nil — and so nothing rendered — unless the group failed or is
                // waiting on the user; a running group says so in the phrase's
                // tense. Matches the native cell's badge logic.
                if let status = summary.statusLabel {
                    Text(status)
                        .font(.caption2)
                        .foregroundStyle(summary.errorCount > 0 ? Color.red : Color.secondary)
                }
                Image(systemName: summary.isExpanded ? "chevron.down" : "chevron.right")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 5)
            .background(Color(nsColor: .windowBackgroundColor).opacity(0.38))
            .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(
            "\(summary.isExpanded ? "Collapse" : "Expand") \(summary.activityPhrase)"
                + (summary.statusLabel.map { ", \($0)" } ?? "")
        )
    }
}

/// Wraps a single `TranscriptRow` and owns its own hover state, so a hover
/// re-renders ONLY the entered/exited row — the enclosing list body never
/// re-runs on hover. This is the load-bearing half of the issue #129
/// hover-rebuild fix: previously the hovered-row id lived on the list view as
/// `@State`, so every mouse crossing re-ran the whole list body (rebuilding the
/// node array, re-diffing the list, forcing AttributeGraph to deep-copy the
/// input). Mirrors the per-row local-hover pattern already used by
/// `ActivityRowChrome`.
///
/// The selection gate (`transcriptTextSelection`) is materialized only while
/// this row is hovered, preserving the #120 fix that keeps at most one row's
/// `NSTextField` alive at a time and avoids the ~17 s per-row-NSTextField storm.
///
/// Latch decision (issue #129): the previous gate was *latched* — it never
/// cleared on hover-exit so a drag-select that wandered slightly outside the row
/// survived. Per-row local state clears on exit instead, and that is safe:
/// AppKit `NSTrackingArea`s (what SwiftUI `.onHover` is built on) do NOT post
/// `mouseExited` during an active drag unless `.enabledDuringMouseDrag` is set,
/// which `.onHover` does not. So while the button is held during a drag-select,
/// `isHovered` stays `true` and the `NSTextField` is not torn down — the latch
/// was only ever protecting a case AppKit already handles. Trade-off: if the
/// pointer leaves the row with no button held, selection clears, which is
/// acceptable since each row is its own `NSTextField` and selection cannot span
/// rows anyway. This guarantee assumes the drag-select begins inside the row; a
/// drag that starts outside never armed this row's selection in the first place.
struct SelectableTranscriptRow: View {
    let node: TranscriptRenderNode
    let terminalID: UUID?

    @State private var isHovered = false

    var body: some View {
        TranscriptRow(node: node, terminalID: terminalID)
            .environment(\.transcriptTextSelection, isHovered)
            .onHover { isHovered = $0 }
    }
}
