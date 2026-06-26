import AppKit
import os

/// Native AppKit cell for non-bubble activity rows (tool-call headers, system
/// reminders, skill bodies, subagent summaries). Replaces the per-row
/// `NSHostingController` SwiftUI render with one layer-backed cell, mirroring
/// `ActivityRowChrome`: an icon + a one-line title + badges + a right-aligned
/// timestamp inside a rounded `windowBackgroundColor` box, with a hover-revealed
/// `scope` affordance and a click that opens the overlay / drills into the
/// thread. The `plainSummary` variant (subagent summaries) drops the background,
/// timestamp, scope and click — an indented tertiary line matching
/// `SubagentSummaryRow`. Reused by identifier across the table. (#129)
@MainActor
final class ActivityRowCellView: NSTableCellView {
    private static let log = Logger(subsystem: "com.tbd.app", category: "activity-row-cell")

    // MARK: Chrome constants (mirror ActivityRowChrome)

    private enum Metrics {
        /// EdgeInsets(top: 4, leading: 12, bottom: 4, trailing: 12).
        static let insetTop: CGFloat = 4
        static let insetLeading: CGFloat = 12
        static let insetBottom: CGFloat = 4
        static let insetTrailing: CGFloat = 12
        /// HStack(spacing: 6) between icon and title.
        static let hStackSpacing: CGFloat = 6
        /// Icon column width (Image…frame(width: 14)).
        static let iconWidth: CGFloat = 14
        /// Spacer(minLength: 8) before the timestamp/scope.
        static let trailingSpacer: CGFloat = 8
        /// Plain subagent-summary leading indent (padding(.leading, 32)).
        static let plainIndent: CGFloat = 32
        static let cornerRadius: CGFloat = 6
    }

    // MARK: Fonts (map SwiftUI text styles → NSFont)

    private static let subheadlineFont = NSFont.preferredFont(forTextStyle: .subheadline)
    private static let caption2Font = NSFont.preferredFont(forTextStyle: .caption2)
    private static let calloutMonoFont = NSFont.monospacedSystemFont(
        ofSize: NSFont.preferredFont(forTextStyle: .callout).pointSize, weight: .regular)

    // MARK: Subviews

    private let backgroundBox = ActivityRoundedBoxView()
    private let iconView = NSImageView()
    private let titleField = NSTextField(labelWithString: "")
    private let badgeStack = NSStackView()
    private let timestampField = NSTextField(labelWithString: "")
    private let scopeView = NSImageView()

    // MARK: Constraints reconfigured per style

    private var widthConstraint: NSLayoutConstraint!
    private var heightConstraint: NSLayoutConstraint!
    private var iconLeading: NSLayoutConstraint!

    // MARK: State

    private var onOpen: (() -> Void)?
    private var trackingArea: NSTrackingArea?
    private var currentStyle: ActivityRowPresentation.RowStyle = .chrome
    /// Box fill alpha drives the hover-lift (0.4 → 0.65).
    private var hovering = false

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        translatesAutoresizingMaskIntoConstraints = false

        widthConstraint = widthAnchor.constraint(equalToConstant: 1)
        heightConstraint = heightAnchor.constraint(equalToConstant: 1)

        backgroundBox.cornerRadius = Metrics.cornerRadius
        backgroundBox.translatesAutoresizingMaskIntoConstraints = false

        iconView.translatesAutoresizingMaskIntoConstraints = false
        iconView.imageScaling = .scaleProportionallyDown
        iconView.contentTintColor = .secondaryLabelColor

        titleField.translatesAutoresizingMaskIntoConstraints = false
        titleField.maximumNumberOfLines = 1
        titleField.lineBreakMode = .byTruncatingTail
        titleField.cell?.lineBreakMode = .byTruncatingTail
        titleField.drawsBackground = false
        titleField.isBezeled = false
        titleField.isEditable = false
        titleField.isSelectable = false
        titleField.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        badgeStack.translatesAutoresizingMaskIntoConstraints = false
        badgeStack.orientation = .horizontal
        badgeStack.spacing = 4
        badgeStack.setContentCompressionResistancePriority(.defaultHigh, for: .horizontal)
        badgeStack.setContentHuggingPriority(.required, for: .horizontal)

        timestampField.translatesAutoresizingMaskIntoConstraints = false
        timestampField.font = Self.caption2Font
        timestampField.textColor = .tertiaryLabelColor
        timestampField.alignment = .right
        timestampField.drawsBackground = false
        timestampField.isBezeled = false
        timestampField.isEditable = false
        timestampField.isSelectable = false
        timestampField.maximumNumberOfLines = 1
        timestampField.setContentCompressionResistancePriority(.required, for: .horizontal)
        timestampField.setContentHuggingPriority(.required, for: .horizontal)

        scopeView.translatesAutoresizingMaskIntoConstraints = false
        scopeView.image = NSImage(systemSymbolName: "scope", accessibilityDescription: nil)
        scopeView.contentTintColor = .tertiaryLabelColor
        scopeView.imageScaling = .scaleProportionallyDown
        scopeView.alphaValue = 0
        scopeView.setContentCompressionResistancePriority(.required, for: .horizontal)
        scopeView.setContentHuggingPriority(.required, for: .horizontal)

        addSubview(backgroundBox)
        addSubview(iconView)
        addSubview(titleField)
        addSubview(badgeStack)
        addSubview(timestampField)
        addSubview(scopeView)

        let m = Metrics.self
        iconLeading = iconView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: m.insetLeading)

        NSLayoutConstraint.activate([
            widthConstraint,
            heightConstraint,

            backgroundBox.leadingAnchor.constraint(equalTo: leadingAnchor),
            backgroundBox.trailingAnchor.constraint(equalTo: trailingAnchor),
            backgroundBox.topAnchor.constraint(equalTo: topAnchor),
            backgroundBox.bottomAnchor.constraint(equalTo: bottomAnchor),

            iconLeading,
            iconView.centerYAnchor.constraint(equalTo: centerYAnchor),
            iconView.widthAnchor.constraint(equalToConstant: m.iconWidth),

            titleField.leadingAnchor.constraint(equalTo: iconView.trailingAnchor, constant: m.hStackSpacing),
            titleField.centerYAnchor.constraint(equalTo: centerYAnchor),

            badgeStack.leadingAnchor.constraint(
                greaterThanOrEqualTo: titleField.trailingAnchor, constant: m.hStackSpacing),
            badgeStack.centerYAnchor.constraint(equalTo: centerYAnchor),

            timestampField.leadingAnchor.constraint(
                greaterThanOrEqualTo: badgeStack.trailingAnchor, constant: m.trailingSpacer),
            timestampField.centerYAnchor.constraint(equalTo: centerYAnchor),

            scopeView.leadingAnchor.constraint(equalTo: timestampField.trailingAnchor, constant: m.hStackSpacing),
            scopeView.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -m.insetTrailing),
            scopeView.centerYAnchor.constraint(equalTo: centerYAnchor),
            scopeView.widthAnchor.constraint(equalToConstant: m.iconWidth)
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    // MARK: Configure

    /// Resets ALL state from `presentation`, pinned to `columnWidth × height`
    /// (the box `heightOfRow` measured). `onOpen` is invoked on click for chrome
    /// rows that carry a target.
    func configure(
        presentation: ActivityRowPresentation,
        columnWidth: CGFloat,
        height: CGFloat,
        onOpen: (() -> Void)?
    ) {
        currentStyle = presentation.style
        self.onOpen = onOpen
        hovering = false

        let w = max(columnWidth, 1)
        let h = max(height, 1)
        if abs(widthConstraint.constant - w) > 0.5 { widthConstraint.constant = w }
        if abs(heightConstraint.constant - h) > 0.5 { heightConstraint.constant = h }

        iconView.image = NSImage(systemSymbolName: presentation.iconSystemName, accessibilityDescription: nil)

        titleField.attributedStringValue = Self.attributedTitle(
            presentation.titleSegments, truncation: presentation.titleTruncation)
        titleField.lineBreakMode = presentation.titleTruncation
        titleField.cell?.lineBreakMode = presentation.titleTruncation

        rebuildBadges(presentation.badges)

        switch presentation.style {
        case .chrome:
            iconLeading.constant = Metrics.insetLeading
            iconView.contentTintColor = .secondaryLabelColor
            backgroundBox.fillColor = Self.boxColor(hovering: false)
            backgroundBox.isHidden = false
            scopeView.isHidden = false
            scopeView.alphaValue = 0
            if let ts = presentation.timestamp {
                timestampField.stringValue = ts.absoluteShort
                timestampField.isHidden = false
            } else {
                timestampField.stringValue = ""
                timestampField.isHidden = true
            }
        case .plainSummary:
            iconLeading.constant = Metrics.plainIndent
            iconView.contentTintColor = .tertiaryLabelColor
            backgroundBox.isHidden = true
            scopeView.isHidden = true
            scopeView.alphaValue = 0
            timestampField.stringValue = ""
            timestampField.isHidden = true
        }
    }

    /// Builds the one-line title `NSAttributedString`, joining segments with a
    /// space and mapping each segment's style to font + color (mirrors the
    /// `Text` styling inside the SwiftUI cards). A leading paragraph style carries
    /// the truncation mode so a single-line field truncates as specified.
    private static func attributedTitle(
        _ segments: [ActivityRowSegment], truncation: NSLineBreakMode
    ) -> NSAttributedString {
        let result = NSMutableAttributedString()
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = truncation
        for (index, segment) in segments.enumerated() {
            if index > 0 { result.append(NSAttributedString(string: " ")) }
            result.append(NSAttributedString(string: segment.text, attributes: attributes(for: segment.style)))
        }
        result.addAttribute(
            .paragraphStyle, value: paragraph, range: NSRange(location: 0, length: result.length))
        return result
    }

    private static func attributes(for style: ActivityRowSegment.Style) -> [NSAttributedString.Key: Any] {
        switch style {
        case .primary:
            return [.font: subheadlineFont, .foregroundColor: NSColor.labelColor]
        case .secondary:
            return [.font: subheadlineFont, .foregroundColor: NSColor.secondaryLabelColor]
        case .tertiary:
            return [.font: caption2Font, .foregroundColor: NSColor.tertiaryLabelColor]
        case .monospace:
            return [.font: calloutMonoFont, .foregroundColor: NSColor.secondaryLabelColor]
        }
    }

    private func rebuildBadges(_ badges: [ActivityRowBadge]) {
        for view in badgeStack.arrangedSubviews {
            badgeStack.removeArrangedSubview(view)
            view.removeFromSuperview()
        }
        for badge in badges {
            badgeStack.addArrangedSubview(Self.makeBadge(badge))
        }
        badgeStack.isHidden = badges.isEmpty
    }

    private static func makeBadge(_ badge: ActivityRowBadge) -> NSView {
        let label = NSTextField(labelWithString: badge.text)
        label.font = caption2Font
        label.drawsBackground = false
        label.isBezeled = false
        label.isEditable = false
        label.isSelectable = false
        label.translatesAutoresizingMaskIntoConstraints = false

        let box = ActivityRoundedBoxView()
        box.cornerRadius = 8
        box.translatesAutoresizingMaskIntoConstraints = false

        switch badge.kind {
        case .neutral:
            box.fillColor = NSColor.quaternaryLabelColor.withAlphaComponent(0.5)
            label.textColor = .secondaryLabelColor
        case .error:
            box.fillColor = NSColor.systemRed.withAlphaComponent(0.2)
            label.textColor = .systemRed
        }

        box.addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: box.leadingAnchor, constant: 5),
            label.trailingAnchor.constraint(equalTo: box.trailingAnchor, constant: -5),
            label.topAnchor.constraint(equalTo: box.topAnchor, constant: 1),
            label.bottomAnchor.constraint(equalTo: box.bottomAnchor, constant: -1)
        ])
        return box
    }

    // MARK: Box color (mirror ActivityRowChrome background)

    private static func boxColor(hovering: Bool) -> NSColor {
        NSColor.windowBackgroundColor.withAlphaComponent(hovering ? 0.65 : 0.4)
    }

    // MARK: Hover tracking

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(
            rect: .zero,
            options: [.activeInActiveApp, .inVisibleRect, .mouseEnteredAndExited],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseEntered(with event: NSEvent) {
        guard currentStyle == .chrome else { return }
        setHover(true)
    }

    override func mouseExited(with event: NSEvent) {
        guard currentStyle == .chrome else { return }
        setHover(false)
    }

    private func setHover(_ value: Bool) {
        guard hovering != value else { return }
        hovering = value
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.12
            ctx.allowsImplicitAnimation = true
            scopeView.animator().alphaValue = value ? 0.8 : 0
        }
        backgroundBox.fillColor = Self.boxColor(hovering: value)
    }

    // MARK: Click to open

    override func mouseDown(with event: NSEvent) {
        guard currentStyle == .chrome, let onOpen else {
            super.mouseDown(with: event)
            return
        }
        onOpen()
    }

    // MARK: Test backstop

    /// Realized drawn height of the cell's content (laid-out subtree height),
    /// for harness render==measure assertions.
    var realizedContentHeight: CGFloat {
        layoutSubtreeIfNeeded()
        return bounds.height
    }
}

/// A layer-backed rounded box (private to the activity cell) that re-resolves its
/// CGColor against the current appearance — the same pattern the bubble cell uses
/// for its tint, replicated here to avoid touching the bubble file. Decorative:
/// never intercepts the mouse, so the cell's own `mouseDown` handles clicks. (#129)
@MainActor
private final class ActivityRoundedBoxView: NSView {
    var fillColor: NSColor = .clear {
        didSet {
            guard fillColor != oldValue else { return }
            needsDisplay = true
        }
    }
    var cornerRadius: CGFloat = 6 {
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

    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}
