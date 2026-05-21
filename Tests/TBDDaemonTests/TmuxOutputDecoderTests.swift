import Foundation
import Testing
@testable import TBDDaemonLib

@Suite("TmuxOutputDecoder")
struct TmuxOutputDecoderTests {
    @Test("passes literal printable text through unchanged")
    func literal() {
        #expect(TmuxOutputDecoder.decode("hello world") == Data("hello world".utf8))
    }

    @Test("decodes an empty payload to empty data")
    func empty() {
        #expect(TmuxOutputDecoder.decode("") == Data())
    }

    @Test("decodes an octal newline escape")
    func newline() {
        // \012 == octal 12 == decimal 10 == '\n'
        #expect(TmuxOutputDecoder.decode("a\\012b") == Data([97, 10, 98]))
    }

    @Test("decodes an escaped backslash")
    func backslash() {
        // \134 == octal 134 == decimal 92 == '\'
        #expect(TmuxOutputDecoder.decode("\\134") == Data([92]))
    }

    @Test("decodes an ESC control byte")
    func escByte() {
        // \033 == octal 33 == decimal 27 == ESC
        #expect(TmuxOutputDecoder.decode("\\033[31m") == Data([27, 91, 51, 49, 109]))
    }

    @Test("decodes multibyte UTF-8 escaped octet-by-octet")
    func utf8() {
        // 日 == UTF-8 E6 97 A5 == octal \346\227\245
        #expect(TmuxOutputDecoder.decode("\\346\\227\\245") == Data("日".utf8))
    }

    @Test("passes a malformed escape through literally")
    func malformed() {
        // backslash not followed by 3 octal digits — keep the bytes, do not drop
        #expect(TmuxOutputDecoder.decode("\\12") == Data("\\12".utf8))
        #expect(TmuxOutputDecoder.decode("\\99x") == Data("\\99x".utf8))
    }
}
