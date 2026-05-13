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

    // `transcriptTextSelection` forced `false` as a #129 falsification test — revert this PR to restore the hover-latch.

    nonisolated private static let perfLog = Logger(subsystem: "com.tbd.app", category: "perf-transcript")

    /// Tracks which terminal IDs have already emitted a `items.body` marker
    /// for >100-node bodies in this process. Throwaway diagnostic state —
    /// removed when the `perf-transcript` instrumentation is cleaned up.
    nonisolated private static let bodyLogged = OSAllocatedUnfairLock<Set<UUID>>(initialState: [])

    nonisolated private static func shortID(_ id: UUID) -> String {
        return String(id.uuidString.suffix(4))
    }

    var body: some View {
        let intervalState = TranscriptSignposts.signposter.beginInterval("transcript.items.body")
        defer { TranscriptSignposts.signposter.endInterval("transcript.items.body", intervalState) }
        return bodyView
    }

    @ViewBuilder
    private var bodyView: some View {
        let nodes = transcriptRenderNodes(from: items)
        let _ = {
            guard nodes.count > 100, let tid = terminalID else { return }
            Self.bodyLogged.withLock { logged in
                if !logged.contains(tid) {
                    logged.insert(tid)
                    Self.perfLog.debug("items.body terminalID=\(Self.shortID(tid), privacy: .public) count=\(nodes.count, privacy: .public)")
                }
            }
        }()
        LazyVStack(alignment: .leading, spacing: 4) {
            ForEach(nodes) { node in
                TranscriptRow(node: node, terminalID: terminalID)
                    .environment(\.transcriptTextSelection, false)
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
