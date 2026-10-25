import Foundation
import Observation

/// The SwiftUI renderer's presenter: the coordinator reports the prompt
/// outline and the active prompt here, and only the rail and card read it.
///
/// - **Who reads it** – the rail and card views alone. A pane body that read
///   it would re-render on every active-prompt change and rerun the table's
///   `updateNSView`, with its whole-transcript comparison, in the middle of a
///   scroll.
/// - **Deferred writes** – the coordinator calls the presenter methods
///   synchronously, sometimes from inside `updateNSView`. Writing observed
///   state there would mutate SwiftUI state during a view update, so each
///   call is held and applied on the next main-queue turn, the way the table
///   pane defers `atBottom` and the near-top report. Calls landing before
///   that turn coalesce: the last value of each wins.
/// - **Clamped index** – `activeIndex` reads nil when the stored index is past
///   the end of `entries`, which a shrunk list can briefly leave behind (see
///   `PromptRailPresenter`).
@MainActor
@Observable
final class PromptRailState: PromptRailPresenter {
    /// The outline last delivered, once applied.
    private(set) var entries: [PromptOutlineEntry] = []

    /// Index into `entries` of the active prompt, or nil with none — and nil
    /// when the delivered index does not name one of the current entries.
    var activeIndex: Int? {
        guard let storedActiveIndex, entries.indices.contains(storedActiveIndex) else { return nil }
        return storedActiveIndex
    }

    /// The active index as delivered, before clamping.
    private var storedActiveIndex: Int?

    /// Jumps the transcript to the entry with this node id. Set by
    /// `TableTranscriptView.makeNSView` to the coordinator's
    /// `jump(toNodeID:)`; nil until a table has mounted.
    @ObservationIgnored var onJump: (@MainActor (String) -> Void)?

    /// Values delivered since the last flush. `pendingActiveIndex` is doubly
    /// optional because nil is a value to deliver: `.some(nil)` means "no
    /// active prompt", `.none` means nothing arrived.
    @ObservationIgnored private var pendingEntries: [PromptOutlineEntry]?
    @ObservationIgnored private var pendingActiveIndex: Int??
    @ObservationIgnored private var isFlushScheduled = false

    init() {}

    func promptRail(entriesDidChange entries: [PromptOutlineEntry]) {
        pendingEntries = entries
        scheduleFlush()
    }

    func promptRail(activeIndexDidChange index: Int?) {
        pendingActiveIndex = .some(index)
        scheduleFlush()
    }

    /// One flush per main-queue turn, however many calls arrive before it.
    private func scheduleFlush() {
        guard !isFlushScheduled else { return }
        isFlushScheduled = true
        DispatchQueue.main.async { [weak self] in
            self?.flush()
        }
    }

    /// Applies what arrived, entries before the index computed against them,
    /// writing only values that changed so an unchanged one does not
    /// invalidate its readers.
    private func flush() {
        isFlushScheduled = false
        if let pending = pendingEntries {
            pendingEntries = nil
            if pending != entries { entries = pending }
        }
        if let pending = pendingActiveIndex {
            pendingActiveIndex = nil
            if pending != storedActiveIndex { storedActiveIndex = pending }
        }
    }
}
