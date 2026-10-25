import CoreGraphics
import Foundation

/// Which framework draws the transcript's prompt rail and its card. A
/// temporary switch so the two renderers can be compared in a running build;
/// the follow-up that picks one deletes the other, this enum, the
/// `AppState.promptRailRendererKey` setting and `TableTranscriptView.promptRail`.
///
/// The raw values are what the UserDefaults key stores.
enum PromptRailRenderer: String, CaseIterable {
    /// An `NSView` rail in a gutter inside `TranscriptContainerView`, with the
    /// card an `NSView` stacked above the table.
    case appKit = "appkit"
    /// A SwiftUI rail beside `TableTranscriptView` in `PromptRailContainer`,
    /// with the card a SwiftUI overlay.
    case swiftUI = "swiftui"
}

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

/// What `TableTranscriptView` mounts for the prompt rail, chosen by
/// `PromptRailContainer.mount(for:earlier:state:)`.
enum PromptRailMount {
    /// No rail and no gutter: tests and harnesses that drive the table alone.
    case none
    /// The AppKit renderer: `TranscriptContainerView` reserves the gutter and
    /// holds the rail and card views.
    case appKit(earlier: PromptRailEarlierHistory?)
    /// The SwiftUI renderer: the coordinator reports into `PromptRailState`,
    /// and `PromptRailContainer` draws the rail beside the table, so the
    /// container view reserves no gutter of its own.
    case swiftUI(PromptRailState)

    /// The gutter `TranscriptContainerView` keeps on its leading edge. It is
    /// fixed for the life of the view and present with zero prompts as with
    /// two hundred, so the table's column width never changes on the rail's
    /// account: a width change discards every cached row height.
    var containerGutter: CGFloat {
        switch self {
        case .appKit:
            return PromptRailLayout.width
        case .none, .swiftUI:
            return 0
        }
    }
}
