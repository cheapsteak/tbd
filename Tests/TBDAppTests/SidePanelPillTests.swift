import CoreGraphics
import Foundation
import Testing
@testable import TBDApp

// Tier 1: deterministic, in-process values only. No view is drawn; the label
// widths come from the system font's metrics.

/// The side region's toggle pills (side panel toggle pills spec, "Pills"):
/// the state each decision stands for, the rule for when the pills that are
/// on show their labels, and the square each pill's hover covers.
@Suite("Side panel pills")
@MainActor
struct SidePanelPillTests {
    private static let changesLabel = TabRowEdgeItem.changesLabel
    private static let transcriptLabel = TabRowEdgeItem.transcriptLabel
    private static let notesLabel = TabRowEdgeItem.notesLabel

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

    // MARK: - The label rule

    @Test("the labels show at the width that fits every pill that is on, and not a point narrower")
    func labelsFitAtTheirBoundary() {
        let items = Self.items(changes: .front, transcript: .behind, notes: .off)
        let changesExtra = SidePanelPillMetrics.labelExtra(Self.changesLabel)
        let transcriptExtra = SidePanelPillMetrics.labelExtra(Self.transcriptLabel)
        let fits = SideStripMetrics.fixedControlsWidth + changesExtra + transcriptExtra
        let narrower = fits - 1

        let fitsAtWidth = SidePanelPillMetrics.labelsFit(stripWidth: fits, edgeItems: items)
        let fitsNarrower = SidePanelPillMetrics.labelsFit(stripWidth: narrower, edgeItems: items)
        #expect(fitsAtWidth, "labels at \(fits) pt")
        #expect(!fitsNarrower, "icons at \(narrower) pt")
    }

    @Test("with all three on, the labels need room for all three")
    func allThreeOnNeedRoomForAllThree() {
        let items = Self.items(changes: .behind, transcript: .front, notes: .behind)
        var fits = SideStripMetrics.fixedControlsWidth
        for label in TabRowEdgeItem.pillLabels {
            fits += SidePanelPillMetrics.labelExtra(label)
        }
        let narrower = fits - 1

        let fitsAtWidth = SidePanelPillMetrics.labelsFit(stripWidth: fits, edgeItems: items)
        let fitsNarrower = SidePanelPillMetrics.labelsFit(stripWidth: narrower, edgeItems: items)
        #expect(fitsAtWidth)
        #expect(!fitsNarrower)
    }

    @Test("a pill that is off never shows a label, and the ones that are on show theirs only while the labels fit")
    func onlyOnPillsShowLabels() {
        let items = Self.items(changes: .front, transcript: .off, notes: .behind)

        let fitting = items.map { SidePanelPillMetrics.showsLabel($0, labelsFit: true) }
        let notFitting = items.map { SidePanelPillMetrics.showsLabel($0, labelsFit: false) }
        #expect(fitting == [true, false, true])
        #expect(notFitting == [false, false, false])

        // Every pill off: no label at any width, though "the labels fit".
        let allOff = Self.items(changes: .off, transcript: .off, notes: .off)
        let fixed = SideStripMetrics.fixedControlsWidth
        let fitsAllOff = SidePanelPillMetrics.labelsFit(stripWidth: fixed, edgeItems: allOff)
        #expect(fitsAllOff, "nothing to fit, so the rule holds at the fixed controls' width")
        let shownAllOff = allOff.map { SidePanelPillMetrics.showsLabel($0, labelsFit: fitsAllOff) }
        #expect(shownAllOff == [false, false, false])
    }

    @Test("the transcript pill's absence leaves its label out of the rule")
    func absentTranscriptNeedsNoRoom() {
        let items: [TabRowEdgeItem] = [
            .changes(.changes(state: .front)),
            .notes(.notes(state: .behind, isEnabled: true)),
        ]
        let fits = SideStripMetrics.fixedControlsWidth
            + SidePanelPillMetrics.labelExtra(Self.changesLabel)
            + SidePanelPillMetrics.labelExtra(Self.notesLabel)
        let narrower = fits - 1

        let fitsAtWidth = SidePanelPillMetrics.labelsFit(stripWidth: fits, edgeItems: items)
        let fitsNarrower = SidePanelPillMetrics.labelsFit(stripWidth: narrower, edgeItems: items)
        #expect(fitsAtWidth)
        #expect(!fitsNarrower)
    }

    @Test("the strip's measured width gives the rule the same answer as its real width")
    func labelRuleWidthKeepsTheAnswer() {
        let band = SidePanelPillMetrics.labelRuleBand
        let fixed = SideStripMetrics.fixedControlsWidth
        let lower = band.lowerBound
        let pointShort = fixed - 1
        #expect(lower == pointShort)

        let combinations: [[TabRowEdgeItem]] = [
            Self.items(changes: .front, transcript: .off, notes: .off),
            Self.items(changes: .off, transcript: .behind, notes: .front),
            Self.items(changes: .front, transcript: .front, notes: .behind),
        ]
        var widths: [CGFloat] = [0, fixed - 40, band.upperBound + 300]
        for items in combinations {
            var threshold = fixed
            for item in items where item.state.isOn {
                threshold += SidePanelPillMetrics.labelExtra(item.pillLabel)
            }
            widths += [threshold - 1, threshold - 0.5, threshold, threshold + 0.5]
        }
        for items in combinations {
            for width in widths {
                let measured = SidePanelPillMetrics.labelRuleWidth(width, band: band)
                let real = SidePanelPillMetrics.labelsFit(stripWidth: width, edgeItems: items)
                let fromMeasured = SidePanelPillMetrics.labelsFit(stripWidth: measured, edgeItems: items)
                #expect(fromMeasured == real, "\(width) pt measured as \(measured) pt")
            }
        }

        // Outside the band the measured width does not move.
        let below = SidePanelPillMetrics.labelRuleWidth(10, band: band)
        let farBelow = SidePanelPillMetrics.labelRuleWidth(100, band: band)
        let above = SidePanelPillMetrics.labelRuleWidth(band.upperBound + 10, band: band)
        let farAbove = SidePanelPillMetrics.labelRuleWidth(band.upperBound + 900, band: band)
        #expect(below == farBelow)
        #expect(above == farAbove)
    }

    // MARK: - Geometry

    @Test("a labelled pill is its padding, icon slot, gap and label, in whole points, wider than the square")
    func labelledWidthIsWholePoints() {
        let side = RowIconSquare.standardSide
        for label in TabRowEdgeItem.pillLabels {
            let width = SidePanelPillMetrics.labelledWidth(label)
            let parts = SidePanelPillMetrics.leadingPadding + SidePanelPillMetrics.iconSlotWidth
                + SidePanelPillMetrics.iconToLabelSpacing + SidePanelPillMetrics.labelWidth(label)
                + SidePanelPillMetrics.trailingPadding
            let extra = SidePanelPillMetrics.labelExtra(label)
            let rounded = width.rounded()
            let beyondSquare = width - side
            #expect(width == parts, "\(label)")
            #expect(width == rounded, "\(label) is \(width) pt")
            #expect(width > side, "\(label)")
            #expect(extra == beyondSquare, "\(label)")
        }
        // The icon sits where the square centres it.
        let centred = SidePanelPillMetrics.leadingPadding + SidePanelPillMetrics.iconSlotWidth / 2
        let squareCentre = side / 2
        #expect(centred == squareCentre)
    }

    @Test("a pill's hover square is the icon square without a label and the pill's own width with one")
    func pillSizeFollowsTheLabel() {
        let item: TabRowEdgeItem = .notes(.notes(state: .behind, isEnabled: true))
        let iconOnly = SidePanelPillButton.size(for: item, showsLabel: false)
        let labelled = SidePanelPillButton.size(for: item, showsLabel: true)
        let expectedLabelled = RowIconSquare.Size.pill(width: SidePanelPillMetrics.labelledWidth(Self.notesLabel))
        #expect(iconOnly == RowIconSquare.standard)
        #expect(labelled == expectedLabelled)
        let radius = RowIconSquare.cornerRadius(for: labelled)
        #expect(radius == MainTabRowMetrics.pillCornerRadius)
    }

    @Test("the strip's fixed controls stay 240 pt, with the pills at their icon-only width in the + menu's place")
    func fixedControlsStay240() {
        let width = SideStripMetrics.fixedControlsWidth
        let slots = SideStripMetrics.trailingSlotCount
        #expect(width == 240)
        #expect(slots == 5)
    }
}
