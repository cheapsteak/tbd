import Foundation
import Testing

@testable import TBDApp

@Suite("Octal Escape Decoder")
struct OctalEscapeDecoderTests {
    @Test("Decodes ESC character from octal \\033")
    func decodesESC() {
        let result = decodeOctalEscapes("\\033")
        #expect(result == Data([0x1B]))
    }

    @Test("Decodes ANSI color sequence \\033[31m")
    func decodesANSIColor() {
        let result = decodeOctalEscapes("\\033[31m")
        // ESC [ 3 1 m
        #expect(result == Data([0x1B, 0x5B, 0x33, 0x31, 0x6D]))
    }

    @Test("Decodes newline from octal \\012")
    func decodesNewline() {
        let result = decodeOctalEscapes("\\012")
        #expect(result == Data([0x0A]))
    }

    @Test("Decodes hello\\012world to hello<newline>world")
    func decodesHelloNewlineWorld() {
        let result = decodeOctalEscapes("hello\\012world")
        let expected = Data("hello\nworld".utf8)
        #expect(result == expected)
    }

    @Test("Passes regular text through unchanged")
    func regularTextPassthrough() {
        let input = "Hello, world! 12345"
        let result = decodeOctalEscapes(input)
        #expect(result == Data(input.utf8))
    }

    @Test("Decodes escaped backslash \\\\")
    func decodesEscapedBackslash() {
        let result = decodeOctalEscapes("\\\\")
        #expect(result == Data([0x5C]))
    }

    @Test("Decodes mixed content with multiple escapes")
    func decodesMixedContent() {
        // ESC[31mhello ESC[0m
        let input = "\\033[31mhello\\033[0m"
        let result = decodeOctalEscapes(input)
        let expected = Data([0x1B, 0x5B, 0x33, 0x31, 0x6D,   // ESC[31m
                            0x68, 0x65, 0x6C, 0x6C, 0x6F,     // hello
                            0x1B, 0x5B, 0x30, 0x6D])           // ESC[0m
        #expect(result == expected)
    }

    @Test("Decodes NUL byte \\000")
    func decodesNUL() {
        let result = decodeOctalEscapes("\\000")
        #expect(result == Data([0x00]))
    }

    @Test("Decodes max octal value \\377 (0xFF)")
    func decodesMaxOctal() {
        let result = decodeOctalEscapes("\\377")
        #expect(result == Data([0xFF]))
    }

    @Test("Handles empty string")
    func emptyString() {
        let result = decodeOctalEscapes("")
        #expect(result == Data())
    }

    @Test("Handles trailing backslash")
    func trailingBackslash() {
        let result = decodeOctalEscapes("abc\\")
        // Should emit the backslash as-is
        #expect(result == Data("abc\\".utf8))
    }

    @Test("Decodes tab \\011 and carriage return \\015")
    func decodesTabAndCR() {
        let result = decodeOctalEscapes("\\011\\015")
        #expect(result == Data([0x09, 0x0D]))
    }

    @Test("Decodes complex terminal output with cursor movement")
    func decodesComplexTerminalOutput() {
        // Simulates: ESC[H ESC[2J (home + clear screen)
        let input = "\\033[H\\033[2J"
        let result = decodeOctalEscapes(input)
        let expected = Data([0x1B, 0x5B, 0x48,               // ESC[H
                            0x1B, 0x5B, 0x32, 0x4A])          // ESC[2J
        #expect(result == expected)
    }
}
