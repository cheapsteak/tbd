import SwiftUI

/// Shared `OpenURLAction` for markdown rendered inside the transcript
/// overlay. Intercepts `tbd-file:` (linkifier output) and `file:` URLs
/// by pushing a file frame onto the overlay coordinator; everything
/// else falls through to the system handler.
///
/// Lives in one place so adding a new in-overlay scheme later
/// (e.g. `tbd-item:` deep-links) only touches one site instead of
/// every markdown-rendering view that wants the same behaviour.
@MainActor
func overlayFileLinkAction(_ coordinator: TranscriptOverlayCoordinator) -> OpenURLAction {
    OpenURLAction { url in
        if url.scheme == "tbd-file" {
            coordinator.pushFile(path: url.path)
            return .handled
        }
        if url.isFileURL {
            coordinator.pushFile(path: url.path)
            return .handled
        }
        return .systemAction
    }
}
