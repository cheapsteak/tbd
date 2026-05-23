// Sources/TBDApp/Panes/Transcript/TranscriptOverlayCoordinator.swift
import Combine
import Foundation

/// One frame of the transcript overlay state machine. Identifies the
/// transcript item to display and the terminal pane region the overlay
/// should render over. `terminalID` is nil when opened from the History
/// pane (no bound terminal — uses the window-root centered-modal fallback).
struct TranscriptOverlayFrame: Equatable {
    let terminalID: UUID?
    let itemID: String
}

/// At most one overlay open per window. Holds an optional one-step back
/// stack used by AgentCard's nested-transcript recursion: opening a row
/// inside an AgentCard overlay pushes the current frame and replaces it;
/// the back button pops.
@MainActor
final class TranscriptOverlayCoordinator: ObservableObject {
    @Published private(set) var openOverlay: TranscriptOverlayFrame?
    @Published private(set) var parentFrame: TranscriptOverlayFrame?

    /// Open or swap. If the requested frame matches what's already open,
    /// close instead (modal-ish toggle: same row click = dismiss).
    /// Swap clears any parent back-stack — the user has navigated away
    /// from the AgentCard context.
    func open(terminalID: UUID?, itemID: String) {
        let next = TranscriptOverlayFrame(terminalID: terminalID, itemID: itemID)
        if openOverlay == next {
            openOverlay = nil
            parentFrame = nil
            return
        }
        openOverlay = next
        parentFrame = nil
    }

    /// Push current frame to back-stack and open the new one over the
    /// same terminal. No-op if nothing is currently open. Called by row
    /// clicks INSIDE an AgentCard's overlay nested transcript.
    func pushAndOpen(itemID: String) {
        guard let current = openOverlay else { return }
        parentFrame = current
        openOverlay = TranscriptOverlayFrame(terminalID: current.terminalID, itemID: itemID)
    }

    /// Restore the back-stack frame. If no parent, close the overlay.
    func popOverlay() {
        if let parent = parentFrame {
            openOverlay = parent
            parentFrame = nil
        } else {
            close()
        }
    }

    func close() {
        openOverlay = nil
        parentFrame = nil
    }
}
