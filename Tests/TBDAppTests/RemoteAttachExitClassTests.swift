import Testing
@testable import TBDApp

/// Tier 1. The app's three-way reading of an `attach` exit code — the split
/// that decides which "don't respawn yet" mechanism applies and which words
/// the user sees.
@Suite("RemoteAttachExitClass")
struct RemoteAttachExitClassTests {
    @Test func zeroIsClean() {
        #expect(RemoteAttachExitClass.classify(exitCode: 0) == .clean)
    }

    /// No exit code available isn't proof of failure — it stays in the
    /// non-alarming class rather than guessing.
    @Test func unreadableExitCodeIsClean() {
        #expect(RemoteAttachExitClass.classify(exitCode: nil) == .clean)
    }

    @Test func exitFourIsAuthNeeded() {
        #expect(RemoteAttachExitClass.classify(exitCode: 4) == .authNeeded)
    }

    @Test func otherNonZeroExitsAreUnexpected() {
        #expect(RemoteAttachExitClass.classify(exitCode: 1) == .unexpected)
        #expect(RemoteAttachExitClass.classify(exitCode: 2) == .unexpected)
        #expect(RemoteAttachExitClass.classify(exitCode: 3) == .unexpected)
        #expect(RemoteAttachExitClass.classify(exitCode: 137) == .unexpected)
    }
}
