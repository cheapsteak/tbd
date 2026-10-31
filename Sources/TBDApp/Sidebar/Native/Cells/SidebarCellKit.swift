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
