import Foundation
import Testing

@testable import TBDShared

/// What `TerminalScreen` promises about any value that exists at all.
///
/// Two properties, both structural. **The whitelist is enforced at
/// construction**, so a row carrying a control character cannot be shipped to a
/// consumer that matches on text and would silently fail to find the characters
/// on either side of it — the failure mode measured in the field as 1,595
/// invisible `U+0000` cells nobody had noticed. And **`output` is derived**, so
/// it can never disagree with `lines` however it arrived.
///
/// The NUL-to-space projection itself is deliberately *not* here. It belongs to
/// whichever store rendered the grid, and is pinned on the constructed value in
/// `HolderScreenContractTests`; here a NUL is simply refused like any other
/// control character, which is what makes a projection that forgot it loud.
@Suite struct TerminalScreenTests {

    private static func make(
        lines: [String],
        viewportStart: Int = 0,
        source: TerminalScreen.Source = .daemon,
        ageMilliseconds: Int = 0
    ) throws -> TerminalScreen {
        try TerminalScreen(
            lines: lines,
            viewportStart: viewportStart,
            cursor: TerminalScreen.Cursor(row: 0, column: 0, visible: true),
            size: TerminalScreen.Size(columns: 80, rows: 24),
            modes: TerminalScreen.ChildModes(
                bracketedPaste: false, applicationCursor: false, alternateScreen: false),
            source: source,
            ageMilliseconds: ageMilliseconds)
    }

    // MARK: - The whitelist

    /// The projection's job is to turn a never-written cell into a space. One
    /// arriving here means it did not, so the boundary refuses rather than
    /// passing on a hole nothing displays.
    @Test("a NUL is refused, and the error names the line it was on")
    func nulIsRefused() throws {
        let error = #expect(throws: TerminalScreen.ValidationError.self) {
            _ = try Self.make(lines: ["fine", "also fine", "bro\u{0}ken"])
        }
        #expect(error == .disallowedCharacter(lineIndex: 2, scalar: 0))
        // The line index is in the text a reader sees, not only in the value —
        // it is the whole of what makes the projection bug findable.
        #expect(error?.description.contains("line 2") == true)
        #expect(error?.description.contains("U+0000") == true)
    }

    @Test("any other control character is refused, named by line and scalar")
    func controlCharactersAreRefused() throws {
        // One from each excluded band: C0, DEL, and C1.
        for (scalar, line) in [(UInt32(0x07), "bel\u{7}l"), (0x7f, "de\u{7f}l"), (0x9b, "c\u{9b}1")] {
            let error = #expect(throws: TerminalScreen.ValidationError.self) {
                _ = try Self.make(lines: ["clean", line])
            }
            #expect(error == .disallowedCharacter(lineIndex: 1, scalar: scalar))
            #expect(error?.description.contains("line 1") == true)
        }
    }

    /// A newline in a *line* is a projection that lost track of its rows, so it
    /// is refused with everything else in the C0 band.
    @Test("a newline inside a line is refused")
    func newlineInsideALineIsRefused() throws {
        let error = #expect(throws: TerminalScreen.ValidationError.self) {
            _ = try Self.make(lines: ["two\nrows"])
        }
        #expect(error == .disallowedCharacter(lineIndex: 0, scalar: 0x0a))
    }

    /// Tab is the one control a line may hold: a program laying a screen out
    /// with tabs is doing something a reader can see, and stripping them would
    /// move every column after one.
    @Test("a tab is allowed through")
    func tabIsAllowed() throws {
        let screen = try Self.make(lines: ["name\tvalue"])
        #expect(screen.lines == ["name\tvalue"])
        #expect(screen.output == "name\tvalue")
    }

    @Test("a negative age is refused")
    func negativeAgeIsRefused() throws {
        let error = #expect(throws: TerminalScreen.ValidationError.self) {
            _ = try Self.make(lines: ["ok"], ageMilliseconds: -1)
        }
        #expect(error == .negativeAge(milliseconds: -1))
    }

    @Test("an age of zero is a well-formed answer, not a refusal")
    func zeroAgeIsAllowed() throws {
        #expect(try Self.make(lines: ["ok"], ageMilliseconds: 0).ageMilliseconds == 0)
    }

    // MARK: - `output` is derived, and it is on the wire

    @Test("output is the lines joined with newlines")
    func outputIsDerived() throws {
        #expect(try Self.make(lines: ["one", "two", "three"]).output == "one\ntwo\nthree")
    }

    /// Scripts read `tbd terminal output --json` and pull `.output` out of it.
    /// A computed property would never reach the wire, so the encoder writes it
    /// explicitly — and this is what would go red if that were dropped as
    /// redundant.
    @Test("output appears in the encoded JSON beside lines")
    func outputIsEncoded() throws {
        let data = try JSONEncoder().encode(try Self.make(lines: ["alpha", "beta"]))
        let object = try #require(
            try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(object["output"] as? String == "alpha\nbeta")
        #expect(object["lines"] as? [String] == ["alpha", "beta"])
    }

    /// The other half: whatever an `output` key on the wire says, the decoded
    /// value derives it from `lines`. A producer and a consumer can therefore
    /// never disagree, and a payload written before the key existed decodes the
    /// same as one written after.
    @Test("decoding ignores any output on the wire and re-derives it from lines")
    func decodingIgnoresWireOutput() throws {
        let cursor = #"{"row":1,"column":2,"visible":true}"#
        let size = #"{"columns":80,"rows":24}"#
        let modes =
            #"{"bracketedPaste":true,"applicationCursor":false,"alternateScreen":false}"#

        let lying = """
            {"lines":["alpha","beta"],"viewportStart":0,"cursor":\(cursor),"size":\(size),\
            "modes":\(modes),"source":"daemon","ageMilliseconds":5,"output":"NOT THE LINES"}
            """
        let fromLie = try JSONDecoder().decode(
            TerminalScreen.self, from: Data(lying.utf8))
        #expect(fromLie.output == "alpha\nbeta")

        let withoutOutput = """
            {"lines":["alpha","beta"],"viewportStart":0,"cursor":\(cursor),"size":\(size),\
            "modes":\(modes),"source":"daemon","ageMilliseconds":5}
            """
        let fromAbsence = try JSONDecoder().decode(
            TerminalScreen.self, from: Data(withoutOutput.utf8))
        #expect(fromAbsence.output == "alpha\nbeta")
        #expect(fromAbsence == fromLie, "the wire's output changed the decoded value")
    }

    // MARK: - The fields a string could not carry

    /// A round trip through JSON is the shape every consumer actually meets,
    /// and `source` is the field a consumer's whole policy is keyed on.
    @Test("source and age survive a round trip")
    func sourceAndAgeRoundTrip() throws {
        let screen = try Self.make(
            lines: ["idle"], source: .staleDaemon, ageMilliseconds: 2_460_000)
        let decoded = try JSONDecoder().decode(
            TerminalScreen.self, from: try JSONEncoder().encode(screen))
        #expect(decoded.source == .staleDaemon)
        #expect(decoded.ageMilliseconds == 2_460_000)
        #expect(decoded == screen)
    }

    /// `viewportStart` is an index into `lines` and may fall outside it in both
    /// directions — negative when the requested tail cut inside the viewport,
    /// and equal to `lines.count` when the whole viewport was blank rows the
    /// trim dropped. Both are well-formed, and a type that refused them would
    /// refuse two ordinary reads.
    @Test("viewportStart may sit outside the lines it indexes")
    func viewportStartMayFallOutsideLines() throws {
        #expect(try Self.make(lines: ["a", "b"], viewportStart: -3).viewportStart == -3)
        #expect(try Self.make(lines: ["a", "b"], viewportStart: 2).viewportStart == 2)
    }

    /// The input path takes a narrower view of the same observation, and it
    /// must be the *same* observation — modes paired with the provenance and
    /// age of the store they came from, never with another's.
    @Test("modeReading carries this screen's modes, source and age")
    func modeReadingMirrorsTheScreen() throws {
        let screen = try TerminalScreen(
            lines: ["x"],
            viewportStart: 0,
            cursor: TerminalScreen.Cursor(row: 0, column: 0, visible: true),
            size: TerminalScreen.Size(columns: 80, rows: 24),
            modes: TerminalScreen.ChildModes(
                bracketedPaste: true, applicationCursor: true, alternateScreen: false),
            source: .staleDaemon,
            ageMilliseconds: 41)
        #expect(
            screen.modeReading
                == TerminalModeReading(
                    modes: screen.modes, source: .staleDaemon, ageMilliseconds: 41))
    }
}
