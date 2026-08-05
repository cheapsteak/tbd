import Foundation

/// A transient in-app toast. One toast is visible at a time
/// (`AppState.activeToast`); showing a new one replaces the current.
/// First client: deep-link navigation to archived worktrees.
struct Toast: Equatable, Identifiable {
    enum Style: Equatable {
        /// Indeterminate work in progress (spinner).
        case progress
        /// Informational notice (archivebox icon); auto-dismisses.
        case notice
        /// A completed action the user just triggered (checkmark); auto-dismisses.
        case success
        /// Failure notice; auto-dismisses.
        case error
    }

    let id: UUID
    var message: String
    var style: Style
}
