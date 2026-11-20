import AppKit
import Foundation
import Testing
@testable import TBDApp
import TBDShared
import TestSupport

/// A repo header's registry filter button and its menu item
/// (docs/specs/2026-11-19-sidebar-remote-session-filter-design.md, "The
/// button"): it sits right after the title and chevron on either side, keeps
/// its 20 pt square whether drawn or not so a hover never moves or cuts the
/// title, draws only with the `+` while off and always, tinted and counted,
/// while on; a click and the menu item flip the repo's saved filter.
///
/// Tier 1. The cell tests lay a `SectionHeaderCell` out directly, off any
/// window, as `SidebarCellCentringTests` does; the outline tests mount the
/// controller offscreen through `OutlineHarness` and drive it with
/// `flushPendingRebuild()`.
@MainActor
@Suite("Sidebar registry filter header")
struct SidebarRegistryFilterHeaderTests {
    /// A repo name that a 220 pt header cuts, button or not.
    static let longTitle = "a repository name long enough to truncate in a narrow sidebar header"

    static func button(isOn: Bool = false, count: Int = 0, providers: [String] = ["acme"])
        -> SidebarRegistryFilterButton {
        SidebarRegistryFilterButton(isOn: isOn, count: count, providerNames: providers)
    }

    static func header(title: String = "tbd", filter: SidebarRegistryFilterButton?, missing: Bool = false)
        -> SectionHeaderModel {
        SectionHeaderModel(
            title: title, isExpanded: true, isHidden: false, isMissing: missing, isSelected: false,
            registryFilter: filter)
    }

    /// A configured header laid out in a row `height` tall, revealed or not.
    static func layOut(
        _ model: SectionHeaderModel, chevronBeforeTitle: Bool, style: SectionHeaderCell.Style = .repo,
        width: CGFloat = 260, height: CGFloat = SectionHeaderCell.rowHeight, revealed: Bool = false
    ) -> SectionHeaderCell {
        let cell = SectionHeaderCell()
        cell.style = style
        cell.chevronBeforeTitle = chevronBeforeTitle
        cell.frame = NSRect(x: 0, y: 0, width: width, height: height)
        cell.configure(model)
        cell.setHovered(revealed)
        cell.layout()
        return cell
    }

    // MARK: Layout

    /// The off button's square is in the layout before the hover draws it,
    /// so revealing the header moves neither the title nor the button.
    @Test func reservedSquareHoldsWhileTheButtonIsNotDrawn() throws {
        for chevronBeforeTitle in [false, true] {
            let label = "chevron before title \(chevronBeforeTitle)"
            let cell = Self.layOut(
                Self.header(title: Self.longTitle, filter: Self.button()),
                chevronBeforeTitle: chevronBeforeTitle, width: 220)
            try #require(SidebarCellKit.truncates(cell.titleField), "\(label): the title fits, so this checks nothing")
            #expect(cell.filterButton.isHidden, "\(label): an off filter drew without hover")
            #expect(cell.filterButton.frame.width == SectionHeaderCell.filterSide,
                    "\(label): the hidden filter keeps no square")
            let title = cell.titleField.frame
            let filter = cell.filterButton.frame

            cell.setHovered(true)
            cell.layout()
            #expect(!cell.filterButton.isHidden, "\(label): hover did not draw the off filter")
            #expect(cell.titleField.frame == title, "\(label): the title moved when the filter appeared")
            #expect(cell.filterButton.frame == filter, "\(label): the filter moved when it appeared")
        }
    }

    /// `name ▸ [filter]` with the chevron after the name, `▸ name [filter]`
    /// with it before; the `+` stays at the trailing edge and a missing
    /// repo's badge and Locate… follow the filter.
    @Test func filterFollowsTheChevronOnEitherSide() throws {
        let spacing = SidebarHeaderMetrics.headerSpacing

        let after = Self.layOut(Self.header(filter: Self.button()), chevronBeforeTitle: false, revealed: true)
        try #require(!after.chevronButton.isHidden, "The trailing chevron is hidden, so this checks nothing")
        #expect(after.filterButton.frame.minX == after.chevronButton.frame.maxX + spacing)
        #expect(after.chevronButton.frame.minX > after.titleField.frame.maxX)
        #expect(after.plusButton.frame.minX == after.bounds.width - 24)
        #expect(after.plusButton.frame.minX > after.filterButton.frame.maxX)

        let before = Self.layOut(Self.header(filter: Self.button()), chevronBeforeTitle: true, revealed: true)
        #expect(before.filterButton.frame.minX == before.titleField.frame.maxX + spacing)
        #expect(before.chevronButton.frame.maxX <= before.titleField.frame.minX)
        #expect(before.plusButton.frame.minX == before.bounds.width - 24)

        for chevronBeforeTitle in [false, true] {
            let missing = Self.layOut(
                Self.header(filter: Self.button(), missing: true), chevronBeforeTitle: chevronBeforeTitle,
                revealed: true)
            try #require(!missing.missingField.isHidden, "The missing badge is hidden, so this checks nothing")
            #expect(missing.missingField.frame.minX > missing.filterButton.frame.maxX,
                    "Chevron before title \(chevronBeforeTitle): the badge does not follow the filter")
            #expect(missing.locateButton.frame.minX > missing.missingField.frame.maxX)
            #expect(missing.filterButton.alphaValue == 0.5, "A missing repo's filter is not dimmed like its chevron")
        }
    }

    /// The reserve is the only difference a button makes to the title: a
    /// header without one keeps today's layout, and the Scratch header never
    /// has one.
    @Test func noButtonReservesNoSquare() throws {
        for chevronBeforeTitle in [false, true] {
            let label = "chevron before title \(chevronBeforeTitle)"
            let none = Self.layOut(
                Self.header(title: Self.longTitle, filter: nil), chevronBeforeTitle: chevronBeforeTitle,
                width: 220, revealed: true)
            let off = Self.layOut(
                Self.header(title: Self.longTitle, filter: Self.button()), chevronBeforeTitle: chevronBeforeTitle,
                width: 220, revealed: true)
            try #require(SidebarCellKit.truncates(off.titleField), "\(label): the title fits, so this checks nothing")
            #expect(none.filterButton.isHidden, "\(label): a header without a filter drew one")
            let difference = none.titleField.frame.width - off.titleField.frame.width
            #expect(difference == SectionHeaderCell.filterSide + SidebarHeaderMetrics.headerSpacing,
                    "\(label): the filter took \(difference) pt from the title")
            #expect(none.titleField.frame.minX == off.titleField.frame.minX)

            // The Scratch header ignores a filter its model should never carry.
            let scratch = Self.layOut(
                Self.header(title: "Scratch", filter: Self.button(isOn: true, count: 2)),
                chevronBeforeTitle: chevronBeforeTitle, style: .scratch, revealed: true)
            #expect(scratch.filterButton.isHidden, "\(label): the Scratch header drew a filter")
        }
    }

    // MARK: States

    @Test func onStateIsAlwaysDrawnTintedWithItsCount() {
        for chevronBeforeTitle in [false, true] {
            let cell = Self.layOut(
                Self.header(filter: Self.button(isOn: true, count: 3)), chevronBeforeTitle: chevronBeforeTitle)
            #expect(!cell.isRevealed)
            #expect(!cell.filterButton.isHidden, "An on filter must draw without hover")
            #expect(cell.filterButton.contentTintColor == NSColor.controlAccentColor)
            #expect(cell.filterButton.title == "3")
            #expect(cell.filterButton.toolTip == "3 acme sessions hidden. Click to show them.")
            #expect(cell.filterButton.accessibilityLabel() == "3 acme sessions hidden. Click to show them.")
            // The count widens the button, never below its square, and it
            // still sits after the title.
            #expect(cell.filterButton.frame.width >= SectionHeaderCell.filterSide)
            #expect(cell.filterButton.frame.minX > cell.titleField.frame.maxX)
            #expect(cell.plusButton.frame.minX >= cell.filterButton.frame.maxX)
        }

        let two = Self.layOut(
            Self.header(filter: Self.button(isOn: true, count: 4, providers: ["acme", "acme-two"])),
            chevronBeforeTitle: false)
        #expect(two.filterButton.toolTip == "4 remote sessions hidden. Click to show them.")
    }

    @Test func offStateDrawsOnlyWhileRevealed() {
        let cell = Self.layOut(Self.header(filter: Self.button()), chevronBeforeTitle: false)
        #expect(cell.filterButton.isHidden)
        cell.setHovered(true)
        #expect(!cell.filterButton.isHidden)
        #expect(cell.filterButton.contentTintColor == NSColor.secondaryLabelColor)
        #expect(cell.filterButton.title.isEmpty)
        #expect(cell.filterButton.toolTip == "Hide acme sessions")
        #expect(cell.filterButton.accessibilityLabel() == "Hide acme sessions")
        cell.setHovered(false)
        #expect(cell.filterButton.isHidden)
        // Like the `+`, it stays while the `+` menu holds the section open.
        cell.setMenuOpen(true)
        #expect(!cell.filterButton.isHidden)
        cell.setMenuOpen(false)
        #expect(cell.filterButton.isHidden)

        let two = Self.layOut(
            Self.header(filter: Self.button(providers: ["acme", "acme-two"])), chevronBeforeTitle: false,
            revealed: true)
        #expect(two.filterButton.toolTip == "Hide remote sessions except cloud")

        // One cell through on, off and no button: nothing of a state leaks
        // into the next.
        cell.configure(Self.header(filter: Self.button(isOn: true, count: 2)))
        #expect(!cell.filterButton.isHidden)
        #expect(cell.filterButton.title == "2")
        cell.configure(Self.header(filter: Self.button()))
        #expect(cell.filterButton.isHidden)
        #expect(cell.filterButton.title.isEmpty)
        #expect(cell.filterButton.contentTintColor == NSColor.secondaryLabelColor)
        cell.configure(Self.header(filter: nil))
        cell.setHovered(true)
        #expect(cell.filterButton.isHidden)
        #expect(cell.filterButton.toolTip == nil)
    }

    // MARK: Hover

    @Test func hoverPartFindsTheFilter() {
        for chevronBeforeTitle in [false, true] {
            let label = "chevron before title \(chevronBeforeTitle)"
            let cell = Self.layOut(Self.header(filter: Self.button()), chevronBeforeTitle: chevronBeforeTitle,
                                   revealed: true)
            let frame = cell.filterButton.frame
            let centre = NSPoint(x: frame.midX, y: frame.midY)
            #expect(cell.hoverPart(at: centre) == .registryFilter, "\(label)")

            cell.setHoveredPart(.registryFilter)
            #expect(cell.filterButton.showsHoverWash, "\(label)")
            #expect(!cell.chevronButton.showsHoverWash, "\(label)")
            #expect(!cell.plusButton.showsHoverWash, "\(label)")
            cell.setHoveredPart(.plus)
            #expect(!cell.filterButton.showsHoverWash, "\(label)")

            // An undrawn filter is no part.
            cell.setHovered(false)
            #expect(cell.hoverPart(at: centre) == .none, "\(label)")
        }
    }

    @Test func filterSquareCentresOnTheRowMidline() {
        for isOn in [false, true] {
            for chevronBeforeTitle in [false, true] {
                for height in [SectionHeaderCell.rowHeight, 27] {
                    let label = "on \(isOn), chevron before title \(chevronBeforeTitle), height \(height)"
                    let cell = Self.layOut(
                        Self.header(filter: Self.button(isOn: isOn, count: 5)),
                        chevronBeforeTitle: chevronBeforeTitle, height: height, revealed: true)
                    let frame = cell.filterButton.frame
                    let minY = frame.minY
                    #expect(!cell.filterButton.isHidden, "\(label)")
                    #expect(minY == minY.rounded(), "\(label): the filter starts at y \(minY)")
                    #expect(abs(frame.midY - cell.bounds.midY) <= 0.5, "\(label): the filter sits off the midline")
                    if height == SectionHeaderCell.rowHeight {
                        #expect(frame.midY == cell.bounds.midY, "\(label)")
                    }
                }
            }
        }
    }

    // MARK: The outline

    @Test func clickingTheFilterHidesAndShowsTheRepoRegistryRows() throws {
        let h = OutlineHarness("registryFilter.click")
        defer { h.tearDown() }
        let repo = Repo(path: "/tmp/acme", displayName: "acme")
        let local = SidebarOutlineControllerTests.row("local", repo, order: 0)
        let remote = SidebarGroupFixtures.row("worker", repoID: repo.id, remote: "one", order: 1)
        h.state.repos = [repo]
        h.state.worktrees = [repo.id: [local, remote]]
        h.state.remoteProviders = [SidebarGroupFixtures.provider()]
        h.mount()

        let names = [local.id: "local", remote.id: "worker"]
        try #require(h.shownIDs.contains(.worktree(remote.id)), h.evidence(names))
        let cell = try #require(Self.headerCell(repo.id, in: h))
        try #require(cell.model?.registryFilter != nil, "The repo header carries no registry filter")
        #expect(cell.filterButton.target === h.controller)
        #expect(cell.filterButton.action == #selector(SidebarOutlineController.registryFilterClicked(_:)))

        cell.setHovered(true)
        try #require(!cell.filterButton.isHidden, "The revealed header does not draw its off filter")
        cell.filterButton.performClick(nil)
        #expect(h.state.sidebarRegistryRemoteHiddenRepoIDs == [repo.id])
        h.controller.flushPendingRebuild()
        #expect(!h.shownIDs.contains(.worktree(remote.id)), h.evidence(names))
        #expect(h.shownIDs.contains(.worktree(local.id)), h.evidence(names))

        let onCell = try #require(Self.headerCell(repo.id, in: h))
        #expect(onCell.model?.registryFilter?.isOn == true)
        #expect(onCell.model?.registryFilter?.count == 1)
        onCell.setHovered(false)
        #expect(!onCell.filterButton.isHidden, "An on filter must draw without hover")

        onCell.filterButton.performClick(nil)
        #expect(h.state.sidebarRegistryRemoteHiddenRepoIDs.isEmpty)
        h.controller.flushPendingRebuild()
        #expect(h.shownIDs.contains(.worktree(remote.id)), h.evidence(names))
    }

    @Test func menuItemIsCheckedWhileOnAndAbsentWithoutRegistryWork() throws {
        let h = OutlineHarness("registryFilter.menu")
        defer { h.tearDown() }
        let repo = Repo(path: "/tmp/acme", displayName: "acme")
        let plain = Repo(path: "/tmp/acme-plain", displayName: "plain")
        let remote = SidebarGroupFixtures.row("worker", repoID: repo.id, remote: "one", order: 1)
        h.state.repos = [repo, plain]
        h.state.worktrees = [
            repo.id: [SidebarOutlineControllerTests.row("work", repo), remote],
            plain.id: [SidebarOutlineControllerTests.row("local", plain)],
        ]
        h.state.remoteProviders = [SidebarGroupFixtures.provider()]
        h.mount()

        let title = "Hide acme Sessions"
        let node = try #require(h.controller.tree.node(.repoHeader(repo.id)))
        let menu = try #require(h.controller.menus.menu(for: node))
        let titles = SidebarInteractionTests.titles(of: menu)
        let hidePosition = titles.firstIndex(of: "Hide")
        let hideIndex = try #require(hidePosition, "The repo menu has no Hide item: \(titles)")
        let filterPosition = titles.firstIndex(of: title)
        let filterIndex = try #require(filterPosition, "The repo menu has no filter item: \(titles)")
        #expect(filterIndex == hideIndex + 1, "The filter item does not follow Hide: \(titles)")
        #expect(menu.items[filterIndex].state == .off)

        menu.performActionForItem(at: filterIndex)
        #expect(h.state.sidebarRegistryRemoteHiddenRepoIDs == [repo.id])
        h.controller.flushPendingRebuild()
        #expect(!h.shownIDs.contains(.worktree(remote.id)))
        let rebuilt = try #require(h.controller.tree.node(.repoHeader(repo.id)))
        let reopened = try #require(h.controller.menus.menu(for: rebuilt))
        let checked = try #require(reopened.item(withTitle: title))
        #expect(checked.state == .on)

        // A repo with only local rows has nothing to hide, so no item.
        let plainNode = try #require(h.controller.tree.node(.repoHeader(plain.id)))
        let plainMenu = try #require(h.controller.menus.menu(for: plainNode))
        let plainTitles = SidebarInteractionTests.titles(of: plainMenu)
        let offersFilter = plainTitles.contains { $0.hasSuffix(" Sessions") || $0.hasSuffix(" Except Cloud") }
        #expect(!offersFilter, "A repo without registry work offers the filter: \(plainTitles)")
    }

    // MARK: Helpers

    /// The repo header's cell, made if the outline has not made it yet.
    static func headerCell(_ repoID: UUID, in h: OutlineHarness) -> SectionHeaderCell? {
        SidebarInteractionTests.cell(.repoHeader(repoID), in: h) as? SectionHeaderCell
    }
}
