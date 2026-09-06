import Foundation
import TBDShared
import Testing

@testable import TBDDaemonLib

/// The bytes a holder send is made of, asserted whole.
///
/// **Every case compares the entire `Data`.** A substring check would pass on a
/// message with the submitting `\r` *inside* the paste — which is the exact
/// defect this composition exists to fix, so an assertion that cannot see it is
/// not an assertion about this at all. `--text --submit` was measured losing its
/// Enter at ~230 bytes and again at 4 KB: an agent TUI's paste-burst heuristic
/// keys on the shape of a chunk, so the envelope's own newline was enough to
/// make a bare `\r` look like part of a paste. Putting the `\r` after an
/// explicit `ESC[201~` is what makes it provably a keystroke.
@Suite struct HolderSendCompositionTests {

    private static let start = Data([0x1b, 0x5b, 0x32, 0x30, 0x30, 0x7e])  // ESC[200~
    private static let end = Data([0x1b, 0x5b, 0x32, 0x30, 0x31, 0x7e])  // ESC[201~
    private static let carriageReturn = Data([0x0d])

    /// The expected bytes, assembled step by step.
    ///
    /// Spelled out rather than written as one `+` chain: `Data`'s concatenation
    /// operators are generic over `Sequence`, and a four-term chain of them
    /// takes the type checker past its budget.
    private static func expected(
        body: String, wrapped: Bool, submit: Bool
    ) -> Data {
        var data = Data()
        if !body.isEmpty {
            if wrapped { data.append(start) }
            data.append(Data(body.utf8))
            if wrapped { data.append(end) }
        }
        if submit { data.append(contentsOf: carriageReturn) }
        return data
    }

    /// How many times `needle` occurs in `haystack`, spelled out rather than
    /// taken from a stdlib search: these assertions are about exact byte
    /// sequences, and the count is what distinguishes "the markers are there"
    /// from "the markers are there once".
    private static func occurrences(of needle: Data, in haystack: Data) -> Int {
        let bytes = [UInt8](haystack)
        let pattern = [UInt8](needle)
        guard !pattern.isEmpty, bytes.count >= pattern.count else { return 0 }
        var found = 0
        for start in 0...(bytes.count - pattern.count)
        where Array(bytes[start..<(start + pattern.count)]) == pattern {
            found += 1
        }
        return found
    }

    /// The whole point, byte for byte: markers around the body, the Enter after
    /// the closing marker, nothing else anywhere.
    @Test("bracketed paste on, submitting: markers around the body, the Enter after them")
    func wrapsAndSubmits() {
        let composed = HolderSendComposition.compose(
            body: "hello", submit: true, bracketedPaste: true)

        #expect(composed == Self.expected(body: "hello", wrapped: true, submit: true))
        // Stated separately because it is the property, not an artefact of the
        // literal above: the Enter is the last byte and it follows the end
        // marker rather than sitting inside the paste.
        #expect(composed.last == 0x0d)
        #expect(composed.dropLast().suffix(Self.end.count) == Self.end)
    }

    /// A child that never asked for bracketing must not receive markers. A
    /// shell at its prompt would execute a line beginning with one.
    @Test("bracketed paste off, submitting: bare body and the Enter, no markers")
    func bareWhenTheChildDidNotAskForBracketing() {
        let composed = HolderSendComposition.compose(
            body: "hello", submit: true, bracketedPaste: false)

        #expect(composed == Self.expected(body: "hello", wrapped: false, submit: true))
        #expect(Self.occurrences(of: Self.start, in: composed) == 0)
        #expect(Self.occurrences(of: Self.end, in: composed) == 0)
    }

    @Test("bracketed paste on, not submitting: markers and no Enter")
    func wrapsWithoutSubmitting() {
        let composed = HolderSendComposition.compose(
            body: "hello", submit: false, bracketedPaste: true)

        #expect(composed == Self.expected(body: "hello", wrapped: true, submit: false))
        #expect(composed.last != 0x0d)
    }

    /// `tbd terminal send --text "" --submit` is a real way to press Enter and
    /// has to stay one. Wrapping nothing would put a pair of markers in front
    /// of it — bytes the child never asked for, in the one case where the
    /// caller asked for a single keystroke and nothing else.
    @Test("an empty body is never wrapped, in either mode")
    func anEmptyBodyIsNeverWrapped() {
        for bracketed in [true, false] {
            #expect(
                HolderSendComposition.compose(
                    body: "", submit: true, bracketedPaste: bracketed) == Self.carriageReturn,
                "an empty submitting send with bracketedPaste: \(bracketed) was not a bare Enter")
        }
    }

    /// Nothing to say and no key to press composes to nothing, and the handler
    /// above turns that into a dispatched row that wrote no bytes.
    @Test("an empty body with no submit composes nothing at all")
    func anEmptyBodyWithoutSubmitIsEmpty() {
        for bracketed in [true, false] {
            #expect(
                HolderSendComposition.compose(
                    body: "", submit: false, bracketedPaste: bracketed).isEmpty)
        }
    }

    /// The multi-line shape the field defect was measured on: the body's own
    /// newlines stay inside the paste, so the burst heuristic sees one paste
    /// and one keystroke rather than one ambiguous chunk.
    @Test("a multi-line body keeps its newlines inside the paste")
    func multiLineBodyStaysInsideThePaste() {
        let body = "<tbd-dispatch id=\"a\"/>\nfirst line\nsecond line"
        let composed = HolderSendComposition.compose(
            body: body, submit: true, bracketedPaste: true)

        #expect(composed == Self.expected(body: body, wrapped: true, submit: true))
        #expect(
            Self.occurrences(of: Self.start, in: composed) == 1,
            "the start marker appears more than once")
    }

    // MARK: - A body that tries to close the paste itself

    /// The break-out. A body carrying `ESC[201~` — one `--text "$(cat file)"`
    /// away — closes the paste where it sits, so the rest of the body and the
    /// submitting `\r` arrive as keystrokes: the exact defect the wrapping
    /// exists to prevent, reached through content instead of chunk shape.
    ///
    /// Asserted as the whole `Data` *and* as a marker count, because they fail
    /// differently: the equality says the composition is right, the count says
    /// there is no second marker anywhere for a child to act on.
    @Test("an end marker inside the body is removed rather than allowed to close the paste")
    func embeddedEndMarkerIsRemoved() {
        let body = "before\u{1b}[201~after"
        let composed = HolderSendComposition.compose(
            body: body, submit: true, bracketedPaste: true)

        #expect(composed == Self.expected(body: "beforeafter", wrapped: true, submit: true))
        #expect(
            Self.occurrences(of: Self.end, in: composed) == 1,
            "the composed message carries more than one end marker")
        #expect(composed.last == 0x0d)
        #expect(composed.dropLast().suffix(Self.end.count) == Self.end)
    }

    /// One replacing pass is not enough, and this is the body that shows it:
    /// take the marker out of `ESC[2` + marker + `01~` and the neighbours join
    /// into a fresh one. The scan retracts a marker as the byte completing it
    /// is appended, so the output provably holds none.
    @Test("an end marker that would re-form across the removal is removed too")
    func aReformingEndMarkerIsAlsoRemoved() {
        let body = "\u{1b}[2\u{1b}[201~01~tail"
        let composed = HolderSendComposition.compose(
            body: body, submit: false, bracketedPaste: true)

        #expect(composed == Self.expected(body: "tail", wrapped: true, submit: false))
        #expect(Self.occurrences(of: Self.end, in: composed) == 1)
    }

    /// **The bare path strips too.** A paste marker is never content a child
    /// can display: with bracketing off it prints the six bytes or misreads
    /// them, so verbatim delivery serves no caller. And the mode this reads can
    /// be stale — a `staleDaemon` "off" is a guess about a child that may have
    /// turned bracketing on since the attach — in which case an unstripped
    /// `ESC[200~` opens a paste nothing closes and swallows the `\r` below and
    /// every later keystroke. So the same body composed bare loses both
    /// markers, exactly as the wrapped one does.
    @Test("the same body unwrapped loses its paste markers too")
    func anUnwrappedBodyLosesItsPasteMarkersToo() {
        let body = "before\u{1b}[200~middle\u{1b}[201~after"
        let composed = HolderSendComposition.compose(
            body: body, submit: true, bracketedPaste: false)

        #expect(
            composed == Self.expected(body: "beforemiddleafter", wrapped: false, submit: true))
        #expect(
            Self.occurrences(of: Self.start, in: composed) == 0,
            "a start marker survived a bare send and can open a paste nothing closes")
        #expect(
            Self.occurrences(of: Self.end, in: composed) == 0,
            "an end marker survived a bare send")
    }

    /// A body that is *nothing but* an end marker has nothing left to paste,
    /// and the empty-body rule then applies to it: a bare Enter, not a pair of
    /// markers wrapped around nothing. The stripping runs before the emptiness
    /// test precisely so the two rules compose.
    @Test("a body of only an end marker composes to a bare Enter")
    func aBodyOfOnlyAnEndMarker() {
        let composed = HolderSendComposition.compose(
            body: "\u{1b}[201~", submit: true, bracketedPaste: true)

        #expect(composed == Self.carriageReturn)
        #expect(Self.occurrences(of: Self.end, in: composed) == 0)
        #expect(Self.occurrences(of: Self.start, in: composed) == 0)
    }

    /// The same body without `--submit`: the strip empties it, the empty-body
    /// rule declines to wrap it, and no Return follows — so the composition is
    /// nothing at all. It is the second way a caller with something to say
    /// reaches an empty message, and the send arm above records the mode
    /// provenance for it, because a composition did run.
    @Test("a body of only an end marker and no submit composes to nothing")
    func aBodyOfOnlyAnEndMarkerWithoutSubmit() {
        let composed = HolderSendComposition.compose(
            body: "\u{1b}[201~", submit: false, bracketedPaste: true)

        #expect(composed.isEmpty)
    }

    /// The bare-mode variant of the pair above, and the case the stale-mode
    /// hazard is sharpest in: a body that is nothing but a marker composes to a
    /// bare Enter here too, because the strip runs before the emptiness test in
    /// both modes. Delivering the marker instead would send a child that has
    /// bracketing on — as a `staleDaemon` "off" cannot rule out — six bytes and
    /// then a `\r` it would absorb.
    @Test("a body of only a marker composes to a bare Enter in bare mode too")
    func aBodyOfOnlyAMarkerIsABareEnterUnwrapped() {
        for marker in ["\u{1b}[201~", "\u{1b}[200~"] {
            let composed = HolderSendComposition.compose(
                body: marker, submit: true, bracketedPaste: false)

            #expect(
                composed == Self.carriageReturn,
                "a bare submitting send of only \(marker.debugDescription) was not a bare Enter")
            #expect(Self.occurrences(of: Self.start, in: composed) == 0)
            #expect(Self.occurrences(of: Self.end, in: composed) == 0)
        }
    }

    /// And without `--submit` there is nothing left to write at all — the
    /// second way a caller with something to say reaches an empty message,
    /// reached in bare mode as well as wrapped.
    @Test("a body of only a marker and no submit composes to nothing in bare mode too")
    func aBodyOfOnlyAMarkerWithoutSubmitIsEmptyUnwrapped() {
        for marker in ["\u{1b}[201~", "\u{1b}[200~"] {
            #expect(
                HolderSendComposition.compose(
                    body: marker, submit: false, bracketedPaste: false).isEmpty,
                "a bare non-submitting send of only \(marker.debugDescription) wrote bytes")
        }
    }

    // MARK: - A body that tries to restart the paste itself

    /// The other break-out, and the reason the start marker is stripped as
    /// well: a child whose reader takes a nested `ESC[200~` as the beginning of
    /// a new paste discards everything before it — the dispatch envelope
    /// included — so what it acts on is not what the caller sent. A log or a
    /// transcript that recorded raw terminal input carries one.
    @Test("a start marker inside the body is removed rather than allowed to restart the paste")
    func anEmbeddedStartMarkerIsRemoved() {
        let body = "before\u{1b}[200~after"
        let composed = HolderSendComposition.compose(
            body: body, submit: false, bracketedPaste: true)

        #expect(composed == Self.expected(body: "beforeafter", wrapped: true, submit: false))
        #expect(
            Self.occurrences(of: Self.start, in: composed) == 1,
            "the composed message carries more than one start marker")
    }

    /// The re-formation property holds for the start marker too: take the
    /// marker out of `ESC[2` + marker + `00~` and the neighbours join into a
    /// fresh one, which the same append-and-retract scan catches as the byte
    /// completing it is appended.
    @Test("a start marker that would re-form across the removal is removed too")
    func aReformingStartMarkerIsAlsoRemoved() {
        let body = "\u{1b}[2\u{1b}[200~00~tail"
        let composed = HolderSendComposition.compose(
            body: body, submit: false, bracketedPaste: true)

        #expect(composed == Self.expected(body: "tail", wrapped: true, submit: false))
        #expect(Self.occurrences(of: Self.start, in: composed) == 1)
    }

    /// The two markers touching, which is what a body copied out of a recorded
    /// paste looks like. They share their first four bytes, so removing one
    /// must not leave a suffix that completes the other unnoticed — the scan
    /// re-checks after every retraction, and both are gone.
    @Test("a start and an end marker adjacent in the body are both removed")
    func adjacentStartAndEndMarkersAreBothRemoved() {
        let body = "head\u{1b}[200~\u{1b}[201~tail"
        let composed = HolderSendComposition.compose(
            body: body, submit: true, bracketedPaste: true)

        #expect(composed == Self.expected(body: "headtail", wrapped: true, submit: true))
        #expect(Self.occurrences(of: Self.start, in: composed) == 1)
        #expect(Self.occurrences(of: Self.end, in: composed) == 1)
        #expect(composed.last == 0x0d)
        #expect(composed.dropLast().suffix(Self.end.count) == Self.end)
    }

    // MARK: - Whether to wrap at all

    private static func reading(
        bracketedPaste: Bool, modesObserved: Bool, source: TerminalScreen.Source = .daemon
    ) -> TerminalModeReading {
        TerminalModeReading(
            modes: TerminalScreen.ChildModes(
                bracketedPaste: bracketedPaste, applicationCursor: false,
                alternateScreen: false),
            modesObserved: modesObserved,
            source: source,
            ageMilliseconds: 0)
    }

    /// Nothing answered, so there is nothing to reason from. The write is about
    /// to fail and say so, and bare bytes are what every child understood
    /// before any of this existed. The child-kind flag cannot change that.
    @Test("no reading at all composes bare")
    func noReadingComposesBare() {
        #expect(HolderSendComposition.bracketedPaste(for: nil, unobservedShouldWrap: true) == false)
        #expect(
            HolderSendComposition.bracketedPaste(for: nil, unobservedShouldWrap: false) == false)
    }

    /// An observed flag is evidence about the child, so it is simply obeyed and
    /// `unobservedShouldWrap` does not enter into it — asserted with the flag
    /// set both ways to show it is ignored when the modes are observed.
    @Test("an observed mode is taken at its word, and the child-kind flag is ignored")
    func observedModeIsObeyed() {
        for unobservedShouldWrap in [true, false] {
            #expect(
                HolderSendComposition.bracketedPaste(
                    for: Self.reading(bracketedPaste: true, modesObserved: true),
                    unobservedShouldWrap: unobservedShouldWrap))
            #expect(
                HolderSendComposition.bracketedPaste(
                    for: Self.reading(bracketedPaste: false, modesObserved: true),
                    unobservedShouldWrap: unobservedShouldWrap) == false)
        }
    }

    /// An unobserved reading is a guess, and where it lands is the caller's
    /// call: `unobservedShouldWrap: true` is an agent session, whose burst
    /// heuristic can absorb a bare `\r` silently, so wrapping buys the visible
    /// failure over the silent one. The flag's own `bracketedPaste` value is
    /// not evidence of anything and does not move the answer.
    @Test("an unobserved reading wraps when the caller says to, whatever the flag reads")
    func unobservedReadingWrapsWhenAsked() {
        #expect(
            HolderSendComposition.bracketedPaste(
                for: Self.reading(bracketedPaste: false, modesObserved: false),
                unobservedShouldWrap: true))
        #expect(
            HolderSendComposition.bracketedPaste(
                for: Self.reading(bracketedPaste: true, modesObserved: false),
                unobservedShouldWrap: true))
    }

    /// The regression this closes: a shell composes bare under the same
    /// uncertainty, because its line editor submits bare input of any length
    /// and has no burst heuristic to fool. `unobservedShouldWrap: false`, and
    /// the guessed `bracketedPaste` value must not talk it back into wrapping.
    @Test("an unobserved reading stays bare when the caller says not to wrap")
    func unobservedReadingStaysBareWhenNotAsked() {
        #expect(
            HolderSendComposition.bracketedPaste(
                for: Self.reading(bracketedPaste: false, modesObserved: false),
                unobservedShouldWrap: false) == false)
        #expect(
            HolderSendComposition.bracketedPaste(
                for: Self.reading(bracketedPaste: true, modesObserved: false),
                unobservedShouldWrap: false) == false)
    }
}
