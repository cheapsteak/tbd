import Testing

@testable import TBDApp

/// The copy is a pure function of the byte count so it can be pinned without
/// driving SwiftUI: the banner's *appearance* is covered by the queue's
/// backpressure-edge tests, and this covers what it says.
@Suite("TerminalBackpressurePresentation")
struct TerminalBackpressurePresentationTests {
    @Test("the message names the session's state and how much is waiting")
    func messageNamesTheWait() {
        #expect(TerminalBackpressurePresentation.message(pendingBytes: 900)
                == "This session is not accepting input — 900 bytes waiting")
        #expect(TerminalBackpressurePresentation.message(pendingBytes: 4_096)
                == "This session is not accepting input — 4.1 KB waiting")
    }

    /// The copy must not say "dropped" or "failed": nothing is dropped and
    /// nothing has failed. The bytes are queued and will land when the agent
    /// reads them, and telling a person otherwise sends them to restart a
    /// session that is working.
    @Test("the message never claims a loss")
    func messageNeverClaimsALoss() {
        let text = TerminalBackpressurePresentation.message(pendingBytes: 4_096)
        #expect(!text.lowercased().contains("drop"))
        #expect(!text.lowercased().contains("fail"))
        #expect(!text.lowercased().contains("lost"))
    }
}
