import Foundation
import Testing

@testable import TBDApp

@MainActor
@Suite("BinaryFallbackActions")
struct BinaryFallbackActionsTests {
    private final class RecordingWorkspace: FileRevealing {
        var selected: [[URL]] = []
        func activateFileViewerSelecting(_ fileURLs: [URL]) { selected.append(fileURLs) }
    }

    private final class PanelShows { var count = 0 }

    @Test func revealSelectsTheFileInFinder() {
        let rec = RecordingWorkspace()
        BinaryFallbackActions.live(workspace: rec).reveal("/x/a.zip")
        #expect(rec.selected == [[URL(fileURLWithPath: "/x/a.zip")]])
    }

    @Test func quickLookPreviewsThatFile() {
        let rec = RecordingWorkspace()
        let shows = PanelShows()
        let presenter = QuickLookPresenter()
        presenter.showPanel = { shows.count += 1 }
        BinaryFallbackActions.live(workspace: rec, presenter: presenter).openQuickLook("/x/a.zip")
        #expect(shows.count == 1)
        #expect(presenter.previewURL?.path == "/x/a.zip")
        #expect(rec.selected.isEmpty)
    }
}
