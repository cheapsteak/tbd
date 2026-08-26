import AppKit
import SwiftUI
import TBDShared

/// Chrome the peer sender header is built from, shared verbatim by the two
/// render sites (`TranscriptBubbleCellView` here, `ChatBubbleView` in SwiftUI).
///
/// Deliberately NOT nested inside `TranscriptBubbleGeometry`: these are plain
/// values with no AppKit isolation, so the SwiftUI bubble can read them and stay
/// free of that helper's `@MainActor` isolation.
///
/// Everything here is derived from the harness-written `origin` — never from the
/// agent-authored message body — so a peer can neither author its own
/// attribution nor mint a worktree-navigation link inside its message. See
/// `docs/specs/2026-08-25-peer-message-attribution-design.md`, "Rendering".
enum PeerHeaderChrome {
    /// Sender glyph. Says "this arrived from elsewhere" before a word is read.
    static let glyph = "\u{21C4}"
    /// Point size of the header line, on both render sites.
    static let fontSize: CGFloat = 11
    /// Horizontal gap between the glyph and the sender name.
    static let itemSpacing: CGFloat = 4
    /// Marker appended to a self-asserted sender label.
    ///
    /// `origin.from` is sender-asserted: anything running as the same OS user can
    /// set it. Drawing it bare would present a self-chosen string as a confirmed
    /// identity, so it never appears without this.
    static let assertedSuffix = " (unverified)"

    /// What the header draws for `sender`: the verified peer name, or the raw
    /// asserted label carrying `assertedSuffix`.
    static func displayName(for sender: PeerSender) -> String {
        guard sender.verified, let name = sender.name, !name.isEmpty else {
            return sender.from + assertedSuffix
        }
        return name
    }
}

/// The sender attribution one peer bubble draws above its body.
///
/// A value, not a view: both render sites build it from `PeerSender` plus the
/// worktree list, and a test can assert the whole decision — name, marker,
/// whether a link is offered — without standing up a pane.
struct TranscriptPeerHeader {
    /// Drawn label — a verified peer name, or the asserted label plus its marker.
    let name: String
    /// Whether the harness verified the peer socket and pid behind this message.
    let verified: Bool
    /// The worktree this sender resolved to, or nil. Nil renders as plain text:
    /// the name still shows, it simply is not clickable. An archived sender and a
    /// duplicated display name both land here — a visible degradation rather than
    /// a silent one, and never a navigation to the wrong session.
    let worktreeID: UUID?
    /// Follows a resolved sender. Nil leaves the name plain even when it
    /// resolved — the affordance is only offered where something can act on it.
    let navigate: (@MainActor (UUID) -> Void)?

    /// Whether the header offers a click target. An asserted sender never does:
    /// there is no verified identity to navigate to.
    var isLink: Bool { verified && worktreeID != nil && navigate != nil }
}

/// Shared geometry + content helpers for the block-based chat-bubble cell.
///
/// A message is an ordered list of typed `MessageBlock`s (prose / table) rendered
/// into ONE bubble as a vertical stack. `heightOfRow` (measure) and `viewFor`
/// (render) both flow through the SAME `bodyWidth(columnWidth:role:)` — called with
/// the SAME role — and the SAME `[MessageBlock]`, so the row height and the cell's
/// drawn height cannot drift. The body width is now role-dependent (see
/// `outerHorizontal(for:)`), but measure and render still agree because they share
/// the role. Mirrors `ChatBubbleView`'s chrome (#129).
@MainActor
enum TranscriptBubbleGeometry {
    enum Role {
        case user
        /// A message received from another agent session. Aligns and pads exactly
        /// like `.user` — it is a received message shown on the reader's side of
        /// the transcript — and differs from it only in tint.
        case peer
        case assistant
    }

    // MARK: Chrome constants (mirror ChatBubbleView)

    /// Outer leading+trailing padding. User bubbles fold a 52pt opposite-side
    /// gutter into the far inset (12 + 64 = 76) so they read as a right-anchored
    /// chat bubble. Assistant messages drop the gutter entirely (12 + 12 = 24) and
    /// span the full column width.
    static func outerHorizontal(for role: Role, columnWidth: CGFloat) -> CGFloat {
        switch role {
        case .user, .peer: return columnWidth < 680 ? 24 : 76
        case .assistant: return 24
        }
    }
    /// Chrome inset on the bubble's own side (12pt). For a user bubble the opposite
    /// side additionally carries the 52pt gutter (12 + 52 = 64); an assistant bubble
    /// carries just the 12pt chrome inset on the opposite side (no gutter).
    static let outerNear: CGFloat = 12
    /// Outer top/bottom padding. Bubbles carry no role/timestamp header — position
    /// alone says who spoke — so this inset is the ONLY thing separating one
    /// message from the next, and it absorbs the vertical role the header line used
    /// to play: 8pt per side gives a 16pt gutter between adjacent bubbles.
    static let outerVertical: CGFloat = 8
    /// bubbleBody inner horizontal insets. User bubbles keep an 11pt inset on each
    /// side (visible chat-bubble padding). Assistant messages have no visible bubble,
    /// so they use ZERO horizontal inset — content sits flush at the box edge so it
    /// aligns with the 12pt tool-row inset.
    static func bodyHorizontal(for role: Role) -> CGFloat {
        switch role {
        case .user, .peer: return 22
        case .assistant: return 0
        }
    }
    /// bubbleBody inner vertical insets (8 top + 8 bottom).
    static let bodyVertical: CGFloat = 16
    /// Bubble corner radius.
    static let cornerRadius: CGFloat = 10
    /// Vertical gap BETWEEN stacked blocks inside one bubble (prose→table etc.).
    static let interBlockSpacing: CGFloat = 6

    /// Single source of truth for the text container width used by BOTH the
    /// measurer and the cell's NSTextView. Role-dependent — a user bubble folds the
    /// 52pt opposite-side gutter into its outer inset (narrower body), while an
    /// assistant bubble drops the gutter and spans the full column. Measure and
    /// render pass the SAME role, so heights can't drift.
    static func bodyWidth(columnWidth: CGFloat, role: Role) -> CGFloat {
        max(columnWidth - outerHorizontal(for: role, columnWidth: columnWidth) - bodyHorizontal(for: role), 1)
    }

    /// Font of the peer sender header. Small and semibold — chrome, not content.
    static let peerHeaderFont = NSFont.systemFont(
        ofSize: PeerHeaderChrome.fontSize, weight: .semibold)

    /// Height of the peer sender header line. `defaultLineHeight(for:)` is the
    /// canonical single-line height of a font — the same quantity a one-line
    /// `NSTextField` lays out at — plus 2pt so a descender is never clipped.
    ///
    /// The header view is pinned to exactly this constant by a constraint, the
    /// way every message block is, so the realized height is this number whatever
    /// the label's intrinsic size turns out to be. That is what keeps measure and
    /// render in agreement rather than an assumption about AppKit's metrics.
    static let peerHeaderLineHeight: CGFloat =
        ceil(NSLayoutManager().defaultLineHeight(for: peerHeaderFont)) + 2

    /// Extra vertical budget a role's bubble carries ABOVE its message blocks.
    ///
    /// A peer bubble draws a sender header as the FIRST arranged subview of the
    /// same block stack its message blocks live in, so it costs one header line
    /// plus the one `interBlockSpacing` gap the stack puts between the header and
    /// the first block. Every other role still draws no header at all and budgets
    /// nothing — position and tint say who spoke.
    ///
    /// The `interBlockSpacing` term over-reserves by exactly that gap for a peer
    /// message that renders to NO blocks at all (only raw HTML, say), because the
    /// stack then has nothing to space the header against. Over-reserving leaves
    /// a hair of empty space; it can never clip, which is the direction that
    /// matters.
    static func headerHeight(for role: Role) -> CGFloat {
        switch role {
        case .peer: return peerHeaderLineHeight + interBlockSpacing
        case .user, .assistant: return 0
        }
    }

    /// Total row height from an ALREADY-REALIZED stack height — one whose peer
    /// header, if any, is already part of `stackHeight`. Adds only the fixed
    /// chrome (body vertical insets + outer vertical padding).
    static func rowHeight(stackHeight: CGFloat) -> CGFloat {
        stackHeight + bodyVertical + outerVertical * 2
    }

    /// Total row height from MEASURED block heights: summed block heights +
    /// inter-block spacing, plus the role's header budget, plus fixed chrome.
    ///
    /// The role is required rather than defaulted so every caller states which
    /// bubble it is sizing. A `.user` or `.assistant` bubble still carries no
    /// header line at all, so its arithmetic is byte-for-byte what it was.
    static func rowHeight(blocksHeight: CGFloat, role: Role) -> CGFloat {
        rowHeight(stackHeight: blocksHeight + headerHeight(for: role))
    }

    /// The sender attribution a peer bubble draws, or nil for every other item
    /// kind — nothing else in the transcript has a sender to attribute.
    ///
    /// Pure: the worktree list is a parameter and resolution goes through
    /// `PeerSenderResolver`, which refuses to guess between duplicate display
    /// names. No I/O, no registry lookup, no singletons.
    static func peerHeader(
        for item: TranscriptItem,
        worktrees: [Worktree],
        navigate: (@MainActor (UUID) -> Void)?
    ) -> TranscriptPeerHeader? {
        guard case .peerMessage(_, let sender, _, _, _) = item else { return nil }
        return TranscriptPeerHeader(
            name: PeerHeaderChrome.displayName(for: sender),
            verified: sender.verified,
            worktreeID: PeerSenderResolver.resolve(sender, worktrees: worktrees),
            navigate: navigate)
    }

    static func role(for item: TranscriptItem) -> Role {
        if case .userPrompt = item { return .user }
        if case .peerMessage = item { return .peer }
        return .assistant
    }

    /// Speaker attribution for ASSISTIVE technology only — it is deliberately not
    /// drawn. The bubble shows no role/timestamp header (position says who spoke),
    /// but VoiceOver has no position cue, so the cell carries this as its
    /// accessibility label: user reads "ts · You", assistant "Claude · ts".
    static func accessibilityAttribution(for item: TranscriptItem) -> String {
        let ts = item.timestamp?.absoluteShort
        switch role(for: item) {
        case .user:
            if let ts { return "\(ts) · You" }
            return "You"
        case .peer:
            // Position and tint say "received from elsewhere"; VoiceOver perceives
            // neither, so the cell speaks it.
            if let ts { return "\(ts) · Peer" }
            return "Peer"
        case .assistant:
            if let ts { return "Claude · \(ts)" }
            return "Claude"
        }
    }

    /// Body text of a chat-bubble item (only userPrompt/assistantText reach here).
    static func text(for item: TranscriptItem) -> String {
        switch item {
        case .userPrompt(_, let t, _): return t
        case .peerMessage(_, _, let t, _, _): return t
        case .assistantText(_, let t, _, _): return t
        default: return ""
        }
    }

    /// The message's blocks: rendered markdown split at GFM tables, with the
    /// token-usage badge (when present) appended to the LAST prose block — or, if
    /// the message ends in a table (or has no prose), a trailing prose block
    /// carrying just the badge. Matches `ContextUsageBadge` styling (font size 9,
    /// secondaryLabelColor). (#129)
    static func composedBlocks(
        for item: TranscriptItem,
        badgeUsage: TokenUsage?,
        linkResolver: TranscriptPathResolver?
    ) -> [MessageBlock] {
        var blocks = MarkdownAttributedRenderer.renderBlocks(
            text(for: item), theme: .chatBubble, linkResolver: linkResolver)
        guard let usage = badgeUsage else { return blocks }

        let badge = NSAttributedString(
            string: ContextUsageBadge.formatted(usage.contextTotal),
            attributes: [
                .font: NSFont.systemFont(ofSize: 9),
                .foregroundColor: NSColor.secondaryLabelColor
            ]
        )

        // Append to the last prose block if one exists; otherwise add a trailing
        // prose block holding the badge alone.
        if let lastProseIndex = blocks.lastIndex(where: { if case .prose = $0 { return true } else { return false } }),
           case .prose(let existing) = blocks[lastProseIndex] {
            let merged = NSMutableAttributedString(attributedString: existing)
            merged.append(NSAttributedString(string: "\n"))
            merged.append(badge)
            blocks[lastProseIndex] = .prose(merged)
        } else {
            blocks.append(.prose(badge))
        }
        return blocks
    }

    /// Bubble background color for a role (matches ChatBubbleView).
    ///
    /// The accent tint says *you*; the amber says *not you*. Same 15% alpha on
    /// both, so the two bubbles differ in hue alone and a reader tells them apart
    /// at a glance without reading a word.
    static func backgroundColor(for role: Role) -> NSColor {
        switch role {
        case .user: return NSColor.controlAccentColor.withAlphaComponent(0.15)
        case .peer: return AttentionAmber.bubbleTint
        case .assistant: return .clear
        }
    }
}

/// A reusable TextKit-1 scratch stack (storage + layout manager + container) that
/// measures the used height of an attributed string at a fixed width.
///
/// TextKit 1's `usedRect(for:)` is the fast, exact, stable height primitive — no
/// TextKit-2 `usageBounds` over-measure (TK2 added phantom lines for the table
/// attachment), no 5s precompute. The bubble's prose `NSTextView` is also TextKit
/// 1 (it never touches `textLayoutManager`), so the measured height equals the
/// cell's drawn text height. `lineFragmentPadding == 0` matches the cell's
/// container. (#129)
@MainActor
final class TranscriptBubbleMeasurer {
    private let textStorage = NSTextStorage()
    private let layoutManager = NSLayoutManager()
    private let container: NSTextContainer

    init() {
        container = NSTextContainer(size: NSSize(width: 1, height: CGFloat.greatestFiniteMagnitude))
        container.lineFragmentPadding = 0
        container.widthTracksTextView = false
        container.heightTracksTextView = false
        layoutManager.addTextContainer(container)
        textStorage.addLayoutManager(layoutManager)
    }

    /// Used text height of `string` laid out at exactly `width`.
    func textHeight(of string: NSAttributedString, width: CGFloat) -> CGFloat {
        ensureLayout(of: string, width: width)
        return ceil(layoutManager.usedRect(for: container).height)
    }

    /// Used text WIDTH of `string` laid out at `width` — for right-anchoring a
    /// user bubble to its measured content width rather than the full column.
    func textWidth(of string: NSAttributedString, width: CGFloat) -> CGFloat {
        ensureLayout(of: string, width: width)
        return ceil(layoutManager.usedRect(for: container).width)
    }

    private func ensureLayout(of string: NSAttributedString, width: CGFloat) {
        container.size = NSSize(width: max(width, 1), height: CGFloat.greatestFiniteMagnitude)
        textStorage.setAttributedString(string)
        // Force layout so `usedRect` reflects the final wrapped extent.
        layoutManager.ensureLayout(for: container)
    }
}

/// Measures and renders the height of `MessageBlock`s with the SAME primitives
/// the cell uses: TextKit-1 `usedRect` for prose, a one-shot
/// `NSHostingController.sizeThatFits` for tables. Owns one reusable measurer so
/// the storage/layout-manager allocation is paid once. (#129)
@MainActor
final class MessageBlockMeasurer {
    private let proseMeasurer = TranscriptBubbleMeasurer()

    /// Height of a single block at `bodyWidth`.
    func height(of block: MessageBlock, bodyWidth: CGFloat) -> CGFloat {
        switch block {
        case .prose(let string):
            return proseMeasurer.textHeight(of: string, width: bodyWidth)
        case .table(let data):
            return Self.tableHeight(data, bodyWidth: bodyWidth)
        case .image(let attachment):
            return Self.imageSize(attachment, bodyWidth: bodyWidth).height
        }
    }

    /// Laid-out size of an attached image. The aspect ratio comes from a
    /// SYNCHRONOUS header-only probe (`CGImageSourceCopyPropertiesAtIndex` reads
    /// the header, it does not decode), so the height is exact from the first
    /// measurement and does not move when the downsampled thumbnail arrives on
    /// the main thread later. A missing or undecodable file falls back to the
    /// chip's fixed size — also deterministic.
    static func imageSize(_ attachment: TranscriptImageAttachment, bodyWidth: CGFloat) -> CGSize {
        let metadata = TranscriptImageService.shared.metadata(forPath: attachment.path)
        return TranscriptImageGeometry.displaySize(metadata: metadata, bodyWidth: bodyWidth)
    }

    /// Per-block measured heights at `bodyWidth`, in block order. The summed-plus-
    /// spacing form is `blocksHeight`; exposing the per-block array lets the
    /// Coordinator cache each block's height so a scroll-reused cell can lay blocks
    /// out from the cache without re-measuring (notably avoiding the table block's
    /// `NSHostingController.sizeThatFits` on every dequeue). (#129)
    func blockHeights(_ blocks: [MessageBlock], bodyWidth: CGFloat) -> [CGFloat] {
        blocks.map { height(of: $0, bodyWidth: bodyWidth) }
    }

    /// Summed height of `blocks` plus inter-block spacing between them.
    func blocksHeight(_ blocks: [MessageBlock], bodyWidth: CGFloat) -> CGFloat {
        blocksHeight(fromBlockHeights: blockHeights(blocks, bodyWidth: bodyWidth))
    }

    /// Summed height of already-measured per-block `heights` plus inter-block
    /// spacing between them. The single source of truth for turning a block-height
    /// array into a row's body height, so cache-fed and freshly-measured paths
    /// agree by construction.
    func blocksHeight(fromBlockHeights heights: [CGFloat]) -> CGFloat {
        guard !heights.isEmpty else { return 0 }
        let total = heights.reduce(0, +)
        let spacing = TranscriptBubbleGeometry.interBlockSpacing * CGFloat(heights.count - 1)
        return total + spacing
    }

    /// Used width of a prose block (for user-bubble shrink-to-fit).
    func proseWidth(of string: NSAttributedString, bodyWidth: CGFloat) -> CGFloat {
        proseMeasurer.textWidth(of: string, width: bodyWidth)
    }

    /// Height of a table block, measured ONCE via a throwaway
    /// `NSHostingController.sizeThatFits` (acceptable here — a single bounded
    /// table block, not the per-row hot path). The table spans the full body
    /// width. (#129)
    static func tableHeight(_ data: TranscriptTableData, bodyWidth: CGFloat) -> CGFloat {
        let view = TranscriptTableView(data: data, borderColor: Color(TranscriptTextTheme.chatBubble.tableBorderColor))
        let controller = NSHostingController(rootView: view)
        controller.sizingOptions = [.preferredContentSize]
        let proposed = NSSize(width: max(bodyWidth, 1), height: .greatestFiniteMagnitude)
        let measured = controller.sizeThatFits(in: proposed).height
        return ceil(measured > 0 ? measured : 1)
    }
}

/// The bubble's rounded tint, painted via a backing `CALayer` rather than in
/// `draw(_:)`. A layer-backed view resolves and re-resolves its CGColor against
/// the current effective appearance, so the user/assistant tint tracks
/// light/dark and accent changes. The view never participates in hit testing —
/// `hitTest(_:)` returns nil — so click-drag selection passes through to the
/// NSTextViews above it. `wantsUpdateLayer` makes AppKit drive drawing through
/// `updateLayer()` (assign the resolved CGColor) instead of `draw(_:)`.
@MainActor
private final class RoundedBoxView: NSView {
    var fillColor: NSColor = .clear {
        didSet {
            guard fillColor != oldValue else { return }
            needsDisplay = true
        }
    }
    var cornerRadius: CGFloat = 10 {
        didSet { layer?.cornerRadius = cornerRadius }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.cornerRadius = cornerRadius
        layer?.cornerCurve = .continuous
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        layer?.cornerRadius = cornerRadius
        layer?.cornerCurve = .continuous
        var resolved: CGColor = fillColor.cgColor
        effectiveAppearance.performAsCurrentDrawingAppearance {
            resolved = fillColor.cgColor
        }
        layer?.backgroundColor = resolved
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }

    /// The bubble is purely decorative: never intercept the mouse, so clicks and
    /// drags reach the selectable NSTextViews layered above it.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

/// Where a clicked transcript link should go.
enum TranscriptLinkTarget: Equatable {
    /// An absolute path, already resolved during the render pass.
    case file(String)
    case web(URL)

    /// Every path-bearing URL gets the same rule the scanner's candidates get —
    /// a path links only if it names a file that is there — whichever scheme
    /// carries it. `TranscriptLinkPass` mints `tbd-file:` only for a path it
    /// resolved during the render pass, but a click sees a URL and not its
    /// provenance, so the check is applied here rather than assumed upstream;
    /// one `stat()` per click is negligible. A `file://` URL is the plain case:
    /// markdown the message wrote can carry one and nothing resolved it.
    /// Failing the check returns nil, which the delegate reports as unhandled
    /// so AppKit's default handling takes the click.
    init?(url: URL, isReadableFile: (String) -> Bool = ClickedPathResolver.isReadableFile) {
        if let path = TranscriptLinkPass.resolvedPath(from: url) ?? (url.isFileURL ? url.path : nil) {
            guard isReadableFile(path) else { return nil }
            self = .file(path)
            return
        }
        if url.scheme == "http" || url.scheme == "https" { self = .web(url); return }
        return nil
    }
}

/// The chat bubble's selectable prose text view (TextKit 1). A DISTINCT subclass
/// so the table's `validateProposedFirstResponder(_:for:)` can recognise it
/// precisely and let it take the mouse immediately — otherwise NSTableView delays
/// first responder and the first click selects the row instead of starting a text
/// drag. A bubble may contain SEVERAL of these (one per prose block).
///
/// It is also its own delegate, and so owns link-click routing: AppKit follows a
/// `.link` on a plain click and still starts a selection on a drag, so the view
/// only has to say where the link goes.
@MainActor
final class TranscriptBubbleTextView: NSTextView {
    /// Set by the cell on every configure. Nil means links are inert.
    var onLinkClicked: ((TranscriptLinkTarget) -> Void)?
}

extension TranscriptBubbleTextView: NSTextViewDelegate {
    func textView(_ textView: NSTextView, clickedOnLink link: Any, at charIndex: Int) -> Bool {
        let url: URL?
        switch link {
        case let value as URL: url = value
        case let value as String: url = URL(string: value)
        default: url = nil
        }
        guard let url, let target = TranscriptLinkTarget(url: url) else { return false }
        onLinkClicked?(target)
        // Handled here — returning false would let AppKit hand a `tbd-file:`
        // URL to NSWorkspace, which has no handler for it.
        return true
    }
}

/// The sender attribution drawn above a peer bubble's body.
///
/// Native chrome, built entirely from `TranscriptPeerHeader` — which comes from
/// the harness-written `origin`, never from the agent-authored message text — so
/// a peer can neither author its own attribution nor mint a worktree-navigation
/// link inside its message. This is the reason attribution lives here rather than
/// being prepended to the body. See
/// `docs/specs/2026-08-25-peer-message-attribution-design.md`, "Rendering".
///
/// Three shapes, one line tall in every case:
///   * resolved  — a link-styled button that navigates to the sender's worktree
///   * verified but unresolved — plain text, no click affordance
///   * asserted  — muted and italic, carrying `PeerHeaderChrome.assertedSuffix`
@MainActor
private final class PeerSenderHeaderView: NSView {
    private let worktreeID: UUID?
    private let navigate: (@MainActor (UUID) -> Void)?

    init(header: TranscriptPeerHeader) {
        self.worktreeID = header.isLink ? header.worktreeID : nil
        self.navigate = header.isLink ? header.navigate : nil
        super.init(frame: .zero)

        let font = TranscriptBubbleGeometry.peerHeaderFont

        let glyph = NSTextField(labelWithString: PeerHeaderChrome.glyph)
        glyph.font = font
        glyph.textColor = AttentionAmber.nsColor(alpha: 1)
        glyph.setAccessibilityHidden(true)

        let name: NSView
        if header.isLink {
            let button = NSButton(title: header.name, target: self, action: #selector(follow))
            button.isBordered = false
            button.attributedTitle = NSAttributedString(
                string: header.name,
                attributes: [
                    .font: font,
                    .foregroundColor: NSColor.linkColor,
                    .underlineStyle: NSUnderlineStyle.single.rawValue
                ])
            // `lineBreakMode` lives on NSCell, not on NSButton/NSTextField.
            button.cell?.lineBreakMode = .byTruncatingTail
            button.setAccessibilityLabel("Go to \(header.name)")
            name = button
        } else {
            let label = NSTextField(labelWithString: header.name)
            label.maximumNumberOfLines = 1
            label.cell?.lineBreakMode = .byTruncatingTail
            // An asserted label is a string the sender chose for itself, so it is
            // drawn the way an unconfirmed thing should be — muted and italic —
            // and never in the weight a verified name gets.
            if header.verified {
                label.font = font
                label.textColor = .labelColor
            } else {
                label.font = NSFontManager.shared.convert(font, toHaveTrait: .italicFontMask)
                label.textColor = .secondaryLabelColor
            }
            name = label
        }

        let row = NSStackView(views: [glyph, name])
        row.orientation = .horizontal
        row.alignment = .firstBaseline
        row.spacing = PeerHeaderChrome.itemSpacing
        row.translatesAutoresizingMaskIntoConstraints = false
        addSubview(row)
        NSLayoutConstraint.activate([
            // Equality on BOTH edges so the row's content actually determines this
            // view's width — with only a `<=` there is no equality driving it and
            // the header collapses to nothing inside the hugging block stack. The
            // caller's `width <= bodyWidth` cap then truncates a long name rather
            // than widening the bubble.
            row.leadingAnchor.constraint(equalTo: leadingAnchor),
            row.trailingAnchor.constraint(equalTo: trailingAnchor),
            row.centerYAnchor.constraint(equalTo: centerYAnchor)
        ])
    }

    @objc private func follow() {
        guard let worktreeID, let navigate else { return }
        navigate(worktreeID)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
}

/// `NSTableCellView` that renders a chat message as a vertical stack of typed
/// block views inside ONE rounded bubble. There is no role/timestamp header —
/// a transcript is not a group chat, and the bubble's side and tint already say
/// who spoke; the attribution survives as the cell's accessibility label. The one
/// exception is a PEER message, whose sender is not derivable from position or
/// tint and so gets a drawn header (`PeerSenderHeaderView`) as the first element
/// of the block stack. It is deliberately not extended to the other roles: peer
/// messages are rare, and the header is the layout node #129 removed. Prose
/// blocks render in selectable TextKit-1 `NSTextView`s; table blocks render in an
/// `NSHostingView` over the native grid. The row height (from `heightOfRow`) is
/// pinned via `columnWidth × cachedHeight`, and each block is laid out at the SAME
/// `bodyWidth` its height was measured at — so render height == row height by
/// construction. ⌘C / right-click copies the whole message's source text. (#129)
@MainActor
final class TranscriptBubbleCellView: NSTableCellView {
    private let backgroundBox = RoundedBoxView()
    /// Vertical stack of block subviews inside the bubble.
    private let blockStack = NSStackView()
    private let measurer = MessageBlockMeasurer()

    /// Source text of the whole message, for ⌘C / "Copy message".
    private var messageSourceText: String = ""

    /// Routes a link click out of the cell. Reset on every `configure` so a
    /// scroll-reused cell never fires the previous row's closure.
    private var onLinkClicked: ((TranscriptLinkTarget) -> Void)?

    /// Monotonic token bumped on every (re)build of the block stack. Async syntax-
    /// highlight completions capture the value current when they were dispatched
    /// and bail if it changed (scroll-reuse / reconfigure recycled the cell onto a
    /// different message), so colors never land on a stale/detached text view. (#129)
    private var highlightGeneration = 0

    // Cell-box + role-dependent anchoring constraints (assigned post-super.init).
    private var widthConstraint: NSLayoutConstraint!
    private var heightConstraint: NSLayoutConstraint!
    private var boxLeading: NSLayoutConstraint!
    private var boxTrailing: NSLayoutConstraint!
    private var boxWidth: NSLayoutConstraint!
    private var blockLeading: NSLayoutConstraint!
    private var blockTrailing: NSLayoutConstraint!

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)

        widthConstraint = widthAnchor.constraint(equalToConstant: 1)
        heightConstraint = heightAnchor.constraint(equalToConstant: 1)
        translatesAutoresizingMaskIntoConstraints = false

        backgroundBox.cornerRadius = TranscriptBubbleGeometry.cornerRadius
        backgroundBox.translatesAutoresizingMaskIntoConstraints = false

        blockStack.orientation = .vertical
        blockStack.alignment = .leading
        blockStack.distribution = .fill
        blockStack.spacing = TranscriptBubbleGeometry.interBlockSpacing
        blockStack.translatesAutoresizingMaskIntoConstraints = false

        // Bubble tint sits BELOW the selectable block stack (siblings, not nested),
        // so the stack's text views are topmost and take the mouse for selection
        // while the bubble paints behind them.
        addSubview(backgroundBox)
        addSubview(blockStack, positioned: .above, relativeTo: backgroundBox)

        let g = TranscriptBubbleGeometry.self
        boxLeading = backgroundBox.leadingAnchor.constraint(equalTo: leadingAnchor)
        boxTrailing = backgroundBox.trailingAnchor.constraint(equalTo: trailingAnchor)
        boxWidth = backgroundBox.widthAnchor.constraint(equalToConstant: 1)
        // Block-stack↔box horizontal insets, role-adjustable in `configure`
        // (initial constant 0 is fine — `configure` sets the real per-role value).
        blockLeading = blockStack.leadingAnchor.constraint(equalTo: backgroundBox.leadingAnchor, constant: 0)
        blockTrailing = blockStack.trailingAnchor.constraint(equalTo: backgroundBox.trailingAnchor, constant: 0)

        NSLayoutConstraint.activate([
            widthConstraint,
            heightConstraint,
            // With the attribution header gone the box hangs straight off the row
            // top; `outerVertical` is the whole top chrome (and matches
            // `rowHeight`'s `outerVertical * 2`).
            backgroundBox.topAnchor.constraint(equalTo: topAnchor, constant: g.outerVertical),
            // The block stack fills the box minus the body insets. The box owns the
            // rounded-rect frame; the stack sits inside it with symmetric padding.
            blockStack.topAnchor.constraint(
                equalTo: backgroundBox.topAnchor, constant: g.bodyVertical / 2),
            blockLeading,
            blockTrailing,
            // Pin the box bottom to the stack so the rounded fill encloses ALL
            // blocks with symmetric inner padding.
            backgroundBox.bottomAnchor.constraint(
                equalTo: blockStack.bottomAnchor, constant: g.bodyVertical / 2)
        ])
    }

    /// Configures the cell from the SAME blocks `heightOfRow` measured, pinned to
    /// `columnWidth × cachedHeight`, each block laid out at the SAME `bodyWidth`
    /// the height was measured at. Resets every role-dependent piece of state and
    /// rebuilds the block stack so a reused cell never shows stale content.
    ///
    /// `peerHeader` is non-nil ONLY for a peer message, and its presence must match
    /// the role the row was sized with: `rowHeight(blocksHeight:role:)` budgets
    /// `headerHeight(for: .peer)` for exactly this view. It is a required argument
    /// with no default so a new call site has to say which it is, rather than
    /// silently sizing a peer row without its header.
    func configure(
        blocks: [MessageBlock],
        blockHeights: [CGFloat],
        sourceText: String,
        role: TranscriptBubbleGeometry.Role,
        peerHeader: TranscriptPeerHeader?,
        accessibilityAttribution: String,
        bodyWidth: CGFloat,
        columnWidth: CGFloat,
        cachedHeight: CGFloat,
        onLinkClicked: ((TranscriptLinkTarget) -> Void)?
    ) {
        let g = TranscriptBubbleGeometry.self
        messageSourceText = sourceText
        // Set before `rebuildBlockStack`, which re-enters `makeProseView` and
        // reads it: `configure` never reuses a prose view across rows.
        self.onLinkClicked = onLinkClicked

        // Pin the cell box.
        let w = max(columnWidth, 1)
        let h = max(cachedHeight, 1)
        if abs(widthConstraint.constant - w) > 0.5 { widthConstraint.constant = w }
        if abs(heightConstraint.constant - h) > 0.5 { heightConstraint.constant = h }

        // The speaker is conveyed visually by position and tint, which VoiceOver
        // cannot perceive — so the attribution the header used to show is spoken
        // as the cell's label instead.
        setAccessibilityLabel(accessibilityAttribution)
        setAccessibilityRole(.group)
        backgroundBox.fillColor = g.backgroundColor(for: role)

        rebuildBlockStack(
            blocks: blocks, blockHeights: blockHeights, bodyWidth: bodyWidth,
            peerHeader: peerHeader)

        // Box width: reader-side bubbles (user, peer) shrink-to-fit (right-anchored),
        // assistant fills. Per-role block-stack inset: reader-side bubbles keep the
        // 11pt-per-side bubble padding, assistant sits flush at the box edge (0),
        // aligning with the tool rows.
        let bodyInset = g.bodyHorizontal(for: role) / 2
        blockLeading.constant = bodyInset
        blockTrailing.constant = -bodyInset
        let bubbleWidth = bodyWidth + g.bodyHorizontal(for: role)
        switch role {
        case .user, .peer:
            // Measure the widest prose block and clamp to the available bubble. A
            // peer bubble must also be wide enough for its sender header, or a
            // short message would truncate the attribution above it.
            var usedWidth = userContentWidth(blocks: blocks, bodyWidth: bodyWidth)
            if let peerHeader {
                usedWidth = max(usedWidth, Self.peerHeaderWidth(peerHeader))
            }
            let fitWidth = min(usedWidth + g.bodyHorizontal(for: role), bubbleWidth)
            applyUserAnchor(width: max(fitWidth, 1))
        case .assistant:
            applyAssistantAnchor(bubbleWidth: bubbleWidth)
        }
    }

    /// Tears down the previous block subviews and rebuilds one subview per block,
    /// each width-pinned to `bodyWidth` (so prose wraps and tables span exactly
    /// the width their height was measured at) and height-pinned to its measured
    /// height (so render height == row height by construction).
    ///
    /// `blockHeights` are the per-block heights the Coordinator already measured
    /// (and cached) when it sized the row — so a scroll-reused cell lays its blocks
    /// out from the cache with ZERO re-measurement, notably never re-allocating an
    /// `NSHostingController` to re-measure a `.table` block. The defensive fallback
    /// (a missing/short `blockHeights` array) re-measures the affected block so the
    /// cell can never render at a wrong height. (#129)
    private func rebuildBlockStack(
        blocks: [MessageBlock],
        blockHeights: [CGFloat],
        bodyWidth: CGFloat,
        peerHeader: TranscriptPeerHeader?
    ) {
        // Invalidate any in-flight async syntax-highlight completions targeting the
        // previous content: a recycled cell rebuilds onto a different message, so
        // those completions must become no-ops (see `applyAsyncHighlights`).
        highlightGeneration &+= 1

        for view in blockStack.arrangedSubviews {
            blockStack.removeArrangedSubview(view)
            view.removeFromSuperview()
        }

        let width = max(bodyWidth, 1)

        // The sender header goes into the SAME stack as the message blocks, as its
        // first arranged subview, pinned to the SAME constant `headerHeight(for:)`
        // budgets — so the stack's realized height carries it by construction and
        // the row cannot drift (the #129 failure mode). The stack's own
        // `interBlockSpacing` supplies the header→body gap, which is the other
        // half of that budget. It is native chrome built from `TranscriptPeerHeader`
        // and never from the message text.
        if let peerHeader {
            let header = PeerSenderHeaderView(header: peerHeader)
            header.translatesAutoresizingMaskIntoConstraints = false
            blockStack.addArrangedSubview(header)
            NSLayoutConstraint.activate([
                header.heightAnchor.constraint(
                    equalToConstant: TranscriptBubbleGeometry.peerHeaderLineHeight),
                // Never let a long sender name push the bubble past its body width;
                // the label and the button both truncate at the tail instead.
                header.widthAnchor.constraint(lessThanOrEqualToConstant: width)
            ])
        }

        for (index, block) in blocks.enumerated() {
            // Cache hit (the common scroll-reuse path): use the Coordinator's
            // pre-measured height. Miss (defensive): re-measure this one block.
            let height: CGFloat = (index < blockHeights.count)
                ? blockHeights[index]
                : measurer.height(of: block, bodyWidth: width)
            let view: NSView
            switch block {
            case .prose(let string):
                view = makeProseView(string, bodyWidth: width)
            case .table(let data):
                view = makeTableView(data, bodyWidth: width)
            case .image(let attachment):
                view = makeImageView(attachment, bodyWidth: width)
            }
            view.translatesAutoresizingMaskIntoConstraints = false
            blockStack.addArrangedSubview(view)
            NSLayoutConstraint.activate([
                view.widthAnchor.constraint(equalToConstant: width),
                view.heightAnchor.constraint(equalToConstant: max(height, 1))
            ])
        }
    }

    /// A selectable TextKit-1 prose block. The view is constructed WITHOUT touching
    /// `layoutManager` first via legacy paths — `NSTextView(frame:)` is TextKit 1
    /// when we configure through `layoutManager`/`textContainer`. We explicitly
    /// build a TK1 stack so prose is measured and drawn by the same `usedRect`
    /// engine. (#129)
    private func makeProseView(_ string: NSAttributedString, bodyWidth: CGFloat) -> NSView {
        let textView = TranscriptBubbleTextView(frame: .zero)
        textView.isEditable = false
        textView.isSelectable = true
        textView.delegate = textView
        // AppKit's own link treatment (blue + underline) would stack on top of
        // the attributes the link pass already put in the storage — but the same
        // dictionary is also where the pointing-hand cursor comes from, so
        // emptying it wholesale would cost every link its hover affordance. The
        // cursor is therefore re-supplied on its own. `.cursor` is a non-layout
        // temporary attribute, so it cannot move a glyph and the composed
        // cache's measure == render invariant is untouched.
        textView.linkTextAttributes = [.cursor: NSCursor.pointingHand]
        textView.onLinkClicked = onLinkClicked
        textView.drawsBackground = false
        textView.backgroundColor = .clear
        textView.textContainerInset = .zero
        textView.isHorizontallyResizable = false
        textView.isVerticallyResizable = false
        // Accessing `textContainer` here returns the TextKit-1 container (the view
        // is created with the legacy text system; we never request
        // `textLayoutManager`), keeping prose on TK1.
        textView.textContainer?.lineFragmentPadding = 0
        textView.textContainer?.widthTracksTextView = false
        textView.textContainer?.heightTracksTextView = false
        textView.textContainer?.containerSize = NSSize(
            width: max(bodyWidth, 1), height: CGFloat.greatestFiniteMagnitude)
        textView.textStorage?.setAttributedString(string)
        textView.setSelectedRange(NSRange(location: 0, length: 0))
        applyAsyncHighlights(in: string, textView: textView)
        return textView
    }

    /// Finds every `.tbdCodeHighlight`-marked code run in `string` and asks the
    /// off-main `CodeHighlightService` to syntax-highlight it. Each completion
    /// (already on the main thread) re-applies only `.foregroundColor` over the
    /// run's characters — colors only, so no relayout — guarded against scroll-reuse
    /// staleness via the generation token + a weak text-view capture. (#129)
    private func applyAsyncHighlights(in string: NSAttributedString, textView: NSTextView) {
        let ns = string.string as NSString
        let full = NSRange(location: 0, length: string.length)
        string.enumerateAttribute(.tbdCodeHighlight, in: full, options: []) { value, range, _ in
            guard let language = value as? String, range.length > 0 else { return }
            let code = ns.substring(with: range)
            let captured = highlightGeneration
            CodeHighlightService.shared.highlight(
                code: code, language: language
            ) { [weak self, weak textView] colorRuns in
                guard let self, let textView, self.highlightGeneration == captured else { return }
                guard let storage = textView.textStorage else { return }
                let storageLength = storage.length
                storage.beginEditing()
                for run in colorRuns {
                    let offset = NSRange(location: range.location + run.range.location, length: run.range.length)
                    // Clamp defensively: the storage must still contain the offset
                    // range (it does unless the content changed, which the
                    // generation guard already rules out).
                    guard offset.location + offset.length <= storageLength else { continue }
                    storage.addAttribute(.foregroundColor, value: run.color, range: offset)
                }
                storage.endEditing()
            }
        }
    }

    /// An attached-image block: a leading-aligned thumbnail at exactly the size
    /// the measurer reserved, decoded off-main and revealed in Finder on click.
    private func makeImageView(_ attachment: TranscriptImageAttachment, bodyWidth: CGFloat) -> NSView {
        let metadata = TranscriptImageService.shared.metadata(forPath: attachment.path)
        let view = TranscriptImageBlockView()
        view.configure(
            attachment: attachment,
            metadata: metadata,
            displaySize: TranscriptImageGeometry.displaySize(metadata: metadata, bodyWidth: bodyWidth))
        return view
    }

    /// A table block hosted in an `NSHostingView` over the native grid.
    private func makeTableView(_ data: TranscriptTableData, bodyWidth: CGFloat) -> NSView {
        let view = TranscriptTableView(
            data: data,
            borderColor: Color(TranscriptTextTheme.chatBubble.tableBorderColor)
        )
        let host = NSHostingView(rootView: view)
        return host
    }

    /// Laid-out width the sender header wants: glyph + gap + name, plus a couple
    /// of points of slack for the borderless button's own insets. Width only — the
    /// header's HEIGHT is the pinned constant, so this cannot move a row height.
    private static func peerHeaderWidth(_ header: TranscriptPeerHeader) -> CGFloat {
        let attributes: [NSAttributedString.Key: Any] = [
            .font: TranscriptBubbleGeometry.peerHeaderFont
        ]
        let glyph = (PeerHeaderChrome.glyph as NSString).size(withAttributes: attributes).width
        let name = (header.name as NSString).size(withAttributes: attributes).width
        return ceil(glyph + PeerHeaderChrome.itemSpacing + name) + 8
    }

    /// Widest used width across the message's prose blocks, for user shrink-to-fit.
    private func userContentWidth(blocks: [MessageBlock], bodyWidth: CGFloat) -> CGFloat {
        var widest: CGFloat = 0
        for block in blocks {
            switch block {
            case .prose(let string):
                widest = max(widest, ceil(measurer.proseWidth(of: string, bodyWidth: bodyWidth)))
            case .table:
                // A table always wants the full body width.
                widest = bodyWidth
            case .image(let attachment):
                // A thumbnail wants exactly its laid-out width, so a bubble that
                // is just an image hugs the picture instead of spanning the column.
                widest = max(widest, MessageBlockMeasurer.imageSize(attachment, bodyWidth: bodyWidth).width)
            }
        }
        return widest
    }

    /// Right-anchor the box, fixed to the measured content width.
    private func applyUserAnchor(width: CGFloat) {
        let g = TranscriptBubbleGeometry.self
        boxLeading.isActive = false
        boxTrailing.isActive = true
        boxTrailing.constant = -g.outerNear  // trailing 12
        boxWidth.isActive = true
        boxWidth.constant = width
    }

    /// Left-anchor the box filling the assistant bubble width.
    private func applyAssistantAnchor(bubbleWidth: CGFloat) {
        let g = TranscriptBubbleGeometry.self
        boxTrailing.isActive = false
        boxWidth.isActive = true
        boxWidth.constant = bubbleWidth
        boxLeading.isActive = true
        // Flush at `outerNear` (12) — the same x as the assistant body (zero body
        // inset) and the 12pt tool-row inset — forming one vertical line.
        boxLeading.constant = g.outerNear  // leading 12
    }

    // MARK: - Copy message

    /// Right-click context menu offering "Copy message" (the whole message's
    /// source text). Per-prose-block text selection still works via the text
    /// views; this copies the entire message regardless of selection.
    override func menu(for event: NSEvent) -> NSMenu? {
        let menu = NSMenu()
        let item = NSMenuItem(
            title: "Copy message", action: #selector(copyMessage(_:)), keyEquivalent: "")
        item.target = self
        menu.addItem(item)
        return menu
    }

    /// ⌘C copies the whole message's source text when no prose text view holds an
    /// active selection. (A text view with a selection handles ⌘C itself.)
    @objc func copyMessage(_ sender: Any?) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(messageSourceText, forType: .string)
    }

    /// Test backstop: realized drawn height of the block stack (its actual
    /// laid-out frame) plus the fixed chrome — i.e. the row height the live cell
    /// genuinely requires. The harness asserts this equals the value `heightOfRow`
    /// returned.
    ///
    /// The stack already CONTAINS the peer sender header when there is one, so
    /// this goes through the `stackHeight:` form: adding `headerHeight(for:)` here
    /// as well would count the header twice.
    var realizedRowHeight: CGFloat {
        layoutSubtreeIfNeeded()
        return TranscriptBubbleGeometry.rowHeight(stackHeight: blockStack.frame.height)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
}
