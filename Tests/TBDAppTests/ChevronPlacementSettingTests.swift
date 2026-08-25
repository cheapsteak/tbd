import Foundation
import Testing
@testable import TBDApp

/// The chevron-placement setting's storage contract: unset means "never
/// chose", and both explicit values persist as written. Mirrors
/// `ShowScratchSectionSettingTests`, and pins that the shipped default is
/// off — nobody's chevron moves, and no row shifts, until they ask.
@MainActor
@Suite("chevronBeforeProjectName setting")
struct ChevronPlacementSettingTests {
    @Test func defaultsToOff() {
        #expect(AppState.chevronBeforeProjectNameDefault == false)
    }

    @Test func storesBothBranches() {
        let suiteName = "chevron-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        #expect(defaults.object(forKey: AppState.chevronBeforeProjectNameKey) == nil)
        defaults.set(true, forKey: AppState.chevronBeforeProjectNameKey)
        #expect(defaults.bool(forKey: AppState.chevronBeforeProjectNameKey) == true)
        defaults.set(false, forKey: AppState.chevronBeforeProjectNameKey)
        #expect(defaults.bool(forKey: AppState.chevronBeforeProjectNameKey) == false)
    }
}

/// Direct proof of the one behavior the two chevron placements disagree
/// about — whether the button is mounted when nothing is hovered. Tests the
/// extracted pure function rather than a live view, the same way
/// `ScratchSectionVisibleTests` does, so an inverted or dropped gate fails
/// here instead of only in the running app.
@MainActor
@Suite("chevronMounted gate")
struct ChevronMountedTests {
    @Test("setting on, leading the name: mounted with no pointer in the section")
    func leadingUnhoveredMounted() {
        #expect(RepoSectionView.chevronMounted(beforeName: true, hovered: false, menuOpen: false))
    }

    @Test("setting on, leading the name: still mounted while hovered")
    func leadingHoveredMounted() {
        #expect(RepoSectionView.chevronMounted(beforeName: true, hovered: true, menuOpen: false))
    }

    @Test("default, trailing the name: hidden with no pointer in the section")
    func trailingUnhoveredHidden() {
        #expect(!RepoSectionView.chevronMounted(beforeName: false, hovered: false, menuOpen: false))
    }

    @Test("default, trailing the name: revealed on hover")
    func trailingHoveredMounted() {
        #expect(RepoSectionView.chevronMounted(beforeName: false, hovered: true, menuOpen: false))
    }

    @Test("default, trailing the name: stays mounted while the + menu is open off-hover")
    func trailingMenuOpenMounted() {
        #expect(RepoSectionView.chevronMounted(beforeName: false, hovered: false, menuOpen: true))
    }
}

/// The sidebar's section titles all sit in one column, and where that column
/// is depends on the chevron placement. Pins the arithmetic both ways so a
/// chevron-less header (Scratch, a remote provider) can't drift out of line
/// with the project titles it's supposed to match.
@MainActor
@Suite("sidebar header title inset")
struct SidebarHeaderMetricsTests {
    /// What a project row's own name ends up at, computed from the row's
    /// pieces rather than from the value under test — so a change to either
    /// one alone fails this.
    private func projectTitleOffset(chevronBeforeName: Bool) -> CGFloat {
        guard chevronBeforeName else { return 0 }
        return SidebarHeaderMetrics.chevronColumnWidth
            + SidebarHeaderMetrics.headerSpacing
            + SidebarHeaderMetrics.nameLeadingClawback
    }

    @Test("setting on: a chevron-less title clears the chevron column")
    func leadingChevronIndentsSiblings() {
        let inset = SidebarHeaderMetrics.titleLeadingInset(chevronBeforeProjectName: true)
        #expect(inset == projectTitleOffset(chevronBeforeName: true))
        #expect(inset > 0)
    }

    @Test("default: every title starts at the row edge")
    func trailingChevronNeedsNoIndent() {
        let inset = SidebarHeaderMetrics.titleLeadingInset(chevronBeforeProjectName: false)
        #expect(inset == projectTitleOffset(chevronBeforeName: false))
        #expect(inset == 0)
    }
}

/// The Scratch section's own collapse bit — app-side, unlike a project's
/// daemon-owned `Repo.expanded`. Pins that it ships expanded and that both
/// explicit values persist.
@MainActor
@Suite("scratchSectionExpanded setting")
struct ScratchSectionExpandedTests {
    @Test func defaultsToExpanded() {
        #expect(AppState.scratchSectionExpandedDefault == true)
    }

    @Test func storesBothBranches() {
        let suiteName = "scratch-expanded-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        #expect(defaults.object(forKey: AppState.scratchSectionExpandedKey) == nil)
        defaults.set(false, forKey: AppState.scratchSectionExpandedKey)
        #expect(defaults.bool(forKey: AppState.scratchSectionExpandedKey) == false)
        defaults.set(true, forKey: AppState.scratchSectionExpandedKey)
        #expect(defaults.bool(forKey: AppState.scratchSectionExpandedKey) == true)
    }
}

/// The rows under a section title track that title's column, in both chevron
/// placements — a scratch pad, a worktree and a remote session all read this
/// one helper, so the numbers here are what keeps them in one column.
@MainActor
@Suite("sidebar child row inset")
struct SidebarChildRowInsetTests {
    /// Where a section title's text lands, measured from the list edge rather
    /// than from the value under test.
    private func titleOrigin(chevronBeforeName: Bool) -> CGFloat {
        SidebarHeaderMetrics.headerRowLeadingInset
            + SidebarHeaderMetrics.titleLeadingInset(chevronBeforeProjectName: chevronBeforeName)
    }

    @Test("setting on: rows sit indented past the title")
    func leadingChevronRowsIndented() {
        let rows = SidebarHeaderMetrics.childRowLeadingInset(chevronBeforeProjectName: true)
        #expect(rows > titleOrigin(chevronBeforeName: true))
        #expect(rows - titleOrigin(chevronBeforeName: true) == SidebarHeaderMetrics.childRowIndent)
    }

    @Test("default: rows sit indented past the title there too")
    func trailingChevronRowsIndented() {
        let rows = SidebarHeaderMetrics.childRowLeadingInset(chevronBeforeProjectName: false)
        #expect(rows > titleOrigin(chevronBeforeName: false))
        #expect(rows - titleOrigin(chevronBeforeName: false) == SidebarHeaderMetrics.childRowIndent)
    }

    @Test("the indent step is the same whichever side the chevron is on")
    func stepIsPlacementIndependent() {
        let onSetting = SidebarHeaderMetrics.childRowLeadingInset(chevronBeforeProjectName: true)
            - titleOrigin(chevronBeforeName: true)
        let byDefault = SidebarHeaderMetrics.childRowLeadingInset(chevronBeforeProjectName: false)
            - titleOrigin(chevronBeforeName: false)
        #expect(onSetting == byDefault)
    }
}

/// The mount gate every collapsible section shares.
@MainActor
@Suite("section chevron mount gate")
struct SectionChevronMountTests {
    @Test("before the title: mounted whether or not the row is revealed")
    func leadingAlwaysMounted() {
        #expect(SidebarHeaderMetrics.chevronMounted(beforeTitle: true, revealed: false))
        #expect(SidebarHeaderMetrics.chevronMounted(beforeTitle: true, revealed: true))
    }

    @Test("after the title: mounted only once the row is revealed")
    func trailingFollowsReveal() {
        #expect(!SidebarHeaderMetrics.chevronMounted(beforeTitle: false, revealed: false))
        #expect(SidebarHeaderMetrics.chevronMounted(beforeTitle: false, revealed: true))
    }
}

/// The whole point of the default being off: with nobody's setting touched,
/// the sidebar's geometry is the geometry that shipped before this setting
/// existed. These are the literal numbers the views used to hardcode, so a
/// change that moves anybody's rows without them asking fails here.
@MainActor
@Suite("default placement changes nothing")
struct DefaultSidebarGeometryTests {
    /// What `ScratchSectionView` and `RemoteProviderHeaderRow` used before the
    /// setting existed: no inset, titles flush with the row's leading edge.
    private let historicalTitleInset: CGFloat = 0
    /// What every child row hardcoded before the setting existed.
    private let historicalChildRowInset: CGFloat = 12

    @Test("titles keep their historical position")
    func titlesUnmoved() {
        #expect(AppState.chevronBeforeProjectNameDefault == false)
        #expect(
            SidebarHeaderMetrics.titleLeadingInset(
                chevronBeforeProjectName: AppState.chevronBeforeProjectNameDefault
            ) == historicalTitleInset)
    }

    @Test("worktrees, scratch pads and remote sessions keep their historical inset")
    func rowsUnmoved() {
        #expect(
            SidebarHeaderMetrics.childRowLeadingInset(
                chevronBeforeProjectName: AppState.chevronBeforeProjectNameDefault
            ) == historicalChildRowInset)
    }

    @Test("the project chevron keeps its hover gate")
    func chevronStillHoverGated() {
        let byDefault = AppState.chevronBeforeProjectNameDefault
        #expect(!RepoSectionView.chevronMounted(beforeName: byDefault, hovered: false, menuOpen: false))
        #expect(RepoSectionView.chevronMounted(beforeName: byDefault, hovered: true, menuOpen: false))
    }
}
