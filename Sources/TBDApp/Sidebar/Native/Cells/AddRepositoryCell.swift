import AppKit

/// The Add Repository row, the outline's last: the repo header's 10 pt `+`
/// and "Add Repository" in the secondary colour, as one button that runs the
/// folder picker, then a small chevron whose menu offers Local Folder… and
/// Clone from URL…. The controller wires both buttons' targets and builds the
/// menu.
///
/// The `+` starts at the section headers' leading inset, and every item
/// centres on the row's midline at whole-point origins, as
/// `SectionHeaderCell.layout()` places a header's. Both buttons draw the hover
/// wash the header's buttons draw, from the part the hover tracker reports.
final class AddRepositoryCell: NSTableCellView, SidebarHoverTarget {
    static let reuseIdentifier = NSUserInterfaceItemIdentifier("tbd.nativeSidebar.addRepository")
    static let title = "Add Repository"
    static let menuAccessibilityLabel = "More ways to add a repository"

    /// The sidebar's 26 pt minimum row height.
    static let rowHeight: CGFloat = 26

    /// The height of both buttons' hover wash, as the header's 20 pt squares.
    static let buttonHeight: CGFloat = 20
    /// How far the add button's wash reaches before the `+`.
    static let washPadding: CGFloat = 4
    /// The space a label's cell keeps clear on each side of its text.
    static let labelTextInset: CGFloat = 2
    /// From the `+`'s frame to the label's. With the label's own inset, the
    /// `+`'s ink sits about 5 pt from the "A".
    static let labelGap: CGFloat = 3
    /// The chevron's button: its glyph's point size, and its width, narrower
    /// than a square so the glyph sits close to the label.
    static let chevronSize: CGFloat = 8
    static let chevronWidth: CGFloat = 16
    /// Room kept clear at the row's trailing edge.
    static let trailingMargin: CGFloat = 4

    var leadingInset: CGFloat = SidebarNativeMetrics.headerContentInset {
        didSet { if leadingInset != oldValue { needsLayout = true } }
    }

    /// The `+` and the label: a click on either runs the folder picker.
    let addButton = AddRepositoryButton(frame: .zero)
    let plusView = SidebarCellKit.imageView()
    let titleField = SidebarCellKit.label(font: SidebarCellKit.nameFont, color: .secondaryLabelColor)
    /// Opens the row's menu.
    let menuButton = SidebarCellKit.hoverButton(symbol: "chevron.down", size: AddRepositoryCell.chevronSize)

    init() {
        super.init(frame: .zero)
        identifier = Self.reuseIdentifier
        addButton.isBordered = false
        addButton.setButtonType(.momentaryChange)
        addButton.title = ""
        addButton.imagePosition = .noImage
        addButton.focusRingType = .none
        addButton.refusesFirstResponder = true
        addButton.setAccessibilityLabel(Self.title)

        plusView.image = SidebarCellKit.symbol("plus", size: 10)
        plusView.contentTintColor = .secondaryLabelColor
        plusView.setAccessibilityElement(false)
        titleField.stringValue = Self.title
        titleField.setAccessibilityElement(false)
        addButton.addSubview(plusView)
        addButton.addSubview(titleField)

        menuButton.isHidden = false
        menuButton.setAccessibilityLabel(Self.menuAccessibilityLabel)
        addSubview(addButton)
        addSubview(menuButton)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var isFlipped: Bool { true }

    /// The row has no model; this resets what reuse may have changed.
    func configure() {
        titleField.stringValue = Self.title
        alphaValue = 1
        needsLayout = true
    }

    /// The button under the pointer draws its hover wash.
    func setHoveredPart(_ part: SidebarHoverPart) {
        addButton.showsHoverWash = part == .addRepository
        menuButton.showsHoverWash = part == .addRepositoryMenu
    }

    func hoverPart(at point: NSPoint) -> SidebarHoverPart {
        if menuButton.frame.contains(point) { return .addRepositoryMenu }
        if addButton.frame.contains(point) { return .addRepository }
        return .none
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        setHoveredPart(.none)
    }

    override func layout() {
        super.layout()
        let height = Self.buttonHeight
        // Every item centres on the row's own midline and starts on a whole
        // point: the buttons, and the `+` and label, which are placed in the
        // cell's coordinates and then moved into the add button's. The
        // button's origin is whole too, so they stay on whole points there.
        let midY = bounds.height / 2
        let buttonY = (midY - height / 2).rounded()
        let addX = leadingInset - Self.washPadding

        let plusSize = plusView.image?.size ?? NSSize(width: 10, height: 10)
        let plusSide = ceil(max(plusSize.width, plusSize.height))
        let plusFrame = NSRect(x: leadingInset, y: (midY - plusSide / 2).rounded(), width: plusSide, height: plusSide)

        let titleSize = SidebarCellKit.size(of: titleField)
        let titleX = plusFrame.maxX + Self.labelGap
        // The wash reaches as far past the last letter as before the `+`.
        let washAfterTitle = Self.washPadding - Self.labelTextInset
        // The label gives up width before the chevron leaves the row.
        let room = bounds.width - titleX - washAfterTitle - Self.chevronWidth - Self.trailingMargin
        let titleWidth = min(titleSize.width, max(room, 0))
        let titleFrame = NSRect(
            x: titleX, y: (midY - titleSize.height / 2).rounded(), width: titleWidth, height: titleSize.height)

        addButton.frame = NSRect(x: addX, y: buttonY, width: titleFrame.maxX + washAfterTitle - addX, height: height)
        plusView.frame = plusFrame.offsetBy(dx: -addX, dy: -buttonY)
        titleField.frame = titleFrame.offsetBy(dx: -addX, dy: -buttonY)
        menuButton.frame = NSRect(x: addButton.frame.maxX, y: buttonY, width: Self.chevronWidth, height: height)
    }
}

/// The Add Repository row's `+`-and-label button. The `+` and the label are
/// its subviews, laid out by the cell, and a click on either is the button's:
/// a label or an image view would otherwise take the mouse-down itself.
final class AddRepositoryButton: SidebarHoverButton {
    override var isFlipped: Bool { true }

    override func hitTest(_ point: NSPoint) -> NSView? {
        super.hitTest(point) == nil ? nil : self
    }
}
