import AppKit
import Foundation
import Testing
@testable import TBDApp

// Tier 1. Cells are configured and laid out directly, off any window, as
// `SidebarCellTests` does, whose fixtures these borrow.

/// A name the native sidebar has room for draws whole, and one it has no room
/// for is cut and says so through `isNameTruncated`, which shows the full name
/// on hover. Whether a label draws whole is AppKit's answer, not the layout's:
/// a cell reports a non-empty expansion frame exactly when its frame cuts the
/// text, so these checks do not trust the width the layout measured.
@MainActor
@Suite("Sidebar cell name truncation")
struct SidebarCellTruncationTests {
    /// Names the native sidebar cut with room to spare, one behind a leading
    /// emoji.
    static let names = ["main", "Panel 3b App Rendering", "Toolbar Glass Regression", "Archive Selection",
                        "🟧🟨🟩acme"]

    @Test func worktreeNameThatFitsDrawsWhole() {
        for name in Self.names {
            for bold in [false, true] {
                let cell = WorktreeRowCell()
                cell.frame = NSRect(x: 0, y: 0, width: 400, height: SidebarNativeMetrics.rowHeight)
                cell.configure(SidebarCellTests.worktree(name: name, bold: bold, suffix: .attention))
                cell.layout()
                let cut = Self.cutsText(cell.nameField)
                #expect(!cut, "\(Self.describe(cell.nameField)), bold \(bold), is cut in a 400 pt row")
                #expect(!cell.isNameTruncated, "\(name), bold \(bold), reports itself truncated in a 400 pt row")
                #expect(cell.suffix.imageView.frame.minX >= cell.nameField.frame.maxX)
            }
        }
    }

    @Test func worktreeNameWithoutRoomIsCut() {
        for bold in [false, true] {
            let cell = WorktreeRowCell()
            cell.leadingInset = 0
            cell.frame = NSRect(x: 0, y: 0, width: 90, height: SidebarNativeMetrics.rowHeight)
            cell.configure(SidebarCellTests.worktree(name: "Toolbar Glass Regression", bold: bold, suffix: .attention))
            cell.layout()
            let cut = Self.cutsText(cell.nameField)
            #expect(cut, "\(Self.describe(cell.nameField)), bold \(bold), draws whole in a 90 pt row")
            #expect(cell.isNameTruncated, "A cut name, bold \(bold), does not report itself truncated")
            // The name gives way: the suffix still fits inside the row.
            #expect(cell.suffix.imageView.frame.maxX <= cell.bounds.width)
        }
    }

    /// At the edge of the room a name needs, the flag agrees with the drawing
    /// to a fraction of a point: whole at exactly the cell's width, cut a
    /// quarter point below it.
    @Test func truncationFlagIsExactAtTheBoundary() throws {
        for name in Self.names {
            let cell = WorktreeRowCell()
            cell.leadingInset = 0
            cell.configure(SidebarCellTests.worktree(name: name))
            let nameCell = try #require(cell.nameField.cell)
            let need = nameCell.cellSize.width
            for (width, fits) in [(need, true), (need - 0.25, false)] {
                cell.frame = NSRect(x: 0, y: 0, width: width, height: SidebarNativeMetrics.rowHeight)
                cell.layout()
                let cut = Self.cutsText(cell.nameField)
                #expect(cut == !fits, "\(Self.describe(cell.nameField)) in a \(width) pt row: cut \(cut)")
                #expect(cell.isNameTruncated == cut,
                        "\(name) in a \(width) pt row: cut \(cut), flagged \(cell.isNameTruncated)")
            }
        }
    }

    /// A cell that drew a short name measures the next one afresh, whether
    /// it is reconfigured in place or handed out again after reuse.
    @Test func reconfiguredCellDrawsItsLongerNameWhole() {
        let cell = WorktreeRowCell()
        cell.frame = NSRect(x: 0, y: 0, width: 400, height: SidebarNativeMetrics.rowHeight)
        cell.configure(SidebarCellTests.worktree(name: "ab"))
        cell.layout()
        let shortWidth = cell.nameField.frame.width

        cell.configure(SidebarCellTests.worktree(name: "Panel 3b App Rendering"))
        cell.layout()
        let cutInPlace = Self.cutsText(cell.nameField)
        #expect(cell.nameField.frame.width > shortWidth)
        #expect(!cutInPlace, "\(Self.describe(cell.nameField)) is cut after reconfiguring in place")
        #expect(!cell.isNameTruncated)

        cell.configure(SidebarCellTests.worktree(name: "ab"))
        cell.layout()
        cell.prepareForReuse()
        cell.configure(SidebarCellTests.worktree(name: "Toolbar Glass Regression", bold: true))
        cell.layout()
        let cutAfterReuse = Self.cutsText(cell.nameField)
        #expect(!cutAfterReuse, "\(Self.describe(cell.nameField)) is cut after reuse")
        #expect(!cell.isNameTruncated)
    }

    @Test func sectionTitleThatFitsDrawsWhole() {
        for style in [SectionHeaderCell.Style.repo, .scratch] {
            for chevronBeforeTitle in [false, true] {
                for title in ["🟧🟨🟩acme", "acme", "Scratch"] {
                    let cell = SectionHeaderCell()
                    cell.style = style
                    cell.chevronBeforeTitle = chevronBeforeTitle
                    cell.frame = NSRect(x: 0, y: 0, width: 300, height: SectionHeaderCell.rowHeight)
                    cell.configure(Self.header(title))
                    cell.layout()
                    let cut = Self.cutsText(cell.titleField)
                    #expect(!cut, "\(Self.describe(cell.titleField)), \(style), chevron before \(chevronBeforeTitle), is cut in a 300 pt header")
                }
            }
        }
    }

    @Test func sectionTitleWithoutRoomIsCut() throws {
        let cell = SectionHeaderCell()
        cell.leadingInset = 0
        cell.frame = NSRect(x: 0, y: 0, width: 60, height: SectionHeaderCell.rowHeight)
        cell.configure(Self.header("🟧🟨🟩acme"))
        cell.layout()
        try #require(cell.titleField.frame.width > 0, "The title got no width, so this checks nothing")
        let cut = Self.cutsText(cell.titleField)
        #expect(cut, "\(Self.describe(cell.titleField)) draws whole in a 60 pt header")
    }

    @Test func remoteSessionNameIsCutOnlyWithoutRoom() {
        let wide = RemoteSessionRowCell()
        wide.frame = NSRect(x: 0, y: 0, width: 400, height: SidebarNativeMetrics.rowHeight)
        wide.configure(SidebarCellTests.session(title: "Panel 3b App Rendering", suffix: .attention))
        wide.layout()
        let wideCut = Self.cutsText(wide.nameField)
        #expect(!wideCut, "\(Self.describe(wide.nameField)) is cut in a 400 pt row")
        #expect(!wide.isNameTruncated)

        let narrow = RemoteSessionRowCell()
        narrow.leadingInset = 0
        narrow.frame = NSRect(x: 0, y: 0, width: 90, height: SidebarNativeMetrics.rowHeight)
        narrow.configure(SidebarCellTests.session(title: "Panel 3b App Rendering", suffix: .attention))
        narrow.layout()
        let narrowCut = Self.cutsText(narrow.nameField)
        #expect(narrowCut, "\(Self.describe(narrow.nameField)) draws whole in a 90 pt row")
        #expect(narrow.isNameTruncated)
    }

    /// Every other label the cells measure goes through the same helper: with
    /// room, each draws its whole text.
    @Test func everyOtherLabelDrawsWholeWithRoom() throws {
        let session = RemoteSessionRowCell()
        session.frame = NSRect(x: 0, y: 0, width: 400, height: SidebarNativeMetrics.rowHeight)
        session.configure(SidebarCellTests.session(title: "lane", caption: "running"))
        session.layout()

        let group = GroupHeaderCell()
        group.frame = NSRect(x: 0, y: 0, width: 400, height: GroupHeaderCell.summaryHeight)
        group.configure(SidebarCellTests.group(summary: "1 running"))
        group.layout()

        let provider = ProviderHeaderCell()
        provider.frame = NSRect(x: 0, y: 0, width: 400, height: ProviderHeaderCell.subtitleHeight)
        provider.configure(SidebarCellTests.provider(issue: "Provider error"))
        provider.layout()

        let prompt = ScratchPromptCell()
        prompt.frame = NSRect(x: 0, y: 0, width: 400, height: ScratchPromptCell.rowHeight)
        prompt.configure()
        prompt.layout()

        let row = WorktreeRowCell()
        row.frame = NSRect(x: 0, y: 0, width: 400, height: WorktreeRowCell.subtitleRowHeight)
        row.configure(SidebarCellTests.worktree(name: "main", subtitles: ["Creating worktree…"], crossRepo: "(acme)"))
        row.layout()
        let subtitle = try #require(row.subtitleFields.first)

        let labels: [(name: String, field: NSTextField)] = [
            ("remote session caption", session.captionField),
            ("group title", group.titleField),
            ("group summary", group.summaryField),
            ("provider name", provider.nameField),
            ("provider issue", provider.issueField),
            ("scratch prompt", prompt.titleField),
            ("worktree subtitle", subtitle),
            ("cross-repo label", row.crossRepoField),
        ]
        for label in labels {
            #expect(!label.field.isHidden, "The \(label.name) is hidden, so this checks nothing")
            #expect(!label.field.stringValue.isEmpty, "The \(label.name) is empty, so this checks nothing")
            let cut = Self.cutsText(label.field)
            #expect(!cut, "The \(label.name), \(Self.describe(label.field)), is cut in a 400 pt cell")
        }
    }

    // MARK: Helpers

    /// AppKit's own answer to whether `field` cuts its text at its frame: the
    /// cell offers an expansion frame exactly when it does.
    static func cutsText(_ field: NSTextField) -> Bool {
        let expansion = field.cell?.expansionFrame(withFrame: field.bounds, in: field) ?? .zero
        return expansion != .zero
    }

    /// The label, the width it has and the width its cell draws it in, for a
    /// failure message.
    static func describe(_ field: NSTextField) -> String {
        let need = field.cell?.cellSize.width ?? -1
        return "\"\(field.stringValue)\" (frame \(field.frame.width) pt, cell needs \(need) pt)"
    }

    static func header(_ title: String) -> SectionHeaderModel {
        SectionHeaderModel(title: title, isExpanded: true, isHidden: false, isMissing: false, isSelected: false)
    }
}
