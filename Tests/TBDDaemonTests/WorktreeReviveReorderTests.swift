import Testing
@testable import TBDDaemonLib
import TBDShared

@Test func reorderFloatsPreferredSessionFirst() {
    let stored = ["a", "b", "c"]
    let preferred = "b"
    let result = reorderSessions(stored: stored, preferred: preferred)
    #expect(result == ["b", "a", "c"])
}

@Test func nilPreferredKeepsOrder() {
    let stored = ["a", "b", "c"]
    let result = reorderSessions(stored: stored, preferred: String?.none)
    #expect(result == ["a", "b", "c"])
}

@Test func unknownPreferredKeepsOrder() {
    let stored = ["a", "b", "c"]
    let result = reorderSessions(stored: stored, preferred: "z")
    #expect(result == ["a", "b", "c"])
}

@Test func nilStoredStaysNil() {
    let result = reorderSessions(stored: [String]?.none, preferred: "anything")
    #expect(result == nil)
}
