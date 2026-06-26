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
/// `TranscriptItemsView` flips this env to `true` only on the most-recently
/// hovered row (latched, not live-hovered), so non-hovered rows render plain
/// `Text` and skip the `NSTextField` materialization entirely.
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

/// Environment key controlling whether a transcript row should render its cards
/// in STABLE/NON-INTERACTIVE mode (currently only `AskUserQuestionCard`).
///
/// The NSTableView transcript pane is display-of-history: it hosts each row in a
/// height-cached `NSHostingView` measured ONCE at install. An interactive
/// AskUserQuestion card whose question bubble expands/collapses on tap would
/// change its rendered height after that single measurement — so in the table
/// pane a click on a historic card collapses it and the row's reserved height no
/// longer matches. Flipping this env to `true` (set only on the table path)
/// makes `AskUserQuestionCard` render with `staticHeight: true`: always-expanded,
/// no toggle chevron, and the async-growth truncation footers suppressed. The
/// live SwiftUI pane leaves this `false`, so its (possibly pending) question card
/// stays interactive. (#129)
private struct TranscriptStaticCardsKey: EnvironmentKey {
    static let defaultValue: Bool = false
}

extension EnvironmentValues {
    /// True iff transcript cards in this row should render statically (no
    /// expand/collapse, fixed height). See `TranscriptStaticCardsKey`.
    var transcriptStaticCards: Bool {
        get { self[TranscriptStaticCardsKey.self] }
        set { self[TranscriptStaticCardsKey.self] = newValue }
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
