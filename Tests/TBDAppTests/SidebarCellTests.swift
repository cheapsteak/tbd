import AppKit
import Foundation
import SwiftUI
import Testing
@testable import TBDApp
import TBDShared
import TestSupport

// Cells are configured and drawn directly, off any window; the bitmap probe
// draws one row view into a bitmap. One test mounts the outline offscreen to
// check the cells it hands out, and one hosts the SwiftUI row to measure it.

/// The native sidebar's cells and row view: every model input reaches the
/// cell, reuse cannot leak opacity, each cell reuses by identifier, the row
/// view draws the selection tint, and heights map from height classes.
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
            suffix: .attention, noStatus: true, devServer: true, crossRepo: "(widge…)"))
        cell.layout()

        #expect(cell.textField === cell.nameField)
        #expect(cell.nameField.stringValue == "alpha")
        #expect(cell.nameField.font == SidebarCellKit.boldNameFont)
        #expect(!cell.leadingImageView.isHidden)
        #expect(cell.leadingImageView.image === WorktreeRowView.loadIcon(iconName))
        #expect(cell.subtitleFields.filter { !$0.isHidden }.map(\.stringValue) == ["Creating worktree…"])
        #expect(cell.suffix.indicator == .attention)
        #expect(!cell.suffix.imageView.isHidden)
        #expect(cell.suffix.typingDots?.isHidden ?? true, "Only a working row draws the typing dots")
        #expect(!cell.noStatusImageView.isHidden)
        #expect(!cell.devServerDot.isHidden)
        #expect(!cell.crossRepoField.isHidden)
        #expect(cell.crossRepoField.stringValue == "(widge…)")
        // The trailing marks pack against the name, in the SwiftUI order.
        #expect(cell.suffix.imageView.frame.minX > cell.nameField.frame.maxX)
        #expect(cell.noStatusImageView.frame.minX > cell.suffix.imageView.frame.maxX)
        #expect(cell.devServerDot.frame.minX > cell.noStatusImageView.frame.maxX)
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
        #expect(cell.noStatusImageView.isHidden)
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
            }
            #expect(cell?.identifier == expected, "Row \(row) (\(item.id)) has the wrong cell")
            #expect(h.outline.rowView(atRow: row, makeIfNecessary: true) is SidebarRowView)
        }
    }

    @Test func rowViewDrawsTintWhenSelected() throws {
        let plain = try Self.capture(selected: false)
        let selected = try Self.capture(selected: true)
        // Inside the tint, clear of any guide line.
        let unselectedInside = try #require(plain.colorAt(x: 200, y: 14))
        let selectedInside = try #require(selected.colorAt(x: 200, y: 14))
        #expect(unselectedInside.alphaComponent < 0.05, "An unselected row paints nothing there")
        #expect(selectedInside.alphaComponent > 0.1, "A selected row paints the tint")
        // The tint starts at the row's content origin, as the SwiftUI row's
        // background does, not at the row view's edge.
        let selectedOutside = try #require(selected.colorAt(x: 4, y: 14))
        #expect(selectedOutside.alphaComponent < 0.05)
    }

    @Test func accessibilityLabelIncludesStatus() throws {
        let cell = WorktreeRowCell()
        cell.configure(Self.worktree(name: "alpha", suffix: .attention, noStatus: true, devServer: true))
        let label = try #require(cell.accessibilityLabel())
        #expect(label.hasPrefix("alpha"))
        #expect(label.contains("Needs your attention"))
        #expect(label.contains(NoStatusMark.accessibilityLabel))
        #expect(label.contains("Dev server running"))
        cell.configure(Self.worktree(name: "alpha"))
        #expect(cell.accessibilityLabel() == "alpha", "A quiet row says only its name")

        let session = RemoteSessionRowCell()
        session.configure(Self.session(title: "lane", suffix: .working))
        #expect(session.accessibilityLabel()?.hasPrefix("lane") == true)
        #expect(session.accessibilityLabel()?.contains("Agent is working") == true)
    }

    @Test func heightMatchesClass() throws {
        #expect(WorktreeRowCell.height(for: Self.worktree(name: "a")) == WorktreeRowView.rowHeight)
        let subtitled = Self.worktree(name: "a", subtitles: ["Creating worktree…"])
        #expect(subtitled.heightClass == .withSubtitle)
        let measured = try Self.measuredSwiftUIRowHeight()
        #expect(abs(WorktreeRowCell.height(for: subtitled) - measured) < 0.5,
                "The SwiftUI row with a subtitle measured \(measured) pt")

        #expect(RemoteSessionRowCell.height(for: Self.session(title: "lane")) == WorktreeRowView.rowHeight)
        #expect(RemoteSessionRowCell.height(for: Self.session(title: "lane", caption: "running"))
                == WorktreeRowView.rowHeight)
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
    }

    // MARK: Fixtures

    static func worktree(
        name: String, leading: WorktreeLeadingSlot? = nil, bold: Bool = false, subtitles: [String] = [],
        suffix: SuffixRowIndicator? = nil, noStatus: Bool = false, devServer: Bool = false,
        crossRepo: String? = nil, dimmed: Bool = false, hiddenSection: Bool = false
    ) -> WorktreeRowModel {
        WorktreeRowModel(
            name: name, leading: leading, isNameBold: bold, subtitles: subtitles, suffix: suffix,
            showsNoStatusMark: noStatus, showsDevServerDot: devServer, crossRepoLabel: crossRepo,
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

    /// One row view, drawn into a bitmap off any window.
    static func capture(selected: Bool) throws -> NSBitmapImageRep {
        let rowView = SidebarRowView(frame: NSRect(x: 0, y: 0, width: 300, height: 28))
        rowView.appearance = NSAppearance(named: .aqua)
        rowView.backgroundColor = .clear
        rowView.configuration = SidebarRowView.Configuration(contentOrigin: 20)
        rowView.isSelected = selected
        let rep = try #require(rowView.bitmapImageRepForCachingDisplay(in: rowView.bounds))
        rowView.cacheDisplay(in: rowView.bounds, to: rep)
        return rep
    }

    /// The SwiftUI row with a "Creating worktree…" subtitle, laid out by
    /// SwiftUI at sidebar width.
    static func measuredSwiftUIRowHeight() throws -> CGFloat {
        let suite = TestDefaultsSuite("SidebarCellTests.measure")
        defer { suite.tearDown() }
        let state = AppState(userDefaults: suite.defaults)
        let repo = Repo(path: "/tmp/acme", displayName: "acme")
        let creating = SidebarGroupFixtures.row("creating", repoID: repo.id, status: .creating)
        state.repos = [repo]
        state.worktrees = [repo.id: [creating]]
        let hosting = NSHostingController(rootView: WorktreeRowView(worktree: creating).environment(state))
        return hosting.sizeThatFits(in: CGSize(width: 320, height: 1000)).height
    }
}
