import AppKit

/// "Click to create scratch space", standing where the first pad would while
/// there is none, as `ScratchSectionView` draws it: a secondary caption 2 pt
/// past the row inset, with 2 pt above and 4 pt below. The controller runs
/// the create action from the outline's click action.
final class ScratchPromptCell: NSTableCellView {
    static let reuseIdentifier = NSUserInterfaceItemIdentifier("tbd.nativeSidebar.scratchPrompt")
    static let title = "Click to create scratch space"

    /// A caption line with its insets, raised to the `List`'s 26 pt minimum.
    static let rowHeight: CGFloat = 26

    var leadingInset: CGFloat = SidebarNativeMetrics.rowContentInset(chevronBeforeTitle: false) + 2 {
        didSet { if leadingInset != oldValue { needsLayout = true } }
    }

    let titleField = SidebarCellKit.label(font: SidebarCellKit.captionFont, color: .secondaryLabelColor)

    init() {
        super.init(frame: .zero)
        identifier = Self.reuseIdentifier
        textField = titleField
        titleField.stringValue = Self.title
        addSubview(titleField)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var isFlipped: Bool { true }

    /// The prompt has no model of its own; this resets what reuse may have
    /// changed.
    func configure() {
        titleField.stringValue = Self.title
        alphaValue = 1
        setAccessibilityLabel(Self.title)
        needsLayout = true
    }

    /// The hover hook, for parity with the other cells. The pointing hand is
    /// a cursor rectangle instead (`resetCursorRects`), which AppKit keeps
    /// balanced as the pointer and the rows move.
    func setHovered(_ hovered: Bool) {}

    /// `ScratchSectionView`'s prompt pushes the pointing hand while hovered.
    override func resetCursorRects() {
        super.resetCursorRects()
        addCursorRect(bounds, cursor: .pointingHand)
    }

    override func layout() {
        super.layout()
        let size = SidebarCellKit.size(of: titleField)
        let midY = (2 + bounds.height - 4) / 2
        titleField.frame = NSRect(
            x: leadingInset, y: (midY - size.height / 2).rounded(),
            width: min(size.width, max(bounds.width - leadingInset, 0)), height: size.height)
    }
}
