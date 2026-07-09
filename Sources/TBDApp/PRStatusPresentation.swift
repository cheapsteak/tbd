import AppKit
import SwiftUI
import TBDShared

struct PRStatusPresentation: Equatable {
    enum ColorSemantic: Equatable {
        case pending
        case nonMergeable
        case draft
        case mergeable
        case merged
    }

    /// What the leading icon draws. `.asset` is a bundled monochrome SVG that
    /// gets tinted with `color`/`nsColor`; `.emoji` is a full-color glyph (the
    /// merge-queue 🚌) that must NOT be tinted — both render sites branch on
    /// this so the tint-vs-no-tint decision lives in one place.
    enum Glyph: Equatable {
        case asset(String)   // existing bundled SVGs, e.g. "git-pull-request"
        case emoji(String)   // 🚌
    }

    let glyph: Glyph
    let colorSemantic: ColorSemantic
    /// 1-indexed merge-queue position rendered as a small corner chip, or nil.
    /// Only set on the bus presentation.
    var badge: Int? = nil

    /// The literal emoji rendered for a PR sitting in a merge queue.
    static let mergeQueueEmoji = "🚌"

    var color: Color {
        switch colorSemantic {
        case .pending:
            // Light: GitHub WIP olive #936921 — readable on light sidebar (~#F1F1F1).
            // Dark:  GitHub attention.fg #D29922 — readable on dark sidebar (~#1E1E1E).
            return adaptiveColor(
                light: NSColor(srgbRed: 147 / 255, green: 105 / 255, blue: 33 / 255, alpha: 1),
                dark: NSColor(srgbRed: 210 / 255, green: 153 / 255, blue: 34 / 255, alpha: 1)
            )
        case .nonMergeable:     return .red
        case .draft:            return .secondary
        case .mergeable:
            // Light: muted forest #3D7D40.
            // Dark:  GitHub success.fg #3FB950.
            return adaptiveColor(
                light: NSColor(srgbRed: 61 / 255, green: 125 / 255, blue: 64 / 255, alpha: 1),
                dark: NSColor(srgbRed: 63 / 255, green: 185 / 255, blue: 80 / 255, alpha: 1)
            )
        case .merged:           return .purple
        }
    }

    /// AppKit equivalent of `color`, for baking a pre-tinted (non-template)
    /// NSImage — toolbar `Menu`/split-button labels strip color from template
    /// images, so the icon must carry its own color via `.renderingMode(.original)`.
    var nsColor: NSColor {
        switch colorSemantic {
        case .pending:
            return NSColor(name: nil) { appearance in
                appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
                    ? NSColor(srgbRed: 210 / 255, green: 153 / 255, blue: 34 / 255, alpha: 1)
                    : NSColor(srgbRed: 147 / 255, green: 105 / 255, blue: 33 / 255, alpha: 1)
            }
        case .nonMergeable:     return .systemRed
        case .draft:            return .secondaryLabelColor
        case .mergeable:
            return NSColor(name: nil) { appearance in
                appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
                    ? NSColor(srgbRed: 63 / 255, green: 185 / 255, blue: 80 / 255, alpha: 1)
                    : NSColor(srgbRed: 61 / 255, green: 125 / 255, blue: 64 / 255, alpha: 1)
            }
        case .merged:           return .systemPurple
        }
    }

    static func make(for prStatus: PRStatus?) -> PRStatusPresentation? {
        guard let prStatus else { return nil }
        // A PR in a merge queue is in a distinct mode (no longer waiting on the
        // author) that `mergeStateStatus` can't express — a queued PR reports
        // UNKNOWN, which maps to the ordinary olive pending icon. Short-circuit
        // to the bus regardless of `state`, gated on a non-nil position so the
        // badge always carries a number. `colorSemantic` is unused for `.emoji`
        // (it isn't tinted) but must still be provided.
        if let position = prStatus.mergeQueuePosition {
            return PRStatusPresentation(
                glyph: .emoji(mergeQueueEmoji),
                colorSemantic: .pending,
                badge: position
            )
        }
        switch prStatus.state {
        case .pending:
            return PRStatusPresentation(glyph: .asset("git-pull-request"), colorSemantic: .pending)
        case .blocked:
            return PRStatusPresentation(glyph: .asset("git-pull-request"), colorSemantic: .nonMergeable)
        case .changesRequested:
            return PRStatusPresentation(glyph: .asset("git-pull-request"), colorSemantic: .nonMergeable)
        case .checksFailed:
            return PRStatusPresentation(glyph: .asset("git-pull-request"), colorSemantic: .nonMergeable)
        case .draft:
            return PRStatusPresentation(glyph: .asset("git-pull-request"), colorSemantic: .draft)
        case .mergeable:
            return PRStatusPresentation(glyph: .asset("git-pull-request"), colorSemantic: .mergeable)
        case .merged:
            return PRStatusPresentation(glyph: .asset("git-merge"), colorSemantic: .merged)
        case .closed:
            return PRStatusPresentation(glyph: .asset("git-pull-request-closed"), colorSemantic: .nonMergeable)
        }
    }

    /// Renders `emoji` to a full-color, non-template `NSImage` of `side`×`side`.
    /// The ONE shared emoji→NSImage path used by both the sidebar row and the
    /// toolbar split-button label so their glyphs can't drift. Full-color and
    /// non-template: callers must render it with `.renderingMode(.original)` and
    /// must NOT tint it.
    @MainActor
    static func emojiImage(_ emoji: String, side: CGFloat) -> NSImage {
        if let cached = emojiImageCache[emoji] { return cached }
        let image = NSImage(size: NSSize(width: side, height: side), flipped: false) { rect in
            drawEmoji(emoji, in: rect)
            return true
        }
        image.isTemplate = false
        emojiImageCache[emoji] = image
        return image
    }

    /// The full-color merge-queue bus glyph with its 1-indexed `position` baked
    /// into a small rounded-rect corner chip. Shared by BOTH render sites (the
    /// sidebar row and the flattened toolbar split-button label, which can only
    /// carry one image), so the bus + badge never drift. `position == nil`
    /// yields the bare bus. Non-template: render with `.renderingMode(.original)`
    /// and do not tint.
    @MainActor
    static func busImage(position: Int?, side: CGFloat) -> NSImage {
        let cacheKey = "bus-\(position.map(String.init) ?? "none")-\(side)"
        if let cached = busImageCache[cacheKey] { return cached }
        let image = NSImage(size: NSSize(width: side, height: side), flipped: false) { rect in
            drawEmoji(mergeQueueEmoji, in: rect)
            if let position { drawQueueBadge(position: position, in: rect) }
            return true
        }
        image.isTemplate = false
        busImageCache[cacheKey] = image
        return image
    }

    /// Draws `emoji` centered within `rect` at a font size matching the square.
    private static func drawEmoji(_ emoji: String, in rect: NSRect) {
        let font = NSFont.systemFont(ofSize: rect.height)
        let attrs: [NSAttributedString.Key: Any] = [.font: font]
        let str = emoji as NSString
        let textSize = str.size(withAttributes: attrs)
        let origin = NSPoint(x: rect.midX - textSize.width / 2, y: rect.midY - textSize.height / 2)
        str.draw(at: origin, withAttributes: attrs)
    }

    /// The largest queue position rendered literally; anything greater collapses
    /// to `"99+"` so the chip never needs more than three glyphs.
    static let maxQueueBadgeValue = 99

    /// Geometry + text for the queue-position chip, computed so a 2- or 3-glyph
    /// badge stays legible and never clips outside `rect`. Pulled out of
    /// `drawQueueBadge` so tests can assert the chip stays within the icon bounds
    /// for double- and triple-digit positions. Nonisolated so it runs inside the
    /// nonisolated `NSImage` draw closure (like the rest of the draw path).
    struct QueueBadgeLayout {
        let text: String
        let chipRect: NSRect
        let attrs: [NSAttributedString.Key: Any]
        let textSize: NSSize
    }

    /// Lays out the badge for `position` inside `rect`. The displayed value is
    /// clamped to `"99+"` past `maxQueueBadgeValue`, and the font is shrunk until
    /// the chip (text + horizontal padding) fits `rect.width`, so the chip is
    /// always fully contained in the icon square — a double-digit position no
    /// longer truncates the way a fixed square chip did.
    static func queueBadgeLayout(position: Int, in rect: NSRect) -> QueueBadgeLayout {
        let display = position > maxQueueBadgeValue ? "\(maxQueueBadgeValue)+" : "\(position)"
        let text = display as NSString
        let padH = rect.width * 0.12
        let maxChipW = rect.width               // the chip may span the icon but never exceed it

        // Shrink the font until text + padding fit the icon width. A single digit
        // keeps the full size; wider values step down so they read without clipping.
        var fontSize = rect.height * 0.5
        var attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: fontSize, weight: .bold),
            .foregroundColor: NSColor.white
        ]
        var textSize = text.size(withAttributes: attrs)
        while textSize.width + padH * 2 > maxChipW && fontSize > 1 {
            fontSize -= 0.5
            attrs[.font] = NSFont.systemFont(ofSize: fontSize, weight: .bold)
            textSize = text.size(withAttributes: attrs)
        }

        let chipW = min(maxChipW, textSize.width + padH * 2)
        let chipH = min(rect.height, textSize.height + padH)
        let chipRect = NSRect(x: rect.maxX - chipW, y: rect.minY, width: chipW, height: chipH)
        return QueueBadgeLayout(text: display, chipRect: chipRect, attrs: attrs, textSize: textSize)
    }

    /// Draws the 1-indexed queue `position` as a rounded-rect chip in the
    /// bottom-trailing corner of `rect`, using the control accent color with
    /// white text so it reads over the bus in light and dark. The chip grows
    /// horizontally (and the font shrinks) for multi-digit positions so 10–99
    /// stay legible instead of clipping; positions past 99 render as `"99+"`.
    private static func drawQueueBadge(position: Int, in rect: NSRect) {
        let layout = queueBadgeLayout(position: position, in: rect)
        let radius = layout.chipRect.height * 0.35
        NSColor.controlAccentColor.setFill()
        NSBezierPath(roundedRect: layout.chipRect, xRadius: radius, yRadius: radius).fill()
        let textOrigin = NSPoint(
            x: layout.chipRect.midX - layout.textSize.width / 2,
            y: layout.chipRect.midY - layout.textSize.height / 2
        )
        (layout.text as NSString).draw(at: textOrigin, withAttributes: layout.attrs)
    }

    /// Identity-stable caches: `Image(nsImage:)` diffs by object identity, so a
    /// fresh bitmap per body evaluation would rebuild the icon layer.
    /// MainActor-confined (SwiftUI bodies run on main), so no lock is needed.
    @MainActor
    private static var emojiImageCache: [String: NSImage] = [:]
    @MainActor
    private static var busImageCache: [String: NSImage] = [:]
}
