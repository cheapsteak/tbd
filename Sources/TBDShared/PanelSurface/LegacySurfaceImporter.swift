import Foundation
import CoreGraphics

/// Spec C §11.2 — pure, single-tab conversion from the legacy layout model
/// (`LayoutNode`/`PaneContent`/`Tab`) to the new panel-surface model
/// (`WorkspaceTabSurface`/`PanelLayoutNode`). Multi-tab orchestration and
/// terminal-leaf promotion to new tabs is Task 4; this only counts the
/// terminals that need promoting.
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
        for tabID in tabOrder {
            guard let payload = byID[tabID] else { continue }
            switch convertTab(worktreeID: worktreeID, payload: payload,
                               paneHistories: paneHistories, makeID: makeID) {
            case .converted(let surface, let histories, let promoted):
                result.surfaces.append(surface)
                for (id, history) in histories { result.histories[id] = history }
                result.promotedTerminalTabs += promoted
            case .skipped(let reason):
                result.skipped.append(reason)
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
        case converted(WorkspaceTabSurface, [PanelID: PanelHistory], Int)
        case skipped(String)
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

    private static func convertTab(
        worktreeID: UUID, payload: LegacyTabPayload,
        paneHistories: [UUID: MRUHistory<PaneContent>], makeID: () -> UUID
    ) -> TabOutcome {
        let tree = payload.layout ?? .pane(payload.content)
        var primaryFound = false
        var promotedCount = 0
        var panelSources: [PanelSource] = []

        func convertNode(_ node: LayoutNode) -> PanelLayoutNode? {
            switch node {
            case .pane(let leaf):
                if !primaryFound && leaf.paneID == payload.content.paneID {
                    primaryFound = true
                    return .primary
                }
                switch leaf {
                case .terminal:
                    promotedCount += 1
                    return nil
                case .note(let noteID):
                    let newID = makeID()
                    let content = PanelContent.note(noteID: noteID)
                    panelSources.append(PanelSource(newID: newID, legacyHistoryKey: leaf.paneID, content: content))
                    return .panel(PanelSlot(id: newID, content: content))
                case .webview, .codeViewer, .liveTranscript:
                    guard let content = panelContent(from: leaf) else { return nil }
                    panelSources.append(PanelSource(newID: leaf.paneID, legacyHistoryKey: leaf.paneID, content: content))
                    return .panel(PanelSlot(id: leaf.paneID, content: content))
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
            return .skipped("tab \(payload.tabID): \(violations)")
        }
        return .converted(surface, histories, promotedCount)
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
