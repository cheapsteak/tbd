import Foundation
import CoreGraphics

/// Spec C §11.2 — pure conversion from the legacy layout model
/// (`LayoutNode`/`PaneContent`/`Tab`) to the new panel-surface model
/// (`WorkspaceTabSurface`/`PanelLayoutNode`). Each legacy tab's primary
/// content converts in place; every ADDITIONAL terminal leaf in its tree is
/// promoted to its own new primary-terminal tab, spliced immediately after
/// the source tab (spec §11.2 step 4 — a terminal is never dropped, even
/// when the source tab itself fails validation and is skipped).
public enum LegacySurfaceImporter {
    public struct Conversion: Sendable, Equatable {
        public var surfaces: [WorkspaceTabSurface]
        public var histories: [PanelID: PanelHistory]
        public var promotedTerminalTabs: Int
        public var skipped: [String]

        public init(
            surfaces: [WorkspaceTabSurface] = [], histories: [PanelID: PanelHistory] = [:],
            promotedTerminalTabs: Int = 0, skipped: [String] = []
        ) {
            self.surfaces = surfaces
            self.histories = histories
            self.promotedTerminalTabs = promotedTerminalTabs
            self.skipped = skipped
        }
    }

    public static func convert(
        worktreeID: UUID,
        tabs: [LegacyTabPayload],
        tabOrder: [UUID],
        paneHistories: [UUID: MRUHistory<PaneContent>],
        makeID: () -> UUID = { UUID() }
    ) -> Conversion {
        let byID = Dictionary(uniqueKeysWithValues: tabs.map { ($0.tabID, $0) })
        var result = Conversion()

        // Final order (spec §11.2.7): tabOrder's sequence first (unknown IDs
        // ignored), then any tabs missing from tabOrder appended in payload
        // order — promoted tabs get spliced in below, after their source.
        var orderedIDs: [UUID] = tabOrder.filter { byID[$0] != nil }
        let known = Set(orderedIDs)
        for tab in tabs where !known.contains(tab.tabID) {
            orderedIDs.append(tab.tabID)
        }

        // Cross-tab dedup (corrupt-blob edge case): viewer-class leaves reuse
        // their legacy pane ID as the new PanelID, but `result.histories` is
        // keyed by PanelID across ALL tabs — a legacy pane ID reused across
        // two different tabs would silently clobber the earlier tab's
        // history entry. Track every PanelID handed out so a repeat mints a
        // fresh one instead.
        var usedPanelIDs = Set<PanelID>()

        for tabID in orderedIDs {
            guard let payload = byID[tabID] else { continue }
            let outcome = convertTab(
                worktreeID: worktreeID, payload: payload, paneHistories: paneHistories,
                makeID: makeID, usedPanelIDs: &usedPanelIDs)
            switch outcome.result {
            case .converted(let surface, let histories):
                result.surfaces.append(surface)
                for (id, history) in histories { result.histories[id] = history }
            case .skipped(let reason):
                result.skipped.append(reason)
            }
            // Terminal-leaf promotion (spec §11.2 step 4, "never kill or
            // discard" a terminal): every additional terminal leaf becomes
            // its own new primary-terminal tab, spliced immediately after
            // its source in traversal order.
            for terminalID in outcome.promotedTerminalIDs {
                result.surfaces.append(WorkspaceTabSurface(
                    id: makeID(), worktreeID: worktreeID, label: nil,
                    primary: .terminal(terminalID: terminalID), layout: .primary, revision: 0))
                result.promotedTerminalTabs += 1
            }
        }
        return result
    }

    // MARK: - Content mapping

    /// Maps a legacy viewer-class pane to its new-model `PanelContent`.
    /// `.terminal` has no panel representation — terminals are promotion
    /// candidates or the tab's primary, never a panel.
    static func panelContent(from legacy: PaneContent) -> PanelContent? {
        switch legacy {
        case .terminal:
            return nil
        case .webview(_, let url):
            return .web(url)
        case .codeViewer(_, let path):
            return .file(FileReference(path: path))
        case .note(let noteID):
            return .note(noteID: noteID)
        case .liveTranscript(_, let terminalID):
            return .transcript(terminalID: terminalID)
        }
    }

    /// Maps a legacy pane (any variant, including `.terminal`) to the new
    /// model's `PrimaryContent` — the superset `PanelContent` deliberately
    /// excludes.
    static func primaryContent(from legacy: PaneContent) -> PrimaryContent {
        switch legacy {
        case .terminal(let id):
            return .terminal(terminalID: id)
        case .webview(_, let url):
            return .web(url)
        case .codeViewer(_, let path):
            return .file(FileReference(path: path))
        case .note(let noteID):
            return .note(noteID: noteID)
        case .liveTranscript(_, let terminalID):
            return .transcript(terminalID: terminalID)
        }
    }

    /// Repairs malformed split ratios to equal shares. Falls back when the
    /// count doesn't match, any value is non-finite or non-positive, or any
    /// normalized share falls below `PanelSurfaceValidator.minShare`;
    /// otherwise normalizes to sum 1.
    static func normalizedRatios(_ ratios: [CGFloat], count: Int) -> [Double] {
        guard count > 0 else { return [] }
        let equalShare = Array(repeating: 1.0 / Double(count), count: count)
        guard ratios.count == count else { return equalShare }

        let values = ratios.map(Double.init)
        guard values.allSatisfy({ $0.isFinite && $0 > 0 }) else { return equalShare }

        let sum = values.reduce(0, +)
        guard sum > 0 else { return equalShare }

        let normalized = values.map { $0 / sum }
        guard normalized.allSatisfy({ $0 >= PanelSurfaceValidator.minShare }) else { return equalShare }
        return normalized
    }

    // MARK: - Per-tab conversion

    private enum TabOutcome {
        case converted(WorkspaceTabSurface, [PanelID: PanelHistory])
        case skipped(String)
    }

    /// `convertTab`'s full result: the single-tab outcome (converted or
    /// skipped), plus every terminal ID from this tab that still needs its
    /// own promoted tab. Populated in both branches — see the doc comment on
    /// `convertTab` for why a skip must still promote.
    private struct TabConversionOutcome {
        var result: TabOutcome
        var promotedTerminalIDs: [UUID]
    }

    /// A surviving panel slot, plus the legacy key under which its history
    /// (if any) is stored: the reused pane ID for viewer-class leaves, or the
    /// original (pre-mint) pane ID for note leaves — recorded so the note's
    /// history can be re-keyed to the freshly minted `PanelID`.
    private struct PanelSource {
        var newID: PanelID
        var legacyHistoryKey: UUID
        var content: PanelContent
    }

    /// Converts one legacy tab. Always reports every terminal ID that needs
    /// promotion to its own new tab — not just when conversion succeeds.
    /// Task 3 skipped a whole tab outright when its declared primary
    /// (`payload.content.paneID`) matched no leaf in the tree (malformed
    /// data): `primaryFound` never flips, the layout ends up with zero
    /// `.primary` markers, and `PanelSurfaceValidator` rejects it. That skip
    /// must not take the tab's terminals down with it (spec §11.2 step 4,
    /// "never kill or discard" a terminal) — so on ANY validation failure we
    /// fall back to promoting every terminal leaf found in the tree, plus the
    /// declared primary itself if it's a terminal that was never matched.
    private static func convertTab(
        worktreeID: UUID, payload: LegacyTabPayload,
        paneHistories: [UUID: MRUHistory<PaneContent>], makeID: () -> UUID,
        usedPanelIDs: inout Set<PanelID>
    ) -> TabConversionOutcome {
        let tree = payload.layout ?? .pane(payload.content)
        var primaryFound = false
        var droppedTerminalIDs: [UUID] = []
        var panelSources: [PanelSource] = []

        func convertNode(_ node: LayoutNode) -> PanelLayoutNode? {
            switch node {
            case .pane(let leaf):
                if !primaryFound && leaf.paneID == payload.content.paneID {
                    primaryFound = true
                    return .primary
                }
                switch leaf {
                case .terminal(let terminalID):
                    droppedTerminalIDs.append(terminalID)
                    return nil
                case .note(let noteID):
                    let newID = makeID()
                    let content = PanelContent.note(noteID: noteID)
                    panelSources.append(PanelSource(newID: newID, legacyHistoryKey: leaf.paneID, content: content))
                    return .panel(PanelSlot(id: newID, content: content))
                case .webview, .codeViewer, .liveTranscript:
                    guard let content = panelContent(from: leaf) else { return nil }
                    // Cross-tab dedup: a corrupt blob may reuse the same
                    // legacy pane ID as a viewer leaf in two different tabs.
                    // Reusing it here as the PanelID would collide in the
                    // caller's global `histories` dict, clobbering whichever
                    // tab converted first. Mint a fresh ID for any repeat.
                    let panelID = usedPanelIDs.contains(leaf.paneID) ? makeID() : leaf.paneID
                    usedPanelIDs.insert(panelID)
                    panelSources.append(PanelSource(newID: panelID, legacyHistoryKey: leaf.paneID, content: content))
                    return .panel(PanelSlot(id: panelID, content: content))
                }

            case .split(let id, let direction, let children, let ratios):
                var newChildren: [PanelLayoutNode] = []
                var keptRatios: [CGFloat] = []
                for (index, child) in children.enumerated() {
                    guard let converted = convertNode(child) else { continue }
                    newChildren.append(converted)
                    if ratios.indices.contains(index) {
                        keptRatios.append(ratios[index])
                    }
                }
                if newChildren.isEmpty { return nil }
                if newChildren.count == 1 { return newChildren[0] }
                let normalized = normalizedRatios(keptRatios, count: newChildren.count)
                return .split(SplitNode(id: id, direction: direction, children: newChildren, ratios: normalized))
            }
        }

        // Nothing survived (no primary match, everything else a terminal) —
        // deliberately invalid (0 primaries) so the validation gate below
        // rejects it with a clear reason instead of us special-casing here.
        let layout = convertNode(tree)
            ?? .split(SplitNode(id: makeID(), direction: .horizontal, children: [], ratios: []))

        let surface = WorkspaceTabSurface(
            id: payload.tabID, worktreeID: worktreeID, label: payload.label,
            primary: primaryContent(from: payload.content), layout: layout, revision: 0)

        var histories: [PanelID: PanelHistory] = [:]
        for source in panelSources {
            histories[source.newID] = rekeyedHistory(
                paneHistories[source.legacyHistoryKey], currentContent: source.content)
        }

        let state = PanelSurfaceState(surface: surface, histories: histories)
        let violations = PanelSurfaceValidator.violations(in: state)
        guard violations.isEmpty else {
            // The tab's own surface never lands — but every terminal it
            // references still must (spec §11.2 step 4). `droppedTerminalIDs`
            // already holds every terminal leaf that wasn't the matched
            // primary; if the declared primary itself is a terminal that was
            // never found in the tree (why `primaryFound` is still false —
            // the malformed case), it's not in that list yet, so add it.
            var allTerminalIDs = droppedTerminalIDs
            if case .terminal(let contentTerminalID) = payload.content,
               !allTerminalIDs.contains(contentTerminalID) {
                allTerminalIDs.insert(contentTerminalID, at: 0)
            }
            return TabConversionOutcome(
                result: .skipped("tab \(payload.tabID): \(violations)"),
                promotedTerminalIDs: allTerminalIDs)
        }
        return TabConversionOutcome(result: .converted(surface, histories), promotedTerminalIDs: droppedTerminalIDs)
    }

    /// Re-keys a legacy `PaneContent` history onto the new `PanelContent`
    /// model: unmappable (`.terminal`) entries are dropped and the cursor is
    /// clamped to the surviving index of the entry that was current. If the
    /// current entry itself is unmappable, or the invariant
    /// `entries[cursor] == currentContent` still doesn't hold afterward, the
    /// whole history is replaced with a fresh seed of the panel's live
    /// content — absent histories are seeded the same way.
    private static func rekeyedHistory(
        _ legacy: MRUHistory<PaneContent>?, currentContent: PanelContent
    ) -> PanelHistory {
        guard let legacy, legacy.entries.indices.contains(legacy.cursor),
              panelContent(from: legacy.entries[legacy.cursor]) != nil else {
            return .seeded(with: currentContent)
        }

        var newEntries: [PanelContent] = []
        var newCursor = 0
        for (index, entry) in legacy.entries.enumerated() {
            guard let mapped = panelContent(from: entry) else { continue }
            if index == legacy.cursor { newCursor = newEntries.count }
            newEntries.append(mapped)
        }

        let rekeyed = PanelHistory(entries: newEntries, cursor: newCursor)
        guard rekeyed.entries.indices.contains(rekeyed.cursor),
              rekeyed.entries[rekeyed.cursor] == currentContent else {
            return .seeded(with: currentContent)
        }
        return rekeyed
    }
}
