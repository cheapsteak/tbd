import AppKit

/// A remote session row, drawn from a `RemoteSessionRowModel` as
/// `RemoteSessionRowView` draws it: the pending glyph or the globe, the name
/// (bold when unread, secondary once exited) with its state caption, then the
/// status suffix or typing dots. A session the provider no longer reports draws
/// at half opacity. The name can be swapped for the inline rename editor.
final class RemoteSessionRowCell: NSTableCellView, SidebarRenamableCell {
    static let reuseIdentifier = NSUserInterfaceItemIdentifier("tbd.nativeSidebar.remoteSessionRow")

    /// `RemoteSessionRowView` pins `.frame(height: 28)` with or without its
    /// caption, as the worktree row does.
    static func height(for model: RemoteSessionRowModel) -> CGFloat {
        WorktreeRowView.rowHeight
    }

    var leadingInset: CGFloat = SidebarNativeMetrics.rowContentInset(chevronBeforeTitle: false) {
        didSet { if leadingInset != oldValue { needsLayout = true } }
    }

    let leadingImageView = SidebarCellKit.imageView()
    let nameField = SidebarCellKit.label(font: SidebarCellKit.nameFont)
    let captionField = SidebarCellKit.label(font: SidebarCellKit.captionFont, color: .secondaryLabelColor)
    private(set) lazy var suffix = SuffixSlot(in: self)
    let toolTips = SidebarToolTips()

    private(set) var model: RemoteSessionRowModel?
    private(set) var isHovered = false
    /// The row's section chevron is hovered: the cell, not the row view,
    /// draws at `SidebarCellKit.chevronHoverOpacity` of its own opacity.
    private(set) var isDimmedByChevron = false
    /// The name is wider than the room it has: hovering the row shows it in
    /// the tooltip bubble.
    private(set) var isNameTruncated = false
    private(set) var renameEditor: SidebarRenameEditor?

    init() {
        super.init(frame: .zero)
        identifier = Self.reuseIdentifier
        textField = nameField
        addSubview(leadingImageView)
        addSubview(nameField)
        addSubview(captionField)
        _ = suffix
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var isFlipped: Bool { true }

    func configure(_ model: RemoteSessionRowModel) {
        self.model = model
        if model.isPending {
            leadingImageView.image = SidebarCellKit.symbol("circle.dotted", size: 10, weight: .semibold)
            leadingImageView.contentTintColor = .secondaryLabelColor
            leadingImageView.alphaValue = 1
            leadingImageView.toolTip = nil
        } else {
            leadingImageView.image = SidebarCellKit.symbol("globe", size: 10)
            leadingImageView.contentTintColor = .secondaryLabelColor
            leadingImageView.alphaValue = 0.55
            leadingImageView.toolTip = "Remote session"
        }
        nameField.stringValue = model.title
        nameField.isHidden = isRenaming
        nameField.font = model.isNameBold ? SidebarCellKit.boldNameFont : SidebarCellKit.nameFont
        nameField.textColor = model.isExited ? .secondaryLabelColor : .labelColor
        captionField.stringValue = model.caption ?? ""
        captionField.isHidden = model.caption == nil
        suffix.show(model.suffix)
        alphaValue = Self.opacity(of: model, dimmedByChevron: isDimmedByChevron)
        setAccessibilityLabel(Self.accessibilityLabel(for: model))
        needsLayout = true
    }

    /// The pointer entered or left the row; the controller reads it for the
    /// truncated-name bubble.
    func setHovered(_ hovered: Bool) {
        isHovered = hovered
    }

    /// The pointer reached or left the chevron of the row's section.
    func setDimmedByChevron(_ dimmed: Bool) {
        guard dimmed != isDimmedByChevron else { return }
        isDimmedByChevron = dimmed
        if let model { alphaValue = Self.opacity(of: model, dimmedByChevron: dimmed) }
    }

    /// The row's opacity: a gone session, a hidden repo's section and a
    /// hovered chevron each dim it, and they compose.
    static func opacity(of model: RemoteSessionRowModel, dimmedByChevron: Bool) -> CGFloat {
        (model.isGone ? 0.5 : 1) * (model.isInHiddenSection ? 0.55 : 1)
            * (dimmedByChevron ? SidebarCellKit.chevronHoverOpacity : 1)
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
        isDimmedByChevron = false
    }

    static func accessibilityLabel(for model: RemoteSessionRowModel) -> String {
        var parts = [model.title]
        if let caption = model.caption { parts.append(caption) }
        if let suffix = model.suffix { parts.append(SidebarCellKit.spokenStatus(suffix)) }
        return parts.joined(separator: ", ")
    }

    override func layout() {
        super.layout()
        let midY = bounds.height / 2
        let spacing = SidebarCellKit.rowSpacing
        var x = leadingInset
        leadingImageView.frame = NSRect(x: x, y: midY - 6, width: 12, height: 12)
        x += 12 + spacing

        let trailingWidth = suffix.isShown ? spacing + suffix.layoutWidth : 0
        let nameSize = SidebarCellKit.size(of: nameField)
        let captionSize = captionField.isHidden ? NSSize.zero : SidebarCellKit.size(of: captionField)
        let blockWidth = min(max(nameSize.width, captionSize.width), max(bounds.width - x - trailingWidth, 0))
        let blockHeight = nameSize.height + (captionField.isHidden ? 0 : captionSize.height - 2)
        let top = ((bounds.height - blockHeight) / 2).rounded()
        nameField.frame = NSRect(x: x, y: top, width: min(nameSize.width, blockWidth), height: nameSize.height)
        isNameTruncated = nameSize.width > nameField.frame.width + 0.5
        if let editor = renameEditor {
            editor.view.frame = NSRect(
                x: x, y: 0, width: max(bounds.width - x - trailingWidth - 4, 40), height: bounds.height)
        }
        if !captionField.isHidden {
            captionField.frame = NSRect(
                x: x, y: top + nameSize.height - 2,
                width: min(captionSize.width, blockWidth), height: captionSize.height)
        }
        x += blockWidth
        if suffix.isShown {
            suffix.place(atX: x + spacing, midY: midY)
        }
        toolTips.update(on: self, [(rect: suffix.shownFrame, target: .suffix)])
    }
}
