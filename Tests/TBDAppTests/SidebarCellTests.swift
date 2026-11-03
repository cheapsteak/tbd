import AppKit
import Foundation
import Testing
@testable import TBDApp
import TBDShared
import TestSupport

// Cells are configured and drawn directly, off any window; the bitmap probe
// draws one row view into a bitmap. One test mounts the outline offscreen to
// check the cells it hands out.

/// The native sidebar's cells and row view: every model input reaches the
/// cell, reuse cannot leak opacity, each cell reuses by identifier, the row
/// view draws each highlight state, and heights map from height classes.
/// Spec: docs/specs/2026-10-31-native-sidebar-design.md, "Units".
@MainActor
@Suite("Sidebar cells")
struct SidebarCellTests {
    @Test func worktreeCellShowsEveryModelInput() throws {
        let cell = WorktreeRowCell()
        cell.frame = NSRect(x: 0, y: 0, width: 300, height: 28)
        let open = try #require(PRStatusPresentation.make(
            for: PRStatus(number: 7, url: "https://example.invalid/acme/pull/7", state: .mergeable)))
        guard case .asset(let iconName) = open.glyph else {
            Issue.record("A mergeable PR should draw a bundled icon")
            return
        }
        cell.configure(Self.worktree(
            name: "alpha", leading: .prStatus(open), bold: true, subtitles: ["Creating worktree…"],
            suffix: .attention, devServer: true, crossRepo: "(widge…)"))
        cell.layout()

        #expect(cell.textField === cell.nameField)
        #expect(cell.nameField.stringValue == "alpha")
        #expect(cell.nameField.font == SidebarCellKit.boldNameFont)
        #expect(!cell.leadingImageView.isHidden)
        #expect(cell.leadingImageView.image === WorktreeRowPresentation.loadIcon(iconName))
        #expect(cell.subtitleFields.filter { !$0.isHidden }.map(\.stringValue) == ["Creating worktree…"])
        #expect(cell.suffix.indicator == .attention)
        #expect(!cell.suffix.imageView.isHidden)
        #expect(cell.suffix.typingDots?.isHidden ?? true, "Only a working row draws the typing dots")
        #expect(!cell.devServerDot.isHidden)
        #expect(!cell.crossRepoField.isHidden)
        #expect(cell.crossRepoField.stringValue == "(widge…)")
        // The trailing marks pack against the name, in the SwiftUI order.
        #expect(cell.suffix.imageView.frame.minX > cell.nameField.frame.maxX)
        #expect(cell.devServerDot.frame.minX > cell.suffix.imageView.frame.maxX)
        #expect(cell.crossRepoField.frame.minX > cell.devServerDot.frame.maxX)

        // Each input switched off again, on the same cell.
        cell.configure(Self.worktree(name: "beta", suffix: .working))
        #expect(cell.nameField.stringValue == "beta")
        #expect(cell.nameField.font == SidebarCellKit.nameFont)
        #expect(cell.leadingImageView.isHidden)
        let subtitlesHidden = cell.subtitleFields.allSatisfy { $0.isHidden }
        #expect(subtitlesHidden)
        #expect(cell.suffix.imageView.isHidden)
        #expect(cell.suffix.typingDots?.isHidden == false, "A working row draws the typing dots")
        #expect(cell.devServerDot.isHidden)
        #expect(cell.crossRepoField.isHidden)

        // The other leading glyphs.
        cell.configure(Self.worktree(name: "gamma", leading: .pending))
        #expect(cell.leadingImageView.image === SidebarCellKit.symbol("circle.dotted", size: 10, weight: .semibold))
        cell.configure(Self.worktree(name: "gamma", leading: .prUnknown))
        #expect(cell.leadingImageView.image
                === SidebarCellKit.symbol("questionmark.circle", size: 10, weight: .semibold))
        cell.configure(Self.worktree(name: "gamma", leading: .remote))
        #expect(cell.leadingImageView.image === SidebarCellKit.symbol("globe", size: 10))
        let queued = PRStatusPresentation(glyph: .emoji(PRStatusPresentation.mergeQueueEmoji),
                                          colorSemantic: .pending, badge: 2)
        cell.configure(Self.worktree(name: "gamma", leading: .prStatus(queued)))
        #expect(cell.leadingImageView.image
                === PRStatusPresentation.busImage(position: 2, side: PRStatusPresentation.busSide))
        #expect(cell.leadingImageView.contentTintColor == nil, "The bus is full colour, never tinted")
    }

    /// The dev-server dot resolves its green against the appearance it draws
    /// in, rather than keeping the colour it was first given.
    @Test func devServerDotFollowsAppearance() throws {
        let dot = StatusDotView(color: .systemGreen, diameter: 6)
        dot.appearance = NSAppearance(named: .aqua)
        dot.updateLayer()
        let light = try #require(dot.layer?.backgroundColor?.components)
        dot.appearance = NSAppearance(named: .darkAqua)
        dot.updateLayer()
        let dark = try #require(dot.layer?.backgroundColor?.components)
        #expect(light != dark, "The dot kept its light-mode colour in dark mode")
        #expect(WorktreeRowCell().devServerDot.color == .systemGreen)
    }

    @Test func reusedCellResetsAlpha() {
        let cell = WorktreeRowCell()
        cell.configure(Self.worktree(name: "pad", dimmed: true))
        #expect(abs(cell.alphaValue - 0.5) < 0.001)
        cell.prepareForReuse()
        cell.configure(Self.worktree(name: "pad"))
        #expect(abs(cell.alphaValue - 1) < 0.001)
        // `configure` sets the alpha itself rather than trusting the reset.
        cell.prepareForReuse()
        cell.configure(Self.worktree(name: "pad", dimmed: true))
        #expect(abs(cell.alphaValue - 0.5) < 0.001)
        cell.configure(Self.worktree(name: "pad", hiddenSection: true))
        #expect(abs(cell.alphaValue - 0.55) < 0.001)

        let session = RemoteSessionRowCell()
        session.configure(Self.session(title: "lane", gone: true))
        #expect(abs(session.alphaValue - 0.5) < 0.001)
        session.prepareForReuse()
        session.configure(Self.session(title: "lane"))
        #expect(abs(session.alphaValue - 1) < 0.001)

        let group = GroupHeaderCell()
        group.configure(Self.group(hiddenSection: true))
        #expect(abs(group.alphaValue - 0.55) < 0.001)
        group.prepareForReuse()
        group.configure(Self.group())
        #expect(abs(group.alphaValue - 1) < 0.001)
    }

    @Test func cellsSetReuseIdentifiers() throws {
        let cells: [(NSView, NSUserInterfaceItemIdentifier)] = [
            (WorktreeRowCell(), WorktreeRowCell.reuseIdentifier),
            (RemoteSessionRowCell(), RemoteSessionRowCell.reuseIdentifier),
            (SectionHeaderCell(), SectionHeaderCell.reuseIdentifier),
            (GroupHeaderCell(), GroupHeaderCell.reuseIdentifier),
            (ProviderHeaderCell(), ProviderHeaderCell.reuseIdentifier),
            (ScratchPromptCell(), ScratchPromptCell.reuseIdentifier),
            (AddRepositoryCell(), AddRepositoryCell.reuseIdentifier),
            (SidebarRowView(frame: .zero), SidebarRowView.reuseIdentifier),
        ]
        for (view, identifier) in cells {
            #expect(view.identifier == identifier, "\(type(of: view)) must set its own identifier")
        }
        #expect(Set(cells.map { $0.1.rawValue }).count == cells.count, "Two kinds share an identifier")

        // The outline hands out each kind's own cell and the custom row view.
        let h = OutlineHarness("cells")
        defer { h.tearDown() }
        let repo = Repo(path: "/tmp/acme", displayName: "acme")
        h.state.repos = [repo]
        h.state.worktrees = [repo.id: [SidebarGroupFixtures.row("work", repoID: repo.id)]]
        h.state.remoteProviders = [SidebarGroupFixtures.provider()]
        h.state.remoteSessions = [SidebarGroupFixtures.session("lane")]
        h.mount()
        for row in 0..<h.outline.numberOfRows {
            let item = try #require(h.outline.item(atRow: row) as? SidebarItem)
            let cell = h.outline.view(atColumn: 0, row: row, makeIfNecessary: true)
            let expected: NSUserInterfaceItemIdentifier = switch item.id {
            case .worktree: WorktreeRowCell.reuseIdentifier
            case .remoteSession: RemoteSessionRowCell.reuseIdentifier
            case .scratchHeader, .repoHeader: SectionHeaderCell.reuseIdentifier
            case .providerHeader: ProviderHeaderCell.reuseIdentifier
            case .group: GroupHeaderCell.reuseIdentifier
            case .scratchPrompt: ScratchPromptCell.reuseIdentifier
            case .addRepository: AddRepositoryCell.reuseIdentifier
            }
            #expect(cell?.identifier == expected, "Row \(row) (\(item.id)) has the wrong cell")
            #expect(h.outline.rowView(atRow: row, makeIfNecessary: true) is SidebarRowView)
        }
    }

    /// Each state paints its own alpha, once, across the whole row: past the
    /// content, and at the leading and trailing edges, which the highlight
    /// reaches whatever the row's content origin.
    @Test func rowViewDrawsHighlightForEachState() throws {
        let light = SidebarRowHighlight.light
        let cases: [(label: String, rep: NSBitmapImageRep, alpha: CGFloat)] = try [
            ("plain", Self.capture(selected: false), 0),
            ("hovered", Self.capture(selected: false, hovered: true), light.hovered),
            ("selected", Self.capture(selected: true), light.selected),
            ("selected and hovered", Self.capture(selected: true, hovered: true), light.selectedHovered),
            // A header its model selects draws as a selected row does.
            ("selected by its model", Self.capture(selected: false, selectedByModel: true), light.selected),
            // Selected both ways, it still fills once: twice would read 0.36.
            ("selected both ways", Self.capture(selected: true, selectedByModel: true), light.selected),
        ]
        for (label, rep, alpha) in cases {
            // Past the content, clear of any guide line; at the leading edge,
            // left of the content origin; at the trailing edge.
            for x in [rep.pixelsWide * 2 / 3, 1, rep.pixelsWide - 2] {
                let painted = try #require(rep.colorAt(x: x, y: rep.pixelsHigh / 2)).alphaComponent
                #expect(abs(painted - alpha) < 0.02, "A \(label) row paints \(painted) at x \(x), not \(alpha)")
            }
        }

        // The dark appearance has its own hover alpha.
        let darkHovered = try Self.capture(selected: false, hovered: true, appearance: .darkAqua)
        let darkPainted = try #require(darkHovered.colorAt(x: 1, y: darkHovered.pixelsHigh / 2)).alphaComponent
        #expect(abs(darkPainted - SidebarRowHighlight.dark.hovered) < 0.02, "A dark hovered row paints \(darkPainted)")
    }

    @Test func accessibilityLabelIncludesStatus() throws {
        let cell = WorktreeRowCell()
        cell.configure(Self.worktree(name: "alpha", suffix: .attention, devServer: true))
        let label = try #require(cell.accessibilityLabel())
        #expect(label.hasPrefix("alpha"))
        #expect(label.contains("Needs your attention"))
        #expect(label.contains("Dev server running"))
        cell.configure(Self.worktree(name: "alpha"))
        #expect(cell.accessibilityLabel() == "alpha", "A quiet row says only its name")

        let session = RemoteSessionRowCell()
        session.configure(Self.session(title: "lane", suffix: .working))
        #expect(session.accessibilityLabel()?.hasPrefix("lane") == true)
        #expect(session.accessibilityLabel()?.contains("Agent is working") == true)
    }

    @Test func heightMatchesClass() throws {
        #expect(WorktreeRowCell.height(for: Self.worktree(name: "a")) == SidebarNativeMetrics.rowHeight)
        let subtitled = Self.worktree(name: "a", subtitles: ["Creating worktree…"])
        #expect(subtitled.heightClass == .withSubtitle)
        #expect(WorktreeRowCell.height(for: subtitled) == WorktreeRowCell.subtitleRowHeight)
        // Every worktree row is one height, so the dock's arithmetic, which
        // counts rows of `SidebarNativeMetrics.rowHeight`, holds for both.
        #expect(WorktreeRowCell.subtitleRowHeight == SidebarNativeMetrics.rowHeight)

        #expect(RemoteSessionRowCell.height(for: Self.session(title: "lane")) == SidebarNativeMetrics.rowHeight)
        #expect(RemoteSessionRowCell.height(for: Self.session(title: "lane", caption: "running"))
                == SidebarNativeMetrics.rowHeight)
        #expect(GroupHeaderCell.height(for: Self.group()) == GroupHeaderCell.singleHeight)
        #expect(GroupHeaderCell.height(for: Self.group(summary: "1 running")) == GroupHeaderCell.summaryHeight)
        #expect(GroupHeaderCell.singleHeight < GroupHeaderCell.summaryHeight)
        #expect(ProviderHeaderCell.height(for: Self.provider(issue: nil)) == ProviderHeaderCell.singleHeight)
        #expect(ProviderHeaderCell.height(for: Self.provider(issue: "Provider error")) == ProviderHeaderCell.subtitleHeight)
        #expect(ProviderHeaderCell.singleHeight < ProviderHeaderCell.subtitleHeight)

        // The controller asks the cells.
        let h = OutlineHarness("heights")
        defer { h.tearDown() }
        #expect(h.controller.rowHeight(for: .worktree(subtitled)) == WorktreeRowCell.height(for: subtitled))
        #expect(h.controller.rowHeight(for: .groupHeader(Self.group(summary: "1 running")))
                == GroupHeaderCell.summaryHeight)
        #expect(h.controller.rowHeight(for: .scratchPrompt) == ScratchPromptCell.rowHeight)
        // The Add Repository row is the sidebar's minimum row height, a
        // section header's.
        #expect(h.controller.rowHeight(for: .addRepository) == AddRepositoryCell.rowHeight)
        #expect(AddRepositoryCell.rowHeight == SectionHeaderCell.rowHeight)
    }

    // MARK: Fixtures

    static func worktree(
        name: String, leading: WorktreeLeadingSlot? = nil, bold: Bool = false, subtitles: [String] = [],
        suffix: SuffixRowIndicator? = nil, devServer: Bool = false,
        crossRepo: String? = nil, dimmed: Bool = false, hiddenSection: Bool = false
    ) -> WorktreeRowModel {
        WorktreeRowModel(
            name: name, leading: leading, isNameBold: bold, subtitles: subtitles, suffix: suffix,
            showsDevServerDot: devServer, crossRepoLabel: crossRepo, homeRepoID: nil,
            isPinned: false, depth: 0, isDimmed: dimmed, isInHiddenSection: hiddenSection, isMain: false,
            heightClass: subtitles.isEmpty ? .single : .withSubtitle)
    }

    static func session(title: String, caption: String? = nil, suffix: SuffixRowIndicator? = nil,
                        gone: Bool = false) -> RemoteSessionRowModel {
        RemoteSessionRowModel(
            title: title, isPending: false, isNameBold: false, isExited: false, caption: caption,
            suffix: suffix, isGone: gone, isSelected: false, depth: 0, isInHiddenSection: false)
    }

    static func group(summary: String? = nil, hiddenSection: Bool = false) -> GroupHeaderModel {
        GroupHeaderModel(
            kind: .remote, count: nil, summary: summary, attention: nil, hasUncertainty: false,
            isExpanded: true, depth: 0, isInHiddenSection: hiddenSection)
    }

    static func provider(issue: String?) -> ProviderHeaderModel {
        ProviderHeaderModel(
            name: "acme", health: issue == nil ? .ok : .error, issueSummary: issue, isSelected: false,
            canCreate: false, isCreateEnabled: true)
    }

    /// One row view, drawn into a bitmap off any window. `selected` is the
    /// list's selection; `selectedByModel` is a header's.
    static func capture(selected: Bool, hovered: Bool = false, selectedByModel: Bool = false,
                        appearance: NSAppearance.Name = .aqua) throws -> NSBitmapImageRep {
        let rowView = SidebarRowView(frame: NSRect(x: 0, y: 0, width: 300, height: 28))
        rowView.appearance = NSAppearance(named: appearance)
        rowView.backgroundColor = .clear
        rowView.configuration = SidebarRowView.Configuration(
            contentOrigin: 20, isSelectedByModel: selectedByModel, isHovered: hovered)
        rowView.isSelected = selected
        let rep = try #require(rowView.bitmapImageRepForCachingDisplay(in: rowView.bounds))
        rowView.cacheDisplay(in: rowView.bounds, to: rep)
        return rep
    }
}

/// Every item in a sidebar header or row centres on the row's midline, and a
/// header's frames start on whole points, so a hover square never sits low in
/// the highlight band or straddles device pixels. Cells are laid out directly,
/// off any window, as `SidebarCellTests` does.
@MainActor
@Suite("Sidebar cell vertical centring")
struct SidebarCellCentringTests {
    static let styles: [SectionHeaderCell.Style] = [.repo, .scratch]

    /// A configured header, revealed so its `+` and trailing chevron show,
    /// laid out in a row `height` tall.
    static func layOutHeader(
        style: SectionHeaderCell.Style, chevronBeforeTitle: Bool, missing: Bool = false,
        height: CGFloat = SectionHeaderCell.rowHeight
    ) -> SectionHeaderCell {
        let cell = SectionHeaderCell()
        cell.style = style
        cell.chevronBeforeTitle = chevronBeforeTitle
        cell.frame = NSRect(x: 0, y: 0, width: 260, height: height)
        cell.configure(SectionHeaderModel(
            title: style == .scratch ? "Scratch" : "tbd", isExpanded: true, isHidden: false,
            isMissing: missing, isSelected: false))
        cell.setHovered(true)
        cell.layout()
        return cell
    }

    /// The frames a revealed header lays out, by name.
    static func headerFrames(_ cell: SectionHeaderCell) -> [(name: String, frame: NSRect)] {
        var frames: [(name: String, frame: NSRect)] = [
            ("chevron", cell.chevronButton.frame),
            ("+", cell.plusButton.frame),
            ("title", cell.titleField.frame),
        ]
        if !cell.missingField.isHidden {
            frames.append(("missing badge", cell.missingField.frame))
            frames.append(("Locate…", cell.locateButton.frame))
        }
        return frames
    }

    @Test func headerSquaresCentreOnTheRowMidline() throws {
        for style in Self.styles {
            for chevronBeforeTitle in [false, true] {
                let cell = Self.layOutHeader(style: style, chevronBeforeTitle: chevronBeforeTitle)
                let label = "\(style), chevron before title \(chevronBeforeTitle)"
                try #require(!cell.plusButton.isHidden, "\(label): the + is hidden, so this checks nothing")
                try #require(!cell.chevronButton.isHidden, "\(label): the chevron is hidden, so this checks nothing")
                let midY = cell.bounds.midY
                let plusMidY = cell.plusButton.frame.midY
                let chevronMidY = cell.chevronButton.frame.midY
                let titleOffset = abs(cell.titleField.frame.midY - midY)
                #expect(plusMidY == midY, "\(label): the + centres at \(plusMidY), not the row's \(midY)")
                #expect(chevronMidY == midY, "\(label): the chevron centres at \(chevronMidY), not the row's \(midY)")
                #expect(titleOffset <= 0.5, "\(label): the title centres \(titleOffset) pt off the row's midline")
                for (name, frame) in Self.headerFrames(cell) {
                    let minY = frame.minY
                    let isWhole = minY == minY.rounded()
                    #expect(isWhole, "\(label): the \(name) starts at y \(minY), between whole points")
                }
            }
        }
    }

    /// A missing repo's badge and Locate… centre on the same midline.
    @Test func missingBadgeCentresOnTheRowMidline() throws {
        for chevronBeforeTitle in [false, true] {
            let cell = Self.layOutHeader(style: .repo, chevronBeforeTitle: chevronBeforeTitle, missing: true)
            try #require(!cell.missingField.isHidden, "The missing badge is hidden, so this checks nothing")
            let midY = cell.bounds.midY
            let badgeOffset = abs(cell.missingField.frame.midY - midY)
            let locateOffset = abs(cell.locateButton.frame.midY - midY)
            #expect(badgeOffset <= 0.5, "The missing badge centres \(badgeOffset) pt off the row's midline")
            #expect(locateOffset <= 0.5, "Locate… centres \(locateOffset) pt off the row's midline")
            for (name, frame) in Self.headerFrames(cell) {
                let minY = frame.minY
                let isWhole = minY == minY.rounded()
                #expect(isWhole, "Chevron before title \(chevronBeforeTitle): the \(name) starts at y \(minY)")
            }
        }
    }

    /// In a row of odd height the midline falls between whole points: every
    /// frame still starts on one, at most half a point off centre.
    @Test func headerFramesStayOnWholePointsInAnOddHeightRow() {
        for style in Self.styles {
            for chevronBeforeTitle in [false, true] {
                let cell = Self.layOutHeader(style: style, chevronBeforeTitle: chevronBeforeTitle, height: 27)
                let label = "\(style), chevron before title \(chevronBeforeTitle)"
                let midY = cell.bounds.midY
                for (name, frame) in Self.headerFrames(cell) {
                    let minY = frame.minY
                    let isWhole = minY == minY.rounded()
                    let offset = abs(frame.midY - midY)
                    #expect(isWhole, "\(label): the \(name) starts at y \(minY), between whole points")
                    #expect(offset <= 0.5, "\(label): the \(name) centres \(offset) pt off the row's midline")
                }
            }
        }
    }

    /// A provider header's name alone, its health glyph and its `+` centre on
    /// the row's midline.
    @Test func providerHeaderGlyphsCentreOnTheRowMidline() throws {
        let cell = ProviderHeaderCell()
        cell.frame = NSRect(x: 0, y: 0, width: 260, height: ProviderHeaderCell.singleHeight)
        cell.configure(ProviderHeaderModel(
            name: "acme", health: .error, issueSummary: nil, isSelected: false,
            canCreate: true, isCreateEnabled: true))
        cell.layout()
        try #require(!cell.plusButton.isHidden, "The + is hidden, so this checks nothing")
        let midY = cell.bounds.midY
        let plusMidY = cell.plusButton.frame.midY
        let healthMidY = cell.healthImageView.frame.midY
        let nameOffset = abs(cell.nameField.frame.midY - midY)
        #expect(plusMidY == midY, "The provider + centres at \(plusMidY), not the row's \(midY)")
        #expect(healthMidY == midY, "The health glyph centres at \(healthMidY), not the row's \(midY)")
        #expect(nameOffset <= 0.5, "The provider name centres \(nameOffset) pt off the row's midline")
    }

    /// The Add Repository row's `+` starts at the section headers' leading
    /// inset, its label follows it whole, the chevron follows the label, and
    /// every item centres on the row's midline at whole-point origins, in an
    /// even row and an odd one.
    @Test func addRepositoryRowCentresAtTheHeaderInset() throws {
        for height in [AddRepositoryCell.rowHeight, 27] {
            let cell = AddRepositoryCell()
            cell.frame = NSRect(x: 0, y: 0, width: 260, height: height)
            cell.configure()
            cell.layout()
            let plus = cell.convert(cell.plusView.bounds, from: cell.plusView)
            let title = cell.convert(cell.titleField.bounds, from: cell.titleField)
            let frames: [(name: String, frame: NSRect)] = [
                ("add button", cell.addButton.frame), ("chevron", cell.menuButton.frame),
                ("+", plus), ("label", title),
            ]
            let midY = cell.bounds.midY
            for (name, frame) in frames {
                let minY = frame.minY
                let isWhole = minY == minY.rounded()
                let offset = abs(frame.midY - midY)
                #expect(isWhole, "Row \(height): the \(name) starts at y \(minY), between whole points")
                #expect(offset <= 0.5, "Row \(height): the \(name) centres \(offset) pt off the row's midline")
                #expect(frame.width > 0, "Row \(height): the \(name) has no width")
            }
            let plusX = plus.minX
            let inset = SidebarNativeMetrics.headerContentInset
            #expect(plusX == inset, "Row \(height): the + starts at \(plusX), not the header inset \(inset)")
            let isWholeX = plusX == plusX.rounded()
            #expect(isWholeX)
            #expect(title.minX > plus.maxX)
            #expect(!SidebarCellKit.truncates(cell.titleField), "The label is cut at \(title.width) pt")
            #expect(cell.menuButton.frame.minX >= cell.addButton.frame.maxX)
            // The add button's wash covers the + and the label.
            let washCoversBoth = cell.addButton.frame.contains(plus) && cell.addButton.frame.contains(title)
            #expect(washCoversBoth)
        }
    }

    /// A working row's typing dots centre on the midline, where the status
    /// glyph they stand in for does.
    @Test func typingDotsCentreOnTheRowMidline() throws {
        let row = WorktreeRowCell()
        row.frame = NSRect(x: 0, y: 0, width: 300, height: SidebarNativeMetrics.rowHeight)
        row.configure(SidebarCellTests.worktree(name: "alpha", suffix: .working))
        row.layout()
        let rowDots = try #require(row.suffix.typingDots, "A working row made no typing dots")
        let rowMidY = row.bounds.midY
        let rowDotsMidY = rowDots.frame.midY
        #expect(rowDotsMidY == rowMidY, "A worktree row's dots centre at \(rowDotsMidY), not \(rowMidY)")

        row.configure(SidebarCellTests.worktree(name: "alpha", suffix: .attention))
        row.layout()
        let glyphMidY = row.suffix.imageView.frame.midY
        #expect(glyphMidY == rowMidY, "A worktree row's status glyph centres at \(glyphMidY), not \(rowMidY)")

        let session = RemoteSessionRowCell()
        session.frame = NSRect(x: 0, y: 0, width: 300, height: SidebarNativeMetrics.rowHeight)
        session.configure(SidebarCellTests.session(title: "lane", suffix: .working))
        session.layout()
        let sessionDots = try #require(session.suffix.typingDots, "A working session made no typing dots")
        let sessionMidY = session.bounds.midY
        let sessionDotsMidY = sessionDots.frame.midY
        #expect(sessionDotsMidY == sessionMidY,
                "A remote session row's dots centre at \(sessionDotsMidY), not \(sessionMidY)")
    }
}
