import Foundation

/// Receives the prompt outline and the active prompt from
/// `TableTranscriptView.Coordinator`. The rail view, `PromptRailNSView`, is
/// the presenter a mounted rail attaches.
///
/// - **When** – each method is called only when its value changed, and both
///   are called at once when the presenter is attached, so a presenter set
///   after the first update still starts in sync. Calls can arrive from inside
///   `updateNSView`, synchronously.
/// - **Order** – a new entries list arrives before the active index computed
///   against it. An index refers to the entries last delivered; between the
///   two calls a presenter can briefly hold an index past the end of a list
///   that shrank, and should read that as no active entry.
@MainActor
protocol PromptRailPresenter: AnyObject {
    func promptRail(entriesDidChange entries: [PromptOutlineEntry])
    func promptRail(activeIndexDidChange index: Int?)
}
