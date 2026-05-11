import CoreGraphics

/// Shared layout constants for transcript row cards (BashCard, WriteCard, …).
/// Centralized so tuning the expanded cap doesn't require touching every card.
/// The expanded cap is intentionally finite (not .infinity) so _FlexFrameLayout
/// short-circuits inside LazyVStack — see issue #129.
enum TranscriptCardLayout {
    /// Max height of an expanded scrollable card body. Generous for typical
    /// bash/write output; bounded so the LazyVStack containing the card
    /// doesn't recursively measure the inner ScrollView's full content.
    static let expandedMaxHeight: CGFloat = 600

    /// Max height of a collapsed scrollable card body. Roughly six lines of
    /// caption-monospaced text — enough to preview without dominating the row.
    static let collapsedMaxHeight: CGFloat = 120
}
