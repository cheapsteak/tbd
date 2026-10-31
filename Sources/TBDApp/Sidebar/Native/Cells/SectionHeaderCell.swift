import AppKit

/// A repo or Scratch section header, drawn from a `SectionHeaderModel` as
/// `RepoSectionView.headerRow` and `ScratchSectionView`'s header draw it: the
/// title, the disclosure chevron on whichever side
/// `AppState.chevronBeforeProjectNameKey` puts it, and a missing repo's
/// "[missing]" badge with its Locate… link.
///
/// Before the title the chevron is always shown. After it — the default — it
/// appears only while the section is revealed, with the `+`: a repo section is
/// revealed while the pointer is over its header or any of its rows, and for
/// 80 ms after it leaves; the Scratch section while the pointer is over its
/// header. The `+` also stays while its menu is open. The chevron keeps its
/// square while hidden so nothing beside it slides. The chevron, `+` and
/// Locate… buttons send their actions to whatever target the controller
/// wires. A repo title can be swapped for the inline rename editor.
final class SectionHeaderCell: NSTableCellView, SidebarHoverTarget, SidebarRenamableCell {
    enum Style: Equatable {
        /// 12 pt semibold, dimmed while the repo is missing.
        case repo
        /// The `.headline` "Scratch" title.
        case scratch
    }

    static let reuseIdentifier = NSUserInterfaceItemIdentifier("tbd.nativeSidebar.sectionHeader")

    /// The SwiftUI headers are 22 pt (`RepoSectionView`'s `.frame(height: 22)`)
    /// or shorter, raised to the `List`'s `defaultMinListRowHeight` of 26.
    static let rowHeight: CGFloat = 26

    static func height(for model: SectionHeaderModel) -> CGFloat {
        rowHeight
    }

    /// Set before `configure(_:)`; a reused cell can change style.
    var style: Style = .repo
    var chevronBeforeTitle = false {
        didSet { if chevronBeforeTitle != oldValue { needsLayout = true } }
    }
    var leadingInset: CGFloat = SidebarNativeMetrics.headerContentInset {
        didSet { if leadingInset != oldValue { needsLayout = true } }
    }

    let chevronButton = SidebarCellKit.hoverButton(symbol: "chevron.right")
    /// A repo's new-worktree `+` (hover opens the profile picker), or the
    /// Scratch section's new-scratch-space `+`.
    let plusButton = SidebarCellKit.hoverButton()
    let titleField = SidebarCellKit.label(font: SidebarCellKit.sectionTitleFont, color: .secondaryLabelColor)
    let missingField = SidebarCellKit.label(font: SidebarCellKit.captionFont, color: .systemRed)
    let locateButton = NSButton(frame: .zero)

    private(set) var model: SectionHeaderModel?
    /// The section's `+` and trailing chevron are showing.
    private(set) var isRevealed = false
    private(set) var isMenuOpen = false
    private(set) var renameEditor: SidebarRenameEditor?

    init() {
        super.init(frame: .zero)
        identifier = Self.reuseIdentifier
        textField = titleField
        missingField.stringValue = "[missing]"
        missingField.alphaValue = 0.7
        locateButton.isBordered = false
        locateButton.setButtonType(.momentaryChange)
        locateButton.focusRingType = .none
        locateButton.attributedTitle = NSAttributedString(
            string: "Locate…",
            attributes: [.font: SidebarCellKit.captionFont, .foregroundColor: NSColor.linkColor])
        for view in [chevronButton, titleField, missingField, locateButton, plusButton] as [NSView] {
            addSubview(view)
        }
        chevronButton.isHidden = false
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var isFlipped: Bool { true }

    func configure(_ model: SectionHeaderModel) {
        self.model = model
        titleField.stringValue = model.title
        titleField.isHidden = isRenaming
        titleField.font = style == .scratch ? SidebarCellKit.headlineFont : SidebarCellKit.sectionTitleFont
        titleField.textColor = model.isSelected && !model.isMissing ? .labelColor : .secondaryLabelColor
        titleField.alphaValue = model.isMissing ? 0.5 : 1

        let glyph = model.isExpanded ? "chevron.down" : "chevron.right"
        chevronButton.image = SidebarCellKit.symbol(glyph, size: chevronBeforeTitle ? 11 : 10)
        chevronButton.contentTintColor = .secondaryLabelColor
        chevronButton.alphaValue = model.isMissing ? 0.5 : 1
        chevronButton.drawsWash = !chevronBeforeTitle
        chevronButton.setAccessibilityLabel(
            model.isExpanded ? "Collapse \(model.title)" : "Expand \(model.title)")
        chevronButton.toolTip = model.isExpanded ? "Collapse" : "Expand"

        // A missing repo's `+` is disabled, and the controller never opens
        // its picker. No tooltip on the repo `+`: it would cover the picker.
        plusButton.isEnabled = !(style == .repo && model.isMissing)
        plusButton.toolTip = style == .scratch ? "New scratch space" : nil
        plusButton.setAccessibilityLabel(style == .scratch ? "New scratch space" : "New worktree")
        updateControls()

        let showsMissing = style == .repo && model.isMissing
        missingField.isHidden = !showsMissing
        locateButton.isHidden = !showsMissing

        // A hidden repo's whole section draws at 0.55 in the SwiftUI sidebar.
        alphaValue = model.isHidden ? 0.55 : 1
        setAccessibilityLabel(model.isMissing ? "\(model.title), missing" : model.title)
        needsLayout = true
    }

    /// Reveals or hides the trailing chevron and the `+`.
    func setHovered(_ revealed: Bool) {
        guard revealed != isRevealed else { return }
        isRevealed = revealed
        updateControls()
    }

    func setMenuOpen(_ open: Bool) {
        guard open != isMenuOpen else { return }
        isMenuOpen = open
        updateControls()
    }

    /// The control under the pointer draws its hover wash.
    func setHoveredPart(_ part: SidebarHoverPart) {
        chevronButton.showsHoverWash = part == .chevron
        plusButton.showsHoverWash = part == .plus
    }

    /// `SidebarHeaderMetrics.chevronMounted` over `HoverMenuModel`'s gate, as
    /// `RepoSectionView.chevronMounted` composes them.
    private func updateControls() {
        let shown = HoverMenuModel.shouldShowPlus(hovered: isRevealed, menuOpen: isMenuOpen)
        plusButton.isHidden = !shown
        chevronButton.isHidden = !SidebarHeaderMetrics.chevronMounted(beforeTitle: chevronBeforeTitle, revealed: shown)
    }

    func hoverPart(at point: NSPoint) -> SidebarHoverPart {
        if !chevronButton.isHidden, chevronButton.frame.contains(point) { return .chevron }
        if !plusButton.isHidden, plusButton.frame.contains(point) { return .plus }
        return .none
    }

    // MARK: Rename

    func beginRename(_ editor: SidebarRenameEditor) {
        renameEditor?.view.removeFromSuperview()
        renameEditor = editor
        titleField.isHidden = true
        addSubview(editor.view)
        needsLayout = true
    }

    func endRename() {
        renameEditor?.view.removeFromSuperview()
        renameEditor = nil
        titleField.isHidden = false
        needsLayout = true
    }

    override func prepareForReuse() {
        releaseRenameForReuse()
        super.prepareForReuse()
        model = nil
        isRevealed = false
        isMenuOpen = false
        setHoveredPart(.none)
        updateControls()
    }

    override func layout() {
        super.layout()
        let chevronSide = SidebarHeaderMetrics.chevronColumnWidth
        let spacing = SidebarHeaderMetrics.headerSpacing
        // The repo header's 22 pt band sits centred in the row with its items
        // bottom-aligned in a 20 pt stack; the Scratch header centres its stack.
        let midY = style == .repo ? bounds.height / 2 + 1 : bounds.height / 2
        var x = leadingInset

        let titleSize = SidebarCellKit.size(of: titleField)
        let missingSize = missingField.isHidden ? NSSize.zero : SidebarCellKit.size(of: missingField)
        let locateSize = locateButton.isHidden ? NSSize.zero : locateButton.intrinsicContentSize
        // Room kept for the hover `+` (a 20 pt square) at the trailing edge.
        let reserved: CGFloat = 20 + spacing
        var after: CGFloat = 0
        if !chevronBeforeTitle { after += spacing + chevronSide - 3 }
        if !missingField.isHidden { after += spacing + missingSize.width + spacing + locateSize.width }

        if chevronBeforeTitle {
            chevronButton.frame = NSRect(x: x, y: midY - chevronSide / 2, width: chevronSide, height: chevronSide)
            x += chevronSide + spacing + SidebarHeaderMetrics.nameLeadingClawback
        }
        let titleWidth = min(titleSize.width, max(bounds.width - x - after - reserved, 0))
        titleField.frame = NSRect(
            x: x, y: (midY - titleSize.height / 2).rounded(), width: titleWidth, height: titleSize.height)
        if let editor = renameEditor {
            editor.view.frame = NSRect(
                x: x, y: 0, width: max(bounds.width - x - reserved, 40), height: bounds.height)
        }
        x += titleWidth
        if !chevronBeforeTitle {
            // `.padding(.leading, -3).offset(y: 2)`: tucked against the title,
            // on its baseline. It keeps its square while hidden.
            x += spacing - 3
            chevronButton.frame = NSRect(
                x: x, y: midY - chevronSide / 2 + 2, width: chevronSide, height: chevronSide)
            x += chevronSide
        }
        if !missingField.isHidden {
            x += spacing
            missingField.frame = NSRect(
                x: x, y: (midY - missingSize.height / 2).rounded(), width: missingSize.width, height: missingSize.height)
            x += missingSize.width + spacing
            locateButton.frame = NSRect(
                x: x, y: (midY - locateSize.height / 2).rounded(), width: locateSize.width, height: locateSize.height)
        }
        // The `+` after the `Spacer()`, at the trailing edge.
        plusButton.frame = NSRect(x: bounds.width - 20 - 4, y: midY - 10, width: 20, height: 20)
    }
}
