import Foundation
import Testing
@testable import TBDShared

/// Spec C §13 migration fixtures + Task 4's multi-tab orchestration:
/// terminal-leaf promotion to new primary-terminal tabs, cross-tab ordering,
/// and cross-tab pane-ID dedup. Task 3 (`LegacySurfaceImporterTests`) covers
/// the single-tab conversion core; this file exercises the layer built on
/// top of it.
@Suite("LegacySurfaceImporter fixtures (spec C §13)")
struct LegacySurfaceImporterFixtureTests {
    private let worktreeID = UUID()

    private func file(_ p: String) -> PanelContent { .file(FileReference(path: p)) }

    private func convert(
        _ tabs: [LegacyTabPayload], tabOrder: [UUID]? = nil,
        paneHistories: [UUID: MRUHistory<PaneContent>] = [:],
        makeID: @escaping () -> UUID = { UUID() }
    ) -> LegacySurfaceImporter.Conversion {
        LegacySurfaceImporter.convert(
            worktreeID: worktreeID, tabs: tabs, tabOrder: tabOrder ?? tabs.map(\.tabID),
            paneHistories: paneHistories, makeID: makeID)
    }

    // MARK: - One terminal only

    @Test func oneTerminalOnlyTab_singleConvertedTab_noPromotion() {
        let termID = UUID()
        let tab = LegacyTabPayload(
            tabID: UUID(), label: "shell", content: .terminal(terminalID: termID), layout: nil)

        let result = convert([tab])

        #expect(result.skipped.isEmpty)
        #expect(result.surfaces.count == 1)
        #expect(result.surfaces[0].primary == .terminal(terminalID: termID))
        #expect(result.surfaces[0].layout == .primary)
        #expect(result.promotedTerminalTabs == 0)
    }

    // MARK: - Terminal + viewer

    @Test func terminalPlusViewer_convertedTab_viewerSurvivesAsPanel_noPromotion() {
        let termID = UUID()
        let viewerID = UUID()
        let splitID = UUID()
        let layout = LayoutNode.split(
            id: splitID, direction: .horizontal,
            children: [.pane(.terminal(terminalID: termID)), .pane(.codeViewer(id: viewerID, path: "/x"))],
            ratios: [0.7, 0.3])
        let tab = LegacyTabPayload(tabID: UUID(), label: nil, content: .terminal(terminalID: termID), layout: layout)

        let result = convert([tab])

        #expect(result.skipped.isEmpty)
        #expect(result.promotedTerminalTabs == 0)
        #expect(result.surfaces.count == 1)
        guard case .split(let split) = result.surfaces[0].layout else {
            Issue.record("expected split"); return
        }
        #expect(split.children[0] == .primary)
        #expect(split.children[1] == .panel(PanelSlot(id: viewerID, content: file("/x"))))
    }

    // MARK: - Nested mixed viewer splits, 3-deep, ratio preservation

    @Test func nestedMixedViewerSplits_threeDeep_ratiosPreservedAtEveryLevel() {
        let mainTerm = UUID()
        let viewerA = UUID()
        let viewerB = UUID()
        let viewerC = UUID()
        let outerID = UUID()
        let innerID = UUID()
        let inner2ID = UUID()
        let tree = LayoutNode.split(
            id: outerID, direction: .horizontal,
            children: [
                .pane(.terminal(terminalID: mainTerm)),
                .split(
                    id: innerID, direction: .vertical,
                    children: [
                        .pane(.codeViewer(id: viewerA, path: "/a")),
                        .split(
                            id: inner2ID, direction: .horizontal,
                            children: [
                                .pane(.codeViewer(id: viewerB, path: "/b")),
                                .pane(.codeViewer(id: viewerC, path: "/c")),
                            ],
                            ratios: [0.3, 0.7]),
                    ],
                    ratios: [0.5, 0.5]),
            ],
            ratios: [0.4, 0.6])
        let tab = LegacyTabPayload(tabID: UUID(), label: nil, content: .terminal(terminalID: mainTerm), layout: tree)

        let result = convert([tab])

        #expect(result.skipped.isEmpty)
        #expect(result.promotedTerminalTabs == 0, "no extra terminal leaves in this tree")

        guard case .split(let outer) = result.surfaces[0].layout, outer.id == outerID else {
            Issue.record("expected outer split"); return
        }
        #expect(outer.ratios == [0.4, 0.6])
        #expect(outer.children[0] == .primary)
        guard case .split(let inner) = outer.children[1], inner.id == innerID else {
            Issue.record("expected inner split"); return
        }
        #expect(inner.ratios == [0.5, 0.5])
        #expect(inner.children[0] == .panel(PanelSlot(id: viewerA, content: file("/a"))))
        guard case .split(let inner2) = inner.children[1], inner2.id == inner2ID else {
            Issue.record("expected inner2 split"); return
        }
        #expect(inner2.ratios == [0.3, 0.7])
        #expect(inner2.children[0] == .panel(PanelSlot(id: viewerB, content: file("/b"))))
        #expect(inner2.children[1] == .panel(PanelSlot(id: viewerC, content: file("/c"))))
    }

    // MARK: - Multiple terminal leaves: promotion count, ordering, no loss

    @Test func multipleTerminalLeaves_promotionCountOrderingAndNoTerminalLost() {
        let mainTerm = UUID()
        let extra1 = UUID()
        let extra2 = UUID()
        let viewerID = UUID()
        let outerID = UUID()
        let innerID = UUID()
        let treeA = LayoutNode.split(
            id: outerID, direction: .horizontal,
            children: [
                .pane(.terminal(terminalID: mainTerm)),
                .split(
                    id: innerID, direction: .vertical,
                    children: [.pane(.terminal(terminalID: extra1)), .pane(.codeViewer(id: viewerID, path: "/v"))],
                    ratios: [0.5, 0.5]),
                .pane(.terminal(terminalID: extra2)),
            ],
            ratios: [1.0 / 3, 1.0 / 3, 1.0 / 3])
        let tabA = LegacyTabPayload(tabID: UUID(), label: nil, content: .terminal(terminalID: mainTerm), layout: treeA)

        let termB = UUID()
        let tabB = LegacyTabPayload(tabID: UUID(), label: nil, content: .terminal(terminalID: termB), layout: nil)

        let result = convert([tabA, tabB], tabOrder: [tabA.tabID, tabB.tabID])

        #expect(result.skipped.isEmpty)
        #expect(result.promotedTerminalTabs == 2)
        #expect(result.surfaces.count == 4, "tabA, 2 promoted, tabB")

        // Ordering: [tabA, promoted1, promoted2, tabB] — promoted tabs
        // spliced immediately after their source, in tree traversal order.
        #expect(result.surfaces[0].id == tabA.tabID)
        #expect(result.surfaces[1].primary == .terminal(terminalID: extra1))
        #expect(result.surfaces[1].layout == .primary)
        #expect(result.surfaces[2].primary == .terminal(terminalID: extra2))
        #expect(result.surfaces[2].layout == .primary)
        #expect(result.surfaces[3].id == tabB.tabID)

        // No terminal lost: union of primary terminal IDs across every
        // output surface equals every terminal leaf across both input trees.
        let expectedTerminals: Set<UUID> = [mainTerm, extra1, extra2, termB]
        let survivingTerminals = Set(result.surfaces.compactMap { surface -> UUID? in
            guard case .terminal(let id) = surface.primary else { return nil }
            return id
        })
        #expect(survivingTerminals == expectedTerminals)
    }

    // MARK: - Note primary, with a secondary viewer panel

    @Test func notePrimaryWithViewerPanel_notePreservedAsPrimaryNotPanel() {
        let noteID = UUID()
        let viewerID = UUID()
        let splitID = UUID()
        let layout = LayoutNode.split(
            id: splitID, direction: .horizontal,
            children: [.pane(.note(noteID: noteID)), .pane(.codeViewer(id: viewerID, path: "/y"))],
            ratios: [0.5, 0.5])
        let tab = LegacyTabPayload(tabID: UUID(), label: nil, content: .note(noteID: noteID), layout: layout)

        let result = convert([tab])

        #expect(result.skipped.isEmpty)
        let surface = result.surfaces[0]
        #expect(surface.primary == .note(noteID: noteID), "note primary preserved by value, not re-minted")
        guard case .split(let split) = surface.layout else { Issue.record("expected split"); return }
        #expect(split.children[0] == .primary, "note-as-primary is a marker, never a panel slot")
        #expect(split.children[1] == .panel(PanelSlot(id: viewerID, content: file("/y"))))
        #expect(result.histories[noteID] == nil, "primary note never gets a panel history entry")
    }

    // MARK: - Viewer only

    @Test func viewerOnlyTab_singleConvertedTab_primaryIsFile() {
        let viewerID = UUID()
        let tab = LegacyTabPayload(tabID: UUID(), label: nil, content: .codeViewer(id: viewerID, path: "/x"), layout: nil)

        let result = convert([tab])

        #expect(result.skipped.isEmpty)
        #expect(result.surfaces[0].layout == .primary)
        #expect(result.surfaces[0].primary == .file(FileReference(path: "/x")))
        #expect(result.promotedTerminalTabs == 0)
    }

    // MARK: - Transcript panes referencing primary AND promoted terminals

    @Test func transcriptPanels_referencingPrimaryAndPromotedTerminal_bothSurvive() {
        let mainTerm = UUID()
        let extraTerm = UUID()
        let transcriptOfMain = UUID()
        let transcriptOfExtra = UUID()
        let splitID = UUID()
        let layout = LayoutNode.split(
            id: splitID, direction: .horizontal,
            children: [
                .pane(.terminal(terminalID: mainTerm)),
                .pane(.terminal(terminalID: extraTerm)),
                .pane(.liveTranscript(id: transcriptOfMain, terminalID: mainTerm)),
                .pane(.liveTranscript(id: transcriptOfExtra, terminalID: extraTerm)),
            ],
            ratios: [0.25, 0.25, 0.25, 0.25])
        let tab = LegacyTabPayload(tabID: UUID(), label: nil, content: .terminal(terminalID: mainTerm), layout: layout)

        let result = convert([tab])

        #expect(result.skipped.isEmpty)
        #expect(result.promotedTerminalTabs == 1)
        #expect(result.surfaces.count == 2)

        guard case .split(let split) = result.surfaces[0].layout else { Issue.record("expected split"); return }
        #expect(split.children.contains(.primary))
        #expect(split.children.contains(.panel(PanelSlot(id: transcriptOfMain, content: .transcript(terminalID: mainTerm)))))
        #expect(split.children.contains(.panel(PanelSlot(id: transcriptOfExtra, content: .transcript(terminalID: extraTerm)))))

        #expect(result.surfaces[1].primary == .terminal(terminalID: extraTerm))
    }

    // MARK: - Malformed ratios still convert (multi-tab batch context)

    @Test func malformedRatios_inBatch_fallsBackToEqualSharesAndStillConverts() {
        let termID = UUID()
        let viewerID = UUID()
        let splitID = UUID()
        let layout = LayoutNode.split(
            id: splitID, direction: .horizontal,
            children: [.pane(.terminal(terminalID: termID)), .pane(.codeViewer(id: viewerID, path: "/a"))],
            ratios: [0.9, 0.9])
        let tab = LegacyTabPayload(tabID: UUID(), label: nil, content: .terminal(terminalID: termID), layout: layout)

        let result = convert([tab])

        #expect(result.skipped.isEmpty)
        guard case .split(let split) = result.surfaces[0].layout else { Issue.record("expected split"); return }
        #expect(split.ratios == [0.5, 0.5])
    }

    // MARK: - Label / order preservation

    @Test func labelOrderPreservation_tabOrderRespected_unknownIgnored_missingAppendedInPayloadOrder() {
        let tabA = LegacyTabPayload(tabID: UUID(), label: "Shell A", content: .terminal(terminalID: UUID()), layout: nil)
        let tabB = LegacyTabPayload(tabID: UUID(), label: "Shell B", content: .terminal(terminalID: UUID()), layout: nil)
        let tabC = LegacyTabPayload(tabID: UUID(), label: "Shell C", content: .terminal(terminalID: UUID()), layout: nil)
        let unknownID = UUID()

        // tabB deliberately omitted from tabOrder; unknownID is in tabOrder
        // but has no matching payload.
        let result = convert([tabA, tabB, tabC], tabOrder: [tabC.tabID, unknownID, tabA.tabID])

        #expect(result.skipped.isEmpty)
        #expect(result.promotedTerminalTabs == 0)
        #expect(result.surfaces.map(\.id) == [tabC.tabID, tabA.tabID, tabB.tabID],
                "tabOrder sequence first (unknown ignored), stragglers appended in payload order")
        #expect(result.surfaces.map(\.label) == ["Shell C", "Shell A", "Shell B"], "labels flow through")
    }

    // MARK: - Empty layout worktree

    @Test func emptyLayoutWorktree_zeroTabs_emptyConversionNoSkips() {
        let result = convert([], tabOrder: [])

        #expect(result.surfaces.isEmpty)
        #expect(result.histories.isEmpty)
        #expect(result.skipped.isEmpty)
        #expect(result.promotedTerminalTabs == 0)
    }

    // MARK: - Mandatory terminal preservation (malformed tab among valid ones)

    @Test func terminalPreservation_malformedTabAmongValidOnes_noTerminalDropped() {
        let termGood = UUID()
        let tabGood = LegacyTabPayload(tabID: UUID(), label: nil, content: .terminal(terminalID: termGood), layout: nil)

        // Malformed: declared primary (termMalformedPrimary) never appears
        // as a leaf anywhere in the tree, so Task 3's single-tab converter
        // never sets `primaryFound` — the tab as a whole fails validation
        // (0 primaries) and would, pre-Task-4, silently drop every terminal
        // it contains. All three of its terminal leaves/references must
        // still survive as their own promoted tabs.
        let termMalformedPrimary = UUID()
        let termX = UUID()
        let termY = UUID()
        let splitID = UUID()
        let malformedTree = LayoutNode.split(
            id: splitID, direction: .horizontal,
            children: [.pane(.terminal(terminalID: termX)), .pane(.terminal(terminalID: termY))],
            ratios: [0.5, 0.5])
        let tabMalformed = LegacyTabPayload(
            tabID: UUID(), label: nil, content: .terminal(terminalID: termMalformedPrimary), layout: malformedTree)

        let result = convert([tabGood, tabMalformed], tabOrder: [tabGood.tabID, tabMalformed.tabID])

        #expect(result.skipped.count == 1, "the malformed tab itself is skipped")
        #expect(result.promotedTerminalTabs == 3, "all 3 of the malformed tab's terminals are promoted")

        let survivingTerminals = Set(result.surfaces.compactMap { surface -> UUID? in
            guard case .terminal(let id) = surface.primary else { return nil }
            return id
        })
        #expect(survivingTerminals == [termGood, termMalformedPrimary, termX, termY],
                "every input terminal ID survives as some output tab's primary — none dropped")
        #expect(result.surfaces.count == 4, "1 converted (tabGood) + 3 promoted; the malformed tab's own surface never lands")
    }

    // MARK: - Cross-tab duplicate legacy pane ID (corrupt blob)

    @Test func crossTabDuplicatePaneID_secondOccurrenceMintsFreshPanelID() {
        let sharedID = UUID()
        let termA = UUID()
        let termB = UUID()
        let tabA = LegacyTabPayload(
            tabID: UUID(), label: nil, content: .terminal(terminalID: termA),
            layout: .split(
                id: UUID(), direction: .horizontal,
                children: [.pane(.terminal(terminalID: termA)), .pane(.codeViewer(id: sharedID, path: "/a"))],
                ratios: [0.5, 0.5]))
        let tabB = LegacyTabPayload(
            tabID: UUID(), label: nil, content: .terminal(terminalID: termB),
            layout: .split(
                id: UUID(), direction: .horizontal,
                children: [.pane(.terminal(terminalID: termB)), .pane(.codeViewer(id: sharedID, path: "/b"))],
                ratios: [0.5, 0.5]))

        let result = convert([tabA, tabB])

        #expect(result.skipped.isEmpty, "cross-tab duplicates are fine — only per-tab duplicates are validator errors")
        #expect(result.surfaces.count == 2)

        guard case .split(let splitA) = result.surfaces[0].layout,
              case .panel(let slotA) = splitA.children[1] else {
            Issue.record("expected tabA split+panel"); return
        }
        #expect(slotA.id == sharedID, "first occurrence keeps the original legacy pane ID")

        guard case .split(let splitB) = result.surfaces[1].layout,
              case .panel(let slotB) = splitB.children[1] else {
            Issue.record("expected tabB split+panel"); return
        }
        #expect(slotB.id != sharedID, "second occurrence mints a fresh panel ID — avoids clobbering tabA's history entry")
        #expect(slotB.content == file("/b"))

        #expect(result.histories[sharedID] != nil)
        #expect(result.histories[slotB.id] != nil)
        #expect(result.histories.count == 2, "no history collision/clobber across tabs")
    }
}
