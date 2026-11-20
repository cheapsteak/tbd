import AppKit

/// A repo or Scratch section header, drawn from a `SectionHeaderModel`: the
/// title, the disclosure chevron on whichever side
/// `AppState.chevronBeforeProjectNameKey` puts it, a repo's registry filter
/// right after the title and chevron, and a missing repo's "[missing]" badge
/// with its Locate… link.
///
/// Before the title the chevron is always shown. After it — the default — it
/// appears only while the section is revealed, with the `+`: a repo section is
/// revealed while the pointer is over its header or any of its rows, and for
/// 80 ms after it leaves; the Scratch section while the pointer is over its
/// header. The `+` also stays while its menu is open. The chevron keeps its
/// square while hidden so nothing beside it slides. The registry filter
/// (`docs/specs/2026-11-19-sidebar-remote-session-filter-design.md`, "The
/// button") shows with the `+` while off and always while on, and keeps its
/// room whenever the repo has one — its square, or while on the width of the
/// largest count it can show — so neither a hover nor a selection that lowers
/// the count moves or cuts the title. The chevron, filter, `+` and Locate…
/// buttons send their actions to whatever target the controller wires. A repo
/// title can be swapped for the inline rename editor.
final class SectionHeaderCell: NSTableCellView, SidebarHoverTarget, SidebarRenamableCell {
    enum Style: Equatable {
        /// 12 pt semibold, dimmed while the repo is missing.
        case repo
        /// The `.headline` "Scratch" title.
        case scratch
    }

    static let reuseIdentifier = NSUserInterfaceItemIdentifier("tbd.nativeSidebar.sectionHeader")

    /// A header's content is 22 pt or shorter, raised to the sidebar's 26 pt
    /// minimum row height.
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

    /// The registry filter's symbol while off, and while on.
    static let filterOffSymbol = "line.3.horizontal.decrease.circle"
    static let filterOnSymbol = "line.3.horizontal.decrease.circle.fill"
    /// The square a repo's registry filter keeps in the layout, drawn or not.
    static let filterSide: CGFloat = 20

    let chevronButton = SidebarCellKit.hoverButton(symbol: "chevron.right")
    /// A repo's registry filter: hides or shows the repo's registry-provider
    /// rows and sessions.
    let filterButton = SidebarCellKit.hoverButton(symbol: SectionHeaderCell.filterOffSymbol, size: 11)
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
        for view in [chevronButton, titleField, filterButton, missingField, locateButton, plusButton] as [NSView] {
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
        configureFilter()
        updateControls()

        let showsMissing = style == .repo && model.isMissing
        missingField.isHidden = !showsMissing
        locateButton.isHidden = !showsMissing

        // A hidden repo's whole section draws at 0.55.
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
        filterButton.showsHoverWash = part == .registryFilter
        plusButton.showsHoverWash = part == .plus
    }

    /// `SidebarHeaderMetrics.chevronMounted` over `HoverMenuModel`'s gate.
    /// The registry filter shows with the `+` while off and always while on,
    /// and never during a rename.
    private func updateControls() {
        let shown = HoverMenuModel.shouldShowPlus(hovered: isRevealed, menuOpen: isMenuOpen)
        plusButton.isHidden = !shown
        chevronButton.isHidden = !SidebarHeaderMetrics.chevronMounted(beforeTitle: chevronBeforeTitle, revealed: shown)
        filterButton.isHidden = isRenaming || (registryFilter.map { !$0.isOn && !shown } ?? true)
    }

    func hoverPart(at point: NSPoint) -> SidebarHoverPart {
        if !chevronButton.isHidden, chevronButton.frame.contains(point) { return .chevron }
        if !filterButton.isHidden, filterButton.frame.contains(point) { return .registryFilter }
        if !plusButton.isHidden, plusButton.frame.contains(point) { return .plus }
        return .none
    }

    // MARK: Registry filter

    /// The repo's registry filter button; nil for the Scratch header and a
    /// repo with nothing to hide.
    private var registryFilter: SidebarRegistryFilterButton? {
        style == .repo ? model?.registryFilter : nil
    }

    /// Off: the outlined symbol in the secondary colour. On: the filled
    /// symbol and the count, in the accent colour.
    private func configureFilter() {
        guard let filter = registryFilter else {
            filterButton.toolTip = nil
            filterButton.setAccessibilityLabel(nil)
            return
        }
        if filter.isOn {
            filterButton.image = SidebarCellKit.symbol(Self.filterOnSymbol, size: 11)
            filterButton.contentTintColor = .controlAccentColor
            filterButton.imagePosition = .imageLeading
            filterButton.attributedTitle = Self.filterCountTitle(filter.count)
        } else {
            filterButton.image = SidebarCellKit.symbol(Self.filterOffSymbol, size: 11)
            filterButton.contentTintColor = .secondaryLabelColor
            filterButton.imagePosition = .imageOnly
            filterButton.title = ""
        }
        filterButton.toolTip = filter.tooltip
        filterButton.setAccessibilityLabel(filter.tooltip)
        filterButton.alphaValue = model?.isMissing == true ? 0.5 : 1
    }

    /// The registry filter's widths: the room it keeps in the layout whether
    /// drawn or not, and the width it draws at. Off, both are its square. On,
    /// it draws at its count, and keeps the room of the largest count it can
    /// show, `hideableCount`: selecting a hidden row lowers the count, and a
    /// room that followed the count would move a truncated title's cut. Nil
    /// when the repo has no button.
    private var filterWidths: (room: CGFloat, drawn: CGFloat)? {
        guard let filter = registryFilter else { return nil }
        guard filter.isOn else { return (Self.filterSide, Self.filterSide) }
        return (room: Self.filterOnWidth(count: max(filter.count, filter.hideableCount)),
                drawn: Self.filterOnWidth(count: filter.count))
    }

    /// The count drawn beside the filled symbol while on.
    private static func filterCountTitle(_ count: Int) -> NSAttributedString {
        NSAttributedString(
            string: "\(count)",
            attributes: [.font: SidebarCellKit.filterCountFont, .foregroundColor: NSColor.controlAccentColor])
    }

    /// The on button's width at `count`, never below its square: measured by
    /// the cell of `filterMeasure`, never `intrinsicContentSize`. The count
    /// font's digits are all one width, so a larger count is never narrower.
    private static func filterOnWidth(count: Int) -> CGFloat {
        let measure = filterMeasure
        measure.attributedTitle = filterCountTitle(count)
        return max(filterSide, ceil(measure.cell?.cellSize.width ?? filterSide) + 4)
    }

    /// A stand-in configured as `filterButton` is while on.
    /// `filterOnWidth(count:)` titles it with any count to measure it, so the
    /// shown button is never retitled to be measured.
    @MainActor private static let filterMeasure: SidebarHoverButton = {
        let button = SidebarCellKit.hoverButton(symbol: SectionHeaderCell.filterOnSymbol, size: 11)
        button.imagePosition = .imageLeading
        return button
    }()

    // MARK: Rename

    func beginRename(_ editor: SidebarRenameEditor) {
        renameEditor?.view.removeFromSuperview()
        renameEditor = editor
        titleField.isHidden = true
        addSubview(editor.view)
        updateControls()
        needsLayout = true
    }

    func endRename() {
        renameEditor?.view.removeFromSuperview()
        renameEditor = nil
        titleField.isHidden = false
        updateControls()
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
        // Every item, in both styles, centres on the row's midline: the
        // chevron and `+` squares, the title, the missing badge and Locate….
        // Each origin rounds to a whole point, so no square or label straddles
        // device pixels.
        let midY = bounds.height / 2
        let chevronY = (midY - chevronSide / 2).rounded()
        var x = leadingInset

        let titleSize = SidebarCellKit.size(of: titleField)
        let missingSize = missingField.isHidden ? NSSize.zero : SidebarCellKit.size(of: missingField)
        let locateSize = locateButton.isHidden ? NSSize.zero : locateButton.intrinsicContentSize
        // Room kept for the hover `+` (a 20 pt square) at the trailing edge.
        let reserved: CGFloat = 20 + spacing
        // The registry filter's room, kept whether or not it is drawn, so a
        // long title truncates by it and neither a hover nor a lower count
        // moves the title.
        let filterWidths = self.filterWidths
        var after: CGFloat = 0
        if !chevronBeforeTitle { after += spacing + chevronSide - 3 }
        if let filterWidths { after += spacing + filterWidths.room }
        if !missingField.isHidden { after += spacing + missingSize.width + spacing + locateSize.width }

        if chevronBeforeTitle {
            chevronButton.frame = NSRect(x: x, y: chevronY, width: chevronSide, height: chevronSide)
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
            // Tucked 3 pt into the spacing against the title, on the same
            // midline. It keeps its square while hidden.
            x += spacing - 3
            chevronButton.frame = NSRect(x: x, y: chevronY, width: chevronSide, height: chevronSide)
            x += chevronSide
        }
        // Directly after the title and chevron, on whichever side the chevron
        // draws: `name ▸ [filter]` or `▸ name [filter]`.
        if let filterWidths {
            x += spacing
            filterButton.frame = NSRect(
                x: x, y: (midY - Self.filterSide / 2).rounded(), width: filterWidths.drawn, height: Self.filterSide)
            x += filterWidths.room
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
        plusButton.frame = NSRect(x: bounds.width - 20 - 4, y: (midY - 10).rounded(), width: 20, height: 20)
    }
}
