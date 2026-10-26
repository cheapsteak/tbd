import AppKit

/// A card row's expansion: drawn over the row it expands and the rows beside
/// it, with the card's background, so the row appears to grow in place and
/// show more of its prompt. `PromptRailCardNSView` shows it once the pointer
/// has rested on the row for `PromptRailCardMetrics.expansionDelay`, and
/// hides it the moment the pointer leaves the row's band or the list
/// scrolls.
///
/// - **Content** – the row's dash and time, on the row's band where the row
///   draws them; the prompt's opening wrapped to the row's text width, its
///   last line ending in "…" when more remains; then a muted line with the
///   turn's tool-call count. The card's list view composes it
///   (`Content`), as it composes the rows.
/// - **Events** – it takes none. `hitTest(_:)` returns nil, so hover, clicks
///   and the wheel all reach the list beneath it, and a click on the row
///   jumps exactly as it does without the expansion.
/// - **Accessibility** – hidden. It draws everything itself, so as a plain
///   view it is no element, and it reports no children, so nothing added
///   inside it later reaches VoiceOver either. The rail's buttons already say
///   each prompt's first line, time and tool-call count.
///
/// It lives in the list's document view, above the rows and the earlier row's
/// controls, so the list's corner clip and edge fade apply to it as to them.
final class PromptRailRowExpansionView: NSView {
    /// What an expansion draws, in its own coordinates.
    struct Content {
        /// The list row it expands.
        let row: Int
        /// Whether it grows up to the row rather than down from it.
        let growsUpward: Bool
        /// The row's 22pt band: the dash and the time sit on it, as on the row.
        let rowBand: NSRect
        let dash: NSRect
        /// A dynamic colour, resolved when drawn.
        let dashColor: NSColor
        let time: NSAttributedString?
        let text: PromptRailExpansionText
        let textOrigin: NSPoint
        let count: NSAttributedString
        let countRect: NSRect
    }

    private(set) var content: Content?

    /// The list row expanded; nil while hidden.
    var row: Int? { content?.row }
    var growsUpward: Bool { content?.growsUpward ?? false }
    /// The prompt text as laid out, "…" included when it was cut.
    var text: String { content?.text.string ?? "" }
    /// Lines the prompt text takes as laid out.
    var lineCount: Int { content?.text.lineCount ?? 0 }
    /// The tool-call line: "40 tool calls".
    var countText: String { content?.count.string ?? "" }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        isHidden = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var isFlipped: Bool { true }

    /// Never the target of an event: whatever is under the pointer in the
    /// list gets it, as if the expansion were not there.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func accessibilityChildren() -> [Any]? { nil }

    func show(_ content: Content, frame: NSRect) {
        self.content = content
        if self.frame != frame { self.frame = frame }
        isHidden = false
        needsDisplay = true
    }

    func hide() {
        content = nil
        isHidden = true
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let content else { return }
        NSColor.windowBackgroundColor.setFill()
        NSBezierPath(rect: bounds).fill()
        // The hovered row's fill, over the whole expansion: it is that row,
        // grown.
        NSColor.quaternarySystemFill.setFill()
        NSBezierPath(
            roundedRect: bounds.insetBy(dx: 1, dy: 0),
            xRadius: PromptRailCardMetrics.hoverCornerRadius, yRadius: PromptRailCardMetrics.hoverCornerRadius
        ).fill()

        let dash = content.dash
        content.dashColor.setFill()
        NSBezierPath(roundedRect: dash, xRadius: dash.height / 2, yRadius: dash.height / 2).fill()

        if let time = content.time {
            let size = time.size()
            time.draw(
                with: NSRect(
                    x: content.rowBand.maxX - PromptRailCardMetrics.trailingPadding - size.width,
                    y: content.rowBand.midY - size.height / 2,
                    width: size.width, height: size.height),
                options: [.usesLineFragmentOrigin])
        }
        content.text.draw(at: content.textOrigin)
        content.count.draw(with: content.countRect, options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
    }
}

/// Prompt text laid out with TextKit at a fixed width, as a row expansion
/// draws it: what the lines are, how tall they stand, and the same text cut
/// to fewer lines. Built only for the row being expanded, when it expands.
@MainActor
final class PromptRailExpansionText {
    let attributedString: NSAttributedString
    let width: CGFloat
    /// Each laid-out line's character range, top to bottom.
    let lineRanges: [NSRange]
    /// The first line's height; 0 for empty text.
    let lineHeight: CGFloat
    /// The laid-out text's height.
    let height: CGFloat

    private let storage: NSTextStorage
    private let layoutManager: NSLayoutManager
    private let container: NSTextContainer

    var string: String { storage.string }
    var lineCount: Int { lineRanges.count }

    init(_ text: NSAttributedString, width: CGFloat) {
        let storage = NSTextStorage(attributedString: text)
        let layoutManager = NSLayoutManager()
        let container = NSTextContainer(size: NSSize(width: width, height: CGFloat.greatestFiniteMagnitude))
        container.lineFragmentPadding = 0
        container.widthTracksTextView = false
        container.heightTracksTextView = false
        layoutManager.addTextContainer(container)
        storage.addLayoutManager(layoutManager)
        layoutManager.ensureLayout(for: container)

        var ranges: [NSRange] = []
        var firstHeight: CGFloat = 0
        var glyphIndex = 0
        let glyphCount = layoutManager.numberOfGlyphs
        while glyphIndex < glyphCount {
            var lineGlyphs = NSRange(location: 0, length: 0)
            let fragment = layoutManager.lineFragmentRect(forGlyphAt: glyphIndex, effectiveRange: &lineGlyphs)
            guard lineGlyphs.length > 0 else { break }
            if ranges.isEmpty { firstHeight = fragment.height }
            ranges.append(layoutManager.characterRange(forGlyphRange: lineGlyphs, actualGlyphRange: nil))
            glyphIndex = NSMaxRange(lineGlyphs)
        }
        attributedString = text
        self.width = width
        lineRanges = ranges
        lineHeight = firstHeight
        height = layoutManager.usedRect(for: container).height
        self.storage = storage
        self.layoutManager = layoutManager
        self.container = container
    }

    /// This text in at most `maxLines` lines: itself when it fits; otherwise
    /// cut after line `maxLines`, with that line ending in "…" and shortened
    /// until the ellipsis fits on it.
    func limited(toLines maxLines: Int) -> PromptRailExpansionText {
        guard maxLines > 0, lineRanges.count > maxLines else { return self }
        let characters = attributedString.string as NSString
        let lastLineStart = lineRanges[maxLines - 1].location
        var end = NSMaxRange(lineRanges[maxLines - 1])
        while true {
            end = Self.trimmingTrailingWhitespace(characters, end: end, floor: lastLineStart)
            guard end > lastLineStart else { break }
            let candidate = PromptRailExpansionText(Self.ellipsized(attributedString, upTo: end), width: width)
            if candidate.lineCount <= maxLines { return candidate }
            end = characters.rangeOfComposedCharacterSequence(at: end - 1).location
        }
        // Not one character of the last line fits beside the ellipsis, which
        // only a row narrower than a word could cause: end the line before.
        let previous = Self.trimmingTrailingWhitespace(characters, end: lastLineStart, floor: 0)
        return PromptRailExpansionText(Self.ellipsized(attributedString, upTo: previous), width: width)
    }

    /// Draws the text with its container's origin at `origin`, in a flipped
    /// view.
    func draw(at origin: NSPoint) {
        let glyphs = layoutManager.glyphRange(for: container)
        layoutManager.drawBackground(forGlyphRange: glyphs, at: origin)
        layoutManager.drawGlyphs(forGlyphRange: glyphs, at: origin)
    }

    /// `end` moved back over any whitespace and newlines before it, but not
    /// past `floor`.
    private static func trimmingTrailingWhitespace(_ characters: NSString, end: Int, floor: Int) -> Int {
        var end = end
        while end > floor,
              let scalar = Unicode.Scalar(characters.character(at: end - 1)),
              scalar.properties.isWhitespace {
            end -= 1
        }
        return end
    }

    /// The first `end` characters of `text`, then "…" styled as the character
    /// before it.
    private static func ellipsized(_ text: NSAttributedString, upTo end: Int) -> NSAttributedString {
        let result = NSMutableAttributedString(
            attributedString: text.attributedSubstring(from: NSRange(location: 0, length: end)))
        let attributes = end > 0 ? text.attributes(at: end - 1, effectiveRange: nil) : [:]
        result.append(NSAttributedString(string: "…", attributes: attributes))
        return result
    }
}
