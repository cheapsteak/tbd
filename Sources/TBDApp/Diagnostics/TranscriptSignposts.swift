import Foundation
import TBDShared
import os

/// Shared OSSignposter for `category: "perf-transcript"`. Use `signposter.beginInterval(_:)`
/// + `signposter.endInterval(_:_:)` to scope a region; the resulting intervals show up
/// in Xcode Instruments' "os_signpost" lane and (with the SwiftUI template) alongside
/// view-body / layout events.
///
/// Region names used today (see docs/superpowers/specs/2026-05-11-transcript-render-node-design.md
/// and docs/diagnostics-strategy.md for capture recipes):
/// - "transcript.swap"             — LiveTranscriptPaneView.pollOnce mainActor block
/// - "transcript.items.body"       — TranscriptItemsView.body (whole pass)
/// - "transcript.row.body"         — TranscriptRow.body per row (issue #129 signposts)
/// - "transcript.markdown.build"   — ChatBubbleView.bubbleBody (split + Markdown view tree)
/// - "transcript.markdown.segment" — MarkdownSegments.split
/// - "transcript.scrollTo"         — proxy.scrollTo call sites
///
/// `event` names:
/// - "hang.detected" — emitted from HangWatchdog when a hang transitions to `.toHung`,
///                     so an Instruments trace shows the marker on the same timeline as
///                     the row intervals.
enum TranscriptSignposts {
    nonisolated static let signposter = OSSignposter(subsystem: "com.tbd.app", category: "perf-transcript")

    /// Short, signpost-friendly classification for a transcript render node.
    /// Kept stable and `.public`-safe — no message content, only structural tags.
    nonisolated static func kindLabel(for node: TranscriptRenderNode) -> String {
        switch node.kind {
        case .chatBubble(let item):
            switch item {
            case .userPrompt: return "userPrompt"
            case .assistantText: return "assistantText"
            default: return "chat"
            }
        case .systemReminder: return "systemReminder"
        case .skillBody: return "skillBody"
        case .toolCall(_, let name, _, _, _, _): return "tool:\(name)"
        case .subagentSummary: return "subagentSummary"
        }
    }

    /// Conservative "how big is this row's payload" measurement, in characters.
    /// Used as signpost metadata so the longest `row.body` interval in a hang
    /// trace can be cross-referenced against payload size. Returns 0 when the
    /// node has no obvious text payload (e.g. a subagent summary).
    nonisolated static func contentLength(for node: TranscriptRenderNode) -> Int {
        switch node.kind {
        case .chatBubble(let item):
            switch item {
            case .userPrompt(_, let t, _),
                 .assistantText(_, let t, _, _),
                 .thinking(_, let t, _):
                return t.count
            case .systemReminder(_, _, let t, _):
                return t.count
            case .toolCall(_, _, let inputJSON, _, let result, _, _, _):
                return inputJSON.count + (result?.text.count ?? 0)
            case .slashCommand(_, let name, let args, _):
                return name.count + (args?.count ?? 0)
            }
        case .systemReminder(_, _, let text, _),
             .skillBody(_, let text, _):
            return text.count
        case .toolCall(_, _, let inputJSON, _, let result, _):
            return inputJSON.count + (result?.text.count ?? 0)
        case .subagentSummary:
            return 0
        }
    }
}
