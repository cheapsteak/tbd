import Foundation

/// Receives the prompt outline, each entry's work and the active prompt from
/// `TableTranscriptView.Coordinator`. The rail view, `PromptRailNSView`, is
/// the presenter a mounted rail attaches.
///
/// - **When** – each method is called only when its value changed, and all
///   three are called at once when the presenter is attached, so a presenter
///   set after the first update still starts in sync. Calls can arrive from
///   inside `updateNSView`, synchronously.
/// - **Order** – a new entries list arrives before the work counts and the
///   active index computed against it. Both refer to the entries last
///   delivered; between the calls a presenter can briefly hold counts for a
///   list that changed, or an index past the end of a list that shrank. It
///   should read a missing count as no work and such an index as no active
///   entry.
/// - **Work counts** – parallel to the entries, recomputed on every update
///   that changes the rows, the ones that only re-render the last row
///   included: a tool call joining a collapsed group arrives that way.
@MainActor
protocol PromptRailPresenter: AnyObject {
    func promptRail(entriesDidChange entries: [PromptOutlineEntry])
    func promptRail(workCountsDidChange counts: [Int])
    func promptRail(activeIndexDidChange index: Int?)
}
