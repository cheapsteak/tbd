import Testing
import Foundation
import TBDShared
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

    // MARK: - Revisions

    // Publishing a set takes two hops — mutate, then read back and send — and
    // the actor orders only the first. The revision is what lets a receiver
    // tell which of two racing sends carries the later state.

    @Test func snapshotPairsEntriesWithTheRevisionThatProducedThem() async {
        let store = PendingQuestionStore()
        let terminalID = UUID()
        let before = await store.snapshot(forTerminal: terminalID)
        #expect(before.entries.isEmpty)
        #expect(before.revision == 0, "a terminal nobody has touched starts at zero")

        await store.set(terminalID: terminalID, PendingAskUserQuestion(
            toolUseID: "toolu_a", inputJSON: "{}", timestamp: Date(timeIntervalSince1970: 1)))
        let after = await store.snapshot(forTerminal: terminalID)

        #expect(after.entries.map(\.toolUseID) == ["toolu_a"])
        #expect(after.revision > before.revision)
    }

    @Test func everyMutationAdvancesTheRevision() async {
        let store = PendingQuestionStore()
        let terminalID = UUID()
        var seen: [UInt64] = []

        await store.set(terminalID: terminalID, PendingAskUserQuestion(
            toolUseID: "toolu_a", inputJSON: "{}", timestamp: Date(timeIntervalSince1970: 1)))
        seen.append(await store.snapshot(forTerminal: terminalID).revision)

        await store.clear(terminalID: terminalID, toolUseID: "toolu_a")
        seen.append(await store.snapshot(forTerminal: terminalID).revision)

        await store.set(terminalID: terminalID, PendingAskUserQuestion(
            toolUseID: "toolu_b", inputJSON: "{}", timestamp: Date(timeIntervalSince1970: 2)))
        seen.append(await store.snapshot(forTerminal: terminalID).revision)

        await store.clear(terminalID: terminalID)
        seen.append(await store.snapshot(forTerminal: terminalID).revision)

        #expect(seen == seen.sorted(), "revisions must never go backwards: \(seen)")
        #expect(Set(seen).count == seen.count, "every mutation is a distinct revision: \(seen)")
    }

    @Test func gcExpiredAdvancesOnlyTheReapedTerminalsRevision() async {
        let store = PendingQuestionStore()
        let reaped = UUID()
        let untouched = UUID()
        let now = Date(timeIntervalSince1970: 10_000)
        await store.set(terminalID: reaped, PendingAskUserQuestion(
            toolUseID: "toolu_old", inputJSON: "{}", timestamp: now.addingTimeInterval(-1000)))
        await store.set(terminalID: untouched, PendingAskUserQuestion(
            toolUseID: "toolu_fresh", inputJSON: "{}", timestamp: now.addingTimeInterval(-10)))
        let reapedBefore = await store.snapshot(forTerminal: reaped).revision
        let untouchedBefore = await store.snapshot(forTerminal: untouched).revision

        await store.gcExpired(now: now, maxAge: .seconds(900))

        #expect(await store.snapshot(forTerminal: reaped).revision > reapedBefore)
        #expect(await store.snapshot(forTerminal: untouched).revision == untouchedBefore,
                "a terminal the gc did not touch must not have its revision moved")
    }

    @Test func revisionsAreIndependentPerTerminal() async {
        let store = PendingQuestionStore()
        let busy = UUID()
        let quiet = UUID()
        for i in 0..<5 {
            await store.set(terminalID: busy, PendingAskUserQuestion(
                toolUseID: "toolu_\(i)", inputJSON: "{}",
                timestamp: Date(timeIntervalSince1970: TimeInterval(i))))
        }
        await store.set(terminalID: quiet, PendingAskUserQuestion(
            toolUseID: "toolu_q", inputJSON: "{}", timestamp: Date(timeIntervalSince1970: 1)))

        let busyRevision = await store.snapshot(forTerminal: busy).revision
        let quietRevision = await store.snapshot(forTerminal: quiet).revision
        #expect(busyRevision == 5)
        #expect(quietRevision == 1,
                "one terminal's traffic must not inflate another's revision — they are separate ordering domains")
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

/// The publish side of the same contract: whatever set goes on the wire is
/// stamped with the revision that produced it, read in the same actor call, so
/// the pair cannot tear.
@Suite("pending question broadcast carries the store's revision")
struct PendingQuestionBroadcastRevisionTests {

    private func capturingManager() -> (StateSubscriptionManager, BroadcastPendingDeltas) {
        let captured = BroadcastPendingDeltas()
        let subs = StateSubscriptionManager()
        subs.addSubscriber { data in
            if let delta = try? JSONDecoder().decode(StateDelta.self, from: data),
               case .terminalPendingQuestionsChanged(let d) = delta {
                captured.append(d)
            }
            return true
        }
        return (subs, captured)
    }

    @Test("each broadcast carries the store's current revision for that terminal")
    func broadcastStampsTheRevision() async {
        let (subs, captured) = capturingManager()
        let store = PendingQuestionStore()
        let terminalID = UUID()

        await store.set(terminalID: terminalID, PendingAskUserQuestion(
            toolUseID: "toolu_a", inputJSON: "{}", timestamp: Date(timeIntervalSince1970: 1)))
        await subs.broadcastPendingQuestions(terminalID: terminalID, from: store)
        await store.clear(terminalID: terminalID)
        await subs.broadcastPendingQuestions(terminalID: terminalID, from: store)

        let deltas = captured.all
        #expect(deltas.count == 2)
        let first = deltas.first
        let second = deltas.last
        #expect(first?.pending.map(\.toolUseID) == ["toolu_a"])
        #expect(second?.pending.isEmpty == true)
        let firstRevision = first?.revision
        let secondRevision = second?.revision
        #expect(firstRevision != nil, "an unstamped delta cannot be ordered by the app")
        #expect(secondRevision != nil)
        if let firstRevision, let secondRevision {
            #expect(secondRevision > firstRevision,
                    "the retraction must outrank the set it retracts")
        }
    }
}

/// Collects the pending-question deltas a manager broadcast.
private final class BroadcastPendingDeltas: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [TerminalPendingQuestionsDelta] = []
    func append(_ delta: TerminalPendingQuestionsDelta) {
        lock.lock(); defer { lock.unlock() }
        storage.append(delta)
    }
    var all: [TerminalPendingQuestionsDelta] {
        lock.lock(); defer { lock.unlock() }
        return storage
    }
}
