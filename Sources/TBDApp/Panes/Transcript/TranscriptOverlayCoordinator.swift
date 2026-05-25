// Sources/TBDApp/Panes/Transcript/TranscriptOverlayCoordinator.swift
import Combine
import Foundation

/// Identifies a transcript item the overlay should render. `terminalID` is
/// nil when opened from the History pane; in that case `historySessionID`
/// carries the session whose transcript is being viewed.
struct ItemFrame: Equatable {
    let terminalID: UUID?
    let itemID: String
    let historySessionID: String?

    init(terminalID: UUID?, itemID: String, historySessionID: String? = nil) {
        self.terminalID = terminalID
        self.itemID = itemID
        self.historySessionID = historySessionID
    }
}

/// One frame of the overlay navigation stack: either a transcript item
/// or a local file. The overlay view branches on this to choose between
/// the existing tool-body renderer and the new `OverlayFileView`.
enum OverlayFrame: Equatable {
    case item(ItemFrame)
    case file(path: String)
}

/// At most one overlay open per window. Maintains a navigation stack so
/// the user can drill from an Agent tool call into a subagent item, and
/// from either into a referenced local file (and from that file into
/// further linked files).
///
/// Tapping the same item frame currently at the top toggles the overlay
/// closed — preserves the existing "click same row to dismiss" behaviour.
/// File frames always push (you cannot toggle-close a file frame by
/// reopening the same link).
@MainActor
final class TranscriptOverlayCoordinator: ObservableObject {
    @Published private(set) var stack: [OverlayFrame] = []

    var current: OverlayFrame? { stack.last }
    var hasBack: Bool { stack.count > 1 }
    var isOpen: Bool { !stack.isEmpty }

    /// Top-level open. Clears any prior stack. If the same item is already
    /// at the top of the stack, toggles closed.
    func open(terminalID: UUID?, itemID: String, historySessionID: String? = nil) {
        let frame = ItemFrame(
            terminalID: terminalID,
            itemID: itemID,
            historySessionID: historySessionID
        )
        if case .item(let top)? = current, top == frame {
            stack.removeAll()
            return
        }
        stack = [.item(frame)]
    }

    /// Push another transcript item, inheriting the current frame's
    /// terminal/session context. No-op if nothing is open or if the
    /// current top is not an item frame.
    func pushItem(itemID: String) {
        guard let top = current, case .item(let frame) = top else { return }
        stack.append(.item(ItemFrame(
            terminalID: frame.terminalID,
            itemID: itemID,
            historySessionID: frame.historySessionID
        )))
    }

    /// Push a local file frame. No-op if nothing is open.
    func pushFile(path: String) {
        guard isOpen else { return }
        stack.append(.file(path: path))
    }

    /// Pop one frame. Closes the overlay when the stack empties.
    func pop() {
        guard !stack.isEmpty else { return }
        stack.removeLast()
    }

    func close() {
        stack.removeAll()
    }
}
