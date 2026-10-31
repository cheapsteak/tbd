import AppKit

/// A worktree row, drawn from a `WorktreeRowModel` as `WorktreeRowView` draws
/// it: the leading slot (PR glyph, PR-unknown mark, pending glyph or remote
/// globe), the name with its subtitles, then the status suffix or typing dots,
/// the no-status mark, the dev-server dot and the cross-repo suffix, packed
/// against the name as the SwiftUI `HStack` packs them.
///
/// The cell never reads `AppState`. Its frame starts at the row's depth (the
/// outline's `frameOfCell` places it); `leadingInset` is the row inset every
/// row under a section title carries. The hover controls — the gutter pin and
/// the nested `+` — and rename are added on top of this cell, behind
/// `setHovered(_:)`.
final class WorktreeRowCell: NSTableCellView {
    static let reuseIdentifier = NSUserInterfaceItemIdentifier("tbd.nativeSidebar.worktreeRow")

    /// The row with a subtitle line. `WorktreeRowView` pins
    /// `.frame(height: rowHeight)` for every variant — the dock's height
    /// arithmetic counts on it — so the subtitle row is the same 28 pt, with
    /// the name and subtitle stacked at -2 pt spacing inside it.
    /// `SidebarCellTests.heightMatchesClass` measures the SwiftUI row against
    /// this value.
    static let subtitleRowHeight: CGFloat = 28

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
    let devServerDot = NSView(frame: .zero)
    let crossRepoField = SidebarCellKit.label(font: SidebarCellKit.captionFont, color: .secondaryLabelColor)

    private(set) var model: WorktreeRowModel?

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
        devServerDot.wantsLayer = true
        devServerDot.layer?.cornerRadius = 3
        devServerDot.layer?.backgroundColor = NSColor.systemGreen.cgColor
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var isFlipped: Bool { true }

    /// Sets every property the model drives, opacity included:
    /// `prepareForReuse` resets a reused view's alpha.
    func configure(_ model: WorktreeRowModel) {
        self.model = model
        configureLeading(model.leading)

        nameField.stringValue = model.name
        nameField.font = model.isNameBold ? SidebarCellKit.boldNameFont : SidebarCellKit.nameFont
        while subtitleFields.count < model.subtitles.count {
            let field = SidebarCellKit.label(font: SidebarCellKit.captionFont, color: .secondaryLabelColor)
            addSubview(field)
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
        devServerDot.layer?.backgroundColor = NSColor.systemGreen.cgColor
        crossRepoField.stringValue = model.crossRepoLabel ?? ""
        crossRepoField.isHidden = model.crossRepoLabel == nil

        alphaValue = (model.isDimmed ? 0.5 : 1) * (model.isInHiddenSection ? 0.55 : 1)
        setAccessibilityLabel(Self.accessibilityLabel(for: model))
        needsLayout = true
    }

    /// The hover hook the pin toggle and nested `+` hang from.
    func setHovered(_ hovered: Bool) {}

    override func prepareForReuse() {
        super.prepareForReuse()
        model = nil
    }

    private func configureLeading(_ leading: WorktreeLeadingSlot?) {
        leadingImageView.alphaValue = 1
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
        let ideal = max(nameSize.width, subtitleSizes.map(\.width).max() ?? 0)
        let blockWidth = min(ideal, max(bounds.width - x - trailingWidth, 0))
        let blockHeight = nameSize.height + subtitleSizes.reduce(0) { $0 + $1.height - 2 }
        var y = ((bounds.height - blockHeight) / 2).rounded()
        nameField.frame = NSRect(x: x, y: y, width: min(nameSize.width, blockWidth), height: nameSize.height)
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
    }
}
