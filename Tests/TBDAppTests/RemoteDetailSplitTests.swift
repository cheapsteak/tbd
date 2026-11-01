import AppKit
import Observation
import SwiftUI
import Testing
@testable import TBDApp

/// `RemoteDetailSplit` exists for one property: showing, hiding or swapping
/// the transcript never remounts either half. The terminal side's
/// `RemoteAttachPager` owns every live attach connection, and the transcript
/// owns a sync driver. Asked of a real mount — an AppKit representable in each
/// half counts how often SwiftUI makes and dismantles it, and keeps its view so
/// a test can read where that half was drawn.
@MainActor
@Suite("Remote detail split", .serialized)
struct RemoteDetailSplitTests {

    typealias Split = RemoteDetailSplit<EmptyView, EmptyView>

    @MainActor
    final class Counts {
        var made = 0
        var dismantled = 0
        /// The probe's view, set when SwiftUI makes it.
        weak var view: NSView?

        /// The probe's left edge in window coordinates, or nil while it is not
        /// mounted.
        var minX: CGFloat? {
            guard let view else { return nil }
            return view.convert(view.bounds, to: nil).minX
        }

        /// Where the probe was drawn, for a failure message.
        var drawnAt: String {
            minX.map { "x = \($0)" } ?? "not mounted"
        }
    }

    @MainActor
    @Observable
    final class Model {
        var showsTranscript: Bool
        var transcriptLeads: Bool

        init(showsTranscript: Bool, transcriptLeads: Bool) {
            self.showsTranscript = showsTranscript
            self.transcriptLeads = transcriptLeads
        }
    }

    private struct Probe: NSViewRepresentable {
        let counts: Counts

        func makeNSView(context: Context) -> NSView {
            counts.made += 1
            let view = NSView()
            counts.view = view
            return view
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
        let terminalCounts: Counts
        let transcriptCounts: Counts

        var body: some View {
            RemoteDetailSplit(
                showsTranscript: model.showsTranscript,
                transcriptLeads: model.transcriptLeads
            ) {
                Probe(counts: terminalCounts)
            } transcript: {
                Probe(counts: transcriptCounts)
            }
        }
    }

    private static var hostSize: NSSize { NSSize(width: 900, height: 400) }

    /// Two halves of one claim. The transcript probe proves the toggles really
    /// happened: made and dismantled once per show and hide, so the test cannot
    /// pass against a split that never renders its transcript. The terminal
    /// probe is the property: made once, never dismantled.
    @Test("toggling the transcript never remakes or dismantles the terminal side")
    func togglingTheTranscriptNeverRemakesTheTerminal() async throws {
        let model = Model(showsTranscript: false, transcriptLeads: false)
        let terminalCounts = Counts()
        let transcriptCounts = Counts()
        let host = OffscreenHost(
            root: Root(model: model, terminalCounts: terminalCounts, transcriptCounts: transcriptCounts),
            size: Self.hostSize)
        defer { host.tearDown() }

        try #require(await host.settle { terminalCounts.made == 1 }, "the terminal side never mounted")
        #expect(transcriptCounts.made == 0, "the transcript mounted while hidden")

        for (step, show) in [true, false, true, false].enumerated() {
            model.showsTranscript = show
            let shows = step / 2 + 1
            let hides = (step + 1) / 2
            let settled = await host.settle {
                transcriptCounts.made == shows && transcriptCounts.dismantled == hides
            }
            #expect(settled, """
                step \(step): the transcript was made \(transcriptCounts.made) and dismantled \
                \(transcriptCounts.dismantled) times, expected \(shows) and \(hides)
                """)
        }

        #expect(transcriptCounts.made == 2)
        #expect(transcriptCounts.dismantled == 2)
        #expect(terminalCounts.made == 1, "the terminal side was rebuilt when the transcript changed")
        #expect(terminalCounts.dismantled == 0, "the terminal side was torn down when the transcript changed")
    }

    /// Each step waits for the swap to be drawn — the terminal right of the
    /// transcript while the transcript leads, left of it otherwise — so the
    /// test cannot pass against a split that never moves its halves. Through
    /// four swaps, neither half is made again or dismantled.
    @Test("swapping the halves never remakes either one")
    func swappingNeverRemakesEitherHalf() async throws {
        let model = Model(showsTranscript: true, transcriptLeads: false)
        let terminalCounts = Counts()
        let transcriptCounts = Counts()
        let host = OffscreenHost(
            root: Root(model: model, terminalCounts: terminalCounts, transcriptCounts: transcriptCounts),
            size: Self.hostSize)
        defer { host.tearDown() }

        let mounted = await host.settle {
            guard let terminalX = terminalCounts.minX, let transcriptX = transcriptCounts.minX else {
                return false
            }
            return transcriptX > terminalX
        }
        try #require(mounted, """
            the halves never mounted with the terminal on the left: terminal \
            \(terminalCounts.drawnAt), transcript \(transcriptCounts.drawnAt)
            """)

        for (step, leads) in [true, false, true, false].enumerated() {
            model.transcriptLeads = leads
            let drawn = await host.settle {
                guard let terminalX = terminalCounts.minX, let transcriptX = transcriptCounts.minX else {
                    return false
                }
                return leads ? terminalX > transcriptX : transcriptX > terminalX
            }
            try #require(drawn, """
                step \(step): with transcriptLeads \(leads) the swap was never drawn: terminal \
                \(terminalCounts.drawnAt), transcript \(transcriptCounts.drawnAt)
                """)
        }

        #expect(terminalCounts.made == 1, "a swap rebuilt the terminal side")
        #expect(terminalCounts.dismantled == 0, "a swap tore down the terminal side")
        #expect(transcriptCounts.made == 1, "a swap rebuilt the transcript")
        #expect(transcriptCounts.dismantled == 0, "a swap tore down the transcript")
    }

    /// Detaching while the transcript is hidden shows it and moves it to the
    /// left in the same update. Only the transcript is made; the terminal side
    /// moves right without being remade.
    @Test("detaching while the transcript is hidden remakes only the transcript")
    func detachingWhileHiddenRemakesOnlyTheTranscript() async throws {
        let model = Model(showsTranscript: false, transcriptLeads: false)
        let terminalCounts = Counts()
        let transcriptCounts = Counts()
        let host = OffscreenHost(
            root: Root(model: model, terminalCounts: terminalCounts, transcriptCounts: transcriptCounts),
            size: Self.hostSize)
        defer { host.tearDown() }

        try #require(await host.settle { terminalCounts.made == 1 }, "the terminal side never mounted")
        #expect(transcriptCounts.made == 0, "the transcript mounted while hidden")

        // Nothing suspends between the two writes, so SwiftUI sees them as one
        // change.
        model.showsTranscript = true
        model.transcriptLeads = true

        let drawn = await host.settle {
            guard transcriptCounts.made == 1,
                  let terminalX = terminalCounts.minX, let transcriptX = transcriptCounts.minX
            else { return false }
            return terminalX > transcriptX
        }
        try #require(drawn, """
            the transcript was made \(transcriptCounts.made) times and never drawn left of the \
            terminal: terminal \(terminalCounts.drawnAt), transcript \(transcriptCounts.drawnAt)
            """)

        #expect(terminalCounts.made == 1, "detaching rebuilt the terminal side")
        #expect(terminalCounts.dismantled == 0, "detaching tore down the terminal side")
        #expect(transcriptCounts.dismantled == 0, "detaching tore down the transcript")
    }

    @Test("the halves are placed by role, and the right half takes the stored width")
    func columns() {
        let attached: RemoteDetailSplitColumns = Split.columns(
            totalWidth: 1000, rightWidth: 420, dividerWidth: 6,
            showsTranscript: true, transcriptLeads: false)
        let attachedExpected: RemoteDetailSplitColumns = RemoteDetailSplitColumns(
            terminal: RemoteDetailSplitColumn(x: 0, width: 574),
            divider: RemoteDetailSplitColumn(x: 574, width: 6),
            transcript: RemoteDetailSplitColumn(x: 580, width: 420))
        #expect(attached == attachedExpected)

        let notAttached: RemoteDetailSplitColumns = Split.columns(
            totalWidth: 1000, rightWidth: 420, dividerWidth: 6,
            showsTranscript: true, transcriptLeads: true)
        let notAttachedExpected: RemoteDetailSplitColumns = RemoteDetailSplitColumns(
            terminal: RemoteDetailSplitColumn(x: 580, width: 420),
            divider: RemoteDetailSplitColumn(x: 574, width: 6),
            transcript: RemoteDetailSplitColumn(x: 0, width: 574))
        #expect(notAttached == notAttachedExpected)

        let terminalOnlyExpected: RemoteDetailSplitColumns = RemoteDetailSplitColumns(
            terminal: RemoteDetailSplitColumn(x: 0, width: 1000),
            divider: nil,
            transcript: nil)
        let terminalOnly: RemoteDetailSplitColumns = Split.columns(
            totalWidth: 1000, rightWidth: 420, dividerWidth: 6,
            showsTranscript: false, transcriptLeads: false)
        #expect(terminalOnly == terminalOnlyExpected)
        // `transcriptLeads` is ignored while the transcript is hidden.
        let terminalOnlyLeading: RemoteDetailSplitColumns = Split.columns(
            totalWidth: 1000, rightWidth: 420, dividerWidth: 6,
            showsTranscript: false, transcriptLeads: true)
        #expect(terminalOnlyLeading == terminalOnlyExpected)
    }

    @Test("the right half is clamped between its minimum and what leaves the left minimum")
    func clamp() {
        #expect(Split.clamp(100, totalWidth: 1000, leftMin: 240, rightMin: 280) == 280)
        #expect(Split.clamp(500, totalWidth: 1000, leftMin: 240, rightMin: 280) == 500)
        #expect(Split.clamp(900, totalWidth: 1000, leftMin: 240, rightMin: 280) == 760)
        // Too narrow for both minimums: the right minimum wins.
        #expect(Split.clamp(500, totalWidth: 400, leftMin: 240, rightMin: 280) == 280)
    }
}
