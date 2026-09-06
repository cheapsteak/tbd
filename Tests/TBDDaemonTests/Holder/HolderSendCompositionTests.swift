import Foundation
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
    @Test("a marker that would re-form across the removal is removed too")
    func aReformingEndMarkerIsAlsoRemoved() {
        let body = "\u{1b}[2\u{1b}[201~01~tail"
        let composed = HolderSendComposition.compose(
            body: body, submit: false, bracketedPaste: true)

        #expect(composed == Self.expected(body: "tail", wrapped: true, submit: false))
        #expect(Self.occurrences(of: Self.end, in: composed) == 1)
    }

    /// **Only the wrapped path touches the body.** With no paste open there is
    /// nothing to break out of, and the bytes are the caller's to send — a
    /// caller writing an end marker to a child that reads them literally is
    /// entitled to have it arrive. Silently editing an unwrapped send would be
    /// a second, invisible rule about what `terminal.send` delivers.
    @Test("the same body unwrapped is delivered verbatim, marker included")
    func anUnwrappedBodyKeepsItsEndMarker() {
        let body = "before\u{1b}[201~after"
        let composed = HolderSendComposition.compose(
            body: body, submit: true, bracketedPaste: false)

        #expect(composed == Self.expected(body: body, wrapped: false, submit: true))
        #expect(
            Self.occurrences(of: Self.end, in: composed) == 1,
            "the caller's own end marker did not survive an unwrapped send")
        #expect(Self.occurrences(of: Self.start, in: composed) == 0)
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

    /// The start marker is deliberately *not* stripped: it opens nothing a
    /// child has not already been told is open, so it cannot break out, and
    /// removing it would edit a body for no gain. This pins the asymmetry so it
    /// reads as a decision rather than an oversight.
    @Test("a start marker inside the body is left alone")
    func anEmbeddedStartMarkerIsLeftAlone() {
        let body = "before\u{1b}[200~after"
        let composed = HolderSendComposition.compose(
            body: body, submit: false, bracketedPaste: true)

        #expect(composed == Self.expected(body: body, wrapped: true, submit: false))
        #expect(Self.occurrences(of: Self.start, in: composed) == 2)
    }
}
