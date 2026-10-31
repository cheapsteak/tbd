import Foundation

/// Pure reveal rules shared by both sidebar paths: the SwiftUI `List` in
/// `SidebarView` and the native outline.
enum SidebarReveal {
    /// The `previous` handed to `revealSidebarGroups` for a selection-reveal
    /// change. Nil — reveal as navigation, expanding a collapsed owning
    /// section — only on the initial mount. Turning the toggle on mid-session
    /// moves the observed value from nil to a reveal; that compares the
    /// reveal against itself, so it opens the selection's groups but never
    /// overrides a section the user collapsed.
    static func baseline(
        previous: SidebarGroupReveal?, reveal: SidebarGroupReveal, hasRevealed: Bool
    ) -> SidebarGroupReveal? {
        hasRevealed ? (previous ?? reveal) : nil
    }
}
