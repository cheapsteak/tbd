import Foundation

// MARK: - PaneContent

enum PaneContent: Codable, Equatable, Sendable {
    case terminal(terminalID: UUID)
    case webview(id: UUID, url: URL)
    case codeViewer(id: UUID, path: String)

    var paneID: UUID {
        switch self {
        case .terminal(let id): return id
        case .webview(let id, _): return id
        case .codeViewer(let id, _): return id
        }
    }
}

// MARK: - Tab

struct Tab: Identifiable, Codable, Equatable, Sendable {
    let id: UUID
    var content: PaneContent
    var label: String?
}
