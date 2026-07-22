import Foundation

// Spec C §5.1 — v1 uses documented typealiases; nominal wrappers can come
// later without wire-format change (all encode as UUID strings).
public typealias WorkspaceTabID = UUID
public typealias PanelID = UUID
public typealias SplitID = UUID
public typealias PanelOperationID = UUID

// MARK: - Content references (§5.3)

public enum FilePresentation: String, Codable, Sendable {
    case automatic, source, rendered
}

public struct FileReference: Codable, Sendable, Equatable {
    public var path: String
    public var presentation: FilePresentation
    public init(path: String, presentation: FilePresentation = .automatic) {
        self.path = path
        self.presentation = presentation
    }
}

/// Viewer-panel content. Deliberately has NO terminal case — Spec C §5.5's
/// "no terminal in any panel" invariant is enforced at the type level.
public enum PanelContent: Codable, Sendable, Equatable {
    case file(FileReference)
    case web(URL)
    case transcript(terminalID: UUID)
    case note(noteID: UUID)
}

/// A workspace tab's primary (anchor) content. Terminals are allowed ONLY
/// here (§5.2); the invariant is one-way — viewer content may also be primary.
public enum PrimaryContent: Codable, Sendable, Equatable {
    case terminal(terminalID: UUID)
    case note(noteID: UUID)
    case file(FileReference)
    case web(URL)
    case transcript(terminalID: UUID)
}

// MARK: - Layout tree (§5.2–5.4)

public struct PanelSlot: Codable, Sendable, Equatable, Identifiable {
    public let id: PanelID
    public var content: PanelContent
    public init(id: PanelID, content: PanelContent) {
        self.id = id
        self.content = content
    }
}

public struct SplitNode: Codable, Sendable, Equatable, Identifiable {
    public let id: SplitID
    public var direction: SplitDirection
    public var children: [PanelLayoutNode]
    public var ratios: [Double]
    public init(id: SplitID, direction: SplitDirection,
                children: [PanelLayoutNode], ratios: [Double]) {
        self.id = id
        self.direction = direction
        self.children = children
        self.ratios = ratios
    }
}

public indirect enum PanelLayoutNode: Codable, Sendable, Equatable {
    case primary
    case panel(PanelSlot)
    case split(SplitNode)

    public var primaryCount: Int {
        switch self {
        case .primary: return 1
        case .panel: return 0
        case .split(let split): return split.children.reduce(0) { $0 + $1.primaryCount }
        }
    }

    public var allPanelIDs: [PanelID] {
        switch self {
        case .primary: return []
        case .panel(let slot): return [slot.id]
        case .split(let split): return split.children.flatMap(\.allPanelIDs)
        }
    }

    public var allSplitIDs: [SplitID] {
        switch self {
        case .primary, .panel: return []
        case .split(let split):
            return [split.id] + split.children.flatMap(\.allSplitIDs)
        }
    }

    public func panelSlot(id: PanelID) -> PanelSlot? {
        switch self {
        case .primary: return nil
        case .panel(let slot): return slot.id == id ? slot : nil
        case .split(let split):
            for child in split.children {
                if let found = child.panelSlot(id: id) { return found }
            }
            return nil
        }
    }
}

// MARK: - Workspace tab aggregate (§5.2)

public struct WorkspaceTabSurface: Codable, Sendable, Equatable, Identifiable {
    public let id: WorkspaceTabID
    public let worktreeID: UUID
    public var label: String?
    public var primary: PrimaryContent
    public var layout: PanelLayoutNode
    public var revision: UInt64
    public init(id: WorkspaceTabID, worktreeID: UUID, label: String? = nil,
                primary: PrimaryContent, layout: PanelLayoutNode, revision: UInt64 = 0) {
        self.id = id
        self.worktreeID = worktreeID
        self.label = label
        self.primary = primary
        self.layout = layout
        self.revision = revision
    }
}

/// New-model per-panel navigation history (§6) — same MRU semantics PR #472
/// shipped, over durable `PanelContent` references.
public typealias PanelHistory = MRUHistory<PanelContent>
