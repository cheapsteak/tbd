import CoreGraphics
import Foundation

/// The Remote pane's earlier-history state, as the card's "Earlier prompts not
/// loaded" row needs it. Nil wherever history is never paged in.
struct PromptRailEarlierHistory {
    /// Whether history above the loaded window can still be loaded.
    let hasEarlier: Bool
    /// The pane's existing load-earlier action, the one its "Load earlier
    /// messages" header button calls. Only the card's Load row calls it; the
    /// rail never loads history by itself.
    let load: @MainActor () -> Void
}

/// What `TableTranscriptView` mounts for the prompt rail.
enum PromptRailMount {
    /// No rail and no gutter: tests and harnesses that drive the table alone.
    case none
    /// The rail: `TranscriptContainerView` reserves the gutter and holds the
    /// rail and card views. `earlier` is the Remote pane's earlier-history
    /// state, nil in panes that never page history in.
    case rail(earlier: PromptRailEarlierHistory?)

    /// The gutter `TranscriptContainerView` keeps on its leading edge. It is
    /// fixed for the life of the view and present with zero prompts as with
    /// two hundred, so the table's column width never changes on the rail's
    /// account: a width change discards every cached row height.
    var containerGutter: CGFloat {
        switch self {
        case .rail:
            return PromptRailLayout.width
        case .none:
            return 0
        }
    }
}
