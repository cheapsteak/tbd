import AppKit
import SwiftUI
import TBDShared

/// Shared geometry + content helpers for the block-based chat-bubble cell.
///
/// A message is an ordered list of typed `MessageBlock`s (prose / table) rendered
/// into ONE bubble as a vertical stack. `heightOfRow` (measure) and `viewFor`
/// (render) both flow through the SAME `bodyWidth(columnWidth:)` and the SAME
/// `[MessageBlock]`, so the row height and the cell's drawn height cannot drift.
/// Mirrors `ChatBubbleView`'s chrome (#129).
@MainActor
enum TranscriptBubbleGeometry {
    enum Role {
        case user
        case assistant
    }

    // MARK: Chrome constants (mirror ChatBubbleView)

    /// Outer leading+trailing padding folds the 52pt opposite-side gutter into
    /// the 12pt chrome inset: 12 + 64 == 76 regardless of role.
    static let outerHorizontal: CGFloat = 76
    /// Chrome inset on the bubble's own side (12pt). The opposite side carries
    /// the 64pt gutter (12 + 52).
    static let outerNear: CGFloat = 12
    /// Outer top/bottom padding.
    static let outerVertical: CGFloat = 4
    /// bubbleBody inner horizontal insets (11 leading + 11 trailing).
    static let bodyHorizontal: CGFloat = 22
    /// bubbleBody inner vertical insets (8 top + 8 bottom).
    static let bodyVertical: CGFloat = 16
    /// VStack header→body spacing.
    static let headerBodyGap: CGFloat = 3
    /// Bubble corner radius.
    static let cornerRadius: CGFloat = 10
    /// Header text horizontal inset (matches ChatBubbleView's roleHeader padding).
    static let headerInset: CGFloat = 4
    /// Vertical gap BETWEEN stacked blocks inside one bubble (prose→table etc.).
    static let interBlockSpacing: CGFloat = 6

    /// Single source of truth for the text container width used by BOTH the
    /// measurer and the cell's NSTextView. Role-independent — the body width
    /// folds the same opposite-side gutter into the chrome inset regardless of
    /// which side the bubble anchors to.
    static func bodyWidth(columnWidth: CGFloat) -> CGFloat {
        max(columnWidth - outerHorizontal - bodyHorizontal, 1)
    }

    /// Total row height: summed block heights + inter-block spacing + fixed chrome
    /// (header line + header→body gap + body vertical insets + outer vertical
    /// padding).
    static func rowHeight(blocksHeight: CGFloat) -> CGFloat {
        blocksHeight + headerLineHeight + headerBodyGap + bodyVertical + outerVertical * 2
    }

    /// Measured single-line height of the caption2 header font.
    static let headerLineHeight: CGFloat = {
        let font = NSFont.preferredFont(forTextStyle: .caption2)
        return ceil(font.ascender - font.descender + font.leading)
    }()

    static let headerFont: NSFont = .preferredFont(forTextStyle: .caption2)

    static func role(for item: TranscriptItem) -> Role {
        if case .userPrompt = item { return .user }
        return .assistant
    }

    /// Header line, matching ChatBubbleView: user shows "ts · You",
    /// assistant shows "Claude · ts".
    static func header(for item: TranscriptItem) -> String {
        let ts = item.timestamp?.absoluteShort
        switch role(for: item) {
        case .user:
            if let ts { return "\(ts) · You" }
            return "You"
        case .assistant:
            if let ts { return "Claude · \(ts)" }
            return "Claude"
        }
    }

    /// Body text of a chat-bubble item (only userPrompt/assistantText reach here).
    static func text(for item: TranscriptItem) -> String {
        switch item {
        case .userPrompt(_, let t, _): return t
        case .assistantText(_, let t, _, _): return t
        default: return ""
        }
    }

    /// The message's blocks: rendered markdown split at GFM tables, with the
    /// token-usage badge (when present) appended to the LAST prose block — or, if
    /// the message ends in a table (or has no prose), a trailing prose block
    /// carrying just the badge. Matches `ContextUsageBadge` styling (font size 9,
    /// secondaryLabelColor). (#129)
    static func composedBlocks(for item: TranscriptItem, badgeUsage: TokenUsage?) -> [MessageBlock] {
        var blocks = MarkdownAttributedRenderer.renderBlocks(text(for: item), theme: .chatBubble)
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
    static func backgroundColor(for role: Role) -> NSColor {
        switch role {
        case .user: return NSColor.controlAccentColor.withAlphaComponent(0.15)
        case .assistant: return NSColor.controlBackgroundColor
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
        }
    }

    /// Summed height of `blocks` plus inter-block spacing between them.
    func blocksHeight(_ blocks: [MessageBlock], bodyWidth: CGFloat) -> CGFloat {
        guard !blocks.isEmpty else { return 0 }
        let total = blocks.reduce(CGFloat(0)) { $0 + height(of: $1, bodyWidth: bodyWidth) }
        let spacing = TranscriptBubbleGeometry.interBlockSpacing * CGFloat(blocks.count - 1)
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

/// The chat bubble's selectable prose text view (TextKit 1). A DISTINCT subclass
/// so the table's `validateProposedFirstResponder(_:for:)` can recognise it
/// precisely and let it take the mouse immediately — otherwise NSTableView delays
/// first responder and the first click selects the row instead of starting a text
/// drag. A bubble may contain SEVERAL of these (one per prose block).
@MainActor
final class TranscriptBubbleTextView: NSTextView {}

/// `NSTableCellView` that renders a chat message as a vertical stack of typed
/// block views inside ONE rounded bubble, with a caption2 header above. Prose
/// blocks render in selectable TextKit-1 `NSTextView`s; table blocks render in an
/// `NSHostingView` over the native grid. The row height (from `heightOfRow`) is
/// pinned via `columnWidth × cachedHeight`, and each block is laid out at the SAME
/// `bodyWidth` its height was measured at — so render height == row height by
/// construction. ⌘C / right-click copies the whole message's source text. (#129)
@MainActor
final class TranscriptBubbleCellView: NSTableCellView {
    private let backgroundBox = RoundedBoxView()
    private let header = NSTextField(labelWithString: "")
    /// Vertical stack of block subviews inside the bubble.
    private let blockStack = NSStackView()
    private let measurer = MessageBlockMeasurer()

    /// Source text of the whole message, for ⌘C / "Copy message".
    private var messageSourceText: String = ""

    // Cell-box + role-dependent anchoring constraints (assigned post-super.init).
    private var widthConstraint: NSLayoutConstraint!
    private var heightConstraint: NSLayoutConstraint!
    private var headerLeading: NSLayoutConstraint!
    private var headerTrailing: NSLayoutConstraint!
    private var boxLeading: NSLayoutConstraint!
    private var boxTrailing: NSLayoutConstraint!
    private var boxWidth: NSLayoutConstraint!

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)

        widthConstraint = widthAnchor.constraint(equalToConstant: 1)
        heightConstraint = heightAnchor.constraint(equalToConstant: 1)
        translatesAutoresizingMaskIntoConstraints = false

        backgroundBox.cornerRadius = TranscriptBubbleGeometry.cornerRadius
        backgroundBox.translatesAutoresizingMaskIntoConstraints = false

        header.font = TranscriptBubbleGeometry.headerFont
        header.textColor = .tertiaryLabelColor
        header.backgroundColor = .clear
        header.isBezeled = false
        header.isEditable = false
        header.drawsBackground = false
        header.translatesAutoresizingMaskIntoConstraints = false

        blockStack.orientation = .vertical
        blockStack.alignment = .leading
        blockStack.distribution = .fill
        blockStack.spacing = TranscriptBubbleGeometry.interBlockSpacing
        blockStack.translatesAutoresizingMaskIntoConstraints = false

        // Bubble tint sits BELOW the selectable block stack (siblings, not nested),
        // so the stack's text views are topmost and take the mouse for selection
        // while the bubble paints behind them.
        addSubview(backgroundBox)
        addSubview(header)
        addSubview(blockStack, positioned: .above, relativeTo: backgroundBox)

        let g = TranscriptBubbleGeometry.self
        headerLeading = header.leadingAnchor.constraint(
            equalTo: leadingAnchor, constant: g.headerInset)
        headerTrailing = header.trailingAnchor.constraint(
            equalTo: trailingAnchor, constant: -g.headerInset)
        boxLeading = backgroundBox.leadingAnchor.constraint(equalTo: leadingAnchor)
        boxTrailing = backgroundBox.trailingAnchor.constraint(equalTo: trailingAnchor)
        boxWidth = backgroundBox.widthAnchor.constraint(equalToConstant: 1)

        NSLayoutConstraint.activate([
            widthConstraint,
            heightConstraint,
            header.topAnchor.constraint(equalTo: topAnchor, constant: g.outerVertical),
            backgroundBox.topAnchor.constraint(
                equalTo: header.bottomAnchor, constant: g.headerBodyGap),
            // The block stack fills the box minus the body insets. The box owns the
            // rounded-rect frame; the stack sits inside it with symmetric padding.
            blockStack.topAnchor.constraint(
                equalTo: backgroundBox.topAnchor, constant: g.bodyVertical / 2),
            blockStack.leadingAnchor.constraint(
                equalTo: backgroundBox.leadingAnchor, constant: g.bodyHorizontal / 2),
            blockStack.trailingAnchor.constraint(
                equalTo: backgroundBox.trailingAnchor, constant: -g.bodyHorizontal / 2),
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
    func configure(
        blocks: [MessageBlock],
        sourceText: String,
        role: TranscriptBubbleGeometry.Role,
        header headerText: String,
        bodyWidth: CGFloat,
        columnWidth: CGFloat,
        cachedHeight: CGFloat
    ) {
        let g = TranscriptBubbleGeometry.self
        messageSourceText = sourceText

        // Pin the cell box.
        let w = max(columnWidth, 1)
        let h = max(cachedHeight, 1)
        if abs(widthConstraint.constant - w) > 0.5 { widthConstraint.constant = w }
        if abs(heightConstraint.constant - h) > 0.5 { heightConstraint.constant = h }

        header.stringValue = headerText
        backgroundBox.fillColor = g.backgroundColor(for: role)

        rebuildBlockStack(blocks: blocks, bodyWidth: bodyWidth)

        // Box width: user bubbles shrink-to-fit (right-anchored), assistant fills.
        let bubbleWidth = bodyWidth + g.bodyHorizontal
        switch role {
        case .user:
            // Measure the widest prose block and clamp to the available bubble.
            let usedWidth = userContentWidth(blocks: blocks, bodyWidth: bodyWidth)
            let fitWidth = min(usedWidth + g.bodyHorizontal, bubbleWidth)
            applyUserAnchor(width: max(fitWidth, 1))
        case .assistant:
            applyAssistantAnchor(bubbleWidth: bubbleWidth)
        }
    }

    /// Tears down the previous block subviews and rebuilds one subview per block,
    /// each width-pinned to `bodyWidth` (so prose wraps and tables span exactly
    /// the width their height was measured at) and height-pinned to its measured
    /// height (so render height == row height by construction).
    private func rebuildBlockStack(blocks: [MessageBlock], bodyWidth: CGFloat) {
        for view in blockStack.arrangedSubviews {
            blockStack.removeArrangedSubview(view)
            view.removeFromSuperview()
        }

        let width = max(bodyWidth, 1)
        for block in blocks {
            let height = measurer.height(of: block, bodyWidth: width)
            let view: NSView
            switch block {
            case .prose(let string):
                view = makeProseView(string, bodyWidth: width)
            case .table(let data):
                view = makeTableView(data, bodyWidth: width)
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
        return textView
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
            }
        }
        return widest
    }

    /// Right-anchor the box, fixed to the measured content width, with the
    /// header right-aligned to match.
    private func applyUserAnchor(width: CGFloat) {
        let g = TranscriptBubbleGeometry.self
        boxLeading.isActive = false
        boxTrailing.isActive = true
        boxTrailing.constant = -g.outerNear  // trailing 12
        boxWidth.isActive = true
        boxWidth.constant = width

        headerLeading.isActive = false
        headerTrailing.isActive = true
        headerTrailing.constant = -(g.outerNear + g.headerInset)
        header.alignment = .right
    }

    /// Left-anchor the box filling the assistant bubble width.
    private func applyAssistantAnchor(bubbleWidth: CGFloat) {
        let g = TranscriptBubbleGeometry.self
        boxTrailing.isActive = false
        boxWidth.isActive = true
        boxWidth.constant = bubbleWidth
        boxLeading.isActive = true
        boxLeading.constant = g.outerNear  // leading 12

        headerTrailing.isActive = false
        headerLeading.isActive = true
        headerLeading.constant = g.outerNear + g.headerInset
        header.alignment = .left
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

    /// Test backstop: realized drawn height of all blocks (their actual laid-out
    /// frames) plus the fixed chrome — i.e. the row height the live cell genuinely
    /// requires. The harness asserts this equals the value `heightOfRow` returned.
    var realizedRowHeight: CGFloat {
        layoutSubtreeIfNeeded()
        let blocksHeight = blockStack.frame.height
        return TranscriptBubbleGeometry.rowHeight(blocksHeight: blocksHeight)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
}
