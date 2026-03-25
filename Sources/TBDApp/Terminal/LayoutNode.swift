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
