import AppKit

/// An account row of the swap, fork and new-tab menus: the name, then the
/// usage bars or a note in a column every row of the menu shares.
///
/// The row stays a plain `NSMenuItem` with an attributed title, so the menu
/// keeps drawing the highlight and handling keys and VoiceOver itself. A
/// custom item view would have to do all of that by hand.
enum AccountMenuRow {
    typealias MenuUsage = ProfileUsagePresentation.MenuUsage

    /// Space between the widest name and the bars.
    static let nameGap: CGFloat = 22

    /// Size 0 asks for the menu's own size, so widths match what the menu draws.
    private static var nameFont: NSFont { NSFont.menuFont(ofSize: 0) }
    private static var noteFont: NSFont { NSFont.menuFont(ofSize: 11) }

    static func nameWidth(_ name: String) -> CGFloat {
        ceil((name as NSString).size(withAttributes: [.font: nameFont]).width)
    }

    /// The widest name among the rows that show bars or a note; 0 when none do.
    /// A row that shows the name alone does not push the column out.
    static func nameColumnWidth(_ rows: [(name: String, usage: MenuUsage)]) -> CGFloat {
        var widest: CGFloat = 0
        for row in rows {
            if case .none = row.usage { continue }
            widest = max(widest, nameWidth(row.name))
        }
        return widest
    }

    /// The clear gap after a name that brings its bars to the shared column.
    static func spacerWidth(name: String, nameColumnWidth: CGFloat) -> CGFloat {
        max(nameColumnWidth - nameWidth(name), 0) + nameGap
    }

    /// The name, a clear spacer, then the bars and any age note, or the note
    /// alone. nil for `.none`, so the item keeps its plain title.
    static func attributedTitle(name: String,
                                usage: MenuUsage,
                                nameColumnWidth: CGFloat) -> NSAttributedString? {
        let font = nameFont
        let trailing: [NSAttributedString]
        switch usage {
        case .none:
            return nil
        case let .bars(session, weekly, ageNote):
            let bars = NSTextAttachment()
            bars.image = UsageBarsMenuImage.image(session: session, weekly: weekly)
            // Centered on the capitals of the name.
            let size = UsageBarsMenuImage.size
            bars.bounds = CGRect(x: 0, y: (font.capHeight - size.height) / 2,
                                 width: size.width, height: size.height)
            var parts = [NSAttributedString(attachment: bars)]
            if let ageNote {
                parts.append(note("  " + ageNote))
            }
            trailing = parts
        case let .note(text):
            trailing = [note(text)]
        }
        // No foreground color on the name, so the menu still turns it white
        // under the highlight.
        let title = NSMutableAttributedString(string: name, attributes: [.font: font])
        title.append(spacer(width: spacerWidth(name: name, nameColumnWidth: nameColumnWidth)))
        for part in trailing {
            title.append(part)
        }
        return title
    }

    /// What the row leaves out: the account's login email on the first line,
    /// then the reset times, for example
    /// "5-hour: 40% used · resets at 8pm — Weekly: 16% used · resets at Fri 7pm".
    /// A window that has ended says when it reset instead of its old percent:
    /// "Weekly: reset at Mon 7am".
    /// The reset times show only when the row shows bars. Either line stands
    /// alone when the other is missing; nil when both are.
    static func toolTip(for usage: MenuUsage, identity: String?) -> String? {
        let lines = [identity, resetTimes(for: usage)]
            .compactMap { $0 }
            .filter { !$0.isEmpty }
        return lines.isEmpty ? nil : lines.joined(separator: "\n")
    }

    /// Sets the item's title and tooltip. The plain `title` stays the name
    /// alone, for type-to-select and accessibility. `identity` is the login
    /// email the tooltip leads with (`ProfileLoginPresentation.menuIdentity`).
    static func apply(to item: NSMenuItem,
                      name: String,
                      usage: MenuUsage,
                      identity: String?,
                      nameColumnWidth: CGFloat) {
        if let attributed = attributedTitle(name: name, usage: usage,
                                            nameColumnWidth: nameColumnWidth) {
            item.attributedTitle = attributed
        }
        // Setting attributedTitle copies its flattened string into `title`.
        item.title = name
        item.toolTip = toolTip(for: usage, identity: identity)
    }

    // MARK: - Pieces

    /// The reset times, one window after the other. nil unless the row shows bars.
    private static func resetTimes(for usage: MenuUsage) -> String? {
        guard case let .bars(session, weekly, _) = usage else { return nil }
        var parts: [String] = []
        if let session { parts.append(toolTipPart("5-hour", session)) }
        if let weekly { parts.append(toolTipPart("Weekly", weekly)) }
        return parts.isEmpty ? nil : parts.joined(separator: " — ")
    }

    private static func spacer(width: CGFloat) -> NSAttributedString {
        let size = NSSize(width: width, height: 1)
        let attachment = NSTextAttachment()
        // An attachment with no image can draw a placeholder; a clear one draws nothing.
        attachment.image = NSImage(size: size, flipped: false) { _ in true }
        attachment.bounds = CGRect(origin: .zero, size: size)
        return NSAttributedString(attachment: attachment)
    }

    private static func note(_ text: String) -> NSAttributedString {
        NSAttributedString(string: text, attributes: [
            .font: noteFont,
            .foregroundColor: NSColor.secondaryLabelColor,
        ])
    }

    private static func toolTipPart(_ window: String,
                                    _ presentation: ProfileUsagePresentation.BucketPresentation) -> String {
        "\(window): \(presentation.usageText())"
    }
}
