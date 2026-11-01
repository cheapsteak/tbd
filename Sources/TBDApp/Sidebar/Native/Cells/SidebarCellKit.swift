import AppKit
import SwiftUI

/// What the native sidebar's cells share: label and image factories, the
/// fonts the SwiftUI rows use, a symbol cache, and the suffix glyph's look and
/// spoken words.
@MainActor
enum SidebarCellKit {
    /// `HStack(spacing: 6)` in `WorktreeRowView` and `RemoteSessionRowView`.
    static let rowSpacing: CGFloat = 6
    /// The leading and suffix glyph slot: `.frame(width: 12, height: 12)`.
    static let glyphSide: CGFloat = 12
    /// A row's share of its own opacity while its section's chevron is
    /// hovered, as `RepoSectionView` dims the rows the gesture would hide.
    static let chevronHoverOpacity: CGFloat = 0.7

    // MARK: Fonts — the SwiftUI rows' text styles on macOS

    static let nameFont = NSFont.systemFont(ofSize: 13)
    static let boldNameFont = NSFont.systemFont(ofSize: 13, weight: .bold)
    /// `.caption` and `.caption2`.
    static let captionFont = NSFont.systemFont(ofSize: 10)
    /// `.headline`: the Scratch header.
    static let headlineFont = NSFont.systemFont(ofSize: 13, weight: .bold)
    /// A repo or provider header's name.
    static let sectionTitleFont = NSFont.systemFont(ofSize: 12, weight: .semibold)
    /// A group header's title.
    static let groupTitleFont = NSFont.systemFont(ofSize: 12, weight: .medium)

    // MARK: Views

    /// A single-line, tail-truncating, non-selectable label.
    static func label(font: NSFont, color: NSColor = .labelColor) -> NSTextField {
        let field = NSTextField(labelWithString: "")
        field.font = font
        field.textColor = color
        field.lineBreakMode = .byTruncatingTail
        field.maximumNumberOfLines = 1
        field.cell?.truncatesLastVisibleLine = true
        field.isSelectable = false
        field.drawsBackground = false
        field.isBordered = false
        return field
    }

    static func imageView() -> NSImageView {
        let view = NSImageView(frame: .zero)
        view.imageScaling = .scaleProportionallyDown
        view.imageAlignment = .alignCenter
        view.isEditable = false
        return view
    }

    /// A borderless, image-only button that never takes focus, for chevrons.
    static func glyphButton() -> NSButton {
        let button = NSButton(frame: .zero)
        button.isBordered = false
        button.setButtonType(.momentaryChange)
        button.imagePosition = .imageOnly
        button.title = ""
        button.focusRingType = .none
        button.refusesFirstResponder = true
        return button
    }

    /// A 20 pt square hover affordance in `HoverPressButtonStyle`'s look: a
    /// secondary glyph that gains a wash while the pointer is over it and a
    /// deeper one while pressed. The section `+`, the worktree row's nested
    /// `+` and its gutter pin.
    static func hoverButton(symbol name: String = "plus", size: CGFloat = 10) -> SidebarHoverButton {
        let button = SidebarHoverButton(frame: NSRect(x: 0, y: 0, width: 20, height: 20))
        button.isBordered = false
        button.setButtonType(.momentaryChange)
        button.imagePosition = .imageOnly
        button.imageScaling = .scaleNone
        button.title = ""
        button.focusRingType = .none
        button.refusesFirstResponder = true
        button.image = SidebarCellKit.symbol(name, size: size)
        button.contentTintColor = .secondaryLabelColor
        button.isHidden = true
        return button
    }

    /// The label's single-line size, padding included.
    static func size(of field: NSTextField) -> NSSize {
        let size = field.intrinsicContentSize
        return NSSize(width: ceil(max(size.width, 0)), height: ceil(max(size.height, 0)))
    }

    // MARK: Symbols

    private static var symbols: [String: NSImage] = [:]

    /// An SF Symbol at a point size and weight, made once per combination so
    /// the image views keep the same instance across reconfigures.
    static func symbol(_ name: String, size: CGFloat, weight: NSFont.Weight = .regular) -> NSImage? {
        let key = "\(name)|\(size)|\(weight.rawValue)"
        if let cached = symbols[key] { return cached }
        let image = NSImage(systemSymbolName: name, accessibilityDescription: nil)?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: size, weight: weight))
        if let image { symbols[key] = image }
        return image
    }

    // MARK: Suffix glyph

    /// The suffix glyph's tint and the opacity it draws at, as
    /// `SuffixRowIndicator.color` gives them to the SwiftUI rows.
    static func suffixTint(_ indicator: SuffixRowIndicator) -> (color: NSColor, alpha: CGFloat) {
        switch indicator {
        case .error: (color: NSColor.systemRed, alpha: 1)
        case .attention, .needsAuth: (color: NSColor(SuffixRowIndicator.attention.color), alpha: 1)
        case .working, .suspended: (color: NSColor.secondaryLabelColor, alpha: 1)
        case .hibernated: (color: NSColor.secondaryLabelColor, alpha: 0.55)
        case .turnFailed: (color: NSColor.systemOrange, alpha: 1)
        }
    }

    /// What a sighted user reads from the suffix glyph, for the row's
    /// accessibility label: the badge's help text in the SwiftUI row.
    static func spokenStatus(_ indicator: SuffixRowIndicator) -> String {
        switch indicator {
        case .error: "Error"
        case .attention: "Needs your attention"
        case .working: "Agent is working"
        case .suspended: "Suspended"
        case .hibernated: "Hibernating — wakes on focus"
        case .needsAuth: "Needs you to sign in again"
        case .turnFailed: "The last turn failed"
        }
    }
}

/// Which control or glyph inside a row the pointer is over. The hover tracker
/// asks the hovered row's cell, so the one tracking area also drives the
/// button washes, the chevron's dimming of its section and the PR tooltip.
enum SidebarHoverPart: Equatable {
    case none
    /// A section header's disclosure chevron.
    case chevron
    /// A section header's `+`, or a worktree row's nested `+`.
    case plus
    /// A worktree row's gutter pin.
    case pin
    /// A worktree row's leading PR glyph or PR-unknown mark.
    case leadingGlyph
}

/// A cell with controls or glyphs the pointer can be over.
@MainActor
protocol SidebarHoverTarget: AnyObject {
    /// The part at `point`, in the cell's own coordinates.
    func hoverPart(at point: NSPoint) -> SidebarHoverPart
}

/// A borderless glyph button that draws `HoverPressButtonStyle`'s wash: the
/// primary colour at 0.08 while the pointer is over it, 0.15 while pressed.
/// The hover tracker, not a tracking area of its own, says when it is hovered.
final class SidebarHoverButton: NSButton {
    var showsHoverWash = false {
        didSet { if showsHoverWash != oldValue { needsDisplay = true } }
    }
    /// Off for the chevron leading a title, which the SwiftUI path draws
    /// plain.
    var drawsWash = true {
        didSet { if drawsWash != oldValue { needsDisplay = true } }
    }

    override func draw(_ dirtyRect: NSRect) {
        if drawsWash, isEnabled, isHighlighted || showsHoverWash {
            NSColor.labelColor.withAlphaComponent(isHighlighted ? 0.15 : 0.08).setFill()
            NSBezierPath(roundedRect: bounds, xRadius: 4, yRadius: 4).fill()
        }
        super.draw(dirtyRect)
    }
}

/// Help text a cell asks for only when AppKit is about to show it, so a row's
/// tooltip — a status badge's OSC detail, the no-status reason, a provider's
/// summary — is computed when the pointer arrives rather than on every
/// rebuild (spec "Units": text needed only on hover).
@MainActor
final class SidebarToolTips: NSObject, NSViewToolTipOwner {
    enum Target: Equatable {
        /// A row's status badge or typing dots.
        case suffix
        /// A worktree row's no-status mark.
        case noStatusMark
        /// A worktree row's shortened "(repo)" suffix: the full repo name.
        case crossRepo
        /// A provider header's name: the provider's compact summary.
        case providerName
        /// A provider header's needs-auth key.
        case providerAuth
    }

    /// Answers a target's text; the controller sets it with the row it is
    /// configuring. Nil or an empty answer shows nothing.
    var provider: ((Target) -> String?)?
    private var targets: [NSView.ToolTipTag: Target] = [:]

    /// Replaces `view`'s tooltip rectangles with `regions`, in `view`'s
    /// coordinates. Called from the cell's `layout()`.
    func update(on view: NSView, _ regions: [(rect: NSRect, target: Target)]) {
        view.removeAllToolTips()
        targets = [:]
        for region in regions where !region.rect.isEmpty {
            targets[view.addToolTip(region.rect, owner: self, userData: nil)] = region.target
        }
    }

    /// `nonisolated` with an assumed main actor, so the conformance holds
    /// whichever isolation the SDK in use declares for the requirement.
    nonisolated func view(
        _ view: NSView, stringForToolTip tag: NSView.ToolTipTag, point: NSPoint,
        userData data: UnsafeMutableRawPointer?
    ) -> String {
        MainActor.assumeIsolated {
            targets[tag].flatMap { provider?($0) } ?? ""
        }
    }
}

/// The trailing status slot both row cells draw: a glyph, or the typing dots
/// while an agent works. Laid out by the owning cell.
@MainActor
final class SuffixSlot {
    let imageView = SidebarCellKit.imageView()
    /// Made the first time a row works, so idle rows carry no animation.
    private(set) var typingDots: TypingDotsNSView?
    private(set) var indicator: SuffixRowIndicator?
    private weak var host: NSView?

    init(in host: NSView) {
        self.host = host
        host.addSubview(imageView)
    }

    var isShown: Bool { indicator != nil }

    /// The width the slot takes in the row's `HStack`: the dots pull 3 pt
    /// back into the spacing before them (`.padding(.leading, -3)`).
    var layoutWidth: CGFloat {
        switch indicator {
        case .working?: 14 - 3
        case .some: SidebarCellKit.glyphSide
        case nil: 0
        }
    }

    func show(_ indicator: SuffixRowIndicator?) {
        self.indicator = indicator
        switch indicator {
        case .working?:
            imageView.isHidden = true
            imageView.image = nil
            let dots = typingDots ?? makeDots()
            dots.isHidden = false
        case let indicator?:
            typingDots?.isHidden = true
            let tint = SidebarCellKit.suffixTint(indicator)
            imageView.image = indicator.systemImage.flatMap {
                SidebarCellKit.symbol($0, size: 11, weight: .semibold)
            }
            imageView.contentTintColor = tint.color
            imageView.alphaValue = tint.alpha
            imageView.isHidden = imageView.image == nil
        case nil:
            typingDots?.isHidden = true
            imageView.isHidden = true
            imageView.image = nil
        }
    }

    /// The frame of whatever the slot shows, for its tooltip; `.zero` when
    /// empty.
    var shownFrame: NSRect {
        switch indicator {
        case .working?: typingDots?.frame ?? .zero
        case .some: imageView.isHidden ? .zero : imageView.frame
        case nil: .zero
        }
    }

    /// Places the slot with its layout box starting at `x`, centred on `midY`.
    func place(atX x: CGFloat, midY: CGFloat) {
        switch indicator {
        case .working?:
            // `.frame(width: 14, height: 12).padding(.leading, -3).offset(y: 2)`.
            typingDots?.frame = NSRect(x: x - 3, y: midY - 6 + 2, width: 14, height: 12)
        case .some:
            imageView.frame = NSRect(x: x, y: midY - 6, width: 12, height: 12)
        case nil:
            break
        }
    }

    private func makeDots() -> TypingDotsNSView {
        let dots = TypingDotsNSView(dotColor: .secondaryLabelColor)
        host?.addSubview(dots)
        typingDots = dots
        return dots
    }
}

/// A small filled circle in a dynamic colour. The colour is resolved against
/// the view's own appearance every time the layer updates, rather than
/// snapshotted into a `CGColor` once, so it follows light and dark.
final class StatusDotView: NSView {
    let color: NSColor

    init(color: NSColor, diameter: CGFloat) {
        self.color = color
        super.init(frame: NSRect(x: 0, y: 0, width: diameter, height: diameter))
        wantsLayer = true
        layer?.cornerRadius = diameter / 2
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.backgroundColor = color.cgColor
        }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }
}
