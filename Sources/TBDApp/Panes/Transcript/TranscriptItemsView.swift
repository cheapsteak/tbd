import SwiftUI
import TBDShared
import os

/// Tool names whose activity is hidden from the timeline. Keep small;
/// these are tools whose existence in the transcript adds no signal
/// for the reader.
let hiddenToolNames: Set<String> = ["TodoWrite", "TaskUpdate", "TaskCreate", "Skill"]

/// True if this item is hidden from the timeline. Centralized so callers
/// like `transcriptRenderNodes(from:)` can compute accurate counts and
/// badge attribution without duplicating the rule.
func isHiddenInTranscript(_ item: TranscriptItem) -> Bool {
    switch item {
    case .thinking:
        return true
    case .toolCall(_, let name, _, _, _, _, _, _):
        return hiddenToolNames.contains(name)
    default:
        return false
    }
}

/// Renders an ordered list of transcript items by mapping `[TranscriptItem]`
/// into a flat `[TranscriptRenderNode]` (via `transcriptRenderNodes(from:)`)
/// and feeding it to a `LazyVStack { ForEach { TranscriptRow } }`. The
/// `ForEach` body is homogeneous — one `TranscriptRow` per node — to
/// satisfy SwiftUI's constant-view-count rule and avoid the
/// `_ViewList_Group.estimatedCount` recursion driving issue #129.
struct TranscriptItemsView: View {
    let items: [TranscriptItem]
    let terminalID: UUID?
    /// Optional upward-flowing at-bottom signal. A 1pt `Color.clear`
    /// sentinel appended after the `ForEach` flips this on
    /// `.onAppear`/`.onDisappear`, replacing the prior
    /// `.onScrollGeometryChange` reader that forced the LazyVStack to
    /// compute its full content size on every scroll event (see issue
    /// #129, Gemini's hypothesis). Pass `nil` from callers that don't
    /// need the signal.
    var atBottom: Binding<Bool>? = nil

    /// Per-`TranscriptItemsView`-instance memoization of the render-node array.
    /// Returns the SAME `[TranscriptRenderNode]` instance when `items` is
    /// unchanged so a `body` re-eval (data poll, parent re-render, etc.) does
    /// not rebuild the array or force AttributeGraph to re-copy it (issue #129).
    /// A reference type held in `@State` so its mutations persist across body
    /// passes without themselves invalidating the view.
    @State private var nodeCache = TranscriptNodeCache()

    nonisolated private static let perfLog = Logger(subsystem: "com.tbd.app", category: "perf-transcript")

    /// Tracks which terminal IDs have already emitted a `items.body` marker
    /// for >100-node bodies in this process. Throwaway diagnostic state —
    /// removed when the `perf-transcript` instrumentation is cleaned up.
    nonisolated private static let bodyLogged = OSAllocatedUnfairLock<Set<UUID>>(initialState: [])

    nonisolated private static func shortID(_ id: UUID) -> String {
        return String(id.uuidString.suffix(4))
    }

    /// Env override for the virtualized-transcript gate (issue #129). When
    /// `TBD_VIRT_TRANSCRIPT == "1"`, the live-transcript pane renders the
    /// AppKit-virtualized `VirtualizedTranscriptList` instead of the
    /// `LazyVStack { ForEach }`, regardless of the Settings toggle — a forced
    /// override for the perf harness / testing. The user-facing renderer setting
    /// is the `AppState.useVirtualizedTranscriptKey` toggle (which defaults ON
    /// when the live-transcript pane is enabled), OR'd with this in
    /// `LiveTranscriptPaneView`. Pure so it's unit-testable (see
    /// `TranscriptVirtualizationGateTests`). The env override itself is off by
    /// default — it's independent of the setting default.
    static func virtualizedTranscriptEnvOverride(_ environment: [String: String]) -> Bool {
        environment["TBD_VIRT_TRANSCRIPT"] == "1"
    }

    var body: some View {
        let intervalState = TranscriptSignposts.signposter.beginInterval("transcript.items.body")
        defer { TranscriptSignposts.signposter.endInterval("transcript.items.body", intervalState) }
        return bodyView
    }

    @ViewBuilder
    private var bodyView: some View {
        let nodes = nodeCache.nodes(for: items)
        let _ = {
            guard nodes.count > 100, let tid = terminalID else { return }
            Self.bodyLogged.withLock { logged in
                if !logged.contains(tid) {
                    logged.insert(tid)
                    Self.perfLog.debug("items.body terminalID=\(Self.shortID(tid), privacy: .public) count=\(nodes.count, privacy: .public)")
                }
            }
        }()
        // Production path: LazyVStack { ForEach }. The virtualization gate
        // (#129) that swaps in `VirtualizedTranscriptList` lives UP in
        // `LiveTranscriptPaneView.transcriptWithAutoscroll`, because a
        // virtualizer must OWN its scrolling — nested inside the pane's SwiftUI
        // `ScrollView` it was proposed unbounded height and never got a
        // viewport. The `virtualizedTranscriptEnvOverride` helper stays here
        // (it's the env override, unit-tested). This body is the production path.
        LazyVStack(alignment: .leading, spacing: 4) {
            ForEach(nodes) { node in
                SelectableTranscriptRow(node: node, terminalID: terminalID)
            }
            // 1pt sentinel that drives `atBottom`. Replaced the prior
            // `.onScrollGeometryChange(for: AtBottomGeometry.self)` reader that
            // computed at-bottom via `contentHeight - viewportBottom < 50` —
            // reading `contentSize.height` on a `ScrollView { LazyVStack }`
            // forced the LazyVStack to compute total content size on every
            // scroll event, contributing to the estimatedCount recursion in #129.
            //
            // Effective at-bottom threshold is ~0pt (was 50pt). Trade-off: during
            // auto-scroll animations the sentinel briefly exits the viewport as
            // new content lands, so the jump-to-bottom button may flash for the
            // animation duration. Acceptable for the perf win.
            Color.clear
                .frame(height: 1)
                .onAppear { atBottom?.wrappedValue = true }
                .onDisappear { atBottom?.wrappedValue = false }
        }
        .padding(.vertical, 8)
    }
}

/// Wraps a single `TranscriptRow` and owns its own hover state, so a hover
/// re-renders ONLY the entered/exited row — `TranscriptItemsView.body` never
/// re-runs on hover. This is the load-bearing half of the issue #129
/// hover-rebuild fix: previously the hovered-row id lived on
/// `TranscriptItemsView` as `@State`, so every mouse crossing re-ran the whole
/// list body (rebuilding the node array, re-diffing the `ForEach`, forcing
/// AttributeGraph to deep-copy the input). Mirrors the per-row local-hover
/// pattern already used by `ActivityRowChrome`.
///
/// The selection gate (`transcriptTextSelection`) is materialized only while
/// this row is hovered, preserving the #120 fix that keeps at most one row's
/// `NSTextField` alive at a time and avoids the ~17 s per-row-NSTextField storm.
///
/// Latch decision (issue #129): the previous gate was *latched* — it never
/// cleared on hover-exit so a drag-select that wandered slightly outside the row
/// survived. Per-row local state clears on exit instead, and that is safe:
/// AppKit `NSTrackingArea`s (what SwiftUI `.onHover` is built on) do NOT post
/// `mouseExited` during an active drag unless `.enabledDuringMouseDrag` is set,
/// which `.onHover` does not. So while the button is held during a drag-select,
/// `isHovered` stays `true` and the `NSTextField` is not torn down — the latch
/// was only ever protecting a case AppKit already handles. Trade-off: if the
/// pointer leaves the row with no button held, selection clears, which is
/// acceptable since each row is its own `NSTextField` and selection cannot span
/// rows anyway. This guarantee assumes the drag-select begins inside the row; a
/// drag that starts outside never armed this row's selection in the first place.
private struct SelectableTranscriptRow: View {
    let node: TranscriptRenderNode
    let terminalID: UUID?

    @State private var isHovered = false

    var body: some View {
        TranscriptRow(node: node, terminalID: terminalID)
            .environment(\.transcriptTextSelection, isHovered)
            .onHover { isHovered = $0 }
    }
}
