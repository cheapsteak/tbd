import SwiftUI
import TBDShared

/// Snapshot of the History pane's transcript items, injected so the
/// overlay's lookup can find items not present in AppState's live
/// session-keyed transcript store.
struct HistoryTranscriptItemsKey: EnvironmentKey {
    static let defaultValue: [TranscriptItem] = []
}

extension EnvironmentValues {
    var historyTranscriptItems: [TranscriptItem] {
        get { self[HistoryTranscriptItemsKey.self] }
        set { self[HistoryTranscriptItemsKey.self] = newValue }
    }
}
