import Foundation

/// Spec C §5/§6 — a workspace tab's panel layout plus each panel's
/// navigation history, keyed by `PanelID`. This is the aggregate the
/// reducer operates on; `WorkspaceTabSurface` alone can't answer "what's
/// panel X's back/forward state".
public struct PanelSurfaceState: Codable, Sendable, Equatable {
    public var surface: WorkspaceTabSurface
    public var histories: [PanelID: PanelHistory]
    public init(surface: WorkspaceTabSurface, histories: [PanelID: PanelHistory]) {
        self.surface = surface
        self.histories = histories
    }
}

public enum PanelOperationError: Error, Equatable, Sendable {
    case panelNotFound(PanelID)
    case splitNotFound(SplitID)
    case anchorNotFound
    case invalidRatios(reason: String)
    case invalidPlacement(reason: String)
    case historyUnavailable(PanelID)
    case notTabScoped
}

/// Pure reducer for Spec C §7.3 panel operations. No clock, no I/O — every
/// `apply` call either returns a fully valid new state or throws, leaving
/// the input `state` untouched (value semantics: `apply` only ever mutates
/// a local copy, so a thrown error can't have touched the caller's value).
public enum PanelSurfaceReducer {
    public static let defaultSideShare = 0.35

    public static func apply(
        _ operation: PanelOperation, to state: PanelSurfaceState,
        makeID: () -> UUID = { UUID() }
    ) throws -> PanelSurfaceState {
        var next = state
        switch operation {
        case .open(let content, let placement):
            try applyOpen(content: content, placement: placement, to: &next, makeID: makeID)
        case .navigate(let panelID, let destination):
            try applyNavigate(panelID: panelID, destination: destination, to: &next)
        case .history(let panelID, let action):
            try applyHistory(panelID: panelID, action: action, to: &next)
        case .selectTab:
            throw PanelOperationError.notTabScoped
        case .close, .move, .resize:
            throw PanelOperationError.invalidPlacement(reason: "unimplemented")
        }
        next.surface.revision += 1
        return next
    }

    // MARK: - open

    private static func applyOpen(
        content: PanelContent, placement: PanelPlacement,
        to state: inout PanelSurfaceState, makeID: () -> UUID
    ) throws {
        switch placement {
        case .automatic:
            if let existing = firstPanelSlot(in: state.surface.layout) {
                try applyNavigate(panelID: existing.id, destination: content, to: &state)
            } else {
                try applyOpen(
                    content: content,
                    placement: .beside(target: .primary, edge: .right, share: nil),
                    to: &state, makeID: makeID)
            }
        case .replace(let panelID):
            try applyNavigate(panelID: panelID, destination: content, to: &state)
        case .beside(let target, let edge, let share):
            let shareValue = share ?? defaultSideShare
            let newSlot = PanelSlot(id: makeID(), content: content)
            guard let updatedTree = inserting(
                .panel(newSlot), beside: target, edge: edge, share: shareValue,
                in: state.surface.layout, makeID: makeID
            ) else {
                throw PanelOperationError.anchorNotFound
            }
            state.surface.layout = updatedTree
            state.histories[newSlot.id] = .seeded(with: content)
        }
    }

    // MARK: - navigate

    private static func applyNavigate(
        panelID: PanelID, destination: PanelContent, to state: inout PanelSurfaceState
    ) throws {
        guard let slot = state.surface.layout.panelSlot(id: panelID) else {
            throw PanelOperationError.panelNotFound(panelID)
        }
        let oldContent = slot.content
        guard let updatedTree = replacingContent(
            of: panelID, with: destination, in: state.surface.layout
        ) else {
            throw PanelOperationError.panelNotFound(panelID)
        }
        state.surface.layout = updatedTree
        var history = state.histories[panelID] ?? .seeded(with: oldContent)
        history.recordReplacement(outgoing: oldContent, incoming: destination)
        state.histories[panelID] = history
    }

    // MARK: - history

    private static func applyHistory(
        panelID: PanelID, action: PanelHistoryAction, to state: inout PanelSurfaceState
    ) throws {
        guard var history = state.histories[panelID] else {
            throw PanelOperationError.historyUnavailable(panelID)
        }
        let moved: PanelContent?
        switch action {
        case .back: moved = history.goBack()
        case .forward: moved = history.goForward()
        case .jump(let index): moved = history.go(to: index)
        }
        guard let content = moved else {
            throw PanelOperationError.historyUnavailable(panelID)
        }
        guard let updatedTree = replacingContent(
            of: panelID, with: content, in: state.surface.layout
        ) else {
            throw PanelOperationError.historyUnavailable(panelID)
        }
        state.surface.layout = updatedTree
        state.histories[panelID] = history
    }

    // MARK: - tree edit helpers

    /// Insert `node` beside the anchor. Returns nil when the anchor is absent.
    private static func inserting(
        _ node: PanelLayoutNode, beside anchor: PanelAnchor,
        edge: PanelEdge, share: Double, in tree: PanelLayoutNode,
        makeID: () -> UUID
    ) -> PanelLayoutNode? {
        if matches(tree, anchor: anchor) {
            return wrapped(node: node, around: tree, edge: edge, share: share, makeID: makeID)
        }
        guard case .split(var split) = tree else { return nil }
        let splitAxis = axis(for: edge)
        let insertBefore = edge == .left || edge == .above

        if let index = split.children.firstIndex(where: { matches($0, anchor: anchor) }) {
            if split.direction == splitAxis {
                let insertIndex = insertBefore ? index : index + 1
                split.children.insert(node, at: insertIndex)
                var ratios = split.ratios.map { $0 * (1 - share) }
                ratios.insert(share, at: insertIndex)
                split.ratios = ratios
            } else {
                split.children[index] = wrapped(
                    node: node, around: split.children[index],
                    edge: edge, share: share, makeID: makeID)
            }
            return .split(split)
        }

        for (index, child) in split.children.enumerated() {
            if let updated = inserting(
                node, beside: anchor, edge: edge, share: share, in: child, makeID: makeID
            ) {
                split.children[index] = updated
                return .split(split)
            }
        }
        return nil
    }

    /// Replace panel slot content in place. Returns nil when the id is absent.
    private static func replacingContent(
        of panelID: PanelID, with content: PanelContent, in tree: PanelLayoutNode
    ) -> PanelLayoutNode? {
        switch tree {
        case .primary:
            return nil
        case .panel(let slot):
            guard slot.id == panelID else { return nil }
            return .panel(PanelSlot(id: slot.id, content: content))
        case .split(var split):
            for (index, child) in split.children.enumerated() {
                if let updated = replacingContent(of: panelID, with: content, in: child) {
                    split.children[index] = updated
                    return .split(split)
                }
            }
            return nil
        }
    }

    /// First panel slot in pre-order, if any.
    private static func firstPanelSlot(in tree: PanelLayoutNode) -> PanelSlot? {
        switch tree {
        case .primary:
            return nil
        case .panel(let slot):
            return slot
        case .split(let split):
            for child in split.children {
                if let found = firstPanelSlot(in: child) { return found }
            }
            return nil
        }
    }

    private static func matches(_ node: PanelLayoutNode, anchor: PanelAnchor) -> Bool {
        switch (node, anchor) {
        case (.primary, .primary): return true
        case (.panel(let slot), .panel(let id)): return slot.id == id
        default: return false
        }
    }

    private static func wrapped(
        node: PanelLayoutNode, around existing: PanelLayoutNode,
        edge: PanelEdge, share: Double, makeID: () -> UUID
    ) -> PanelLayoutNode {
        let newFirst = edge == .left || edge == .above
        let children = newFirst ? [node, existing] : [existing, node]
        let ratios = newFirst ? [share, 1 - share] : [1 - share, share]
        return .split(SplitNode(id: makeID(), direction: axis(for: edge),
                                 children: children, ratios: ratios))
    }

    private static func axis(for edge: PanelEdge) -> SplitDirection {
        switch edge {
        case .left, .right: return .horizontal
        case .above, .below: return .vertical
        }
    }
}
