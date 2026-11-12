import Testing
@testable import TBDDaemonLib

/// `PasteExecutor` puts its temp path between single quotes in a tmux
/// command, so it refuses any path holding a `'` or a newline. tmux reads
/// bytes, so the check reads scalars: a `'` that a mark joins into one
/// `Character` still ends the quoted path.
@Suite("PasteExecutor temp-path quoting")
struct PasteExecutorQuotingTests {

    @Test func anOrdinaryTempPathIsQuotable() {
        #expect(PasteExecutor.isSafelyQuotable("/var/folders/ab/cd/T/tbd-paste-1234"))
        #expect(PasteExecutor.isSafelyQuotable("/tmp/with space/tbd-paste-1"))
        #expect(PasteExecutor.isSafelyQuotable("/tmp/cafe\u{301}/tbd-paste-1"))
    }

    @Test func aQuoteOrNewlineIsRefused() {
        #expect(!PasteExecutor.isSafelyQuotable("/tmp/it's/tbd-paste-1"))
        #expect(!PasteExecutor.isSafelyQuotable("/tmp/a\nb/tbd-paste-1"))
    }

    /// A combining acute accent, an emoji variation selector and a combining
    /// enclosing keycap each join the `'` before them into one `Character`. A
    /// prepended concatenation mark joins the `'` after it, and a CR joins the
    /// LF after it.
    @Test func aQuoteOrNewlineThatAnotherScalarJoinsIsStillRefused() {
        for mark in ["\u{301}", "\u{FE0F}", "\u{20E3}"] {
            #expect(
                !PasteExecutor.isSafelyQuotable("/tmp/a'" + mark + "b/tbd-paste-1"),
                "U+\(String(mark.unicodeScalars.first!.value, radix: 16))")
        }
        #expect(!PasteExecutor.isSafelyQuotable("/tmp/a\u{600}'b/tbd-paste-1"))
        #expect(!PasteExecutor.isSafelyQuotable("/tmp/a\r\nb/tbd-paste-1"))
    }
}
