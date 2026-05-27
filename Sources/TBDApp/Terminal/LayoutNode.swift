import Foundation
import CoreGraphics

// MARK: - SplitDirection

enum SplitDirection: String, Codable, Sendable {
    case horizontal, vertical
}

// MARK: - LayoutNode

indirect enum LayoutNode: Equatable, Sendable {
    case pane(PaneContent)
    case split(direction: SplitDirection, children: [LayoutNode], ratios: [CGFloat])

    // MARK: - Helpers

    /// Finds the pane with the given ID and replaces it with a split
    /// containing the original + new pane at 50/50 ratio.
    func splitPane(id: UUID, direction: SplitDirection, newContent: PaneContent) -> LayoutNode {
        switch self {
        case .pane(let content):
            if content.paneID == id {
                return .split(
                    direction: direction,
                    children: [
                        .pane(content),
                        .pane(newContent),
                    ],
                    ratios: [0.5, 0.5]
                )
            }
            return self

        case .split(let dir, let children, let ratios):
            let newChildren = children.map { child in
                child.splitPane(id: id, direction: direction, newContent: newContent)
            }
            return .split(direction: dir, children: newChildren, ratios: ratios)
        }
    }

    /// Removes a pane, simplifying the tree. If a split has one child left,
    /// unwrap it. Returns nil if the last pane is removed.
    func removePane(id: UUID) -> LayoutNode? {
        switch self {
        case .pane(let content):
            if content.paneID == id {
                return nil
            }
            return self

        case .split(let direction, let children, let ratios):
            var newChildren: [LayoutNode] = []
            var newRatios: [CGFloat] = []

            for (index, child) in children.enumerated() {
                if let remaining = child.removePane(id: id) {
                    newChildren.append(remaining)
                    newRatios.append(ratios[index])
                }
            }

            if newChildren.isEmpty {
                return nil
            }

            if newChildren.count == 1 {
                return newChildren[0]
            }

            // Renormalize ratios so they sum to 1.0
            let total = newRatios.reduce(0, +)
            if total > 0 {
                newRatios = newRatios.map { $0 / total }
            }

            return .split(direction: direction, children: newChildren, ratios: newRatios)
        }
    }

    /// Flat list of all pane IDs in the tree.
    func allPaneIDs() -> [UUID] {
        switch self {
        case .pane(let content):
            return [content.paneID]
        case .split(_, let children, _):
            return children.flatMap { $0.allPaneIDs() }
        }
    }

    // MARK: - Backward-compatible convenience

    /// Flat list of all terminal IDs in the tree (terminals only).
    func allTerminalIDs() -> [UUID] {
        switch self {
        case .pane(let content):
            if case .terminal(let id) = content {
                return [id]
            }
            return []
        case .split(_, let children, _):
            return children.flatMap { $0.allTerminalIDs() }
        }
    }

    /// Returns a copy of the layout with terminal panes outside `allowedIDs`
    /// removed. Non-terminal panes are preserved. If every pane is removed,
    /// returns nil.
    func removingTerminalPanes(notIn allowedIDs: Set<UUID>) -> LayoutNode? {
        switch self {
        case .pane(let content):
            if case .terminal(let id) = content, !allowedIDs.contains(id) {
                return nil
            }
            return self

        case .split(let direction, let children, let ratios):
            var keptChildren: [LayoutNode] = []
            var keptRatios: [CGFloat] = []

            for (index, child) in children.enumerated() {
                if let kept = child.removingTerminalPanes(notIn: allowedIDs) {
                    keptChildren.append(kept)
                    keptRatios.append(ratios[index])
                }
            }

            if keptChildren.isEmpty {
                return nil
            }
            if keptChildren.count == 1 {
                return keptChildren[0]
            }

            let total = keptRatios.reduce(0, +)
            if total > 0 {
                keptRatios = keptRatios.map { $0 / total }
            }

            return .split(direction: direction, children: keptChildren, ratios: keptRatios)
        }
    }
}

// MARK: - Pane lookup / replacement helpers

extension LayoutNode {
    /// Returns the id of the first pane (in pre-order, left-to-right traversal)
    /// whose content matches the predicate, or nil if none match.
    func firstPaneID(where predicate: (PaneContent) -> Bool) -> UUID? {
        switch self {
        case .pane(let content):
            return predicate(content) ? content.paneID : nil
        case .split(_, let children, _):
            for child in children {
                if let found = child.firstPaneID(where: predicate) {
                    return found
                }
            }
            return nil
        }
    }

    /// Returns a copy of the tree with the pane identified by `paneID` replaced
    /// by `newContent`. Sibling panes and split ratios are preserved exactly.
    /// Returns nil if no pane has that id.
    func replacingContent(at paneID: UUID, with newContent: PaneContent) -> LayoutNode? {
        switch self {
        case .pane(let content):
            return content.paneID == paneID ? .pane(newContent) : nil

        case .split(let direction, let children, let ratios):
            var newChildren = children
            var replaced = false
            for (index, child) in children.enumerated() {
                if let updated = child.replacingContent(at: paneID, with: newContent) {
                    newChildren[index] = updated
                    replaced = true
                    break
                }
            }
            return replaced
                ? .split(direction: direction, children: newChildren, ratios: ratios)
                : nil
        }
    }
}

// MARK: - Codable (manual conformance for indirect enum)

extension LayoutNode: Codable {
    private enum CodingKeys: String, CodingKey {
        case type
        case terminalID    // legacy key for backward compat
        case paneContent   // new key
        case direction
        case children
        case ratios
    }

    private enum NodeType: String, Codable {
        case terminal  // legacy
        case pane
        case split
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let type = try container.decode(NodeType.self, forKey: .type)

        switch type {
        case .terminal:
            // Backward compat: old format {"type":"terminal","terminalID":"..."}
            let terminalID = try container.decode(UUID.self, forKey: .terminalID)
            self = .pane(.terminal(terminalID: terminalID))
        case .pane:
            let content = try container.decode(PaneContent.self, forKey: .paneContent)
            self = .pane(content)
        case .split:
            let direction = try container.decode(SplitDirection.self, forKey: .direction)
            let children = try container.decode([LayoutNode].self, forKey: .children)
            let ratios = try container.decode([CGFloat].self, forKey: .ratios)
            self = .split(direction: direction, children: children, ratios: ratios)
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)

        switch self {
        case .pane(let content):
            try container.encode(NodeType.pane, forKey: .type)
            try container.encode(content, forKey: .paneContent)
        case .split(let direction, let children, let ratios):
            try container.encode(NodeType.split, forKey: .type)
            try container.encode(direction, forKey: .direction)
            try container.encode(children, forKey: .children)
            try container.encode(ratios, forKey: .ratios)
        }
    }
}
