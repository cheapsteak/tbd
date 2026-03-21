import Foundation
import CoreGraphics

// MARK: - SplitDirection

enum SplitDirection: String, Codable, Sendable {
    case horizontal, vertical
}

// MARK: - LayoutNode

indirect enum LayoutNode: Equatable, Sendable {
    case terminal(terminalID: UUID)
    case split(direction: SplitDirection, children: [LayoutNode], ratios: [CGFloat])

    // MARK: - Helpers

    /// Finds the terminal node with the given ID and replaces it with a split
    /// containing the original + new terminal at 50/50 ratio.
    func splitTerminal(id: UUID, direction: SplitDirection, newTerminalID: UUID) -> LayoutNode {
        switch self {
        case .terminal(let terminalID):
            if terminalID == id {
                return .split(
                    direction: direction,
                    children: [
                        .terminal(terminalID: terminalID),
                        .terminal(terminalID: newTerminalID),
                    ],
                    ratios: [0.5, 0.5]
                )
            }
            return self

        case .split(let dir, let children, let ratios):
            let newChildren = children.map { child in
                child.splitTerminal(id: id, direction: direction, newTerminalID: newTerminalID)
            }
            return .split(direction: dir, children: newChildren, ratios: ratios)
        }
    }

    /// Removes a terminal, simplifying the tree. If a split has one child left,
    /// unwrap it. Returns nil if the last terminal is removed.
    func removeTerminal(id: UUID) -> LayoutNode? {
        switch self {
        case .terminal(let terminalID):
            if terminalID == id {
                return nil
            }
            return self

        case .split(let direction, let children, let ratios):
            var newChildren: [LayoutNode] = []
            var newRatios: [CGFloat] = []

            for (index, child) in children.enumerated() {
                if let remaining = child.removeTerminal(id: id) {
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

    /// Flat list of all terminal IDs in the tree.
    func allTerminalIDs() -> [UUID] {
        switch self {
        case .terminal(let terminalID):
            return [terminalID]
        case .split(_, let children, _):
            return children.flatMap { $0.allTerminalIDs() }
        }
    }
}

// MARK: - Codable (manual conformance for indirect enum)

extension LayoutNode: Codable {
    private enum CodingKeys: String, CodingKey {
        case type
        case terminalID
        case direction
        case children
        case ratios
    }

    private enum NodeType: String, Codable {
        case terminal, split
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let type = try container.decode(NodeType.self, forKey: .type)

        switch type {
        case .terminal:
            let terminalID = try container.decode(UUID.self, forKey: .terminalID)
            self = .terminal(terminalID: terminalID)
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
        case .terminal(let terminalID):
            try container.encode(NodeType.terminal, forKey: .type)
            try container.encode(terminalID, forKey: .terminalID)
        case .split(let direction, let children, let ratios):
            try container.encode(NodeType.split, forKey: .type)
            try container.encode(direction, forKey: .direction)
            try container.encode(children, forKey: .children)
            try container.encode(ratios, forKey: .ratios)
        }
    }
}
