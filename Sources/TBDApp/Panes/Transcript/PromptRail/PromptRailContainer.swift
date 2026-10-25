import SwiftUI

/// Wraps a pane's `TableTranscriptView` and mounts the prompt rail renderer
/// chosen in Settings, handing the table the `PromptRailMount` to build with.
///
/// - **AppKit** – renders `content` alone; the gutter, rail and card live
///   inside the table's `TranscriptContainerView`.
/// - **SwiftUI** – renders `PromptRailSwiftUIView` beside `content` in an
///   `HStack`, fed by a `PromptRailState` this view owns, with the card in a
///   `PromptRailCardOverlay` laid over both. This view owns the renderer's
///   hover model, pointer and Escape monitor, and closes the card when the
///   renderer leaves the screen.
///
/// The renderer is part of the transcript's identity (`.id(renderer)`), so a
/// change in Settings rebuilds open panes, which reopen at the bottom as any
/// freshly opened transcript does. A pane puts its own identity (`.id`) and
/// overlays on this view rather than on the table, so they cover the rail too.
///
/// The body never reads `state`, the hover model or the pointer: it hands the
/// objects on, and only the rail and the card overlay observe them. Reading
/// them here would re-run `content` — and the table's `updateNSView` — on
/// every active-prompt change.
///
/// **Rail hover** comes from one handler on the whole `HStack`, card overlay
/// included, which counts the pointer as on the rail while it is over the
/// rail's column (`PromptRailPointer.pointerMoved`). SwiftUI hover follows
/// hit-testing, so a handler on the rail itself would hear the pointer leave
/// as soon as the open card covered the rail, lifting the Escape and click
/// suppression with the pointer still on it, and the card would reopen.
struct PromptRailContainer<Content: View>: View {
    var earlier: PromptRailEarlierHistory?
    let content: (PromptRailMount) -> Content

    /// The raw stored choice; `AppState.promptRailRenderer(stored:)` decodes
    /// it, so an unset or unknown value takes the one shipped default.
    @AppStorage(AppState.promptRailRendererKey) private var storedRenderer: String?
    @State private var state = PromptRailState()
    /// The SwiftUI renderer's. The AppKit renderer makes its own in the
    /// table's `makeNSView`.
    @State private var hover: PromptRailHoverModel
    @State private var pointer = PromptRailPointer()
    @State private var escape: PromptRailEscapeMonitor

    /// `hover` and `escapeMonitor` default to the production ones; tests pass
    /// a hover model on a test clock and a monitor over a fake table. Only
    /// the first value of each is kept, as with any `@State`.
    init(
        earlier: PromptRailEarlierHistory? = nil,
        hover: PromptRailHoverModel = PromptRailHoverModel(),
        escapeMonitor: PromptRailEscapeMonitor = PromptRailEscapeMonitor(),
        @ViewBuilder content: @escaping (PromptRailMount) -> Content
    ) {
        self.earlier = earlier
        self.content = content
        _hover = State(initialValue: hover)
        _escape = State(initialValue: escapeMonitor)
    }

    var body: some View {
        let renderer = AppState.promptRailRenderer(stored: storedRenderer)
        let mount = Self.mount(for: renderer, earlier: earlier, state: state)
        Group {
            switch renderer {
            case .appKit:
                content(mount)
            case .swiftUI:
                swiftUIRenderer(table: content(mount))
            }
        }
        .id(renderer)
    }

    /// The rail beside the table, the card over both, and the hover handler
    /// over all of it.
    private func swiftUIRenderer(table: Content) -> some View {
        let state = self.state
        let hover = self.hover
        let pointer = self.pointer
        return HStack(spacing: 0) {
            PromptRailSwiftUIView(state: state, pointer: pointer)
            table
        }
        .overlay(alignment: .topLeading) {
            PromptRailCardOverlay(
                state: state, hover: hover, pointer: pointer, escape: escape, earlier: earlier)
        }
        // After the overlay, so the card covering the rail is inside the
        // hovered view and cannot end the rail's hover.
        .onContinuousHover { phase in
            switch phase {
            case .active(let location):
                pointer.pointerMoved(to: location, count: state.entries.count, hover: hover)
            case .ended:
                pointer.pointerMoved(to: nil, count: state.entries.count, hover: hover)
            }
        }
        // A renderer switch, a pane rebuilt under a new identity (as on
        // session rollover) or a pane closing takes the card with it.
        .onDisappear { hover.closeNow() }
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
