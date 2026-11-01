import AppKit

/// A worktree row, drawn from a `WorktreeRowModel` as `WorktreeRowView` draws
/// it: the leading slot (PR glyph, PR-unknown mark, pending glyph or remote
/// globe), the name with its subtitles, then the status suffix or typing dots,
/// the no-status mark, the dev-server dot and the cross-repo suffix, packed
/// against the name as the SwiftUI `HStack` packs them.
///
/// The cell never reads `AppState`. Its frame starts at the row's depth (the
/// outline's `frameOfCell` places it); `leadingInset` is the row inset every
/// row under a section title carries.
///
/// On top of the drawing sit the row's two controls, as overlays that take no
/// layout width: the pin toggle in the gutter left of the content (shown on
/// hover, and always once pinned) and the nested `+` at the trailing edge
/// (shown on hover or while its menu is open). They are real `NSButton`s, so a
/// press on one tracks the button; a press anywhere else — the PR glyph
/// included — reaches the outline and can start a drag. A click on the PR
/// glyph opens the pull request through the outline's click action
/// (`isPullRequestGlyph(at:)`). The buttons send their actions to whatever
/// target the controller wires. The pin, the nested `+` and opening the pull
/// request are also offered as accessibility custom actions.
final class WorktreeRowCell: NSTableCellView, SidebarHoverTarget, SidebarRenamableCell {
    static let reuseIdentifier = NSUserInterfaceItemIdentifier("tbd.nativeSidebar.worktreeRow")

    /// The row with a subtitle line. `WorktreeRowView` pins
    /// `.frame(height: rowHeight)` for every variant — the dock's height
    /// arithmetic counts on it — so the subtitle row is the same 28 pt, with
    /// the name and subtitle stacked at -2 pt spacing inside it.
    /// `SidebarCellTests.heightMatchesClass` measures the SwiftUI row against
    /// this value.
    static let subtitleRowHeight: CGFloat = 28

    /// `WorktreeRowView.pinButtonGutter`: the pin's 20 pt square sits that far
    /// left of the row content, clearing the leading glyph exactly.
    static let pinGutter: CGFloat = 20

    static let pinActionName = "Pin to dock"
    static let unpinActionName = "Unpin from dock"
    static let nestedWorktreeActionName = "New nested worktree"
    static let openPullRequestActionName = "Open pull request"

    static func height(for model: WorktreeRowModel) -> CGFloat {
        switch model.heightClass {
        case .single: WorktreeRowView.rowHeight
        case .withSubtitle: subtitleRowHeight
        }
    }

    /// Where the row's content starts inside the cell.
    var leadingInset: CGFloat = SidebarNativeMetrics.rowContentInset(chevronBeforeTitle: false) {
        didSet { if leadingInset != oldValue { needsLayout = true } }
    }

    let leadingImageView = SidebarCellKit.imageView()
    let nameField = SidebarCellKit.label(font: SidebarCellKit.nameFont)
    private(set) var subtitleFields: [NSTextField] = []
    private(set) lazy var suffix = SuffixSlot(in: self)
    let noStatusImageView = SidebarCellKit.imageView()
    let devServerDot = StatusDotView(color: .systemGreen, diameter: 6)
    let crossRepoField = SidebarCellKit.label(font: SidebarCellKit.captionFont, color: .secondaryLabelColor)

    let pinButton = SidebarCellKit.hoverButton(symbol: "pin")
    let plusButton = SidebarCellKit.hoverButton()
    let toolTips = SidebarToolTips()
    /// Opens the row's pull request, for the accessibility action; the
    /// controller sets it.
    var onOpenPullRequest: (() -> Bool)?

    private(set) var model: WorktreeRowModel?
    private(set) var isHovered = false
    /// The nested `+`'s menu is open, which keeps the `+` shown after the
    /// pointer leaves the row for the menu.
    private(set) var isMenuOpen = false
    private(set) var hoveredPart: SidebarHoverPart = .none
    /// The row's section chevron is hovered: the cell draws at
    /// `SidebarCellKit.chevronHoverOpacity` of its own opacity. The cell dims,
    /// not the row view, so the selection tint and the guide lines keep
    /// theirs, as in the SwiftUI row.
    private(set) var isDimmedByChevron = false
    /// The name is wider than the room it has: hovering the row shows it in
    /// the tooltip bubble.
    private(set) var isNameTruncated = false
    private(set) var renameEditor: SidebarRenameEditor?

    init() {
        super.init(frame: .zero)
        identifier = Self.reuseIdentifier
        textField = nameField
        for view in [leadingImageView, nameField, noStatusImageView, devServerDot, crossRepoField] as [NSView] {
            addSubview(view)
        }
        _ = suffix
        noStatusImageView.image = SidebarCellKit.symbol(NoStatusMark.systemImage, size: 10)
        noStatusImageView.contentTintColor = .tertiaryLabelColor
        devServerDot.toolTip = "A dev server is running"
        devServerDot.setAccessibilityLabel("Dev server running")
        // No tooltip on the nested `+`: hovering it opens the profile picker,
        // which a tooltip would cover.
        addSubview(pinButton)
        addSubview(plusButton)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var isFlipped: Bool { true }

    /// Sets every property the model drives, opacity included:
    /// `prepareForReuse` resets a reused view's alpha. A rename in progress is
    /// left alone: the label stays hidden under the editor.
    func configure(_ model: WorktreeRowModel) {
        self.model = model
        configureLeading(model.leading)

        nameField.stringValue = model.name
        nameField.font = model.isNameBold ? SidebarCellKit.boldNameFont : SidebarCellKit.nameFont
        nameField.isHidden = isRenaming
        while subtitleFields.count < model.subtitles.count {
            let field = SidebarCellKit.label(font: SidebarCellKit.captionFont, color: .secondaryLabelColor)
            addSubview(field, positioned: .below, relativeTo: pinButton)
            subtitleFields.append(field)
        }
        for (index, field) in subtitleFields.enumerated() {
            let shown = index < model.subtitles.count
            field.stringValue = shown ? model.subtitles[index] : ""
            field.isHidden = !shown
        }

        suffix.show(model.suffix)
        noStatusImageView.isHidden = !model.showsNoStatusMark
        noStatusImageView.setAccessibilityLabel(NoStatusMark.accessibilityLabel)
        devServerDot.isHidden = !model.showsDevServerDot
        crossRepoField.stringValue = model.crossRepoLabel ?? ""
        crossRepoField.isHidden = model.crossRepoLabel == nil

        pinButton.image = SidebarCellKit.symbol(model.isPinned ? "pin.fill" : "pin", size: 10)
        pinButton.toolTip = model.isPinned ? Self.unpinActionName : Self.pinActionName
        pinButton.setAccessibilityLabel(model.isPinned
            ? "Unpin \(model.name) from dock"
            : "Pin \(model.name) to dock")
        plusButton.setAccessibilityLabel("New nested worktree under \(model.name)")
        updateControls()

        alphaValue = Self.opacity(of: model, dimmedByChevron: isDimmedByChevron)
        setAccessibilityLabel(Self.accessibilityLabel(for: model))
        setAccessibilityCustomActions(customActions(for: model))
        needsLayout = true
    }

    /// The pointer entered or left the row.
    func setHovered(_ hovered: Bool) {
        guard hovered != isHovered else { return }
        isHovered = hovered
        updateControls()
    }

    /// The pointer reached or left the chevron of the row's section.
    func setDimmedByChevron(_ dimmed: Bool) {
        guard dimmed != isDimmedByChevron else { return }
        isDimmedByChevron = dimmed
        if let model { alphaValue = Self.opacity(of: model, dimmedByChevron: dimmed) }
    }

    /// The row's opacity: a missing scratch directory, a hidden repo's
    /// section and a hovered chevron each dim it, and they compose.
    static func opacity(of model: WorktreeRowModel, dimmedByChevron: Bool) -> CGFloat {
        (model.isDimmed ? 0.5 : 1) * (model.isInHiddenSection ? 0.55 : 1)
            * (dimmedByChevron ? SidebarCellKit.chevronHoverOpacity : 1)
    }

    func setMenuOpen(_ open: Bool) {
        guard open != isMenuOpen else { return }
        isMenuOpen = open
        updateControls()
    }

    /// The control under the pointer draws its hover wash.
    func setHoveredPart(_ part: SidebarHoverPart) {
        hoveredPart = part
        pinButton.showsHoverWash = part == .pin
        plusButton.showsHoverWash = part == .plus
    }

    /// The pin shows on hover and always once pinned; the nested `+` on
    /// hover or while its menu is open. The main row offers neither, and a
    /// row outside any repo has no `+`.
    private func updateControls() {
        guard let model else {
            pinButton.isHidden = true
            plusButton.isHidden = true
            return
        }
        pinButton.isHidden = !(isHovered || model.isPinned) || model.isMain
        plusButton.isHidden = !HoverMenuModel.shouldShowPlus(hovered: isHovered, menuOpen: isMenuOpen)
            || model.isMain || !model.hasRepo
    }

    func hoverPart(at point: NSPoint) -> SidebarHoverPart {
        if !pinButton.isHidden, pinButton.frame.contains(point) { return .pin }
        if !plusButton.isHidden, plusButton.frame.contains(point) { return .plus }
        if hasLeadingTooltip, !leadingImageView.isHidden, leadingImageView.frame.contains(point) {
            return .leadingGlyph
        }
        return .none
    }

    /// Whether `point`, in the cell's coordinates, lands on a PR glyph — the
    /// click that opens the pull request, as the SwiftUI row's glyph button
    /// does.
    func isPullRequestGlyph(at point: NSPoint) -> Bool {
        guard case .prStatus? = model?.leading, !leadingImageView.isHidden else { return false }
        return leadingImageView.frame.contains(point)
    }

    /// The leading slot shows the PR glyph or the PR-unknown mark, each of
    /// which explains itself in the tooltip bubble.
    var hasLeadingTooltip: Bool {
        switch model?.leading {
        case .prStatus?, .prUnknown?: true
        default: false
        }
    }

    // MARK: Rename

    func beginRename(_ editor: SidebarRenameEditor) {
        renameEditor?.view.removeFromSuperview()
        renameEditor = editor
        nameField.isHidden = true
        addSubview(editor.view)
        needsLayout = true
    }

    func endRename() {
        renameEditor?.view.removeFromSuperview()
        renameEditor = nil
        nameField.isHidden = false
        needsLayout = true
    }

    override func prepareForReuse() {
        releaseRenameForReuse()
        super.prepareForReuse()
        model = nil
        isHovered = false
        isMenuOpen = false
        isDimmedByChevron = false
        setHoveredPart(.none)
        updateControls()
    }

    // MARK: Accessibility

    /// VoiceOver reaches the hover-only controls through these.
    private func customActions(for model: WorktreeRowModel) -> [NSAccessibilityCustomAction] {
        guard !model.isMain else { return [] }
        var actions = [
            NSAccessibilityCustomAction(name: model.isPinned ? Self.unpinActionName : Self.pinActionName) { [weak self] in
                MainActor.assumeIsolated { self?.send(self?.pinButton) ?? false }
            },
        ]
        if model.hasRepo {
            actions.append(NSAccessibilityCustomAction(name: Self.nestedWorktreeActionName) { [weak self] in
                MainActor.assumeIsolated { self?.send(self?.plusButton) ?? false }
            })
        }
        if case .prStatus? = model.leading {
            actions.append(NSAccessibilityCustomAction(name: Self.openPullRequestActionName) { [weak self] in
                MainActor.assumeIsolated { self?.onOpenPullRequest?() ?? false }
            })
        }
        return actions
    }

    /// Sends `button`'s action as a click would, hidden or not.
    private func send(_ button: NSButton?) -> Bool {
        guard let button, let action = button.action else { return false }
        return NSApp.sendAction(action, to: button.target, from: button)
    }

    private func configureLeading(_ leading: WorktreeLeadingSlot?) {
        leadingImageView.alphaValue = 1
        leadingImageView.toolTip = nil
        switch leading {
        case .prStatus(let presentation)?:
            switch presentation.glyph {
            case .asset(let name):
                leadingImageView.image = WorktreeRowView.loadIcon(name)
                leadingImageView.contentTintColor = presentation.nsColor
            case .emoji:
                // Full colour, never tinted.
                leadingImageView.image = PRStatusPresentation.busImage(
                    position: presentation.badge, side: PRStatusPresentation.busSide)
                leadingImageView.contentTintColor = nil
            }
        case .prUnknown?:
            leadingImageView.image = SidebarCellKit.symbol("questionmark.circle", size: 10, weight: .semibold)
            leadingImageView.contentTintColor = .secondaryLabelColor
        case .pending?:
            leadingImageView.image = SidebarCellKit.symbol("circle.dotted", size: 10, weight: .semibold)
            leadingImageView.contentTintColor = .secondaryLabelColor
        case .remote?:
            // The tertiary "whisper" tint the remote session row uses too.
            leadingImageView.image = SidebarCellKit.symbol("globe", size: 10)
            leadingImageView.contentTintColor = .secondaryLabelColor
            leadingImageView.alphaValue = 0.55
            leadingImageView.toolTip = "Remote session"
        case nil:
            leadingImageView.image = nil
        }
        leadingImageView.isHidden = leadingImageView.image == nil
    }

    /// The name, then what a sighted user reads from the row's subtitles and
    /// trailing marks.
    static func accessibilityLabel(for model: WorktreeRowModel) -> String {
        var parts = [model.name] + model.subtitles
        if let suffix = model.suffix { parts.append(SidebarCellKit.spokenStatus(suffix)) }
        if model.showsNoStatusMark { parts.append(NoStatusMark.accessibilityLabel) }
        if model.showsDevServerDot { parts.append("Dev server running") }
        return parts.joined(separator: ", ")
    }

    override func layout() {
        super.layout()
        let midY = bounds.height / 2
        let spacing = SidebarCellKit.rowSpacing
        var x = leadingInset
        if !leadingImageView.isHidden {
            leadingImageView.frame = NSRect(x: x, y: midY - 6, width: 12, height: 12)
            x += 12 + spacing
        }

        // The trailing items, in order, with the width each takes.
        let crossRepoSize = SidebarCellKit.size(of: crossRepoField)
        var trailingWidth: CGFloat = 0
        if suffix.isShown { trailingWidth += spacing + suffix.layoutWidth }
        if !noStatusImageView.isHidden { trailingWidth += spacing + 12 }
        if !devServerDot.isHidden { trailingWidth += spacing + 6 }
        if !crossRepoField.isHidden { trailingWidth += spacing + crossRepoSize.width }

        // The name and its subtitles stack at -2 pt and centre as one block.
        let shownSubtitles = subtitleFields.filter { !$0.isHidden }
        let nameSize = SidebarCellKit.size(of: nameField)
        let subtitleSizes = shownSubtitles.map(SidebarCellKit.size(of:))
        let room = max(bounds.width - x - trailingWidth, 0)
        let ideal = max(nameSize.width, subtitleSizes.map(\.width).max() ?? 0)
        let blockWidth = min(ideal, room)
        let blockHeight = nameSize.height + subtitleSizes.reduce(0) { $0 + $1.height - 2 }
        var y = ((bounds.height - blockHeight) / 2).rounded()
        nameField.frame = NSRect(x: x, y: y, width: min(nameSize.width, blockWidth), height: nameSize.height)
        // `WorktreeRowView.updateNameTruncation`'s half-point tolerance.
        isNameTruncated = nameSize.width > nameField.frame.width + 0.5
        if let editor = renameEditor {
            editor.view.frame = NSRect(x: x, y: 0, width: max(room - 4, 40), height: bounds.height)
        }
        y += nameSize.height - 2
        for (field, size) in zip(shownSubtitles, subtitleSizes) {
            field.frame = NSRect(x: x, y: y, width: min(size.width, blockWidth), height: size.height)
            y += size.height - 2
        }
        x += blockWidth

        if suffix.isShown {
            x += spacing
            suffix.place(atX: x, midY: midY)
            x += suffix.layoutWidth
        }
        if !noStatusImageView.isHidden {
            x += spacing
            noStatusImageView.frame = NSRect(x: x, y: midY - 6, width: 12, height: 12)
            x += 12
        }
        if !devServerDot.isHidden {
            x += spacing
            devServerDot.frame = NSRect(x: x, y: midY - 3, width: 6, height: 6)
            x += 6
        }
        if !crossRepoField.isHidden {
            x += spacing
            let width = min(crossRepoSize.width, max(bounds.width - x, 0))
            crossRepoField.frame = NSRect(
                x: x, y: ((bounds.height - crossRepoSize.height) / 2).rounded(),
                width: width, height: crossRepoSize.height)
        }

        // Overlays: the pin in the gutter left of the content, the `+` 4 pt in
        // from the trailing edge. Neither moves the row's content.
        pinButton.frame = NSRect(x: leadingInset - Self.pinGutter, y: midY - 10, width: 20, height: 20)
        plusButton.frame = NSRect(x: bounds.width - 4 - 20, y: midY - 10, width: 20, height: 20)

        toolTips.update(on: self, [
            (rect: suffix.shownFrame, target: .suffix),
            (rect: noStatusImageView.isHidden ? .zero : noStatusImageView.frame, target: .noStatusMark),
            (rect: crossRepoField.isHidden ? .zero : crossRepoField.frame, target: .crossRepo),
        ])
    }
}
