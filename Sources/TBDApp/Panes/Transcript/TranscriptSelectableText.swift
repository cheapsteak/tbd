import SwiftUI

/// Environment key controlling whether a transcript row should materialize
/// `.textSelection(.enabled)`.
///
/// On macOS, `.textSelection(.enabled)` materializes a `SelectionOverlay`
/// NSViewRepresentable wrapping `NSTextField` per call site. In a `LazyVStack`
/// with N visible rows × multiple selection sites each, every env/state change
/// triggers per-cell `-[NSControl setFont:]` invalidation and associated-object
/// env propagation. Layout passes go super-linear and the main thread stalls
/// (confirmed via spindumps showing ~17 s hangs).
///
/// `TranscriptItemsView` normally flips this env to `true` only on the most-
/// recently hovered row (latched, not live-hovered), so non-hovered rows render
/// plain `Text` and skip the `NSTextField` materialization entirely. (Currently
/// forced `false` for every row while the #129 hover-trigger falsification test
/// in PR #140 is live — `ChatBubbleView` overrides to `true` in its subtree, so
/// user/assistant text stays selectable.)
private struct TranscriptTextSelectionKey: EnvironmentKey {
    static let defaultValue: Bool = false
}

extension EnvironmentValues {
    /// True iff the hosting view should enable text selection on transcript text.
    /// See `TranscriptTextSelectionKey` for the perf rationale.
    var transcriptTextSelection: Bool {
        get { self[TranscriptTextSelectionKey.self] }
        set { self[TranscriptTextSelectionKey.self] = newValue }
    }
}

/// Conditionally applies `.textSelection(.enabled)` based on
/// `EnvironmentValues.transcriptTextSelection`.
///
/// Implemented as a `ViewModifier` with a `@ViewBuilder` if/else so SwiftUI's
/// diffing handles the conditional cleanly — flipping the env value swaps the
/// branch, which lets SwiftUI tear down the `SelectionOverlay` NSView when
/// selection turns off.
private struct TranscriptSelectableTextModifier: ViewModifier {
    @Environment(\.transcriptTextSelection) private var enabled

    @ViewBuilder
    func body(content: Content) -> some View {
        if enabled {
            content.textSelection(.enabled)
        } else {
            content
        }
    }
}

extension View {
    /// Apply `.textSelection(.enabled)` iff the surrounding transcript row has
    /// opted in via `EnvironmentValues.transcriptTextSelection`. Use this in
    /// place of a bare `.textSelection(.enabled)` for any text that lives
    /// inside a `LazyVStack` transcript row to avoid the per-row
    /// `NSTextField` materialization tax.
    func transcriptSelectableText() -> some View {
        modifier(TranscriptSelectableTextModifier())
    }
}
