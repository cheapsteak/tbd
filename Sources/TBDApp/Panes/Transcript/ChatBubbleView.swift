import SwiftUI
import TBDShared
import AppKit
import MarkdownUI

/// Resolves a peer sender to the worktree it came from. Nil (the default) leaves
/// a peer bubble's sender header as plain text — the name still renders, it simply
/// is not clickable.
///
/// Injected as a closure rather than an `AppState` so this view stays testable
/// without standing up a pane, and so a host that has no worktree list at all
/// (a preview, a snapshot test) degrades visibly rather than trapping.
private struct TranscriptPeerSenderResolutionKey: EnvironmentKey {
    static let defaultValue: (@MainActor (PeerSender) -> UUID?)? = nil
}

/// Navigates to a worktree — the same entry point `tbd://open?worktree=<uuid>`
/// uses. Nil leaves a resolved sender name unlinked.
private struct TranscriptOpenWorktreeKey: EnvironmentKey {
    static let defaultValue: (@MainActor (UUID) -> Void)? = nil
}

extension EnvironmentValues {
    var transcriptPeerSenderResolution: (@MainActor (PeerSender) -> UUID?)? {
        get { self[TranscriptPeerSenderResolutionKey.self] }
        set { self[TranscriptPeerSenderResolutionKey.self] = newValue }
    }

    var transcriptOpenWorktree: (@MainActor (UUID) -> Void)? {
        get { self[TranscriptOpenWorktreeKey.self] }
        set { self[TranscriptOpenWorktreeKey.self] = newValue }
    }
}

/// The sender attribution drawn above a PEER bubble's body, and above no other.
///
/// Native SwiftUI chrome built from `PeerSender` — the harness-written `origin` —
/// and rendered outside the markdown body, so a peer can neither author its own
/// attribution nor mint a worktree-navigation link inside its message. Mirrors
/// `PeerSenderHeaderView` at the native render site: same glyph, same marker,
/// same three shapes.
///
/// A separate `View` rather than an inline branch so the two environment reads
/// happen ONLY on a peer row — a user or assistant bubble never evaluates them.
///
/// Explicitly `@MainActor` (which conformance to `View` already implies) because
/// its helper properties call the two `@MainActor` environment closures outside
/// `body`, and relying on inference there is exactly the kind of thing that
/// changes under a compiler upgrade.
@MainActor
private struct PeerSenderHeaderRow: View {
    let sender: PeerSender

    @Environment(\.transcriptPeerSenderResolution) private var resolveSender
    @Environment(\.transcriptOpenWorktree) private var openWorktree

    private var name: String { PeerHeaderChrome.displayName(for: sender) }

    /// The worktree to navigate to, or nil when the sender is asserted, does not
    /// resolve, or nothing here can act on it.
    private var target: UUID? {
        guard sender.verified, let resolveSender, openWorktree != nil else { return nil }
        return resolveSender(sender)
    }

    var body: some View {
        HStack(spacing: PeerHeaderChrome.itemSpacing) {
            Text(PeerHeaderChrome.glyph)
                .foregroundStyle(AttentionAmber.color)
                .accessibilityHidden(true)
            attribution
        }
        .font(.system(size: PeerHeaderChrome.fontSize, weight: .semibold))
        .lineLimit(1)
    }

    @ViewBuilder private var attribution: some View {
        if let target, let openWorktree {
            Button { openWorktree(target) } label: {
                Text(name).underline()
            }
            .buttonStyle(.plain)
            .foregroundStyle(Color.accentColor)
            .accessibilityLabel("Go to \(name)")
        } else if sender.verified {
            Text(name)
        } else {
            // An asserted label is a string the sender chose for itself. Muted and
            // italic, and never without its marker: it must not read as a
            // confirmed identity.
            Text(name)
                .italic()
                .foregroundStyle(.secondary)
        }
    }
}

/// Single user/assistant prose bubble. Renders block-level markdown
/// (paragraphs, lists, tables, blockquotes, headings) via MarkdownUI
/// and fenced code blocks via the local `codeBlock(...)` view, with
/// segments partitioned upstream by `MarkdownSegments`.
struct ChatBubbleView: View {
    let item: TranscriptItem

    /// The three bubble shapes this view draws. Mirrors
    /// `TranscriptBubbleGeometry.Role` so the two render sites agree; kept as a
    /// local enum so this view stays free of the geometry helper's `@MainActor`
    /// isolation.
    private enum BubbleRole {
        case user
        case peer
        case assistant
    }

    private var bubbleRole: BubbleRole {
        if case .userPrompt = item { return .user }
        if case .peerMessage = item { return .peer }
        return .assistant
    }

    /// True for the roles drawn on the READER's side of the transcript. A peer
    /// message is a received message shown alongside the reader's own prompts, so
    /// it aligns and pads exactly like a user prompt — only the tint differs. This
    /// drives geometry; tint switches on `bubbleRole` instead.
    private var isUserAligned: Bool { bubbleRole != .assistant }

    private var text: String {
        switch item {
        case .userPrompt(_, let t, _): return t
        case .peerMessage(_, _, let t, _, _): return t
        case .assistantText(_, let t, _, _): return t
        default: return ""
        }
    }

    /// The peer bubble's sender header, and `EmptyView` for every other role.
    ///
    /// `EmptyView` contributes no subview to the enclosing `VStack`, so a user or
    /// assistant bubble's geometry is byte-for-byte what it was — the header line
    /// #129 deleted does not come back for them. Reintroducing it for peer rows
    /// only is acceptable because peer messages are rare; do not add a node to the
    /// common path to make this symmetrical.
    @ViewBuilder private var peerSenderHeader: some View {
        if case .peerMessage(_, let sender, _, _, _) = item {
            PeerSenderHeaderRow(sender: sender)
        }
    }

    private var roleLabel: String {
        switch bubbleRole {
        case .user: return "You"
        case .peer: return "Peer"
        case .assistant: return "Claude"
        }
    }

    /// Role name for the perf signpost only — never drawn.
    private var signpostRoleName: String {
        switch bubbleRole {
        case .user: return "user"
        case .peer: return "peer"
        case .assistant: return "assistant"
        }
    }

    /// Bubble fill. The accent tint says *you*, the amber says *not you*, both at
    /// the same 15% alpha so the two differ in hue alone. Mirrors
    /// `TranscriptBubbleGeometry.backgroundColor(for:)`.
    private var bubbleTint: Color {
        switch bubbleRole {
        case .user: return Color.accentColor.opacity(0.15)
        case .peer: return AttentionAmber.bubbleTintColor
        case .assistant: return Color.clear
        }
    }

    /// Speaker attribution for assistive technology only — never drawn. A
    /// transcript is not a group chat, so the bubble shows no role/timestamp
    /// header and relies on position and tint; VoiceOver has no position cue, so
    /// the bubble carries the attribution as its accessibility label. Mirrors
    /// `TranscriptBubbleGeometry.accessibilityAttribution(for:)`.
    private var accessibilityAttribution: String {
        guard let ts = item.timestamp?.absoluteShort else { return roleLabel }
        return isUserAligned ? "\(ts) · \(roleLabel)" : "\(roleLabel) · \(ts)"
    }

    var body: some View {
        // Flattened row wrapper (issue #129 per-row layout-depth): the prior
        // `HStack { Spacer ; column.frame(maxWidth:.infinity) ; Spacer }` is
        // layout-equivalent to a single column that fills width and reserves the
        // 52pt opposite-side gutter via padding. Dropping the outer HStack +
        // Spacer removes a StackLayout node from every bubble row's measure pass.
        // The role/timestamp header is gone too, which took the enclosing VStack
        // with it — one fewer StackLayout node per bubble row.
        bubbleBody
            .frame(maxWidth: .infinity, alignment: isUserAligned ? .trailing : .leading)
            // Single EdgeInsets folds the 52pt opposite-side gutter into the 8/12
            // chrome insets (12 + 52 = 64) — one _PaddingLayout instead of two,
            // per bubble row. Nested uniform paddings compose additively, so this
            // is layout-identical to the prior two-`.padding` chain. The 8pt
            // top/bottom matches `TranscriptBubbleGeometry.outerVertical`: with no
            // header line between them it is the only thing separating one message
            // from the next.
            .padding(EdgeInsets(
                top: 8,
                leading: isUserAligned ? 64 : 16,
                bottom: 8,
                trailing: 12
            ))
            .accessibilityElement(children: .contain)
            .accessibilityLabel(accessibilityAttribution)
    }

    private var bubbleBody: some View {
        // Wrap the whole bubble-body construction (split + Markdown view tree
        // assembly) so a transcript-perf trace can distinguish "row body slow
        // because markdown" from "row body slow because outer layout". The
        // narrower "transcript.markdown.segment" interval inside split() is
        // still emitted — both will appear in the trace. See issue #129.
        let state = TranscriptSignposts.signposter.beginInterval(
            "transcript.markdown.build",
            id: TranscriptSignposts.signposter.makeSignpostID(),
            "len=\(text.count, privacy: .public) role=\(signpostRoleName, privacy: .public)"
        )
        defer { TranscriptSignposts.signposter.endInterval("transcript.markdown.build", state) }
        let segments = MarkdownSegments.split(text)
        // The 6pt stack spacing is `TranscriptBubbleGeometry.interBlockSpacing`:
        // the header→body gap is the same gap the native cell's block stack puts
        // there, which is the other half of `headerHeight(for: .peer)`.
        return VStack(alignment: .leading, spacing: 6) {
            peerSenderHeader
            ForEach(segments) { seg in
                switch seg {
                case .prose(let p):
                    Markdown(p)
                        .markdownTheme(.chatBubble)
                        .transcriptSelectableText()
                case .code(let lang, let body):
                    codeBlock(language: lang, content: body)
                case .image(let attachment):
                    TranscriptImageAttachmentView(attachment: attachment)
                }
            }
        }
        .padding(EdgeInsets(
            top: 8,
            leading: isUserAligned ? 11 : 0,
            bottom: 8,
            trailing: isUserAligned ? 11 : 0
        ))
        .background(bubbleTint)
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }

    @ViewBuilder
    private func codeBlock(language: String?, content: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            if let language, !language.isEmpty {
                Text(language)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .padding(EdgeInsets(top: 2, leading: 6, bottom: 2, trailing: 6))
                    .background(Color(nsColor: .quaternaryLabelColor).opacity(0.5))
                    .clipShape(Capsule())
            }
            Text(content)
                .font(.system(.body, design: .monospaced))
                .transcriptSelectableText()
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color(nsColor: .textBackgroundColor).opacity(0.6))
                .clipShape(RoundedRectangle(cornerRadius: 6))
        }
    }
}

// MARK: - MarkdownUI theme

/// Chat-bubble-tuned MarkdownUI theme. Built from `Theme.basic` and
/// pared back so the common case — plain prose with inline `**bold**`,
/// `*italic*`, `` `code` ``, `[links]` — is visually indistinguishable
/// from the prior `AttributedString(markdown:)` rendering. Block
/// elements (tables, lists, blockquotes, headings) light up as a
/// byproduct.
extension MarkdownUI.Theme {
    @MainActor static let chatBubble = MarkdownUI.Theme.basic
        .text {
            ForegroundColor(.primary)
        }
        .code {
            FontFamilyVariant(.monospaced)
            FontSize(.em(0.92))
            ForegroundColor(.chatBubbleInlineCode)
        }
        .paragraph { configuration in
            configuration.label
                .fixedSize(horizontal: false, vertical: true)
                .markdownMargin(top: 0, bottom: 16)
        }
        .listItem { configuration in
            configuration.label
                .markdownMargin(top: .em(0.35))
        }
        .list { configuration in
            configuration.label
                .markdownMargin(top: 0, bottom: 16)
        }
        .blockquote { configuration in
            HStack(spacing: 0) {
                RoundedRectangle(cornerRadius: 3)
                    .fill(Color.secondary.opacity(0.4))
                    .relativeFrame(width: .em(0.2))
                configuration.label
                    .markdownTextStyle { ForegroundColor(.secondary) }
                    .relativePadding(.horizontal, length: .em(1))
            }
            .fixedSize(horizontal: false, vertical: true)
        }
        .heading1 { configuration in
            configuration.label
                .markdownMargin(top: .em(0.4), bottom: .em(0.2))
                .markdownTextStyle {
                    FontWeight(.semibold)
                    FontSize(.em(1.4))
                }
        }
        .heading2 { configuration in
            configuration.label
                .markdownMargin(top: .em(0.4), bottom: .em(0.2))
                .markdownTextStyle {
                    FontWeight(.semibold)
                    FontSize(.em(1.2))
                }
        }
        .heading3 { configuration in
            configuration.label
                .markdownMargin(top: .em(0.4), bottom: .em(0.2))
                .markdownTextStyle {
                    FontWeight(.semibold)
                    FontSize(.em(1.05))
                }
        }
        .heading4 { configuration in
            configuration.label
                .markdownMargin(top: .em(0.4), bottom: .em(0.2))
                .markdownTextStyle { FontWeight(.semibold) }
        }
        .heading5 { configuration in
            configuration.label
                .markdownMargin(top: .em(0.4), bottom: .em(0.2))
                .markdownTextStyle { FontWeight(.semibold) }
        }
        .heading6 { configuration in
            configuration.label
                .markdownMargin(top: .em(0.4), bottom: .em(0.2))
                .markdownTextStyle { FontWeight(.semibold) }
        }
        .table { configuration in
            configuration.label
                .fixedSize(horizontal: false, vertical: true)
                .markdownTableBorderStyle(
                    .init(color: .secondary.opacity(0.3))
                )
                .markdownTableBackgroundStyle(
                    .alternatingRows(
                        Color.clear,
                        Color.primary.opacity(0.05)
                    )
                )
                .markdownMargin(top: 0, bottom: 0)
        }
        .tableCell { configuration in
            configuration.label
                .markdownTextStyle {
                    if configuration.row == 0 {
                        FontWeight(.semibold)
                    }
                    BackgroundColor(nil)
                }
                .fixedSize(horizontal: false, vertical: true)
                .padding(.vertical, 4)
                .padding(.horizontal, 8)
        }
        .thematicBreak {
            Divider()
                .markdownMargin(top: .em(0.25), bottom: .em(0.25))
        }
}

extension Color {
    /// Inline code foreground — desaturated cool/blue. Matches the
    /// Claude Code terminal style: rgb(172,179,209) on dark, mirrored
    /// to a dark slate blue on light. Distinguishes inline code from
    /// surrounding body text without competing visually.
    static let chatBubbleInlineCode = Color(
        light: Color(red: 82.0/255, green: 88.0/255, blue: 130.0/255),
        dark: Color(red: 172.0/255, green: 179.0/255, blue: 209.0/255)
    )
}

// MARK: - Preview

/// Exercises the chat-bubble Markdown rendering path. Uses
/// `PreviewProvider` (not the `#Preview` macro) so the file still
/// compiles under bare `swift build` — the SPM toolchain doesn't ship
/// the `PreviewsMacros` plugin that Xcode injects.
struct ChatBubbleView_Previews: PreviewProvider {
    static let inlineProse = """
    Plain prose with **bold**, *italic*, `inline code`, and a [link](https://example.com).
    """

    static let tableProse = """
    Here are the span kinds we emit:

    | span_kind | Where |
    |---|---|
    | copy_context_suggestion | copy-context |
    | research_report | all research-pipeline steps share this kind |
    """

    static let listProse = """
    ## Next steps

    - First item
    - Second item with `code`
    - Third item
    """

    static let blockquoteProse = """
    > A quoted note from earlier in the thread.
    > Continues onto a second line.
    """

    static let fencedProse = """
    Here is some Swift:

    ```swift
    func greet(_ name: String) -> String {
        return "Hello, \\(name)"
    }
    ```
    """

    static var previews: some View {
        // PreviewProvider only, not in LazyVStack — see #129
        // swiftlint:disable:next no_scrollview_in_transcript_cards
        ScrollView {
            VStack(spacing: 8) {
                ChatBubbleView(item: .assistantText(id: "a1", text: inlineProse, timestamp: nil))
                ChatBubbleView(item: .assistantText(id: "a2", text: tableProse, timestamp: nil))
                ChatBubbleView(item: .assistantText(id: "a3", text: listProse, timestamp: nil))
                ChatBubbleView(item: .assistantText(id: "a4", text: blockquoteProse, timestamp: nil))
                ChatBubbleView(item: .assistantText(id: "a5", text: fencedProse, timestamp: nil))
            }
            .padding()
        }
        .frame(width: 560, height: 720)
        // Match ChatBubbleParityPreviews: previews have no enclosing
        // transcript pane to flip the env, so force-enable
        // text selection for review ergonomics.
        .environment(\.transcriptTextSelection, true)
    }
}

/// Side-by-side parity preview: renders the SAME prose with the OLD
/// `Text(AttributedString(markdown:, options: .inlineOnlyPreservingWhitespace))`
/// path on the left and the NEW `Markdown(...).markdownTheme(.chatBubble)`
/// path on the right. For pure inline prose the two columns should
/// visually overlay; tables, lists, etc. only render on the right
/// (expected — they're block-level features the old path can't show).
struct ChatBubbleParityPreviews: PreviewProvider {
    static let sampleA = """
    Plain prose with **bold**, *italic*, `inline code`, and a [link](https://example.com).

    A second paragraph follows after a blank line. It should sit one body-line-height below the first paragraph, no more, no less.

    And a third paragraph for good measure, so we can eyeball the inter-paragraph gap multiple times.
    """

    static let sampleB = """
    Short opener.

    A longer paragraph that wraps across multiple lines so we can see the intra-paragraph leading clearly. The lines within this paragraph should have zero extra spacing — only the natural body-font line height. If they look airy, the `relativeLineSpacing` is wrong.
    """

    static let sampleC = """
    One-liner with `code`.

    Another paragraph with **strong** and *emph* and a [link](https://example.com) all inline.
    """

    private static let bubbleBg: Color = Color(nsColor: .controlBackgroundColor)

    @ViewBuilder
    private static func oldBubble(_ prose: String) -> some View {
        let attr = (try? AttributedString(
            markdown: prose,
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        )) ?? AttributedString(prose)
        Text(attr)
            .font(.body)
            .transcriptSelectableText()
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 11)
            .padding(.vertical, 8)
            .background(bubbleBg)
            .clipShape(RoundedRectangle(cornerRadius: 10))
    }

    @ViewBuilder
    private static func newBubble(_ prose: String) -> some View {
        Markdown(prose)
            .markdownTheme(.chatBubble)
            .transcriptSelectableText()
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 11)
            .padding(.vertical, 8)
            .background(bubbleBg)
            .clipShape(RoundedRectangle(cornerRadius: 10))
    }

    @ViewBuilder
    private static func row(_ prose: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text("OLD: Text(AttributedString)").font(.caption2).foregroundStyle(.tertiary)
                oldBubble(prose)
            }
            VStack(alignment: .leading, spacing: 4) {
                Text("NEW: Markdown + chatBubble theme").font(.caption2).foregroundStyle(.tertiary)
                newBubble(prose)
            }
        }
    }

    static var previews: some View {
        // PreviewProvider only, not in LazyVStack — see #129
        // swiftlint:disable:next no_scrollview_in_transcript_cards
        ScrollView {
            VStack(spacing: 16) {
                row(sampleA)
                Divider()
                row(sampleB)
                Divider()
                row(sampleC)
            }
            .padding()
        }
        .frame(width: 900, height: 800)
        // Previews have no enclosing transcript pane to flip the
        // env. Force-enable here so reviewers can still copy
        // text out of the preview while inspecting layout parity.
        .environment(\.transcriptTextSelection, true)
    }
}
