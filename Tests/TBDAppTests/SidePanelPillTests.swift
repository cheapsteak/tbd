import AppKit
import CoreGraphics
import Foundation
import Testing
import TBDShared
@testable import TBDApp

// Tier 1: deterministic, in-process values only. No view is drawn; the label
// widths come from the system font's metrics, and the sidebar's grey from a
// sidebar row cell configured off any window.

/// The side region's toggle pills (side panel toggle pills spec, "Pills"):
/// the state each decision stands for, each pill's symbol and colour, the
/// label each kind always shows or never does, the square each pill's hover
/// covers, and the side region's minimum width that holds them.
@Suite("Side panel pills")
@MainActor
struct SidePanelPillTests {
    private static let transcriptLabel = TabRowEdgeItem.transcriptLabel
    private static let notesLabel = TabRowEdgeItem.notesLabel
    private static let allStates: [SidePanelPillState] = [.off, .behind, .front]

    /// Changes, the transcript and Notes in the given states.
    private static func items(
        changes: SidePanelPillState, transcript: SidePanelPillState, notes: SidePanelPillState
    ) -> [TabRowEdgeItem] {
        [
            .changes(.changes(state: changes)),
            .transcript(.transcript(state: transcript, isEnabled: true)),
            .notes(.notes(state: notes, isEnabled: true)),
        ]
    }

    /// The width a pill of `size` is framed in.
    private static func width(of size: RowIconSquare.Size) -> CGFloat {
        switch size {
        case .pill(let width): width
        case .square(let side): side
        case .outset: RowIconSquare.standardSide
        }
    }

    // MARK: - State

    @Test("a Changes or transcript decision stands for off, behind or in front")
    func panelDecisionStates() {
        let panelID = UUID()
        let decisions: [PanelToggleDecision] = [.open, .select(panelID), .close(panelID)]
        let states = decisions.map { SidePanelPillState.state(for: $0) }
        let expected: [SidePanelPillState] = [.off, .behind, .front]
        #expect(states == expected)
        let onStates = expected.map(\.isOn)
        #expect(onStates == [false, true, true])
    }

    @Test("the transcript pill draws an empty bubble on and off, and each pill keeps one symbol in every state")
    func pillSymbols() {
        // `SidePanelPillButton` draws its control's symbol.
        let states: [SidePanelPillState] = [.front, .behind, .off]
        let transcript = states.map {
            TabRowEdgeItem.transcript(.transcript(state: $0, isEnabled: true)).control.systemImage
        }
        let changes = states.map { TabRowEdgeItem.changes(.changes(state: $0)).control.systemImage }
        let notes = states.map {
            TabRowEdgeItem.notes(.notes(state: $0, isEnabled: true)).control.systemImage
        }
        let noteSymbol = PanelKind.noteSystemImage
        #expect(transcript == ["bubble", "bubble", "bubble"])
        #expect(changes == ["plusminus", "plusminus", "plusminus"])
        #expect(notes == [noteSymbol, noteSymbol, noteSymbol])
        // A disabled transcript pill draws the same bubble.
        let disabled = TabRowEdgeItem.transcript(.transcript(state: .off, isEnabled: false))
        let disabledSymbol = disabled.control.systemImage
        #expect(disabledSymbol == "bubble")
    }

    // MARK: - Colour

    @Test("a pill draws the left sidebar's grey, the same grey as its toggle at the tab bar's end")
    func pillsDrawTheSidebarsGrey() {
        let pill = SidePanelPillMetrics.foregroundColor
        #expect(pill == NSColor.secondaryLabelColor)

        // The sidebar's row icons draw it: the pending glyph's tint.
        let cell = WorktreeRowCell()
        cell.configure(SidebarCellTests.worktree(name: "acme", leading: .pending))
        let sidebarIcon = cell.leadingImageView.contentTintColor
        #expect(sidebarIcon == pill)

        // The toggles at the workspace tab bar's end name the same colour,
        // in every state, enabled or not.
        let controls: [PaneChromeControl] = [
            .changes(state: .front), .changes(state: .behind), .changes(state: .off),
            .transcript(state: .front, isEnabled: true), .transcript(state: .behind, isEnabled: true),
            .transcript(state: .off, isEnabled: true), .transcript(state: .off, isEnabled: false),
            .notes(state: .front, isEnabled: true), .notes(state: .behind, isEnabled: true),
            .notes(state: .off, isEnabled: true), .notes(state: .off, isEnabled: false),
        ]
        for control in controls {
            let tint = control.tint
            let color = PaneChromeControlButton.symbolColor(for: tint)
            #expect(tint == .sidebarGrey, "\(control)")
            #expect(color == pill, "\(control)")
        }
    }

    @Test("the icon button's other tints keep their colours: primary the label colour, secondary and none the style's grey")
    func otherTintsKeepTheirColours() {
        let primary = PaneChromeControlButton.symbolColor(for: .primary)
        let secondary = PaneChromeControlButton.symbolColor(for: .secondary)
        let none = PaneChromeControlButton.symbolColor(for: nil)
        #expect(primary == NSColor.labelColor)
        #expect(secondary == nil)
        #expect(none == nil)
    }

    // MARK: - Labels

    @Test("the transcript and Notes pills show their label off, behind and in front, and Changes shows none in any state")
    func labelsFollowTheKindNotTheState() {
        for state in Self.allStates {
            let changes = TabRowEdgeItem.changes(.changes(state: state)).pillLabel
            let transcript = TabRowEdgeItem.transcript(.transcript(state: state, isEnabled: true)).pillLabel
            let notes = TabRowEdgeItem.notes(.notes(state: state, isEnabled: true)).pillLabel
            #expect(changes == nil, "Changes \(state)")
            #expect(transcript == "Transcript", "the transcript \(state)")
            #expect(notes == "Notes", "Notes \(state)")
        }
        // A transcript pill that cannot act, and a Notes pill whose notes are
        // loading, keep their labels too.
        let disabledTranscript = TabRowEdgeItem.transcript(.transcript(state: .off, isEnabled: false)).pillLabel
        let loadingNotes = TabRowEdgeItem.notes(.notes(state: .off, isEnabled: false)).pillLabel
        #expect(disabledTranscript == "Transcript")
        #expect(loadingNotes == "Notes")
        // The labels the pills measure are exactly the two that show.
        let measured = TabRowEdgeItem.pillLabels
        #expect(measured == ["Transcript", "Notes"])
    }

    // MARK: - Geometry

    @Test("the transcript and Notes pills take their labelled width and Changes the icon square, in every state")
    func pillSizeFollowsTheKind() {
        let square = RowIconSquare.standard
        let transcriptWidth = SidePanelPillMetrics.labelledWidth(Self.transcriptLabel)
        let notesWidth = SidePanelPillMetrics.labelledWidth(Self.notesLabel)
        let transcriptPill = RowIconSquare.Size.pill(width: transcriptWidth)
        let notesPill = RowIconSquare.Size.pill(width: notesWidth)
        for state in Self.allStates {
            let changes = SidePanelPillButton.size(for: .changes(.changes(state: state)))
            let transcript = SidePanelPillButton.size(for: .transcript(.transcript(state: state, isEnabled: true)))
            let notes = SidePanelPillButton.size(for: .notes(.notes(state: state, isEnabled: true)))
            #expect(changes == square, "Changes \(state)")
            #expect(transcript == transcriptPill, "the transcript \(state)")
            #expect(notes == notesPill, "Notes \(state)")
        }
        let disabled = SidePanelPillButton.size(for: .transcript(.transcript(state: .off, isEnabled: false)))
        #expect(disabled == transcriptPill)
        let squareRadius = RowIconSquare.cornerRadius(for: square)
        let pillRadius = RowIconSquare.cornerRadius(for: notesPill)
        #expect(squareRadius == MainToolbarMetrics.iconButtonCornerRadius)
        #expect(pillRadius == MainTabRowMetrics.pillCornerRadius)
    }

    @Test("a labelled pill is its padding, icon slot, gap and label, in whole points, wider than the square")
    func labelledWidthIsWholePoints() {
        let side = RowIconSquare.standardSide
        for label in TabRowEdgeItem.pillLabels {
            let width = SidePanelPillMetrics.labelledWidth(label)
            let parts = SidePanelPillMetrics.leadingPadding + SidePanelPillMetrics.iconSlotWidth
                + SidePanelPillMetrics.iconToLabelSpacing + SidePanelPillMetrics.labelWidth(label)
                + SidePanelPillMetrics.trailingPadding
            let rounded = width.rounded()
            #expect(width == parts, "\(label)")
            #expect(width == rounded, "\(label) is \(width) pt")
            #expect(width > side, "\(label)")
        }
        // The icon sits where the square centres Changes' icon.
        let centred = SidePanelPillMetrics.leadingPadding + SidePanelPillMetrics.iconSlotWidth / 2
        let squareCentre = side / 2
        #expect(centred == squareCentre)
    }

    // MARK: - The side region's minimum width

    @Test("the strip's fixed controls, with the transcript and Notes pills labelled and the tabs given no room, take exactly the side region's minimum width")
    func fullStripFitsTheMinimumWidth() {
        let square = RowIconSquare.standardSide
        // The fullest trailing group: an active panel's control, all three
        // pills, and collapse.
        let full = SideStripTrailingItem.items(
            activePanelControl: .refresh,
            edgeItems: Self.items(changes: .front, transcript: .behind, notes: .off))
        var trailing: CGFloat = 0
        for item in full {
            switch item {
            case .activePanelControl, .collapse:
                trailing += square
            case .edge(let edgeItem):
                trailing += Self.width(of: SidePanelPillButton.size(for: edgeItem))
            }
        }
        let historyButtons = CGFloat(SideStripMetrics.historyButtonCount) * square
        let history = SideStripMetrics.historyLeadingInset + historyButtons
        let needed = history + trailing + MainTabRowMetrics.trailingInset
        let minimum = SideStripMetrics.fixedControlsWidth
        let rounded = minimum.rounded()
        let slots = full.count

        #expect(needed == minimum, "the strip needs \(needed) pt; the side region's minimum is \(minimum) pt")
        #expect(minimum == rounded, "\(minimum) pt is not whole points")
        #expect(slots == SideStripMetrics.trailingSlotCount)
    }
}
