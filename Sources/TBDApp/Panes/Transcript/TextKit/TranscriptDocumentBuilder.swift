import AppKit
import TBDShared

/// Converts a `TranscriptRenderNode` into an `NSAttributedString` fragment
/// for the TextKit 2 document layer. Pure-text nodes (chat bubbles, subagent
/// summaries) return role header + markdown body + optional usage badge;
/// interactive nodes (tool calls, system reminders, skill bodies) return a
/// single `TranscriptCardAttachment` keyed to `node.id`. (#129)
@MainActor
enum TranscriptDocumentBuilder {

    // MARK: - Public API

    /// Returns an `NSAttributedString` fragment for `node`. Each fragment ends
    /// with a trailing newline so the document's paragraphs are separated.
    static func fragment(
        for node: TranscriptRenderNode,
        context: TranscriptCardContext
    ) -> NSAttributedString {
        switch node.kind {

        case let .chatBubble(item):
            let out = NSMutableAttributedString()
            out.append(roleHeader(for: item))
            out.append(MarkdownAttributedRenderer.render(bodyText(for: item)))
            appendBadge(node.badgeUsage, into: out)
            out.append(NSAttributedString(string: "\n"))
            return out

        case let .subagentSummary(_, count, agentType):
            let label: String
            if let agentType {
                label = "\(count) subagent \(count == 1 ? "activity" : "activities") · \(agentType)\n"
            } else {
                label = "\(count) subagent \(count == 1 ? "activity" : "activities")\n"
            }
            return NSAttributedString(
                string: label,
                attributes: [
                    .font: TranscriptTextTheme.chatBubble.bodyFont,
                    .foregroundColor: NSColor.secondaryLabelColor
                ]
            )

        case .systemReminder, .skillBody, .toolCall:
            guard let card = TranscriptCardFactory.card(for: node, context: context) else {
                // Unreachable in practice: card(for:) returns nil only for
                // AskUserQuestion with nil appState; callers of this builder
                // supply a non-nil appState for those nodes in the live pane.
                return NSAttributedString(string: "")
            }
            let attachment = TranscriptCardAttachment(nodeID: node.id, card: card)
            let out = NSMutableAttributedString(
                attributedString: NSAttributedString(attachment: attachment)
            )
            appendBadge(node.badgeUsage, into: out)
            out.append(NSAttributedString(string: "\n"))
            return out
        }
    }

    // MARK: - Private helpers

    /// Extracts the plain text body from a chat-bubble item. Mirrors the
    /// `text` computed var in `ChatBubbleView` (userPrompt → second payload,
    /// assistantText → second payload, all others → empty).
    private static func bodyText(for item: TranscriptItem) -> String {
        switch item {
        case .userPrompt(_, let text, _): return text
        case .assistantText(_, let text, _, _): return text
        default: return ""
        }
    }

    /// Styled role-label paragraph ("You" / "Claude") with the same caption2
    /// font and tertiary color used by `ChatBubbleView.roleHeader`.
    private static func roleHeader(for item: TranscriptItem) -> NSAttributedString {
        let isUser: Bool
        if case .userPrompt = item { isUser = true } else { isUser = false }
        let label = isUser ? "You" : "Claude"
        return NSAttributedString(
            string: "\(label)\n",
            attributes: [
                .font: NSFont.preferredFont(forTextStyle: .caption2),
                .foregroundColor: NSColor.tertiaryLabelColor
            ]
        )
    }

    /// Appends a muted "NNk tokens" badge line, mirroring `ContextUsageBadge`
    /// (9 pt, secondary color, 0.7 opacity).
    private static func appendBadge(_ usage: TokenUsage?, into out: NSMutableAttributedString) {
        guard let usage else { return }
        let total = usage.inputTokens + usage.cacheCreationTokens + usage.cacheReadTokens
        let badgeText = ContextUsageBadge.formatted(total)
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 9),
            .foregroundColor: NSColor.secondaryLabelColor.withAlphaComponent(0.7)
        ]
        out.append(NSAttributedString(string: "\n\(badgeText)", attributes: attrs))
    }
}
