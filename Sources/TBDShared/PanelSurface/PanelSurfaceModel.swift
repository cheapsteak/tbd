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

/// A viewer panel's kind, read from its content. A panel's kind is fixed for
/// its lifetime: navigating or reusing a panel keeps it, so a file never lands
/// in a transcript's tab and a transcript never lands in a file's tab.
public enum PanelKind: String, Codable, Sendable {
    case file, web, note, transcript
}

extension PanelContent {
    public var kind: PanelKind {
        switch self {
        case .file: return .file
        case .web: return .web
        case .note: return .note
        case .transcript: return .transcript
        }
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
/// panels it is hidden.
public struct SideRegion: Codable, Sendable, Equatable {
    /// The legacy divider's limit, as a share of the workspace tab's width.
    public static let widthRange: ClosedRange<Double> = 0.1...0.9
    public static let defaultWidth = 0.5
    public static let empty = SideRegion()

    /// Tab-strip order, left to right.
    public var panels: [ViewerPanel]
    /// Names a panel in `panels`; nil exactly when `panels` is empty.
    public var activePanelID: PanelID?
    /// The panel IDs, most recent first; drives reuse and the next active
    /// panel after a close. An ordered list rather than timestamps, so the
    /// reducer needs no clock.
    public var recency: [PanelID]
    /// Hidden with its panels kept.
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

    public func panel(id: PanelID) -> ViewerPanel? {
        panels.first { $0.id == id }
    }

    public var isVisible: Bool { !panels.isEmpty && !collapsed }
}

// MARK: - Workspace tab aggregate

/// Everything inside one workspace tab: its primary plus one side region.
/// Which workspace tabs exist, their order and selection stay app-owned; the
/// tab's position is a store column, not a field here.
public struct WorkspaceTabSurface: Codable, Sendable, Equatable, Identifiable {
    /// The workspace tab's ID (the spec's `tabID`).
    public let id: WorkspaceTabID
    public let worktreeID: UUID
    public var label: String?
    public var primary: PrimaryContent
    public var side: SideRegion
    /// Daemon-wide and monotonic: the daemon stores every write at the next
    /// value of one counter, so of two snapshots of a tab the higher revision
    /// is the newer, even across a delete and re-import.
    public var revision: UInt64

    public init(id: WorkspaceTabID, worktreeID: UUID, label: String? = nil,
                primary: PrimaryContent, side: SideRegion = .empty, revision: UInt64 = 0) {
        self.id = id
        self.worktreeID = worktreeID
        self.label = label
        self.primary = primary
        self.side = side
        self.revision = revision
    }
}
