import AppKit
import Observation
import SwiftUI
import Testing
@testable import TBDApp

/// `RemoteDetailSplit` exists for one property: opening or closing the
/// transcript half never remounts the terminal half, whose
/// `RemoteAttachPager` owns every live attach connection. Asked of a real
/// mount — an AppKit representable in the leading slot counts how often
/// SwiftUI makes and dismantles it while the trailing half comes and goes.
@MainActor
@Suite("Remote detail split", .serialized)
struct RemoteDetailSplitTests {

    @MainActor
    final class Counts {
        var made = 0
        var dismantled = 0
    }

    @MainActor
    @Observable
    final class Model {
        var showsTrailing = false
    }

    private struct Probe: NSViewRepresentable {
        let counts: Counts

        func makeNSView(context: Context) -> NSView {
            counts.made += 1
            return NSView()
        }

        func updateNSView(_ nsView: NSView, context: Context) {}

        static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) {
            coordinator.counts.dismantled += 1
        }

        func makeCoordinator() -> Coordinator { Coordinator(counts: counts) }

        final class Coordinator {
            let counts: Counts
            init(counts: Counts) { self.counts = counts }
        }
    }

    private struct Root: View {
        let model: Model
        let counts: Counts
        let trailingCounts: Counts

        var body: some View {
            RemoteDetailSplit(showsTrailing: model.showsTrailing) {
                Probe(counts: counts)
            } trailing: {
                Probe(counts: trailingCounts)
            }
        }
    }

    /// Two halves of one claim. The trailing probe proves the toggles really
    /// happened: made and dismantled once per show/hide, so the test cannot
    /// pass against a split that never renders its trailing half. The leading
    /// probe is the property: made once, never dismantled.
    @Test("toggling the trailing half never remakes or dismantles the leading one")
    func leadingSurvivesToggle() async throws {
        let model = Model()
        let counts = Counts()
        let trailingCounts = Counts()
        let host = OffscreenHost(
            root: Root(model: model, counts: counts, trailingCounts: trailingCounts),
            size: NSSize(width: 900, height: 400))
        defer { host.tearDown() }

        try #require(await host.settle { counts.made == 1 }, "the leading half never mounted")
        #expect(trailingCounts.made == 0, "the trailing half mounted while hidden")

        for (step, show) in [true, false, true, false].enumerated() {
            model.showsTrailing = show
            let shows = step / 2 + 1
            let hides = (step + 1) / 2
            let settled = await host.settle {
                trailingCounts.made == shows && trailingCounts.dismantled == hides
            }
            #expect(settled, """
                step \(step): the trailing half was made \(trailingCounts.made) and dismantled \
                \(trailingCounts.dismantled) times, expected \(shows) and \(hides)
                """)
        }

        #expect(trailingCounts.made == 2)
        #expect(trailingCounts.dismantled == 2)
        #expect(counts.made == 1, "the leading half was rebuilt when the trailing half changed")
        #expect(counts.dismantled == 0, "the leading half was torn down when the trailing half changed")
    }

    @Test("the trailing half is clamped between its minimum and what leaves the leading minimum")
    func clamp() {
        typealias Split = RemoteDetailSplit<EmptyView, EmptyView>
        #expect(Split.clamp(100, totalWidth: 1000, leadingMin: 240, trailingMin: 280) == 280)
        #expect(Split.clamp(500, totalWidth: 1000, leadingMin: 240, trailingMin: 280) == 500)
        #expect(Split.clamp(900, totalWidth: 1000, leadingMin: 240, trailingMin: 280) == 760)
        // Too narrow for both minimums: the trailing minimum wins.
        #expect(Split.clamp(500, totalWidth: 400, leadingMin: 240, trailingMin: 280) == 280)
    }
}
