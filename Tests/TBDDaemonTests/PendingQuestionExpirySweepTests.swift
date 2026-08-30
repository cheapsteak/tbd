import Foundation
import Testing
@testable import TBDDaemonLib
@testable import TBDShared

@Suite("PendingQuestionExpirySweep")
struct PendingQuestionExpirySweepTests {

    private func makeStore(
        terminalID: UUID, entries: [(String, TimeInterval)], now: Date
    ) async -> PendingQuestionStore {
        let store = PendingQuestionStore()
        for (toolUseID, age) in entries {
            await store.set(terminalID: terminalID, PendingAskUserQuestion(
                toolUseID: toolUseID,
                inputJSON: "{}",
                timestamp: now.addingTimeInterval(-age)))
        }
        return store
    }

    @Test("entries older than the max age are reaped, fresher ones kept")
    func reapsExpiredEntries() async {
        let terminalID = UUID()
        let now = Date(timeIntervalSince1970: 10_000)
        let store = await makeStore(
            terminalID: terminalID, entries: [("old", 1000), ("fresh", 10)], now: now)

        await store.gcExpired(now: now, maxAge: PendingQuestionExpirySweep.maxAge)

        let remaining = await store.entries(forTerminal: terminalID).map(\.toolUseID)
        #expect(remaining == ["fresh"], "the 1000s-old entry must be reaped, the 10s-old one kept")
    }

    @Test("a sweep with nothing expired removes nothing")
    func keepsFreshEntries() async {
        let terminalID = UUID()
        let now = Date(timeIntervalSince1970: 10_000)
        let store = await makeStore(terminalID: terminalID, entries: [("a", 0)], now: now)

        await store.gcExpired(now: now, maxAge: PendingQuestionExpirySweep.maxAge)

        #expect(await store.entries(forTerminal: terminalID).count == 1)
    }

    @Test("the sweep's max age matches what the RPC handler used")
    func maxAgeUnchanged() {
        #expect(PendingQuestionExpirySweep.maxAge == .seconds(900))
    }

    @Test("the sweep reaps through the store and reports the affected terminal")
    func sweepOnceReapsAndReports() async {
        let terminalID = UUID()
        let now = Date(timeIntervalSince1970: 10_000)
        let store = await makeStore(
            terminalID: terminalID, entries: [("old", 1000), ("fresh", 10)], now: now)
        let reaped = ReapedTerminals()

        let sweep = PendingQuestionExpirySweep(
            store: store,
            now: { now },
            onReap: { await reaped.record($0) })
        await sweep.sweepOnce()

        #expect(await store.entries(forTerminal: terminalID).map(\.toolUseID) == ["fresh"])
        #expect(await reaped.ids == [terminalID],
                "a reap is a mutation; without the callback the app renders the reaped entry forever")
    }

    @Test("a sweep that reaps nothing broadcasts nothing")
    func sweepOnceStaysQuietWhenNothingExpires() async {
        let terminalID = UUID()
        let now = Date(timeIntervalSince1970: 10_000)
        let store = await makeStore(terminalID: terminalID, entries: [("a", 10)], now: now)
        let reaped = ReapedTerminals()

        let sweep = PendingQuestionExpirySweep(
            store: store,
            now: { now },
            onReap: { await reaped.record($0) })
        await sweep.sweepOnce()

        #expect(await reaped.ids.isEmpty)
    }

    @Test("gcExpired names every terminal that lost an entry")
    func gcExpiredReportsAllAffectedTerminals() async {
        let store = PendingQuestionStore()
        let expired = UUID()
        let survivor = UUID()
        let now = Date(timeIntervalSince1970: 10_000)
        await store.set(terminalID: expired, PendingAskUserQuestion(
            toolUseID: "a", inputJSON: "{}", timestamp: now.addingTimeInterval(-1000)))
        await store.set(terminalID: survivor, PendingAskUserQuestion(
            toolUseID: "b", inputJSON: "{}", timestamp: now.addingTimeInterval(-10)))

        let reaped = await store.gcExpired(now: now, maxAge: .seconds(900))

        #expect(reaped == [expired])
    }
}

/// Collects the terminal ids a sweep reported, across the concurrency domains
/// the `@Sendable` callback can be invoked from.
private actor ReapedTerminals {
    private(set) var ids: [UUID] = []
    func record(_ id: UUID) { ids.append(id) }
}
