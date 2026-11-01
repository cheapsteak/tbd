import AppKit
import Observation
import SwiftUI
import Testing
@testable import TBDApp

/// `RemoteDetailSplit` exists for one property: showing, hiding or swapping
/// the transcript never remounts any of its parts. The live-terminal slot's
/// `RemoteAttachPager` owns every live attach connection, and the transcript
/// owns a sync driver. Asked of a real mount — an AppKit representable in each
/// slot counts how often SwiftUI makes and dismantles it, and keeps its view so
/// a test can read where that slot was drawn. A swap must also leave the live
/// terminal exactly where it is, because resizing a kept-alive terminal
/// resizes its remote program.
@MainActor
@Suite("Remote detail split", .serialized)
struct RemoteDetailSplitTests {

    typealias Split = RemoteDetailSplit<EmptyView, EmptyView, EmptyView>

    @MainActor
    final class Counts {
        var made = 0
        var dismantled = 0
        /// The probe's view, set when SwiftUI makes it.
        weak var view: NSView?

        /// The probe's frame in window coordinates, or nil while it is not
        /// mounted.
        var frame: CGRect? {
            guard let view else { return nil }
            return view.convert(view.bounds, to: nil)
        }

        /// The probe's left edge in window coordinates, or nil while it is not
        /// mounted.
        var minX: CGFloat? { frame?.minX }

        /// Where the probe was drawn, for a failure message.
        var drawnAt: String {
            frame.map { "x = \($0.minX), width = \($0.width)" } ?? "not mounted"
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
        let liveCounts: Counts

        var body: some View {
            RemoteDetailSplit(
                showsTranscript: model.showsTranscript,
                transcriptLeads: model.transcriptLeads
            ) {
                Probe(counts: terminalCounts)
            } transcript: {
                Probe(counts: transcriptCounts)
            } liveTerminal: {
                Probe(counts: liveCounts)
            }
        }
    }

    private static var hostSize: NSSize { NSSize(width: 900, height: 400) }

    /// Two halves of one claim. The transcript probe proves the toggles really
    /// happened: made and dismantled once per show and hide, so the test cannot
    /// pass against a split that never renders its transcript. The terminal
    /// and live-terminal probes are the property: each made once, never
    /// dismantled.
    @Test("toggling the transcript never remakes or dismantles the terminal side or the live terminal")
    func togglingTheTranscriptNeverRemakesTheTerminal() async throws {
        let model = Model(showsTranscript: false, transcriptLeads: false)
        let terminalCounts = Counts()
        let transcriptCounts = Counts()
        let liveCounts = Counts()
        let host = OffscreenHost(
            root: Root(
                model: model, terminalCounts: terminalCounts, transcriptCounts: transcriptCounts,
                liveCounts: liveCounts),
            size: Self.hostSize)
        defer { host.tearDown() }

        try #require(
            await host.settle { terminalCounts.made == 1 && liveCounts.made == 1 },
            "the terminal side or the live terminal never mounted")
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
        #expect(liveCounts.made == 1, "the live terminal was rebuilt when the transcript changed")
        #expect(liveCounts.dismantled == 0, "the live terminal was torn down when the transcript changed")
    }

    /// Each step waits for the swap to be drawn — the terminal right of the
    /// transcript while the transcript leads, left of it otherwise — so the
    /// test cannot pass against a split that never moves its halves. Through
    /// four swaps no part is made again or dismantled, and the live terminal
    /// stays exactly where the attached terminal side was drawn: a live
    /// terminal that moved with the terminal side would go from the left
    /// half's width to the right half's.
    @Test("swapping the halves never remakes either one or moves the live terminal")
    func swappingNeverRemakesEitherHalf() async throws {
        let model = Model(showsTranscript: true, transcriptLeads: false)
        let terminalCounts = Counts()
        let transcriptCounts = Counts()
        let liveCounts = Counts()
        let host = OffscreenHost(
            root: Root(
                model: model, terminalCounts: terminalCounts, transcriptCounts: transcriptCounts,
                liveCounts: liveCounts),
            size: Self.hostSize)
        defer { host.tearDown() }

        let mounted = await host.settle {
            guard let terminalX = terminalCounts.minX, let transcriptX = transcriptCounts.minX,
                  let liveFrame = liveCounts.frame
            else { return false }
            return transcriptX > terminalX && liveFrame == terminalCounts.frame
        }
        try #require(mounted, """
            the parts never mounted with the terminal side on the left and the live terminal \
            under it: terminal \(terminalCounts.drawnAt), transcript \(transcriptCounts.drawnAt), \
            live terminal \(liveCounts.drawnAt)
            """)
        let attachedFrame = try #require(liveCounts.frame, "the live terminal was not mounted")

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
            let liveFrame = try #require(liveCounts.frame, "step \(step): the live terminal was not mounted")
            #expect(liveFrame == attachedFrame, """
                step \(step): with transcriptLeads \(leads) the live terminal was drawn at \
                \(liveCounts.drawnAt), expected x = \(attachedFrame.minX), width = \(attachedFrame.width)
                """)
        }

        #expect(terminalCounts.made == 1, "a swap rebuilt the terminal side")
        #expect(terminalCounts.dismantled == 0, "a swap tore down the terminal side")
        #expect(transcriptCounts.made == 1, "a swap rebuilt the transcript")
        #expect(transcriptCounts.dismantled == 0, "a swap tore down the transcript")
        #expect(liveCounts.made == 1, "a swap rebuilt the live terminal")
        #expect(liveCounts.dismantled == 0, "a swap tore down the live terminal")
    }

    /// Detaching while the transcript is hidden shows it and moves it to the
    /// left in the same update. Only the transcript is made; the terminal side
    /// moves right, and neither it nor the live terminal is remade.
    @Test("detaching while the transcript is hidden remakes only the transcript")
    func detachingWhileHiddenRemakesOnlyTheTranscript() async throws {
        let model = Model(showsTranscript: false, transcriptLeads: false)
        let terminalCounts = Counts()
        let transcriptCounts = Counts()
        let liveCounts = Counts()
        let host = OffscreenHost(
            root: Root(
                model: model, terminalCounts: terminalCounts, transcriptCounts: transcriptCounts,
                liveCounts: liveCounts),
            size: Self.hostSize)
        defer { host.tearDown() }

        try #require(
            await host.settle { terminalCounts.made == 1 && liveCounts.made == 1 },
            "the terminal side or the live terminal never mounted")
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
        #expect(liveCounts.made == 1, "detaching rebuilt the live terminal")
        #expect(liveCounts.dismantled == 0, "detaching tore down the live terminal")
    }

    @Test("the halves are placed by role, the right half takes the stored width, and the live terminal stays left")
    func columns() {
        let attached: RemoteDetailSplitColumns = Split.columns(
            totalWidth: 1000, rightWidth: 420, dividerWidth: 6,
            showsTranscript: true, transcriptLeads: false)
        let attachedExpected: RemoteDetailSplitColumns = RemoteDetailSplitColumns(
            terminal: RemoteDetailSplitColumn(x: 0, width: 574),
            divider: RemoteDetailSplitColumn(x: 574, width: 6),
            transcript: RemoteDetailSplitColumn(x: 580, width: 420),
            liveTerminal: RemoteDetailSplitColumn(x: 0, width: 574))
        #expect(attached == attachedExpected)

        // The live terminal keeps the left half when the transcript leads:
        // that is where the attached terminal is drawn.
        let notAttached: RemoteDetailSplitColumns = Split.columns(
            totalWidth: 1000, rightWidth: 420, dividerWidth: 6,
            showsTranscript: true, transcriptLeads: true)
        let notAttachedExpected: RemoteDetailSplitColumns = RemoteDetailSplitColumns(
            terminal: RemoteDetailSplitColumn(x: 580, width: 420),
            divider: RemoteDetailSplitColumn(x: 574, width: 6),
            transcript: RemoteDetailSplitColumn(x: 0, width: 574),
            liveTerminal: RemoteDetailSplitColumn(x: 0, width: 574))
        #expect(notAttached == notAttachedExpected)

        let terminalOnlyExpected: RemoteDetailSplitColumns = RemoteDetailSplitColumns(
            terminal: RemoteDetailSplitColumn(x: 0, width: 1000),
            divider: nil,
            transcript: nil,
            liveTerminal: RemoteDetailSplitColumn(x: 0, width: 1000))
        let terminalOnly: RemoteDetailSplitColumns = Split.columns(
            totalWidth: 1000, rightWidth: 420, dividerWidth: 6,
            showsTranscript: false, transcriptLeads: false)
        #expect(terminalOnly == terminalOnlyExpected)
        // `transcriptLeads` is ignored while the transcript is hidden.
        let terminalOnlyLeading: RemoteDetailSplitColumns = Split.columns(
            totalWidth: 1000, rightWidth: 420, dividerWidth: 6,
            showsTranscript: false, transcriptLeads: true)
        #expect(terminalOnlyLeading == terminalOnlyExpected)

        // Too narrow for both minimums: the right half keeps the width it was
        // clamped to, and the left half shrinks.
        let narrow: RemoteDetailSplitColumns = Split.columns(
            totalWidth: 400, rightWidth: 280, dividerWidth: 6,
            showsTranscript: true, transcriptLeads: false)
        let narrowExpected: RemoteDetailSplitColumns = RemoteDetailSplitColumns(
            terminal: RemoteDetailSplitColumn(x: 0, width: 114),
            divider: RemoteDetailSplitColumn(x: 114, width: 6),
            transcript: RemoteDetailSplitColumn(x: 120, width: 280),
            liveTerminal: RemoteDetailSplitColumn(x: 0, width: 114))
        #expect(narrow == narrowExpected)

        // Narrower than the right half plus the divider: the right half is
        // capped at what the divider leaves, so it never extends past the
        // pane, and the left half is empty.
        let tooNarrow: RemoteDetailSplitColumns = Split.columns(
            totalWidth: 250, rightWidth: 280, dividerWidth: 6,
            showsTranscript: true, transcriptLeads: false)
        let tooNarrowExpected: RemoteDetailSplitColumns = RemoteDetailSplitColumns(
            terminal: RemoteDetailSplitColumn(x: 0, width: 0),
            divider: RemoteDetailSplitColumn(x: 0, width: 6),
            transcript: RemoteDetailSplitColumn(x: 6, width: 244),
            liveTerminal: RemoteDetailSplitColumn(x: 0, width: 0))
        #expect(tooNarrow == tooNarrowExpected)
    }

    @Test("the right half is clamped between its minimum and what leaves the left minimum beside the divider")
    func clamp() {
        let belowMinimum: CGFloat = Split.clamp(
            100, totalWidth: 1000, leftMin: 240, rightMin: 280, dividerWidth: 6)
        let belowMinimumExpected: CGFloat = 280
        #expect(belowMinimum == belowMinimumExpected)

        let inRange: CGFloat = Split.clamp(
            500, totalWidth: 1000, leftMin: 240, rightMin: 280, dividerWidth: 6)
        let inRangeExpected: CGFloat = 500
        #expect(inRange == inRangeExpected)

        // The upper bound leaves the left minimum and the divider: 1000 − 240 − 6.
        let aboveMaximum: CGFloat = Split.clamp(
            900, totalWidth: 1000, leftMin: 240, rightMin: 280, dividerWidth: 6)
        let aboveMaximumExpected: CGFloat = 754
        #expect(aboveMaximum == aboveMaximumExpected)

        // Too narrow for both minimums and the divider: the left half keeps
        // its minimum and the right half takes the rest: 400 − 240 − 6.
        let tooNarrow: CGFloat = Split.clamp(
            500, totalWidth: 400, leftMin: 240, rightMin: 280, dividerWidth: 6)
        let tooNarrowExpected: CGFloat = 154
        #expect(tooNarrow == tooNarrowExpected)

        // Narrower than the left minimum plus the divider: nothing is left.
        let belowLeftMinimum: CGFloat = Split.clamp(
            500, totalWidth: 200, leftMin: 240, rightMin: 280, dividerWidth: 6)
        let belowLeftMinimumExpected: CGFloat = 0
        #expect(belowLeftMinimum == belowLeftMinimumExpected)

        // Exactly both minimums and the divider.
        let exactFit: CGFloat = Split.clamp(
            526, totalWidth: 526, leftMin: 240, rightMin: 280, dividerWidth: 6)
        let exactFitExpected: CGFloat = 280
        #expect(exactFit == exactFitExpected)
    }
}
