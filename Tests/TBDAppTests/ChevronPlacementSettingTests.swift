import Foundation
import Testing
@testable import TBDApp

/// The chevron-placement setting's storage contract: unset means "never
/// chose", and both explicit values persist as written. Mirrors
/// `ShowScratchSectionSettingTests`, and pins that the shipped default is
/// off — the chevron leads the project name unless a user asks otherwise.
@MainActor
@Suite("chevronAfterProjectName setting")
struct ChevronPlacementSettingTests {
    @Test func defaultsToOff() {
        #expect(AppState.chevronAfterProjectNameDefault == false)
    }

    @Test func storesBothBranches() {
        let suiteName = "chevron-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        #expect(defaults.object(forKey: AppState.chevronAfterProjectNameKey) == nil)
        defaults.set(true, forKey: AppState.chevronAfterProjectNameKey)
        #expect(defaults.bool(forKey: AppState.chevronAfterProjectNameKey) == true)
        defaults.set(false, forKey: AppState.chevronAfterProjectNameKey)
        #expect(defaults.bool(forKey: AppState.chevronAfterProjectNameKey) == false)
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
    @Test("leading the name: mounted with no pointer in the section")
    func leadingUnhoveredMounted() {
        #expect(RepoSectionView.chevronMounted(afterName: false, hovered: false, menuOpen: false))
    }

    @Test("leading the name: still mounted while hovered")
    func leadingHoveredMounted() {
        #expect(RepoSectionView.chevronMounted(afterName: false, hovered: true, menuOpen: false))
    }

    @Test("trailing the name: hidden with no pointer in the section")
    func trailingUnhoveredHidden() {
        #expect(!RepoSectionView.chevronMounted(afterName: true, hovered: false, menuOpen: false))
    }

    @Test("trailing the name: revealed on hover")
    func trailingHoveredMounted() {
        #expect(RepoSectionView.chevronMounted(afterName: true, hovered: true, menuOpen: false))
    }

    @Test("trailing the name: stays mounted while the + menu is open off-hover")
    func trailingMenuOpenMounted() {
        #expect(RepoSectionView.chevronMounted(afterName: true, hovered: false, menuOpen: true))
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
    private func projectTitleOffset(chevronAfterName: Bool) -> CGFloat {
        guard !chevronAfterName else { return 0 }
        return SidebarHeaderMetrics.chevronColumnWidth
            + SidebarHeaderMetrics.headerSpacing
            + SidebarHeaderMetrics.nameLeadingClawback
    }

    @Test("chevron before the name: a chevron-less title clears the chevron column")
    func leadingChevronIndentsSiblings() {
        let inset = SidebarHeaderMetrics.titleLeadingInset(chevronAfterProjectName: false)
        #expect(inset == projectTitleOffset(chevronAfterName: false))
        #expect(inset > 0)
    }

    @Test("chevron after the name: every title starts at the row edge")
    func trailingChevronNeedsNoIndent() {
        let inset = SidebarHeaderMetrics.titleLeadingInset(chevronAfterProjectName: true)
        #expect(inset == projectTitleOffset(chevronAfterName: true))
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
    private func titleOrigin(chevronAfterName: Bool) -> CGFloat {
        SidebarHeaderMetrics.headerRowLeadingInset
            + SidebarHeaderMetrics.titleLeadingInset(chevronAfterProjectName: chevronAfterName)
    }

    @Test("chevron before the name: rows sit indented past the title")
    func leadingChevronRowsIndented() {
        let rows = SidebarHeaderMetrics.childRowLeadingInset(chevronAfterProjectName: false)
        #expect(rows > titleOrigin(chevronAfterName: false))
        #expect(rows - titleOrigin(chevronAfterName: false) == SidebarHeaderMetrics.childRowIndent)
    }

    @Test("chevron after the name: rows sit indented past the title there too")
    func trailingChevronRowsIndented() {
        let rows = SidebarHeaderMetrics.childRowLeadingInset(chevronAfterProjectName: true)
        #expect(rows > titleOrigin(chevronAfterName: true))
        #expect(rows - titleOrigin(chevronAfterName: true) == SidebarHeaderMetrics.childRowIndent)
    }

    @Test("the indent step is the same whichever side the chevron is on")
    func stepIsPlacementIndependent() {
        let leading = SidebarHeaderMetrics.childRowLeadingInset(chevronAfterProjectName: false)
            - titleOrigin(chevronAfterName: false)
        let trailing = SidebarHeaderMetrics.childRowLeadingInset(chevronAfterProjectName: true)
            - titleOrigin(chevronAfterName: true)
        #expect(leading == trailing)
    }
}

/// The mount gate every collapsible section shares.
@MainActor
@Suite("section chevron mount gate")
struct SectionChevronMountTests {
    @Test("before the title: mounted whether or not the row is revealed")
    func leadingAlwaysMounted() {
        #expect(SidebarHeaderMetrics.chevronMounted(afterTitle: false, revealed: false))
        #expect(SidebarHeaderMetrics.chevronMounted(afterTitle: false, revealed: true))
    }

    @Test("after the title: mounted only once the row is revealed")
    func trailingFollowsReveal() {
        #expect(!SidebarHeaderMetrics.chevronMounted(afterTitle: true, revealed: false))
        #expect(SidebarHeaderMetrics.chevronMounted(afterTitle: true, revealed: true))
    }
}
