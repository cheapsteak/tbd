import Foundation

// MARK: - PaneContent

/// Legacy pane-content model (Phase 1). Spec C's successor is `PanelContent`
/// in `PanelSurfaceModel.swift` — note the deliberate one-letter difference:
/// `Pane*` is legacy, `Panel*` is the new model.
public enum PaneContent: Codable, Equatable, Sendable {
    case terminal(terminalID: UUID)
    case webview(id: UUID, url: URL)
    case codeViewer(id: UUID, path: String)
    case note(noteID: UUID)
    case liveTranscript(id: UUID, terminalID: UUID)

    public var paneID: UUID {
        switch self {
        case .terminal(let id): return id
        case .webview(let id, _): return id
        case .codeViewer(let id, _): return id
        case .note(let id): return id
        case .liveTranscript(let id, _): return id
        }
    }

    /// Viewer-class panes form one interchangeable "slot" per tab:
    /// content-navigation gestures replace within the slot (preserving the
    /// pane UUID); explicit split gestures still create new panes.
    public var isViewerClass: Bool {
        switch self {
        case .codeViewer, .webview, .liveTranscript: return true
        case .terminal, .note: return false
        }
    }
}

// MARK: - Tab

/// Collides in name with `SwiftUI.Tab` (the macOS 15 `TabView` builder), so
/// app call sites qualify this as `TBDShared.Tab`. Legacy type; successor is
/// `WorkspaceTabSurface`.
public struct Tab: Identifiable, Codable, Equatable, Sendable {
    public let id: UUID
    public var content: PaneContent
    public var label: String?

    public init(id: UUID, content: PaneContent, label: String? = nil) {
        self.id = id
        self.content = content
        self.label = label
    }
}
