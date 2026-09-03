import Foundation
import SwiftTerm
import Testing
@testable import TBDTerminalSerialization

/// `Terminal.tdel` is weak, so a delegate nobody else retains is deallocated
/// and the terminal's replies vanish. Hold it strongly.
private final class SilentDelegate: TerminalDelegate {
    func send(source: Terminal, data: ArraySlice<UInt8>) {}
}

/// Feeds an SGR sequence then one character, and returns that cell's attribute.
private func attribute(after sgr: String) -> Attribute {
    let delegate = SilentDelegate()
    let terminal = Terminal(delegate: delegate)
    terminal.feed(text: sgr + "X")
    return terminal.getCharData(col: 0, row: 0)!.attribute
}

@Suite("SGR encoder")
struct SGREncoderTests {
    @Test("A plain cell encodes as a bare reset")
    func plainCell() {
        #expect(SGREncoder.parameters(for: attribute(after: "\u{1b}[0m")) == "0")
    }

    @Test("Each style bit gets its own parameter")
    func styleBits() {
        #expect(SGREncoder.parameters(for: attribute(after: "\u{1b}[1m")) == "0;1")
        #expect(SGREncoder.parameters(for: attribute(after: "\u{1b}[2m")) == "0;2")
        #expect(SGREncoder.parameters(for: attribute(after: "\u{1b}[3m")) == "0;3")
        #expect(SGREncoder.parameters(for: attribute(after: "\u{1b}[5m")) == "0;5")
        #expect(SGREncoder.parameters(for: attribute(after: "\u{1b}[7m")) == "0;7")
        #expect(SGREncoder.parameters(for: attribute(after: "\u{1b}[8m")) == "0;8")
        #expect(SGREncoder.parameters(for: attribute(after: "\u{1b}[9m")) == "0;9")
    }

    @Test("The 256-colour boundary at 16 is not off by one")
    func colour256Boundary() {
        // The internal toSgr() uses `c > 16` here and is wrong for exactly 16.
        #expect(SGREncoder.parameters(for: attribute(after: "\u{1b}[38;5;16m")) == "0;38;5;16")
        #expect(SGREncoder.parameters(for: attribute(after: "\u{1b}[38;5;15m")) == "0;97")
    }

    @Test("Truecolour survives in both directions")
    func trueColour() {
        let attr = attribute(after: "\u{1b}[38;2;10;20;30;48;2;40;50;60m")
        #expect(SGREncoder.parameters(for: attr) == "0;38;2;10;20;30;48;2;40;50;60")
    }

    @Test("Underline style and colour are emitted, unlike the internal encoder")
    func underline() {
        #expect(SGREncoder.parameters(for: attribute(after: "\u{1b}[4:3m")).contains("4:3"))
        let coloured = attribute(after: "\u{1b}[4m\u{1b}[58;2;1;2;3m")
        #expect(SGREncoder.parameters(for: coloured).contains("58;2;1;2;3"))
    }

    @Test("No parameter list ends with a separator")
    func noTrailingSeparator() {
        // The internal toSgr() emits a stray trailing ';' on ANSI-16 branches.
        for sgr in ["\u{1b}[31m", "\u{1b}[91m", "\u{1b}[41m", "\u{1b}[101m"] {
            #expect(!SGREncoder.parameters(for: attribute(after: sgr)).hasSuffix(";"))
        }
    }

    @Test("A round trip through a second terminal reproduces the attribute")
    func roundTrip() {
        for sgr in [
            "\u{1b}[1;4;38;5;200;48;2;9;8;7m",
            "\u{1b}[2;3;9;38;2;1;2;3m",
            "\u{1b}[7;31;42m",
            "\u{1b}[5;1;38;5;200m",
        ] {
            let original = attribute(after: sgr)
            let reproduced = attribute(after: SGREncoder.sequence(for: original))
            #expect(reproduced == original, "round trip failed for \(sgr)")
        }
    }
}
