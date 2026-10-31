import AppKit
import TBDShared

/// A Remote, Exited, Ended or Hibernated disclosure, drawn from a
/// `GroupHeaderModel` as `SidebarGroupHeader` draws it: the small chevron, the
/// title with its summary line beneath, and on the trailing edge the attention
/// glyph or, failing one, the uncertainty mark. The whole row is the toggle;
/// the controller runs it from the outline's click action.
final class GroupHeaderCell: NSTableCellView {
    static let reuseIdentifier = NSUserInterfaceItemIdentifier("tbd.nativeSidebar.groupHeader")

    /// Title alone: a 16 pt line plus 4 pt above and below, raised to the
    /// `List`'s 26 pt minimum.
    static let singleHeight: CGFloat = 26
    /// Title, 1 pt, a 10 pt summary line, and the same 4 pt padding.
    static let summaryHeight: CGFloat = 36

    static func height(for model: GroupHeaderModel) -> CGFloat {
        switch model.heightClass {
        case .single: singleHeight
        case .withSubtitle: summaryHeight
        }
    }

    var leadingInset: CGFloat = SidebarNativeMetrics.rowContentInset(chevronBeforeTitle: false) {
        didSet { if leadingInset != oldValue { needsLayout = true } }
    }

    let chevronImageView = SidebarCellKit.imageView()
    let titleField = SidebarCellKit.label(font: SidebarCellKit.groupTitleFont)
    let summaryField = SidebarCellKit.label(font: SidebarCellKit.captionFont, color: .secondaryLabelColor)
    let trailingImageView = SidebarCellKit.imageView()

    private(set) var model: GroupHeaderModel?

    init() {
        super.init(frame: .zero)
        identifier = Self.reuseIdentifier
        textField = titleField
        chevronImageView.contentTintColor = .labelColor
        for view in [chevronImageView, titleField, summaryField, trailingImageView] as [NSView] {
            addSubview(view)
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var isFlipped: Bool { true }

    func configure(_ model: GroupHeaderModel) {
        self.model = model
        chevronImageView.image = SidebarCellKit.symbol(
            model.isExpanded ? "chevron.down" : "chevron.right", size: 9, weight: .semibold)
        titleField.stringValue = model.title
        summaryField.stringValue = model.summary ?? ""
        summaryField.isHidden = model.summary == nil

        if let attention = model.attention {
            let isError = attention == .error
            trailingImageView.image = SidebarCellKit.symbol(
                isError ? "exclamationmark.octagon.fill" : "hand.raised.fill", size: 13)
            trailingImageView.contentTintColor = isError ? .systemRed : .systemOrange
        } else if model.hasUncertainty {
            trailingImageView.image = SidebarCellKit.symbol("questionmark.circle", size: 13)
            trailingImageView.contentTintColor = .secondaryLabelColor
        } else {
            trailingImageView.image = nil
        }
        trailingImageView.isHidden = trailingImageView.image == nil

        alphaValue = model.isInHiddenSection ? 0.55 : 1
        setAccessibilityLabel(model.summary.map { "\(model.title), \($0)" } ?? model.title)
        setAccessibilityValue(model.isExpanded ? "Expanded" : "Collapsed")
        needsLayout = true
    }

    /// The hover hook, for parity with the other cells.
    func setHovered(_ hovered: Bool) {}

    override func prepareForReuse() {
        super.prepareForReuse()
        model = nil
    }

    override func layout() {
        super.layout()
        let titleSize = SidebarCellKit.size(of: titleField)
        let summarySize = summaryField.isHidden ? NSSize.zero : SidebarCellKit.size(of: summaryField)
        let textHeight = titleSize.height + (summaryField.isHidden ? 0 : 1 + summarySize.height)
        let contentHeight = max(16, textHeight)
        // `HStack(alignment: .top)` padded 4 pt vertically, centred in the row.
        let top = ((bounds.height - contentHeight) / 2).rounded()
        var x = leadingInset
        chevronImageView.frame = NSRect(x: x, y: top, width: 12, height: 16)
        x += 12 + 6

        let trailingSide: CGFloat = 16
        let trailingRoom = trailingImageView.isHidden ? 0 : 2 + trailingSide
        let textWidth = max(bounds.width - x - trailingRoom, 0)
        titleField.frame = NSRect(x: x, y: top, width: min(titleSize.width, textWidth), height: titleSize.height)
        if !summaryField.isHidden {
            summaryField.frame = NSRect(
                x: x, y: top + titleSize.height + 1, width: min(summarySize.width, textWidth), height: summarySize.height)
        }
        if !trailingImageView.isHidden {
            trailingImageView.frame = NSRect(
                x: bounds.width - trailingSide, y: top, width: trailingSide, height: trailingSide)
        }
    }
}
