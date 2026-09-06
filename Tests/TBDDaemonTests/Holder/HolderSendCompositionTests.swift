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
}
