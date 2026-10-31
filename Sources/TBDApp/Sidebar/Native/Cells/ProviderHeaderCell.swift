import AppKit
import TBDShared

/// A provider header in the Remote section, drawn from a `ProviderHeaderModel`
/// as `RemoteProviderHeaderRow` draws it: the provider's name across the free
/// width, the health glyph at the trailing edge, and the issue line under the
/// name while the provider is unhealthy. The selected provider's tinted
/// background is the row view's. The create `+` and the needs-auth popover are
/// controls added on top of this cell.
final class ProviderHeaderCell: NSTableCellView {
    static let reuseIdentifier = NSUserInterfaceItemIdentifier("tbd.nativeSidebar.providerHeader")

    /// The name alone: `.frame(minHeight: 22)` raised to the `List`'s 26 pt.
    static let singleHeight: CGFloat = 26
    /// The name and the issue line stacked at -1 pt.
    static let subtitleHeight: CGFloat = 28

    static func height(for model: ProviderHeaderModel) -> CGFloat {
        switch model.heightClass {
        case .single: singleHeight
        case .withSubtitle: subtitleHeight
        }
    }

    /// Where the title starts: the header inset plus the title column the
    /// chevron placement sets.
    var leadingInset: CGFloat = SidebarNativeMetrics.headerContentInset {
        didSet { if leadingInset != oldValue { needsLayout = true } }
    }

    let nameField = SidebarCellKit.label(font: SidebarCellKit.sectionTitleFont, color: .secondaryLabelColor)
    let healthImageView = SidebarCellKit.imageView()
    let issueField = SidebarCellKit.label(font: SidebarCellKit.captionFont, color: .secondaryLabelColor)

    private(set) var model: ProviderHeaderModel?

    init() {
        super.init(frame: .zero)
        identifier = Self.reuseIdentifier
        textField = nameField
        addSubview(nameField)
        addSubview(healthImageView)
        addSubview(issueField)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var isFlipped: Bool { true }

    func configure(_ model: ProviderHeaderModel) {
        self.model = model
        nameField.stringValue = model.name
        nameField.textColor = model.isSelected ? .labelColor : .secondaryLabelColor
        switch model.health {
        case .stale:
            healthImageView.image = SidebarCellKit.symbol("clock.badge.exclamationmark", size: 11)
            healthImageView.contentTintColor = .secondaryLabelColor
        case .needsAuth:
            healthImageView.image = SidebarCellKit.symbol("key.slash", size: 11)
            healthImageView.contentTintColor = SidebarCellKit.suffixTint(.attention).color
        case .error:
            healthImageView.image = SidebarCellKit.symbol("exclamationmark.triangle", size: 11)
            healthImageView.contentTintColor = SidebarCellKit.suffixTint(.error).color
        case .ok:
            healthImageView.image = nil
        }
        healthImageView.isHidden = healthImageView.image == nil
        issueField.stringValue = model.issueSummary ?? ""
        issueField.isHidden = model.issueSummary == nil
        alphaValue = 1
        setAccessibilityLabel([model.name, model.issueSummary].compactMap { $0 }.joined(separator: ", "))
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
        let nameSize = SidebarCellKit.size(of: nameField)
        let issueSize = issueField.isHidden ? NSSize.zero : SidebarCellKit.size(of: issueField)
        let healthSide: CGFloat = 14
        let healthRoom = healthImageView.isHidden ? 0 : SidebarHeaderMetrics.headerSpacing + healthSide
        let x = leadingInset
        let textWidth = max(bounds.width - x - healthRoom - 4, 0)
        // Bottom-aligned in a 22 pt box centred in the row; with the issue
        // line the stack fills the row.
        let stackHeight = nameSize.height + (issueField.isHidden ? 0 : issueSize.height - 1)
        let boxBottom = issueField.isHidden ? (bounds.height + 22) / 2 : bounds.height
        let top = (boxBottom - stackHeight).rounded()
        nameField.frame = NSRect(x: x, y: top, width: min(nameSize.width, textWidth), height: nameSize.height)
        if !issueField.isHidden {
            issueField.frame = NSRect(
                x: x, y: top + nameSize.height - 1, width: min(issueSize.width, textWidth), height: issueSize.height)
        }
        if !healthImageView.isHidden {
            healthImageView.frame = NSRect(
                x: bounds.width - 4 - healthSide, y: (nameField.frame.midY - healthSide / 2).rounded(),
                width: healthSide, height: healthSide)
        }
    }
}
