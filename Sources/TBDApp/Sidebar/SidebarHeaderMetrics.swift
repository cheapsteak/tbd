import CoreGraphics

/// Shared geometry for the sidebar's section headers and the rows beneath
/// them, so a project row, the Scratch header, and a remote-provider header
/// put their titles in one column instead of each carrying its own copy of the
/// arithmetic.
///
/// Everything here turns on `AppState.chevronBeforeProjectNameKey`, off by
/// default. Off, every value below reproduces the layout that shipped before
/// the setting existed: titles start at their row's leading edge and rows sit
/// 12pt in. On, a project row's chevron moves to the left of its name, so the
/// titles clear a chevron column and every row follows its title.
enum SidebarHeaderMetrics {
    /// The square a project row's disclosure chevron occupies — its hit
    /// target, wider than the glyph inside it.
    static let chevronColumnWidth: CGFloat = 18

    /// Spacing between a section header's `HStack` items.
    static let headerSpacing: CGFloat = 4

    /// Leading padding on a project row's name while the chevron leads it,
    /// clawing back the chevron square's trailing slack so the glyph and the
    /// name read as one label. Zero while the chevron trails instead.
    static let nameLeadingClawback: CGFloat = -2

    /// The `listRowInsets` leading every section HEADER row carries — the
    /// left edge of a section's chrome, chevron included.
    static let headerRowLeadingInset: CGFloat = -2

    /// How far a child row's content sits past its section's title. Applied
    /// only where the title has moved: with the chevron trailing the name,
    /// this reproduces the historical 12pt row inset exactly.
    static let childRowIndent: CGFloat = 14

    /// How far a section title sits from its row's leading edge.
    ///
    /// With the chevron before the project name, a project title clears the
    /// chevron column, so a chevron-less header needs this much leading
    /// padding to land in the same column. With the chevron after the name —
    /// the default — every title starts at the row's edge and no header needs
    /// padding at all.
    static func titleLeadingInset(chevronBeforeProjectName: Bool) -> CGFloat {
        chevronBeforeProjectName
            ? chevronColumnWidth + headerSpacing + nameLeadingClawback
            : 0
    }

    /// The `listRowInsets` leading for the rows under a section title —
    /// worktrees, scratch pads, remote sessions. Derived from the title's own
    /// position so children track it: with the chevron before the project
    /// name the titles sit a chevron column in, and the rows come with them.
    /// With the chevron after the name this is the historical 12pt.
    static func childRowLeadingInset(chevronBeforeProjectName: Bool) -> CGFloat {
        headerRowLeadingInset
            + titleLeadingInset(chevronBeforeProjectName: chevronBeforeProjectName)
            + childRowIndent
    }

    /// Whether a section's disclosure chevron is mounted at all. Before the
    /// title it always is, so the expanded/collapsed state reads without a
    /// pointer; after the title — the default — it appears only once
    /// `revealed` by the row's hover gate, shared with its `+`.
    static func chevronMounted(beforeTitle: Bool, revealed: Bool) -> Bool {
        beforeTitle || revealed
    }
}
