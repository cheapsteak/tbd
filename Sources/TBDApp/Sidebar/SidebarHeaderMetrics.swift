import CoreGraphics

/// Shared geometry for the sidebar's section headers, so a project row, the
/// Scratch header, and a remote-provider header put their titles in one
/// column instead of each carrying its own copy of the arithmetic.
///
/// A project row is the only section header with a disclosure chevron, so it
/// is the one whose title can start somewhere other than the row's leading
/// edge — and where that is depends on
/// `AppState.chevronAfterProjectNameKey`. Every other section header follows
/// it via `titleLeadingInset(chevronAfterProjectName:)`.
enum SidebarHeaderMetrics {
    /// The square a project row's disclosure chevron occupies — its hit
    /// target, wider than the glyph inside it.
    static let chevronColumnWidth: CGFloat = 18

    /// Spacing between a section header's `HStack` items.
    static let headerSpacing: CGFloat = 4

    /// Leading padding on a project row's name while the chevron leads it,
    /// clawing back the chevron square's trailing slack so the glyph and the
    /// name read as one label.
    static let nameLeadingClawback: CGFloat = -2

    /// How far a section title sits from its row's leading edge.
    ///
    /// With the chevron before the project name (the default), a project
    /// title clears the chevron column, so a chevron-less header needs this
    /// much leading padding to land in the same column. With the chevron
    /// after the name, project titles start at the row's edge and no header
    /// needs padding at all.
    static func titleLeadingInset(chevronAfterProjectName: Bool) -> CGFloat {
        chevronAfterProjectName
            ? 0
            : chevronColumnWidth + headerSpacing + nameLeadingClawback
    }
}
