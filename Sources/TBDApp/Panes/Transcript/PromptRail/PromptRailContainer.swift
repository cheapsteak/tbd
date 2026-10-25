import SwiftUI

/// Wraps a pane's `TableTranscriptView` and mounts the prompt rail renderer
/// chosen in Settings, handing the table the `PromptRailMount` to build with.
///
/// - **AppKit** – renders `content` alone; the gutter, rail and card live
///   inside the table's `TranscriptContainerView`.
/// - **SwiftUI** – renders the rail beside `content` in an `HStack`, fed by a
///   `PromptRailState` this view owns. The rail is a fixed-width placeholder
///   until the SwiftUI renderer draws into it.
///
/// The renderer is part of the transcript's identity (`.id(renderer)`), so a
/// change in Settings rebuilds open panes, which reopen at the bottom as any
/// freshly opened transcript does. A pane puts its own identity (`.id`) and
/// overlays on this view rather than on the table, so they cover the rail too.
///
/// The body never reads `state`'s properties: it hands the object on, and only
/// the rail and card observe it. Reading it here would re-run `content` — and
/// the table's `updateNSView` — on every active-prompt change.
struct PromptRailContainer<Content: View>: View {
    var earlier: PromptRailEarlierHistory?
    let content: (PromptRailMount) -> Content

    /// The raw stored choice; `AppState.promptRailRenderer(stored:)` decodes
    /// it, so an unset or unknown value takes the one shipped default.
    @AppStorage(AppState.promptRailRendererKey) private var storedRenderer: String?
    @State private var state = PromptRailState()

    init(
        earlier: PromptRailEarlierHistory? = nil,
        @ViewBuilder content: @escaping (PromptRailMount) -> Content
    ) {
        self.earlier = earlier
        self.content = content
    }

    var body: some View {
        let renderer = AppState.promptRailRenderer(stored: storedRenderer)
        let mount = Self.mount(for: renderer, earlier: earlier, state: state)
        Group {
            switch renderer {
            case .appKit:
                content(mount)
            case .swiftUI:
                HStack(spacing: 0) {
                    Color.clear.frame(width: PromptRailLayout.width)
                    content(mount)
                }
            }
        }
        .id(renderer)
    }

    /// The mount each renderer hands the table: the AppKit one carries the
    /// earlier-history state to its card, the SwiftUI one the state its rail
    /// reads.
    static func mount(
        for renderer: PromptRailRenderer,
        earlier: PromptRailEarlierHistory?,
        state: PromptRailState
    ) -> PromptRailMount {
        switch renderer {
        case .appKit:
            return .appKit(earlier: earlier)
        case .swiftUI:
            return .swiftUI(state)
        }
    }
}
