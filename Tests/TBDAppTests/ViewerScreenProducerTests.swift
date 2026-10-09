import AppKit
import Foundation
import SwiftTerm
import TBDShared
import TBDTerminalSerialization
import Testing

@testable import TBDApp

/// What a viewer's answer says, and what it refuses to say.
///
/// The lines, the viewport offset, the cursor position and the modes must equal
/// what the shared projection produces from the same terminal — that is the
/// screen contract's "the two stores project identically by construction",
/// asserted on the app's side of it. The age must come from the view holder's
/// stamp rather than the wall clock. And cursor visibility must be reported as
/// a default and flagged as one, because SwiftTerm's `TerminalView` keeps
/// `DECTCEM` to itself.
@Suite("Viewer screen producer")
@MainActor
struct ViewerScreenProducerTests {

    /// A real `TBDTerminalView` fed real bytes, which is the production path:
    /// `withTerminal` is what the producer takes its single hold on, and a
    /// hand-built grid would agree with anything.
    ///
    /// Isolated defaults, per `Tests/CLAUDE.md`: `AppearanceSettings` must
    /// never read or write the developer's real `TBDApp.plist`, and the suite
    /// is removed on the way out.
    private func withView(
        feeding text: String = "", _ body: (TBDTerminalView) throws -> Void
    ) throws {
        let suiteName = "TBDAppTests.ViewerScreenProducer.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { UserDefaults().removePersistentDomain(forName: suiteName) }
        let view = TBDTerminalView(
            frame: CGRect(x: 0, y: 0, width: 600, height: 300),
            font: TBDTerminalView.defaultMonospaceFont,
            appearance: AppearanceSettings(defaults: defaults))
        if !text.isEmpty { view.withTerminal { $0.feed(text: text) } }
        try body(view)
    }

    private func request(
        lines: Int = 50, styled: Bool = false
    ) -> SidecarScreenRequest {
        SidecarScreenRequest(
            terminalID: UUID(), requestID: UUID(), requestedLines: lines,
            retainedScrollbackLines: 5_000, wantStyledCapture: styled)
    }

    /// One fixed instant the age tests measure from, so nothing races a clock.
    private static let start = ContinuousClock.now

    // MARK: - Identical projection

    @Test("the payload's lines, viewport, cursor and modes are the shared projection's")
    func payloadMatchesTheSharedProjection() throws {
        try withView(feeding: "\u{1b}[?2004h\u{1b}[?1hfirst\r\nsecond\r\n\u{1b}[2;4H") { view in
            let answer = ViewerScreenProducer.answer(
                for: request(), terminalView: view,
                lastByteAt: Self.start, attachedAt: Self.start, now: Self.start)
            let projected = view.withTerminal {
                TerminalScreenProjection.project($0, maxLines: 50)
            }

            #expect(answer.payload.lines == projected.lines)
            #expect(answer.payload.viewportStart == projected.viewportStart)
            #expect(answer.payload.cursorRow == projected.cursorRow)
            #expect(answer.payload.cursorColumn == projected.cursorColumn)
            #expect(answer.payload.size == projected.size)
            #expect(answer.payload.modes == projected.modes)
            // Guards the fixture: a stream that set no modes would make the
            // comparison above two sets of defaults and assert nothing.
            #expect(answer.payload.modes.bracketedPaste)
            #expect(answer.payload.modes.applicationCursor)
            #expect(answer.payload.lines.contains("first"))
        }
    }

    /// The depth the request names is the depth that comes back, because the
    /// cap is the daemon's and the viewer does not second-guess it.
    @Test("the requested depth bounds the lines the payload carries")
    func requestedDepthBoundsTheLines() throws {
        let body = (1...80).map { "line \($0)" }.joined(separator: "\r\n")
        try withView(feeding: body) { view in
            let shallow = ViewerScreenProducer.answer(
                for: request(lines: 5), terminalView: view,
                lastByteAt: nil, attachedAt: Self.start, now: Self.start)
            #expect(shallow.payload.lines.count <= 5)

            let deep = ViewerScreenProducer.answer(
                for: request(lines: 500), terminalView: view,
                lastByteAt: nil, attachedAt: Self.start, now: Self.start)
            #expect(deep.payload.lines.count > shallow.payload.lines.count,
                    "a deeper request must actually reach further back")
        }
    }

    /// A modes-only reading walks nothing, which is what makes the oracle's
    /// consultation a few hundred bytes instead of a scrollback walk.
    @Test("a zero-line request carries no lines but still carries the modes")
    func zeroLineRequestCarriesModesOnly() throws {
        try withView(feeding: "\u{1b}[?2004hvisible text") { view in
            let answer = ViewerScreenProducer.answer(
                for: request(lines: 0), terminalView: view,
                lastByteAt: nil, attachedAt: Self.start, now: Self.start)

            #expect(answer.payload.lines.isEmpty)
            #expect(answer.payload.modes.bracketedPaste)
            #expect(answer.payload.size.columns > 0, "the grid is still reported")
        }
    }

    // MARK: - The age

    /// Driven from the stamp, never measured: the producer takes both instants,
    /// so a test states the interval rather than racing the clock.
    @Test("the age is the interval since the store's last byte")
    func ageComesFromTheLastByteStamp() throws {
        try withView(feeding: "hello") { view in
            let fedAt = Self.start
            let answer = ViewerScreenProducer.answer(
                for: request(), terminalView: view,
                lastByteAt: fedAt, attachedAt: fedAt.advanced(by: .seconds(-30)),
                now: fedAt.advanced(by: .milliseconds(1_250)))

            #expect(answer.payload.ageMilliseconds == 1_250)
        }
    }

    /// The app-side twin of the daemon emulator's `lastByteAt ?? adoptedAt`
    /// rule: a store that has never consumed a byte reports the age of the
    /// store itself, so a session that went quiet before its viewer arrived
    /// does not read as instantly current.
    @Test("a store that has never been fed reports its age from the attach")
    func neverFedStoreAgesFromTheAttach() throws {
        try withView { view in
            let attachedAt = Self.start
            let answer = ViewerScreenProducer.answer(
                for: request(), terminalView: view,
                lastByteAt: nil, attachedAt: attachedAt,
                now: attachedAt.advanced(by: .milliseconds(700)))

            #expect(answer.payload.ageMilliseconds == 700,
                    "with no byte ever consumed the age is the store's own, not zero")
        }
    }

    /// `TerminalScreen` refuses a negative age, so a clock seam that ran
    /// backwards must not be able to put one on the wire.
    @Test("an age measured backwards clamps at zero rather than going negative")
    func backwardsClockClampsAtZero() throws {
        try withView { view in
            let fedAt = Self.start
            let answer = ViewerScreenProducer.answer(
                for: request(), terminalView: view,
                lastByteAt: fedAt, attachedAt: fedAt,
                now: fedAt.advanced(by: .milliseconds(-500)))

            #expect(answer.payload.ageMilliseconds == 0)
        }
    }

    // MARK: - Provenance the app must not invent

    /// The ruling, as an assertion: a viewer answer reports the `DECTCEM`
    /// default and says it is a default. SwiftTerm's `TerminalView` implements
    /// `TerminalDelegate` itself and forwards neither `showCursor` nor
    /// `hideCursor`, and probing a live parser is forbidden — so the honest
    /// answer is the default plus the flag.
    @Test("cursor visibility is the mode default, flagged as not observed")
    func cursorVisibilityIsADefault() throws {
        // The child hides its cursor. The payload still reports it visible,
        // because this store cannot see the difference — and says so.
        try withView(feeding: "\u{1b}[?25lhidden") { view in
            let answer = ViewerScreenProducer.answer(
                for: request(), terminalView: view,
                lastByteAt: nil, attachedAt: Self.start, now: Self.start)

            #expect(answer.payload.cursorVisible == ViewerScreenProducer.cursorVisibleDefault)
            #expect(!answer.payload.cursorVisibleObserved,
                    "a viewer's emulator cannot observe DECTCEM, and must not claim to")
        }
    }

    /// The payload carries the viewer's half of a screen and none of the
    /// daemon's. Nothing here can set `source`, `modesObserved` or
    /// `contentObserved`, and this is the producer end of that: the type has no
    /// field for them, so the assertion is on what it *does* carry being
    /// everything it was given.
    @Test("the payload carries no provenance beyond the cursor flag")
    func payloadCarriesNoDaemonProvenance() throws {
        try withView(feeding: "text") { view in
            let answer = ViewerScreenProducer.answer(
                for: request(), terminalView: view,
                lastByteAt: nil, attachedAt: Self.start, now: Self.start)
            let encoded = try JSONEncoder().encode(answer.payload)
            let object = try JSONSerialization.jsonObject(with: encoded)
            let fields = try #require(object as? [String: Any])

            #expect(
                Set(fields.keys)
                    .isDisjoint(with: ["source", "modesObserved", "contentObserved"]))
        }
    }

    // MARK: - The styled capture

    @Test("the styled capture is produced only when it is asked for")
    func styledCaptureOnlyWhenAsked() throws {
        try withView(feeding: "\u{1b}[31mred line\u{1b}[0m") { view in
            let without = ViewerScreenProducer.answer(
                for: request(styled: false), terminalView: view,
                lastByteAt: nil, attachedAt: Self.start, now: Self.start)
            #expect(without.styledCapture == nil)

            let with = ViewerScreenProducer.answer(
                for: request(styled: true), terminalView: view,
                lastByteAt: nil, attachedAt: Self.start, now: Self.start)
            let capture = try #require(with.styledCapture)
            #expect(capture.contains("red line"))
            #expect(capture.contains("\u{1b}["), "the colours are the point of a styled capture")
        }
    }

    /// The shape Closed Terminals history records, applied where the capture is
    /// produced rather than re-derived on receipt — so one shape is written
    /// whichever store answered. Every rule here is
    /// `HolderReader.closedTerminalCapture`'s.
    @Test("a styled capture ends with an SGR reset and joins with newlines")
    func styledCaptureMatchesTheHistoryShape() throws {
        try withView(feeding: "first\r\nsecond") { view in
            let answer = ViewerScreenProducer.answer(
                for: request(styled: true), terminalView: view,
                lastByteAt: nil, attachedAt: Self.start, now: Self.start)
            let capture = try #require(answer.styledCapture)

            #expect(capture.hasSuffix("\u{1b}[0m\n"),
                    "a revived shell's prompt must not inherit the last line's colours")
            #expect(!capture.contains("\r\n"),
                    "a revive cats the file rather than feeding it to a terminal")
            #expect(capture.contains("first"))
            #expect(capture.contains("second"))
        }
    }

    @Test("an empty screen's styled capture is empty rather than a bare reset")
    func emptyScreenGivesAnEmptyCapture() throws {
        try withView { view in
            let answer = ViewerScreenProducer.answer(
                for: request(styled: true), terminalView: view,
                lastByteAt: nil, attachedAt: Self.start, now: Self.start)

            #expect(answer.styledCapture == "",
                    "the history store records an empty capture as an entry with no capture")
        }
    }
}
