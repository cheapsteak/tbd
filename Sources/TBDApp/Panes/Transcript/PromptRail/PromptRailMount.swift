import CoreGraphics
import Foundation

/// What `TableTranscriptView` mounts for the prompt rail.
enum PromptRailMount {
    /// No rail and no gutter: tests and harnesses that drive the table alone.
    case none
    /// The rail: `TranscriptContainerView` reserves the gutter and lays the
    /// rail's overlay over the transcript.
    case rail

    /// The gutter `TranscriptContainerView` keeps on its leading edge. It is
    /// fixed for the life of the view and present with zero prompts as with
    /// two hundred, so the table's column width never changes on the rail's
    /// account: a width change discards every cached row height. While the
    /// lens is open, the rail's overlay is wider than the gutter, but it
    /// draws over the transcript and never narrows the table.
    var containerGutter: CGFloat {
        switch self {
        case .rail:
            return PromptRailLayout.width
        case .none:
            return 0
        }
    }
}
