import Foundation
import Testing
@testable import TBDShared

@Suite("LegacySurfaceImporter")
struct LegacySurfaceImporterTests {
    private let worktreeID = UUID()

    private func file(_ p: String) -> PanelContent { .file(FileReference(path: p)) }

    private func convertOne(
        _ payload: LegacyTabPayload,
        paneHistories: [UUID: MRUHistory<PaneContent>] = [:],
        makeID: @escaping () -> UUID = { UUID() }
    ) -> LegacySurfaceImporter.Conversion {
        LegacySurfaceImporter.convert(
            worktreeID: worktreeID, tabs: [payload], tabOrder: [payload.tabID],
            paneHistories: paneHistories, makeID: makeID)
    }

    // MARK: - Terminal-only tab

    @Test func terminalOnlyTab_layoutNilBecomesPrimary_noPanelsNoHistory() {
        let termID = UUID()
        let tabID = UUID()
        let payload = LegacyTabPayload(
            tabID: tabID, label: nil, content: .terminal(terminalID: termID), layout: nil)

        let result = convertOne(payload)

        #expect(result.skipped.isEmpty)
        #expect(result.surfaces.count == 1)
        let surface = result.surfaces[0]
        #expect(surface.layout == .primary)
        #expect(surface.primary == .terminal(terminalID: termID))
        #expect(result.histories.isEmpty)
        #expect(result.promotedTerminalTabs == 0)
    }

    // MARK: - Terminal + codeViewer split

    @Test func terminalPlusViewerSplit_primaryReplacesTerminal_viewerKeepsID() {
        let termID = UUID()
        let viewerID = UUID()
        let splitID = UUID()
        let tabID = UUID()
        let layout = LayoutNode.split(
            id: splitID, direction: .horizontal,
            children: [.pane(.terminal(terminalID: termID)), .pane(.codeViewer(id: viewerID, path: "/a"))],
            ratios: [0.6, 0.4])
        let payload = LegacyTabPayload(
            tabID: tabID, label: nil, content: .terminal(terminalID: termID), layout: layout)
        let legacyHistory = MRUHistory<PaneContent>.seeded(with: .codeViewer(id: viewerID, path: "/a"))

        let result = convertOne(payload, paneHistories: [viewerID: legacyHistory])

        #expect(result.skipped.isEmpty)
        let surface = result.surfaces[0]
        guard case .split(let split) = surface.layout else {
            Issue.record("expected split"); return
        }
        #expect(split.id == splitID, "split ID reused")
        #expect(split.direction == .horizontal)
        #expect(split.children[0] == .primary)
        #expect(split.children[1] == .panel(PanelSlot(id: viewerID, content: file("/a"))), "viewer keeps paneID")
        #expect(split.ratios == [0.6, 0.4], "ratios preserved")
        #expect(result.histories[viewerID]?.entries == [file("/a")], "history carried with same key")
        #expect(result.promotedTerminalTabs == 0)
    }

    // MARK: - Note-leaf tab

    @Test func noteLeafTab_freshPanelID_historyRekeyedToFreshID() {
        let termID = UUID()
        let noteID = UUID()
        let splitID = UUID()
        let tabID = UUID()
        let layout = LayoutNode.split(
            id: splitID, direction: .vertical,
            children: [.pane(.terminal(terminalID: termID)), .pane(.note(noteID: noteID))],
            ratios: [0.5, 0.5])
        let payload = LegacyTabPayload(
            tabID: tabID, label: nil, content: .terminal(terminalID: termID), layout: layout)
        let legacyHistory = MRUHistory<PaneContent>.seeded(with: .note(noteID: noteID))
        let mintedID = UUID()

        let result = convertOne(payload, paneHistories: [noteID: legacyHistory], makeID: { mintedID })

        #expect(result.skipped.isEmpty)
        let surface = result.surfaces[0]
        guard case .split(let split) = surface.layout,
              case .panel(let slot) = split.children[1] else {
            Issue.record("expected split with panel"); return
        }
        #expect(slot.id == mintedID)
        #expect(slot.id != noteID, "note pane ID is a resource ID, not slot identity")
        #expect(slot.content == .note(noteID: noteID))
        #expect(result.histories[mintedID]?.entries == [.note(noteID: noteID)], "re-keyed to fresh ID")
        #expect(result.histories[noteID] == nil, "no leftover entry under the old key")
    }

    // MARK: - Viewer-only tab (primary IS a viewer)

    @Test func viewerOnlyTab_primaryIsFile_layoutIsPrimaryWhenTreeIsSinglePane() {
        let viewerID = UUID()
        let tabID = UUID()
        let payload = LegacyTabPayload(
            tabID: tabID, label: nil, content: .codeViewer(id: viewerID, path: "/x"), layout: nil)

        let result = convertOne(payload)

        #expect(result.skipped.isEmpty)
        let surface = result.surfaces[0]
        #expect(surface.layout == .primary)
        #expect(surface.primary == .file(FileReference(path: "/x")))
        #expect(result.histories.isEmpty, "primary leaf never becomes a panel slot")
    }

    // MARK: - Malformed ratios

    @Test func malformedRatios_repeatedNonNormalizedValues_fallBackToEqualShares() {
        let termID = UUID()
        let viewerA = UUID()
        let viewerB = UUID()
        let splitID = UUID()
        let tabID = UUID()
        let layout = LayoutNode.split(
            id: splitID, direction: .horizontal,
            children: [
                .pane(.terminal(terminalID: termID)),
                .pane(.codeViewer(id: viewerA, path: "/a")),
                .pane(.codeViewer(id: viewerB, path: "/b")),
            ],
            ratios: [0.9, 0.9, 0.9])
        let payload = LegacyTabPayload(
            tabID: tabID, label: nil, content: .terminal(terminalID: termID), layout: layout)

        let result = convertOne(payload)

        #expect(result.skipped.isEmpty)
        guard case .split(let split) = result.surfaces[0].layout else {
            Issue.record("expected split"); return
        }
        #expect(split.ratios == [1.0 / 3, 1.0 / 3, 1.0 / 3])
    }

    @Test func malformedRatios_nonFiniteValue_fallsBackToEqualShares() {
        let termID = UUID()
        let viewerID = UUID()
        let splitID = UUID()
        let tabID = UUID()
        let layout = LayoutNode.split(
            id: splitID, direction: .horizontal,
            children: [.pane(.terminal(terminalID: termID)), .pane(.codeViewer(id: viewerID, path: "/a"))],
            ratios: [CGFloat.nan, 1])
        let payload = LegacyTabPayload(
            tabID: tabID, label: nil, content: .terminal(terminalID: termID), layout: layout)

        let result = convertOne(payload)

        #expect(result.skipped.isEmpty)
        guard case .split(let split) = result.surfaces[0].layout else {
            Issue.record("expected split"); return
        }
        #expect(split.ratios == [0.5, 0.5])
    }

    @Test func normalizedRatios_directUnit() {
        #expect(LegacySurfaceImporter.normalizedRatios([0.6, 0.4], count: 2) == [0.6, 0.4])
        #expect(LegacySurfaceImporter.normalizedRatios([0.9, 0.9, 0.9], count: 3) == [1.0 / 3, 1.0 / 3, 1.0 / 3])
        #expect(LegacySurfaceImporter.normalizedRatios([.nan, 1], count: 2) == [0.5, 0.5])
        #expect(LegacySurfaceImporter.normalizedRatios([0.6], count: 2) == [0.5, 0.5], "count mismatch")
        #expect(LegacySurfaceImporter.normalizedRatios([0.05, 0.95], count: 2) == [0.5, 0.5], "sub-minShare")
    }

    // MARK: - History with terminal entries

    @Test func historyWithTerminalEntries_droppedAndCursorClamped() {
        let mainTerm = UUID()
        let viewerID = UUID()
        let webID = UUID()
        let historyTermID = UUID()
        let splitID = UUID()
        let tabID = UUID()
        let webURL = URL(string: "https://example.com")!
        let layout = LayoutNode.split(
            id: splitID, direction: .horizontal,
            children: [.pane(.terminal(terminalID: mainTerm)), .pane(.codeViewer(id: viewerID, path: "/a"))],
            ratios: [0.6, 0.4])
        let payload = LegacyTabPayload(
            tabID: tabID, label: nil, content: .terminal(terminalID: mainTerm), layout: layout)
        let legacyHistory = MRUHistory<PaneContent>(
            entries: [
                .terminal(terminalID: historyTermID),
                .codeViewer(id: viewerID, path: "/a"),
                .webview(id: webID, url: webURL),
            ],
            cursor: 1)

        let result = convertOne(payload, paneHistories: [viewerID: legacyHistory])

        #expect(result.skipped.isEmpty)
        let history = result.histories[viewerID]
        #expect(history?.entries == [file("/a"), .web(webURL)], "terminal entry dropped")
        #expect(history?.cursor == 0, "cursor clamped to surviving current entry")
    }

    @Test func historyWhereCurrentEntryIsTerminal_dropsWholeHistoryAndReseeds() {
        let mainTerm = UUID()
        let viewerID = UUID()
        let splitID = UUID()
        let tabID = UUID()
        let layout = LayoutNode.split(
            id: splitID, direction: .horizontal,
            children: [.pane(.terminal(terminalID: mainTerm)), .pane(.codeViewer(id: viewerID, path: "/a"))],
            ratios: [0.6, 0.4])
        let payload = LegacyTabPayload(
            tabID: tabID, label: nil, content: .terminal(terminalID: mainTerm), layout: layout)
        let legacyHistory = MRUHistory<PaneContent>(
            entries: [.terminal(terminalID: UUID()), .codeViewer(id: viewerID, path: "/a")],
            cursor: 0)

        let result = convertOne(payload, paneHistories: [viewerID: legacyHistory])

        #expect(result.histories[viewerID] == MRUHistory<PanelContent>.seeded(with: file("/a")))
    }

    // MARK: - Validator-clean assertion + nested split collapse + terminal promotion count

    @Test func nestedSplitCollapsesAndConvertedSurfaceIsValidatorClean() {
        let mainTerm = UUID()
        let extraTerm = UUID()
        let viewerID = UUID()
        let outerID = UUID()
        let innerID = UUID()
        let tabID = UUID()
        let layout = LayoutNode.split(
            id: outerID, direction: .horizontal,
            children: [
                .pane(.terminal(terminalID: mainTerm)),
                .split(
                    id: innerID, direction: .vertical,
                    children: [.pane(.terminal(terminalID: extraTerm)), .pane(.codeViewer(id: viewerID, path: "/b"))],
                    ratios: [0.5, 0.5]),
            ],
            ratios: [0.5, 0.5])
        let payload = LegacyTabPayload(
            tabID: tabID, label: nil, content: .terminal(terminalID: mainTerm), layout: layout)

        let result = convertOne(payload)

        #expect(result.skipped.isEmpty)
        let surface = result.surfaces[0]
        guard case .split(let split) = surface.layout else {
            Issue.record("expected split"); return
        }
        #expect(split.id == outerID)
        #expect(split.children == [.primary, .panel(PanelSlot(id: viewerID, content: file("/b")))],
                "inner split collapsed to its single surviving child")
        #expect(result.promotedTerminalTabs == 1, "extraTerm counted for promotion")

        let state = PanelSurfaceState(surface: surface, histories: result.histories)
        #expect(PanelSurfaceValidator.violations(in: state).isEmpty)
    }

    @Test func allEmittedSurfacesAreValidatorClean() {
        let fixtures: [LegacyTabPayload] = [
            LegacyTabPayload(tabID: UUID(), label: nil, content: .terminal(terminalID: UUID()), layout: nil),
            LegacyTabPayload(tabID: UUID(), label: nil, content: .codeViewer(id: UUID(), path: "/x"), layout: nil),
        ]
        let result = LegacySurfaceImporter.convert(
            worktreeID: worktreeID, tabs: fixtures, tabOrder: fixtures.map(\.tabID), paneHistories: [:])

        #expect(result.skipped.isEmpty)
        #expect(result.surfaces.count == fixtures.count)
        for surface in result.surfaces {
            let state = PanelSurfaceState(surface: surface, histories: result.histories)
            #expect(PanelSurfaceValidator.violations(in: state).isEmpty)
        }
    }

    // MARK: - Direct helper unit tests

    @Test func panelContent_mapsViewersAndRejectsTerminal() {
        #expect(LegacySurfaceImporter.panelContent(from: .terminal(terminalID: UUID())) == nil)
        let path = "/a"
        #expect(LegacySurfaceImporter.panelContent(from: .codeViewer(id: UUID(), path: path)) == file(path))
        let url = URL(string: "https://example.com")!
        #expect(LegacySurfaceImporter.panelContent(from: .webview(id: UUID(), url: url)) == .web(url))
        let noteID = UUID()
        #expect(LegacySurfaceImporter.panelContent(from: .note(noteID: noteID)) == .note(noteID: noteID))
        let terminalID = UUID()
        #expect(LegacySurfaceImporter.panelContent(from: .liveTranscript(id: UUID(), terminalID: terminalID))
                == .transcript(terminalID: terminalID))
    }

    @Test func primaryContent_mapsAllVariantsIncludingTerminal() {
        let terminalID = UUID()
        #expect(LegacySurfaceImporter.primaryContent(from: .terminal(terminalID: terminalID))
                == .terminal(terminalID: terminalID))
        let noteID = UUID()
        #expect(LegacySurfaceImporter.primaryContent(from: .note(noteID: noteID)) == .note(noteID: noteID))
    }
}
