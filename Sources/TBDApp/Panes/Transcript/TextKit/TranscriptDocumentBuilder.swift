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
            let isUser: Bool
            if case .userPrompt = item { isUser = true } else { isUser = false }
            let header = roleHeader(for: item)
            out.append(header)
            // Body range starts after the header; the bubble chrome wraps only
            // this span (header label sits above the bubble, as in ChatBubbleView).
            let bodyStart = header.length
            out.append(MarkdownAttributedRenderer.render(bodyText(for: item)))
            appendBadge(node.badgeUsage, into: out)
            let bodyEnd = out.length
            // Reserve a gap between the header and the drawn card so the header
            // sits ABOVE the card with clearance (not painted over the top
            // border). The bubble's top edge is the body top minus
            // `BubbleBackgroundView.vInset`; making the body's first paragraph
            // start `headerBodyGap` below the header keeps that edge below the
            // header. (#129)
            applyHeaderBodyGap(to: out, bodyRange: NSRange(location: bodyStart, length: bodyEnd - bodyStart))
            out.append(NSAttributedString(string: "\n"))
            // Lay the user prompt over to the right (narrower, right-aligned) so
            // its drawn bubble mirrors `ChatBubbleView`'s right-aligned blue
            // bubble; the assistant block stays full-width for its bordered card.
            // (#129)
            if isUser { applyUserAlignment(to: out) }
            // Stamp the role on the body so the text view draws a bubble behind it.
            if bodyEnd > bodyStart {
                let role: BubbleRole = isUser ? .user : .assistant
                out.addAttribute(
                    .transcriptBubbleRole,
                    value: role.attributeValue,
                    range: NSRange(location: bodyStart, length: bodyEnd - bodyStart)
                )
            }
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

    /// Classifies a render node for chat-bubble background drawing. Only
    /// `.chatBubble` nodes get a user/assistant bubble; everything else draws
    /// its own chrome (tool cards) or none. (#129)
    static func bubbleRole(for node: TranscriptRenderNode) -> BubbleRole {
        guard case let .chatBubble(item) = node.kind else { return .other }
        if case .userPrompt = item { return .user }
        return .assistant
    }

    /// Character length of the role-header prefix ("You\n" / "Claude\n") a
    /// chat-bubble fragment begins with. The renderer subtracts this from the
    /// block's range so the drawn bubble wraps only the body — the header label
    /// sits ABOVE/outside the bubble, mirroring `ChatBubbleView`. Non-bubble
    /// nodes have no header. (#129)
    static func headerLength(for node: TranscriptRenderNode) -> Int {
        guard case let .chatBubble(item) = node.kind else { return 0 }
        let isUser: Bool
        if case .userPrompt = item { isUser = true } else { isUser = false }
        // Matches `roleHeader`: "<label>\n".
        return (isUser ? "You" : "Claude").count + 1
    }

    // MARK: - Private helpers

    /// Width fraction of the content column the user prompt's text may occupy.
    /// The drawn bubble hugs the right edge, so the remaining gutter sits on the
    /// LEFT — mirroring `ChatBubbleView`'s right-aligned narrower user bubble.
    private static let userBubbleWidthFraction: CGFloat = 0.62

    /// Right-aligns the whole user message (header + body) and pushes its text
    /// into the right portion of the column via a head indent, so the segment
    /// union the renderer draws a bubble around lands on the right and is
    /// narrower than full width. We rewrite each run's paragraph style rather
    /// than blanket-replacing so list indents etc. from the markdown renderer
    /// are preserved while gaining `.right` alignment + the left gutter.
    private static func applyUserAlignment(to out: NSMutableAttributedString) {
        let full = NSRange(location: 0, length: out.length)
        // Approximate the content column width; the head indent is resolved as a
        // fraction of it. 680pt matches the transcript content column / harness
        // width. Slightly conservative so wrapping doesn't overflow the bubble.
        let columnWidth: CGFloat = 680
        let leftGutter = columnWidth * (1 - userBubbleWidthFraction)
        out.enumerateAttribute(.paragraphStyle, in: full, options: []) { value, range, _ in
            let style = (value as? NSParagraphStyle).map {
                // swiftlint:disable:next force_cast
                $0.mutableCopy() as! NSMutableParagraphStyle
            } ?? NSMutableParagraphStyle()
            style.alignment = .right
            style.headIndent = max(style.headIndent, leftGutter)
            style.firstLineHeadIndent = max(style.firstLineHeadIndent, leftGutter)
            // Inset the text's RIGHT edge inward by the bubble's interior padding so
            // right-aligned wrapped lines stop short of the container margin (a
            // negative `tailIndent` is measured from the container's right edge).
            // Without this, multi-line user text runs flush to / past the drawn
            // bubble's right edge. The matching `hInset` in `BubbleBackgroundView`
            // grows the bubble back out so the text sits inside with symmetric
            // horizontal padding. (#129)
            style.tailIndent = -BubbleRole.horizontalPadding
            out.addAttribute(.paragraphStyle, value: style, range: range)
        }
    }

    /// Adds `BubbleRole.headerBodyGap` of leading space before the body's FIRST
    /// paragraph so the drawn card starts below the header with clearance. Only
    /// the first paragraph is touched (the `\n`-delimited prefix of `bodyRange`)
    /// so internal paragraph spacing inside the message is unchanged. (#129)
    private static func applyHeaderBodyGap(to out: NSMutableAttributedString, bodyRange: NSRange) {
        guard bodyRange.length > 0 else { return }
        // First paragraph = body start up to (and including) the first newline.
        let text = out.string as NSString
        let firstNewline = text.range(
            of: "\n",
            options: [],
            range: bodyRange
        )
        let firstParagraphEnd = firstNewline.location == NSNotFound
            ? bodyRange.location + bodyRange.length
            : firstNewline.location
        let firstParagraph = NSRange(
            location: bodyRange.location,
            length: firstParagraphEnd - bodyRange.location
        )
        guard firstParagraph.length > 0 else { return }
        out.enumerateAttribute(.paragraphStyle, in: firstParagraph, options: []) { value, range, _ in
            let style = (value as? NSParagraphStyle).map {
                // swiftlint:disable:next force_cast
                $0.mutableCopy() as! NSMutableParagraphStyle
            } ?? NSMutableParagraphStyle()
            style.paragraphSpacingBefore = max(style.paragraphSpacingBefore, BubbleRole.headerBodyGap)
            out.addAttribute(.paragraphStyle, value: style, range: range)
        }
    }

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
