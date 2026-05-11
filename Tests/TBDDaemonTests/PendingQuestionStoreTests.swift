import Testing
import Foundation
@testable import TBDDaemonLib

@Suite struct PendingQuestionStoreTests {
    @Test func setThenEntriesReturnsStoredValue() async {
        let store = PendingQuestionStore()
        let terminalID = UUID()
        let pending = PendingAskUserQuestion(
            toolUseID: "toolu_test1",
            inputJSON: "{\"questions\":[]}",
            timestamp: Date(timeIntervalSince1970: 1000)
        )
        await store.set(terminalID: terminalID, pending)
        let entries = await store.entries(forTerminal: terminalID)
        #expect(entries.count == 1)
        #expect(entries.first?.toolUseID == "toolu_test1")
    }

    @Test func twoSetsSameTerminalDifferentToolIDsCoexist() async {
        let store = PendingQuestionStore()
        let terminalID = UUID()
        await store.set(terminalID: terminalID, PendingAskUserQuestion(
            toolUseID: "toolu_a", inputJSON: "{}", timestamp: Date()))
        await store.set(terminalID: terminalID, PendingAskUserQuestion(
            toolUseID: "toolu_b", inputJSON: "{}", timestamp: Date()))
        let entries = await store.entries(forTerminal: terminalID)
        #expect(entries.count == 2)
        #expect(Set(entries.map { $0.toolUseID }) == ["toolu_a", "toolu_b"])
    }

    @Test func clearMatchingToolUseIDRemovesOnlyThatEntry() async {
        let store = PendingQuestionStore()
        let terminalID = UUID()
        await store.set(terminalID: terminalID, PendingAskUserQuestion(
            toolUseID: "toolu_a", inputJSON: "{}", timestamp: Date(timeIntervalSince1970: 1)))
        await store.set(terminalID: terminalID, PendingAskUserQuestion(
            toolUseID: "toolu_b", inputJSON: "{}", timestamp: Date(timeIntervalSince1970: 2)))
        await store.clear(terminalID: terminalID, toolUseID: "toolu_a")
        let entries = await store.entries(forTerminal: terminalID)
        #expect(entries.map { $0.toolUseID } == ["toolu_b"])
    }

    @Test func clearMismatchedToolUseIDIsNoOp() async {
        let store = PendingQuestionStore()
        let terminalID = UUID()
        await store.set(terminalID: terminalID, PendingAskUserQuestion(
            toolUseID: "toolu_a", inputJSON: "{}", timestamp: Date()))
        await store.clear(terminalID: terminalID, toolUseID: "toolu_missing")
        let entries = await store.entries(forTerminal: terminalID)
        #expect(entries.count == 1)
    }

    @Test func clearTerminalRemovesAllEntries() async {
        let store = PendingQuestionStore()
        let terminalID = UUID()
        await store.set(terminalID: terminalID, PendingAskUserQuestion(
            toolUseID: "toolu_a", inputJSON: "{}", timestamp: Date()))
        await store.set(terminalID: terminalID, PendingAskUserQuestion(
            toolUseID: "toolu_b", inputJSON: "{}", timestamp: Date()))
        await store.clear(terminalID: terminalID)
        let entries = await store.entries(forTerminal: terminalID)
        #expect(entries == [])
    }

    @Test func gcExpiredRemovesEntriesOlderThanMaxAge() async {
        let store = PendingQuestionStore()
        let terminalID = UUID()
        let now = Date(timeIntervalSince1970: 10_000)
        let oldEntry = PendingAskUserQuestion(
            toolUseID: "toolu_old",
            inputJSON: "{}",
            timestamp: now.addingTimeInterval(-1000)
        )
        let freshEntry = PendingAskUserQuestion(
            toolUseID: "toolu_fresh",
            inputJSON: "{}",
            timestamp: now.addingTimeInterval(-10)
        )
        await store.set(terminalID: terminalID, oldEntry)
        await store.set(terminalID: terminalID, freshEntry)
        await store.gcExpired(now: now, maxAge: .seconds(60))
        let entries = await store.entries(forTerminal: terminalID)
        #expect(entries.map { $0.toolUseID } == ["toolu_fresh"])
    }

    @Test func entriesIsolatedByTerminalID() async {
        let store = PendingQuestionStore()
        let a = UUID()
        let b = UUID()
        await store.set(terminalID: a, PendingAskUserQuestion(
            toolUseID: "toolu_a", inputJSON: "{}", timestamp: Date()))
        await store.set(terminalID: b, PendingAskUserQuestion(
            toolUseID: "toolu_b", inputJSON: "{}", timestamp: Date()))
        let aEntries = await store.entries(forTerminal: a)
        let bEntries = await store.entries(forTerminal: b)
        #expect(aEntries.map { $0.toolUseID } == ["toolu_a"])
        #expect(bEntries.map { $0.toolUseID } == ["toolu_b"])
    }
}
