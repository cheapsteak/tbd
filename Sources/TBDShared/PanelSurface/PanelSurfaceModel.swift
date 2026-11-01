import Foundation

// Spec C §5.1 — v1 uses documented typealiases; nominal wrappers can come
// later without wire-format change (all encode as UUID strings).
public typealias WorkspaceTabID = UUID
public typealias PanelID = UUID
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
///
/// File, web and transcript content is shown by a workspace tab's own panels;
/// note and Changes content only by the worktree's panels
/// (`WorktreePanelContent`).
public enum PanelContent: Codable, Sendable, Equatable {
    case file(FileReference)
    case web(URL)
    case transcript(terminalID: UUID)
    case note(noteID: UUID)
    /// The worktree's Changes list: staged, changed, untracked and branch
    /// files.
    case changes
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

/// A viewer panel's kind, read from its content. A panel's kind is fixed for
/// its lifetime: navigating or reusing a panel keeps it, so a file never lands
/// in a transcript's tab and a transcript never lands in a file's tab.
public enum PanelKind: String, Codable, Sendable {
    case file, web, note, transcript, changes
}

extension PanelContent {
    public var kind: PanelKind {
        switch self {
        case .file: return .file
        case .web: return .web
        case .note: return .note
        case .transcript: return .transcript
        case .changes: return .changes
        }
    }
}

// MARK: - Worktree panels (side panel notes spec, "The model")

/// The content a worktree panel shows: a note or the Changes list. Each is
/// shown by at most one worktree panel, and never by a workspace tab's own
/// panel.
public enum WorktreePanelContent: Codable, Sendable, Equatable, Hashable {
    case note(noteID: UUID)
    case changes

    /// The worktree content `content` names; nil for file, web and transcript
    /// content, which only a workspace tab's own panels show.
    public init?(_ content: PanelContent) {
        switch content {
        case .note(let noteID): self = .note(noteID: noteID)
        case .changes: self = .changes
        case .file, .web, .transcript: return nil
        }
    }

    /// The same content in the panel operations' vocabulary.
    public var panelContent: PanelContent {
        switch self {
        case .note(let noteID): return .note(noteID: noteID)
        case .changes: return .changes
        }
    }
}

/// One tab in the side strip that belongs to the whole worktree: every
/// workspace tab of the worktree carries the same ordered list, and its strip
/// shows these before the tab's own panels. It has no history: it shows one
/// piece of content for its whole life.
public struct WorktreePanel: Codable, Sendable, Equatable, Identifiable {
    public let id: PanelID
    public var content: WorktreePanelContent

    public init(id: PanelID, content: WorktreePanelContent) {
        self.id = id
        self.content = content
    }
}

/// Per-panel navigation history (spec C §6) — same MRU semantics PR #472
/// shipped, over durable `PanelContent` references.
public typealias PanelHistory = MRUHistory<PanelContent>

// MARK: - Side region (panel tabs spec, "The model")

/// One tab in the side region's strip. It stores no content of its own: what
/// it shows is its history's cursor entry, so there is no copy to keep in step.
public struct ViewerPanel: Codable, Sendable, Equatable, Identifiable {
    public let id: PanelID
    public var history: PanelHistory

    /// The content shown — `history.current`. Nil only when the history is
    /// empty or malformed, which in-process operations never produce; decoded
    /// bad data reads as nil rather than trapping on an out-of-range cursor.
    public var content: PanelContent? { history.current }

    /// A new panel whose history holds only `content`.
    public init(id: PanelID, content: PanelContent) {
        self.id = id
        self.history = .seeded(with: content)
    }

    public init(id: PanelID, history: PanelHistory) {
        self.id = id
        self.history = history
    }
}

/// The region beside a workspace tab's primary. It is always present; with no
/// panels of its own and no worktree panels it is hidden.
public struct SideRegion: Codable, Sendable, Equatable {
    /// The legacy divider's limit, as a share of the workspace tab's width.
    public static let widthRange: ClosedRange<Double> = 0.1...0.9
    public static let defaultWidth = 0.5
    public static let empty = SideRegion()

    /// The tab's own panels, in tab-strip order, left to right. The strip
    /// shows them after the worktree's panels.
    public var panels: [ViewerPanel]
    /// The panel in front: one in `panels` or one of the surface's
    /// `worktreePanels`, chosen per workspace tab. Nil exactly when there is
    /// neither.
    public var activePanelID: PanelID?
    /// The IDs of `panels`, most recent first; drives reuse and the next
    /// active panel after a close. Worktree panels take no part in it. An
    /// ordered list rather than timestamps, so the reducer needs no clock.
    public var recency: [PanelID]
    /// Hidden with its panels kept, the worktree's panels included.
    public var collapsed: Bool
    /// Share of the workspace tab's width, within `widthRange`.
    public var width: Double

    public init(panels: [ViewerPanel] = [], activePanelID: PanelID? = nil,
                recency: [PanelID] = [], collapsed: Bool = false,
                width: Double = SideRegion.defaultWidth) {
        self.panels = panels
        self.activePanelID = activePanelID
        self.recency = recency
        self.collapsed = collapsed
        self.width = width
    }

    /// A width the model accepts: clamped to `widthRange`, or `defaultWidth`
    /// when not finite. The one clamp the legacy converter and the divider
    /// share.
    public static func clamp(_ width: Double) -> Double {
        guard width.isFinite else { return defaultWidth }
        return min(max(width, widthRange.lowerBound), widthRange.upperBound)
    }

    /// The tab's own panel with this ID; nil for a worktree panel's ID.
    public func panel(id: PanelID) -> ViewerPanel? {
        panels.first { $0.id == id }
    }

    /// True while the tab's own panels show. It does not see worktree
    /// panels; `WorkspaceTabSurface.isSideVisible` does.
    public var isVisible: Bool { !panels.isEmpty && !collapsed }
}

// MARK: - Workspace tab aggregate

/// Everything inside one workspace tab: its primary, one side region, and
/// the worktree's panels, which every workspace tab of the worktree carries
/// alike. Which workspace tabs exist, their order and selection stay
/// app-owned; the tab's position is a store column, not a field here.
public struct WorkspaceTabSurface: Codable, Sendable, Equatable, Identifiable {
    /// The workspace tab's ID (the spec's `tabID`).
    public let id: WorkspaceTabID
    public let worktreeID: UUID
    public var label: String?
    public var primary: PrimaryContent
    public var side: SideRegion
    /// The worktree's panels, in strip order. The same list on every
    /// workspace tab of the worktree; the panel in front, collapse and
    /// recency stay the tab's, in `side`.
    public var worktreePanels: [WorktreePanel]
    /// Daemon-wide and monotonic: the daemon stores every write at the next
    /// value of one counter, so of two snapshots of a tab the higher revision
    /// is the newer, even across a delete and re-import.
    public var revision: UInt64

    public init(id: WorkspaceTabID, worktreeID: UUID, label: String? = nil,
                primary: PrimaryContent, side: SideRegion = .empty,
                worktreePanels: [WorktreePanel] = [], revision: UInt64 = 0) {
        self.id = id
        self.worktreeID = worktreeID
        self.label = label
        self.primary = primary
        self.side = side
        self.worktreePanels = worktreePanels
        self.revision = revision
    }

    private enum CodingKeys: String, CodingKey {
        case id, worktreeID, label, primary, side, worktreePanels, revision
    }

    /// Decodes a missing `worktreePanels` as no worktree panels, so a surface
    /// encoded by a build that predates them still decodes.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try container.decode(WorkspaceTabID.self, forKey: .id)
        self.worktreeID = try container.decode(UUID.self, forKey: .worktreeID)
        self.label = try container.decodeIfPresent(String.self, forKey: .label)
        self.primary = try container.decode(PrimaryContent.self, forKey: .primary)
        self.side = try container.decode(SideRegion.self, forKey: .side)
        self.worktreePanels = try container.decodeIfPresent(
            [WorktreePanel].self, forKey: .worktreePanels) ?? []
        self.revision = try container.decode(UInt64.self, forKey: .revision)
    }

    /// True when the side strip has any tab: the tab's own or the worktree's.
    public var hasPanels: Bool { !side.panels.isEmpty || !worktreePanels.isEmpty }

    /// True while the side region shows: it has a panel and is not collapsed.
    public var isSideVisible: Bool { hasPanels && !side.collapsed }

    /// The worktree panel with this ID; nil for an own panel's ID.
    public func worktreePanel(id: PanelID) -> WorktreePanel? {
        worktreePanels.first { $0.id == id }
    }

    /// The worktree panel showing `content`, if one does: there is at most
    /// one.
    public func worktreePanel(showing content: WorktreePanelContent) -> WorktreePanel? {
        worktreePanels.first { $0.content == content }
    }
}
