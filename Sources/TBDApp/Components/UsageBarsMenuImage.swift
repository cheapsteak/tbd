import AppKit

/// The 5-hour and weekly usage bars drawn as one image, for an account row of
/// the swap, fork and new-tab menus. It draws what `UsageBarsView` draws, side
/// by side on one line, because an `NSMenuItem` title can hold an image but
/// not a SwiftUI view.
///
/// The layout (`marks`) is pure so tests can check it without drawing. The
/// image resolves light or dark each time it draws, so it follows the menu's
/// appearance.
enum UsageBarsMenuImage {
    typealias BucketPresentation = ProfileUsagePresentation.BucketPresentation
    typealias FillLevel = ProfileUsagePresentation.FillLevel

    // Geometry, in points.
    static let labelWidth: CGFloat = 14
    static let innerGap: CGFloat = 4
    static let barWidth: CGFloat = 44
    static let barHeight: CGFloat = 5
    static let barRadius: CGFloat = 2.5
    static let tickWidth: CGFloat = 2.5
    static let tickHeight: CGFloat = 9
    static let tickRadius: CGFloat = 1
    static let percentWidth: CGFloat = 27
    static let slotGap: CGFloat = 14
    static let textSize: CGFloat = 10
    static let height: CGFloat = 13
    /// One window's slot: label, gap, bar, gap, percent.
    static let slotWidth: CGFloat = labelWidth + innerGap + barWidth + innerGap + percentWidth
    /// Every row's image is this size, whichever buckets it has, so the bars
    /// line up down the menu.
    static let size = NSSize(width: 2 * slotWidth + slotGap, height: height)

    /// One thing to draw, in the image's unflipped coordinates.
    struct Mark: Equatable {
        enum Kind: Equatable {
            case label(String)
            case track
            case fill(FillLevel)
            case tick
            case percent(String, FillLevel)
        }

        let kind: Kind
        let rect: CGRect
    }

    /// The layout of both slots. A missing bucket leaves its slot empty, so the
    /// weekly bar starts at the same x on every row.
    static func marks(session: BucketPresentation?, weekly: BucketPresentation?) -> [Mark] {
        slotMarks(session, label: "5h", originX: 0)
            + slotMarks(weekly, label: "wk", originX: slotWidth + slotGap)
    }

    static func image(session: BucketPresentation?, weekly: BucketPresentation?) -> NSImage {
        let layout = marks(session: session, weekly: weekly)
        let image = NSImage(size: size, flipped: false) { _ in
            let isDark = NSAppearance.currentDrawing().bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            for mark in layout {
                Self.draw(mark, isDark: isDark)
            }
            return true
        }
        // The pace colors are the point; a template image would draw them in one tint.
        image.isTemplate = false
        image.accessibilityDescription = accessibilityText(session: session, weekly: weekly)
        return image
    }

    /// "5-hour 40%, weekly 16%". A missing bucket is left out.
    static func accessibilityText(session: BucketPresentation?, weekly: BucketPresentation?) -> String {
        var parts: [String] = []
        if let session { parts.append("5-hour \(session.percentText)") }
        if let weekly { parts.append("weekly \(weekly.percentText)") }
        return parts.joined(separator: ", ")
    }

    // MARK: - Layout

    private static func slotMarks(_ presentation: BucketPresentation?,
                                  label: String,
                                  originX: CGFloat) -> [Mark] {
        guard let presentation else { return [] }
        let track = CGRect(x: originX + labelWidth + innerGap,
                           y: (height - barHeight) / 2,
                           width: barWidth,
                           height: barHeight)
        // Over 100% (or a stray negative) clamps to the track.
        let fillFraction = min(max(presentation.percent / 100, 0), 1)
        var marks = [
            Mark(kind: .label(label),
                 rect: CGRect(x: originX, y: 0, width: labelWidth, height: height)),
            Mark(kind: .track, rect: track),
            Mark(kind: .fill(presentation.fill),
                 rect: CGRect(x: track.minX, y: track.minY,
                              width: barWidth * fillFraction, height: barHeight)),
        ]
        // Same placement as UsageBarsView's time marker; none once the window is over.
        if let elapsed = presentation.elapsedFraction {
            marks.append(Mark(kind: .tick,
                              rect: CGRect(x: track.minX + (barWidth * elapsed).rounded() - 0.75,
                                           y: track.midY - tickHeight / 2,
                                           width: tickWidth,
                                           height: tickHeight)))
        }
        marks.append(Mark(kind: .percent(presentation.percentText, presentation.fill),
                          rect: CGRect(x: track.maxX + innerGap, y: 0,
                                       width: percentWidth, height: height)))
        return marks
    }

    // MARK: - Drawing

    private static func draw(_ mark: Mark, isDark: Bool) {
        switch mark.kind {
        case let .label(text):
            drawText(text, in: mark.rect, font: NSFont.systemFont(ofSize: textSize),
                     color: .secondaryLabelColor, alignRight: false)
        case .track:
            fillRoundedRect(mark.rect, radius: barRadius,
                            color: NSColor.labelColor.withAlphaComponent(0.08))
        case let .fill(level):
            fillRoundedRect(mark.rect, radius: barRadius, color: level.nsBarColor(isDark: isDark))
        case .tick:
            fillRoundedRect(mark.rect, radius: tickRadius, color: .labelColor)
        case let .percent(text, level):
            drawText(text, in: mark.rect, font: percentFont,
                     color: level.nsBarColor(isDark: isDark), alignRight: true)
        }
    }

    private static func fillRoundedRect(_ rect: CGRect, radius: CGFloat, color: NSColor) {
        guard rect.width > 0, rect.height > 0 else { return }
        color.setFill()
        NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).fill()
    }

    /// Draws `text` vertically centered in `rect`, at its leading or trailing edge.
    private static func drawText(_ text: String, in rect: CGRect, font: NSFont,
                                 color: NSColor, alignRight: Bool) {
        let string = NSAttributedString(string: text, attributes: [
            .font: font,
            .foregroundColor: color,
        ])
        let measured = string.size()
        let x = alignRight ? rect.maxX - measured.width : rect.minX
        string.draw(at: NSPoint(x: x, y: rect.midY - measured.height / 2))
    }

    /// 10 pt semibold rounded with tabular digits, as `UsageBarsView`'s percent.
    private static var percentFont: NSFont {
        let base = NSFont.monospacedDigitSystemFont(ofSize: textSize, weight: .semibold)
        guard let rounded = base.fontDescriptor.withDesign(.rounded),
              let font = NSFont(descriptor: rounded, size: textSize) else { return base }
        return font
    }
}
