import Foundation
import Testing
@testable import TBDShared

/// Each violation test builds a surface that breaks exactly one rule and
/// expects exactly that one violation back, so a validator that over-reports
/// fails as surely as one that under-reports.
@Suite("PanelSurfaceValidator")
struct PanelSurfaceValidatorTests {
    private static let site = URL(string: "https://example.com/docs")!

    private func file(_ path: String) -> PanelContent {
        .file(FileReference(path: path))
    }

    private func surface(_ side: SideRegion) -> WorkspaceTabSurface {
        WorkspaceTabSurface(id: UUID(), worktreeID: UUID(),
                            primary: .terminal(terminalID: UUID()), side: side)
    }

    /// A region that satisfies every rule over `panels`: the first panel is
    /// active and `recency` is the panel order.
    private func region(_ panels: [ViewerPanel],
                        width: Double = SideRegion.defaultWidth) -> SideRegion {
        SideRegion(panels: panels, activePanelID: panels.first?.id,
                   recency: panels.map(\.id), collapsed: false, width: width)
    }

    private func violations(_ side: SideRegion) -> [PanelSurfaceViolation] {
        PanelSurfaceValidator.violations(in: surface(side))
    }

    // MARK: - Valid surfaces

    @Test func validSurfaceHasNoViolations() {
        var aHistory = PanelHistory.seeded(with: file("/old.swift"))
        aHistory.recordReplacement(outgoing: file("/old.swift"), incoming: file("/a.swift"))
        let a = ViewerPanel(id: UUID(), history: aHistory)
        let b = ViewerPanel(id: UUID(), content: file("/b.md"))
        let transcript = ViewerPanel(id: UUID(), content: .transcript(terminalID: UUID()))
        let side = SideRegion(
            panels: [a, b, transcript], activePanelID: transcript.id,
            recency: [transcript.id, a.id, b.id], collapsed: false, width: 0.5)
        #expect(violations(side) == [])
    }

    @Test func emptyRegionIsValid() {
        #expect(violations(.empty) == [])
    }

    @Test func widthBoundsAreInclusive() {
        let panel = ViewerPanel(id: UUID(), content: file("/a"))
        let bounds = [SideRegion.widthRange.lowerBound, SideRegion.widthRange.upperBound]
        for width in bounds {
            #expect(violations(region([panel], width: width)) == [], "width \(width)")
        }
    }

    // MARK: - One test per violation

    @Test func duplicatePanelIDIsAViolation() {
        let id = UUID()
        let side = SideRegion(
            panels: [ViewerPanel(id: id, content: file("/a")),
                     ViewerPanel(id: id, content: file("/b"))],
            activePanelID: id, recency: [id, id])
        #expect(violations(side) == [.duplicatePanelID(id)])
    }

    @Test func activePanelMissingIsAViolation() {
        let panel = ViewerPanel(id: UUID(), content: file("/a"))
        let stray = UUID()
        let side = SideRegion(panels: [panel], activePanelID: stray, recency: [panel.id])
        #expect(violations(side) == [.activePanelMissing(stray)])
    }

    @Test func activePanelWithoutPanelsIsAViolation() {
        let side = SideRegion(panels: [], activePanelID: UUID(), recency: [])
        #expect(violations(side) == [.activePanelWithoutPanels])
    }

    @Test func noActivePanelIsAViolation() {
        let panel = ViewerPanel(id: UUID(), content: file("/a"))
        let side = SideRegion(panels: [panel], activePanelID: nil, recency: [panel.id])
        #expect(violations(side) == [.noActivePanel])
    }

    @Test func recencyMismatchIsAViolation() {
        let a = ViewerPanel(id: UUID(), content: file("/a"))
        let b = ViewerPanel(id: UUID(), content: file("/b"))
        let recencies: [String: [PanelID]] = [
            "missing an ID": [a.id],
            "an ID with no panel": [a.id, b.id, UUID()],
            "a repeated ID": [a.id, a.id],
            "an ID swapped for a stray": [a.id, UUID()],
        ]
        for (label, recency) in recencies {
            let side = SideRegion(panels: [a, b], activePanelID: a.id, recency: recency)
            #expect(violations(side) == [.recencyMismatch], "recency \(label)")
        }
    }

    @Test func malformedHistoryIsAViolation() {
        let outOfRange = ViewerPanel(
            id: UUID(), history: PanelHistory(entries: [file("/a")], cursor: 1))
        let empty = ViewerPanel(id: UUID(), history: PanelHistory())
        for panel in [outOfRange, empty] {
            #expect(violations(region([panel])) == [.malformedHistory(panel.id)])
        }
    }

    @Test func historyOverCapIsAViolation() {
        // maxEntries + 1 entries, all files.
        let overCap = (0...PanelHistory.maxEntries).map { file("/f\($0).swift") }
        let panel = ViewerPanel(id: UUID(), history: PanelHistory(entries: overCap, cursor: 0))
        #expect(violations(region([panel])) == [.historyOverCap(panel.id)])

        let atCap = (1...PanelHistory.maxEntries).map { file("/f\($0).swift") }
        let full = ViewerPanel(id: UUID(), history: PanelHistory(entries: atCap, cursor: 0))
        #expect(violations(region([full])) == [], "exactly maxEntries is allowed")
    }

    @Test func historyMixingKindsIsAViolation() {
        let panel = ViewerPanel(
            id: UUID(),
            history: PanelHistory(entries: [file("/a"), .web(Self.site)], cursor: 0))
        #expect(violations(region([panel])) == [.historyMixesKinds(panel.id)])
    }

    @Test func duplicateTranscriptViewIsAViolation() {
        let terminal = UUID()
        let first = ViewerPanel(id: UUID(), content: .transcript(terminalID: terminal))
        let second = ViewerPanel(id: UUID(), content: .transcript(terminalID: terminal))
        #expect(violations(region([first, second]))
            == [.duplicateTranscriptView(terminalID: terminal)])
    }

    /// The rule counts views — what panels currently show — not history.
    @Test func transcriptHeldOnlyInHistoryIsNotADuplicateView() {
        let terminal = UUID()
        let other = UUID()
        let showing = ViewerPanel(id: UUID(), content: .transcript(terminalID: terminal))
        let remembering = ViewerPanel(
            id: UUID(),
            history: PanelHistory(
                entries: [.transcript(terminalID: other), .transcript(terminalID: terminal)],
                cursor: 0))
        #expect(remembering.content == .transcript(terminalID: other))
        #expect(violations(region([showing, remembering])) == [])
    }

    @Test func widthOutsideRangeIsAViolation() {
        let panel = ViewerPanel(id: UUID(), content: file("/a"))
        let outside: [Double] = [0.05, 0.95, .infinity]
        for width in outside {
            #expect(violations(region([panel], width: width)) == [.widthOutOfRange(width)],
                    "width \(width)")
        }

        // NaN never equals itself, so match the case instead of comparing it.
        let nanViolations = violations(region([panel], width: .nan))
        #expect(nanViolations.count == 1)
        guard case .widthOutOfRange(let reported)? = nanViolations.first else {
            Issue.record("expected widthOutOfRange, got \(nanViolations)")
            return
        }
        #expect(reported.isNaN)
    }
}
