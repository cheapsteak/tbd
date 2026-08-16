import Foundation
import Testing
@testable import TBDDaemonLib
@testable import TBDShared

/// A transcript reader backed by an in-memory map, so the counter arithmetic is
/// tier 1 — no filesystem, no real appends, and every read is countable.
private final class FakeAppendReader: TranscriptAppendReading, @unchecked Sendable {
    /// path → the file's bytes.
    var files: [String: Data] = [:]

    func endOffset(atPath path: String) -> UInt64? {
        guard let data = files[path] else { return nil }
        return UInt64(data.count)
    }

    func appendedRecords(atPath path: String, from offset: UInt64) -> AppendedRecords? {
        guard let data = files[path] else { return nil }
        let end = UInt64(data.count)
        guard end > offset else { return AppendedRecords(records: 0, endOffset: end) }
        let span = data.suffix(from: Int(offset))
        let records = span.reduce(into: 0) { count, byte in if byte == 0x0A { count += 1 } }
        return AppendedRecords(records: records, endOffset: end)
    }

    func append(_ recordCount: Int, to path: String) {
        var data = files[path] ?? Data()
        for _ in 0..<recordCount {
            data.append(contentsOf: Array(#"{"type":"assistant"}"#.utf8))
            data.append(0x0A)
        }
        files[path] = data
    }
}

/// Tier 1.
@Suite("SessionCountersTracker")
struct SessionCountersTrackerTests {

    private let t0 = Date(timeIntervalSince1970: 1_700_000_000)
    /// The worktree the tests that don't care about scoping sample into.
    private let wt = UUID()

    // MARK: - Turns

    @Test func turnsCountOnlyRecordsAppendedAfterTheFirstSample() async {
        let reader = FakeAppendReader()
        let path = "/fake/session-a.jsonl"
        reader.append(4_000, to: path)  // pre-existing history
        let tracker = SessionCountersTracker(reader: reader)
        let id = UUID()

        // First sighting baselines at the file's end: history is not a burst.
        let first = await tracker.sample(
            terminalID: id, worktreeID: wt, transcriptPath: path, commitsUnchangedSince: nil, at: t0)
        #expect(first?.turnsInWindow == 0)

        reader.append(7, to: path)
        let second = await tracker.sample(
            terminalID: id, worktreeID: wt, transcriptPath: path, commitsUnchangedSince: nil,
            at: t0.addingTimeInterval(60))
        #expect(second?.turnsInWindow == 7)

        // And the count accumulates across samples within one window.
        reader.append(3, to: path)
        let third = await tracker.sample(
            terminalID: id, worktreeID: wt, transcriptPath: path, commitsUnchangedSince: nil,
            at: t0.addingTimeInterval(120))
        #expect(third?.turnsInWindow == 10)
    }

    @Test func nothingIsParsed_onlyNewlinesAreCounted() async {
        let reader = FakeAppendReader()
        let path = "/fake/session-b.jsonl"
        reader.files[path] = Data()
        let tracker = SessionCountersTracker(reader: reader)
        let id = UUID()
        _ = await tracker.sample(
            terminalID: id, worktreeID: wt, transcriptPath: path, commitsUnchangedSince: nil, at: t0)

        // Bytes that are not JSON at all still count as records: the format is
        // internal and version-unstable, and "a record is a line" is the one
        // property that survives its changes.
        reader.files[path] = Data("not json\nnot json either\n".utf8)
        let counters = await tracker.sample(
            terminalID: id, worktreeID: wt, transcriptPath: path, commitsUnchangedSince: nil,
            at: t0.addingTimeInterval(30))
        #expect(counters?.turnsInWindow == 2)
    }

    @Test func aTranscriptPathChangeResetsTheBaselineInsteadOfReportingABogusDelta() async {
        let reader = FakeAppendReader()
        let old = "/fake/before-clear.jsonl"
        let new = "/fake/after-clear.jsonl"
        reader.append(3, to: old)
        let tracker = SessionCountersTracker(reader: reader)
        let id = UUID()

        _ = await tracker.sample(
            terminalID: id, worktreeID: wt, transcriptPath: old, commitsUnchangedSince: nil, at: t0)
        reader.append(6, to: old)
        let onOld = await tracker.sample(
            terminalID: id, worktreeID: wt, transcriptPath: old, commitsUnchangedSince: nil,
            at: t0.addingTimeInterval(60))
        #expect(onOld?.turnsInWindow == 6)

        // `/compact` rolls the session onto a different file that is LONGER
        // than the old baseline offset — the case that produces a plausible
        // and completely fictitious burst if the path is not compared, because
        // the bytes past the old offset in the *new* file were never appends.
        reader.append(100, to: new)
        let rolled = await tracker.sample(
            terminalID: id, worktreeID: wt, transcriptPath: new, commitsUnchangedSince: nil,
            at: t0.addingTimeInterval(120))
        #expect(rolled?.turnsInWindow == 0)

        reader.append(5, to: new)
        let after = await tracker.sample(
            terminalID: id, worktreeID: wt, transcriptPath: new, commitsUnchangedSince: nil,
            at: t0.addingTimeInterval(180))
        #expect(after?.turnsInWindow == 5)
    }

    @Test func aTranscriptTruncatedBelowItsBaselineAlsoReBaselines() async {
        let reader = FakeAppendReader()
        let path = "/fake/session-c.jsonl"
        reader.append(10, to: path)
        let tracker = SessionCountersTracker(reader: reader)
        let id = UUID()
        _ = await tracker.sample(
            terminalID: id, worktreeID: wt, transcriptPath: path, commitsUnchangedSince: nil, at: t0)

        // A real count accumulates first, so the reset below is observable.
        reader.append(6, to: path)
        let before = await tracker.sample(
            terminalID: id, worktreeID: wt, transcriptPath: path, commitsUnchangedSince: nil,
            at: t0.addingTimeInterval(30))
        #expect(before?.turnsInWindow == 6)

        reader.files[path] = Data("one\n".utf8)  // rotated in place
        let counters = await tracker.sample(
            terminalID: id, worktreeID: wt, transcriptPath: path, commitsUnchangedSince: nil,
            at: t0.addingTimeInterval(60))
        // The bytes those 6 records were counted from are gone; carrying the
        // count forward would report a window that no longer has evidence.
        #expect(counters?.turnsInWindow == 0)
    }

    @Test func anUnreadableTranscriptReportsNoCountersRatherThanZero() async {
        let tracker = SessionCountersTracker(reader: FakeAppendReader())
        #expect(await tracker.sample(
            terminalID: UUID(), worktreeID: wt, transcriptPath: "/fake/missing.jsonl",
            commitsUnchangedSince: nil, at: t0) == nil)
        #expect(await tracker.sample(
            terminalID: UUID(), worktreeID: wt, transcriptPath: nil,
            commitsUnchangedSince: nil, at: t0) == nil)
    }

    // MARK: - Hook events

    @Test func hookEventsAreCountedPerTerminalPerWindow() async {
        let reader = FakeAppendReader()
        let path = "/fake/session-d.jsonl"
        reader.files[path] = Data()
        let tracker = SessionCountersTracker(reader: reader)
        let a = UUID()
        let b = UUID()

        _ = await tracker.sample(
            terminalID: a, worktreeID: wt, transcriptPath: path, commitsUnchangedSince: nil, at: t0)
        for _ in 0..<5 { await tracker.recordHookEvent(terminalID: a, at: t0.addingTimeInterval(10)) }
        await tracker.recordHookEvent(terminalID: b, at: t0.addingTimeInterval(10))

        let counters = await tracker.sample(
            terminalID: a, worktreeID: wt, transcriptPath: path, commitsUnchangedSince: nil,
            at: t0.addingTimeInterval(20))
        #expect(counters?.hookEventsInWindow == 5)
    }

    @Test func hookEventsArrivingBeforeTheFirstSampleAreNotLost() async {
        let reader = FakeAppendReader()
        let path = "/fake/session-e.jsonl"
        reader.files[path] = Data()
        let tracker = SessionCountersTracker(reader: reader)
        let id = UUID()

        for _ in 0..<3 { await tracker.recordHookEvent(terminalID: id, at: t0) }
        let counters = await tracker.sample(
            terminalID: id, worktreeID: wt, transcriptPath: path, commitsUnchangedSince: nil,
            at: t0.addingTimeInterval(5))
        #expect(counters?.hookEventsInWindow == 3)
    }

    // MARK: - The pending map is bounded

    /// `pendingHookEvents` gets an entry for every terminal the fleet produces a
    /// hook for, and its only pruner is the fleet-wide `retain` — which nothing
    /// in `Sources/` calls today. On a daemon that runs for weeks that is an
    /// unbounded map, so it expires its own entries.
    ///
    /// Asserted through what a sample reports, not through the map's size: an
    /// expired pending entry contributes nothing to the terminal's first
    /// counters, and a live one contributes its count.
    @Test func pendingHookEventsOlderThanTheWindowAreDropped() async {
        let reader = FakeAppendReader()
        let stale = "/fake/pending-stale.jsonl"
        let live = "/fake/pending-live.jsonl"
        reader.files[stale] = Data()
        reader.files[live] = Data()
        let tracker = SessionCountersTracker(
            windowLength: 100, reader: reader, pendingSweepThreshold: 1)
        let old = UUID()
        let recent = UUID()

        await tracker.recordHookEvent(terminalID: old, at: t0)
        // Two windows later. This event's own write is what makes the map
        // exceed the sweep threshold, so the sweep runs and finds `old` expired.
        await tracker.recordHookEvent(terminalID: recent, at: t0.addingTimeInterval(200))

        let expired = await tracker.sample(
            terminalID: old, worktreeID: wt, transcriptPath: stale,
            commitsUnchangedSince: nil, at: t0.addingTimeInterval(200))
        #expect(expired?.hookEventsInWindow == 0,
                "a pending count from a window that closed two windows ago was folded in anyway")

        let kept = await tracker.sample(
            terminalID: recent, worktreeID: wt, transcriptPath: live,
            commitsUnchangedSince: nil, at: t0.addingTimeInterval(200))
        #expect(kept?.hookEventsInWindow == 1, "a pending count inside its own window was lost")
    }

    @Test func pendingHookEventsAreCappedEvenWhenEveryWindowIsStillOpen() async {
        let reader = FakeAppendReader()
        let tracker = SessionCountersTracker(
            windowLength: 10_000, reader: reader, pendingSweepThreshold: 1, pendingLimit: 2)
        let oldest = UUID()
        let newest = UUID()

        await tracker.recordHookEvent(terminalID: oldest, at: t0)
        await tracker.recordHookEvent(terminalID: UUID(), at: t0.addingTimeInterval(1))
        await tracker.recordHookEvent(terminalID: newest, at: t0.addingTimeInterval(2))

        for path in ["/fake/cap-oldest.jsonl", "/fake/cap-newest.jsonl"] { reader.files[path] = Data() }
        let evicted = await tracker.sample(
            terminalID: oldest, worktreeID: wt, transcriptPath: "/fake/cap-oldest.jsonl",
            commitsUnchangedSince: nil, at: t0.addingTimeInterval(2))
        #expect(evicted?.hookEventsInWindow == 0)
        let survivor = await tracker.sample(
            terminalID: newest, worktreeID: wt, transcriptPath: "/fake/cap-newest.jsonl",
            commitsUnchangedSince: nil, at: t0.addingTimeInterval(2))
        #expect(survivor?.hookEventsInWindow == 1)
    }

    /// The sweep is amortized against **growth**, not against traffic.
    ///
    /// A bare size threshold amortizes nothing once the map sits above it with
    /// every entry fresh: the filter drops nothing, the count stays over the
    /// line, and every subsequent hook event pays a whole-map rebuild — on the
    /// path whose documented budget is one actor hop and an integer add. The map
    /// only grows when a terminal TBD has never seen produces its first event,
    /// so gating on growth makes the sweep cost proportional to new terminals.
    @Test func theSweepRunsOnGrowthNotOnEveryEventPastTheThreshold() async {
        let reader = FakeAppendReader()
        let tracker = SessionCountersTracker(
            windowLength: 10_000, reader: reader, pendingSweepThreshold: 2)
        let known = [UUID(), UUID(), UUID()]

        // Three never-seen terminals; the third takes the map past the
        // threshold and sweeps.
        for (i, id) in known.enumerated() {
            await tracker.recordHookEvent(terminalID: id, at: t0.addingTimeInterval(Double(i)))
        }
        let afterGrowth = await tracker.pendingSweepsPerformed
        #expect(afterGrowth == 1, "the sweep did not run when the map first grew past its threshold")

        // Fifty more events, all from terminals already in the map. Nothing can
        // have expired (the window is 10_000s) and the map cannot grow.
        for i in 0..<50 {
            await tracker.recordHookEvent(
                terminalID: known[i % known.count], at: t0.addingTimeInterval(Double(10 + i)))
        }
        #expect(await tracker.pendingSweepsPerformed == afterGrowth,
                "an event from a terminal already in the map paid a whole-map rebuild")

        // …and the gate is not a disarm: a new terminal grows the map past the
        // watermark and sweeps again.
        await tracker.recordHookEvent(terminalID: UUID(), at: t0.addingTimeInterval(100))
        #expect(await tracker.pendingSweepsPerformed == afterGrowth + 1,
                "growth past the watermark no longer sweeps at all")
    }

    // MARK: - The window

    @Test func theWindowRollsAndBothCountsRestartWithoutRereadingTheTranscript() async {
        let reader = FakeAppendReader()
        let path = "/fake/session-f.jsonl"
        reader.files[path] = Data()
        let tracker = SessionCountersTracker(windowLength: 100, reader: reader)
        let id = UUID()

        _ = await tracker.sample(
            terminalID: id, worktreeID: wt, transcriptPath: path, commitsUnchangedSince: nil, at: t0)
        reader.append(4, to: path)
        await tracker.recordHookEvent(terminalID: id, at: t0.addingTimeInterval(10))
        let inWindow = await tracker.sample(
            terminalID: id, worktreeID: wt, transcriptPath: path, commitsUnchangedSince: nil,
            at: t0.addingTimeInterval(20))
        #expect(inWindow?.turnsInWindow == 4)
        #expect(inWindow?.hookEventsInWindow == 1)
        #expect(inWindow?.windowStart == t0)

        // Past the window: counts restart, and the byte offset survives so the
        // records already counted are not counted a second time.
        let rolled = await tracker.sample(
            terminalID: id, worktreeID: wt, transcriptPath: path, commitsUnchangedSince: nil,
            at: t0.addingTimeInterval(200))
        #expect(rolled?.turnsInWindow == 0)
        #expect(rolled?.hookEventsInWindow == 0)
        #expect(rolled?.windowStart == t0.addingTimeInterval(200))
    }

    @Test func theObservationWindowIsAWindowNotAThreshold() async throws {
        let reader = FakeAppendReader()
        let path = "/fake/session-g.jsonl"
        reader.files[path] = Data()
        let tracker = SessionCountersTracker(windowLength: 10_000, reader: reader)
        let id = UUID()
        _ = await tracker.sample(
            terminalID: id, worktreeID: wt, transcriptPath: path, commitsUnchangedSince: nil, at: t0)

        // Far past §13's shipped-program figures (30 turns, and then some).
        reader.append(500, to: path)
        for _ in 0..<400 { await tracker.recordHookEvent(terminalID: id, at: t0.addingTimeInterval(1)) }

        let counters = try #require(await tracker.sample(
            terminalID: id, worktreeID: wt, transcriptPath: path, commitsUnchangedSince: nil,
            at: t0.addingTimeInterval(2)))
        // The only effect of a huge count is a huge number. Nothing is paused,
        // nothing is sent, no state is mutated — the tracker has no actuation
        // surface at all, which is what "reported, never acted on" means.
        #expect(counters.turnsInWindow == 500)
        #expect(counters.hookEventsInWindow == 400)
        #expect(counters.observedAt == t0.addingTimeInterval(2))
    }

    // MARK: - Commits

    @Test func commitsUnchangedSinceIsCarriedThroughVerbatimIncludingNil() async {
        let reader = FakeAppendReader()
        let path = "/fake/session-h.jsonl"
        reader.files[path] = Data()
        let tracker = SessionCountersTracker(reader: reader)
        let id = UUID()
        let since = t0.addingTimeInterval(-3_600)

        let withFact = await tracker.sample(
            terminalID: id, worktreeID: wt, transcriptPath: path, commitsUnchangedSince: since, at: t0)
        #expect(withFact?.commitsUnchangedSince == since)

        let withoutFact = await tracker.sample(
            terminalID: id, worktreeID: wt, transcriptPath: path, commitsUnchangedSince: nil,
            at: t0.addingTimeInterval(60))
        #expect(withoutFact?.commitsUnchangedSince == nil)
    }

    // MARK: - Housekeeping

    @Test func retainDropsBookkeepingForTerminalsThatNoLongerExist() async {
        let reader = FakeAppendReader()
        let path = "/fake/session-i.jsonl"
        reader.files[path] = Data()
        let tracker = SessionCountersTracker(reader: reader)
        let id = UUID()

        _ = await tracker.sample(
            terminalID: id, worktreeID: wt, transcriptPath: path, commitsUnchangedSince: nil, at: t0)
        await tracker.recordHookEvent(terminalID: id, at: t0)
        await tracker.retain(terminalIDs: [], inWorktree: nil)

        // Re-sampling starts a fresh window with a fresh baseline.
        let counters = await tracker.sample(
            terminalID: id, worktreeID: wt, transcriptPath: path, commitsUnchangedSince: nil,
            at: t0.addingTimeInterval(60))
        #expect(counters?.hookEventsInWindow == 0)
        #expect(counters?.windowStart == t0.addingTimeInterval(60))
    }

    /// Counters established for one terminal per worktree, so scoped and
    /// unscoped pruning can be told apart by what survives.
    private func trackerWithTwoWorktrees() async -> (
        tracker: SessionCountersTracker, reader: FakeAppendReader,
        here: UUID, there: UUID, hereWorktree: UUID, thereWorktree: UUID,
        herePath: String, therePath: String
    ) {
        let reader = FakeAppendReader()
        let herePath = "/fake/session-here.jsonl"
        let therePath = "/fake/session-there.jsonl"
        reader.files[herePath] = Data()
        reader.files[therePath] = Data()
        let tracker = SessionCountersTracker(reader: reader)
        let here = UUID(), there = UUID()
        let hereWorktree = UUID(), thereWorktree = UUID()

        for (id, worktree, path) in [(here, hereWorktree, herePath), (there, thereWorktree, therePath)] {
            _ = await tracker.sample(
                terminalID: id, worktreeID: worktree, transcriptPath: path,
                commitsUnchangedSince: nil, at: t0)
            reader.append(2, to: path)
            await tracker.recordHookEvent(terminalID: id, at: t0.addingTimeInterval(10))
            let established = await tracker.sample(
                terminalID: id, worktreeID: worktree, transcriptPath: path,
                commitsUnchangedSince: nil, at: t0.addingTimeInterval(20))
            #expect(established?.turnsInWindow == 2)
            #expect(established?.hookEventsInWindow == 1)
        }
        return (tracker, reader, here, there, hereWorktree, thereWorktree, herePath, therePath)
    }

    @Test func aWorktreeScopedRetainLeavesOtherWorktreesCountersIntact() async throws {
        let f = await trackerWithTwoWorktrees()

        // The shape `session.states` takes when it is asked about one worktree:
        // the terminal list it enumerated names only that worktree's terminals.
        // Pruning against it fleet-wide would evict the other worktree's live
        // baseline, and the next fleet-wide call would re-baseline it as a
        // first sighting with both counts back at zero.
        await f.tracker.retain(terminalIDs: [f.here], inWorktree: f.hereWorktree)

        let survivor = try #require(await f.tracker.sample(
            terminalID: f.there, worktreeID: f.thereWorktree, transcriptPath: f.therePath,
            commitsUnchangedSince: nil, at: t0.addingTimeInterval(30)))
        #expect(survivor.turnsInWindow == 2)
        #expect(survivor.hookEventsInWindow == 1)
        #expect(survivor.windowStart == t0)
    }

    @Test func aWorktreeScopedRetainStillPrunesTerminalsGoneFromThatWorktree() async throws {
        let f = await trackerWithTwoWorktrees()
        let departed = UUID()
        _ = await f.tracker.sample(
            terminalID: departed, worktreeID: f.hereWorktree, transcriptPath: f.herePath,
            commitsUnchangedSince: nil, at: t0)
        await f.tracker.recordHookEvent(terminalID: departed, at: t0.addingTimeInterval(10))

        // Scoping is not an excuse to stop pruning: a terminal that is gone
        // from the very worktree being enumerated still goes.
        await f.tracker.retain(terminalIDs: [f.here], inWorktree: f.hereWorktree)

        let reBaselined = try #require(await f.tracker.sample(
            terminalID: departed, worktreeID: f.hereWorktree, transcriptPath: f.herePath,
            commitsUnchangedSince: nil, at: t0.addingTimeInterval(30)))
        #expect(reBaselined.hookEventsInWindow == 0)
        #expect(reBaselined.windowStart == t0.addingTimeInterval(30))

        // And the terminal that is still there kept its window.
        let kept = try #require(await f.tracker.sample(
            terminalID: f.here, worktreeID: f.hereWorktree, transcriptPath: f.herePath,
            commitsUnchangedSince: nil, at: t0.addingTimeInterval(30)))
        #expect(kept.hookEventsInWindow == 1)
        #expect(kept.windowStart == t0)
    }

    @Test func anUnscopedRetainPrunesFleetWide() async throws {
        let f = await trackerWithTwoWorktrees()

        // nil scope means the caller enumerated the whole fleet, so it is the
        // one call that may evict a terminal in any worktree.
        await f.tracker.retain(terminalIDs: [f.here], inWorktree: nil)

        let evicted = try #require(await f.tracker.sample(
            terminalID: f.there, worktreeID: f.thereWorktree, transcriptPath: f.therePath,
            commitsUnchangedSince: nil, at: t0.addingTimeInterval(30)))
        #expect(evicted.turnsInWindow == 0)
        #expect(evicted.hookEventsInWindow == 0)
        #expect(evicted.windowStart == t0.addingTimeInterval(30))

        let kept = try #require(await f.tracker.sample(
            terminalID: f.here, worktreeID: f.hereWorktree, transcriptPath: f.herePath,
            commitsUnchangedSince: nil, at: t0.addingTimeInterval(30)))
        #expect(kept.hookEventsInWindow == 1)
        #expect(kept.windowStart == t0)
    }
}

/// Tier 2 — the production reader against real files in a temp dir. The
/// arithmetic above is proven on the fake; this proves the seam's own
/// implementation agrees with it.
@Suite("FileTranscriptAppendReader")
struct FileTranscriptAppendReaderTests {

    private func scratchFile(_ contents: String) throws -> String {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("tbd-append-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let path = dir.appendingPathComponent("session.jsonl").path
        try Data(contents.utf8).write(to: URL(fileURLWithPath: path))
        return path
    }

    @Test func countsNewlinesPastTheOffsetAndReportsTheNewEnd() throws {
        let path = try scratchFile("a\nb\nc\n")
        defer { try? FileManager.default.removeItem(atPath: path) }
        let reader = FileTranscriptAppendReader()

        let end = try #require(reader.endOffset(atPath: path))
        #expect(end == 6)

        let handle = try #require(FileHandle(forWritingAtPath: path))
        try handle.seekToEnd()
        try handle.write(contentsOf: Data("d\ne\n".utf8))
        try handle.close()

        // Two records appended past the old end, and nothing before it counted.
        let appended = try #require(reader.appendedRecords(atPath: path, from: end))
        #expect(appended.records == 2)
        #expect(appended.endOffset == 10)

        // Asking again from the new end sees nothing, and says so with zero
        // rather than nil — readable-and-empty is evidence.
        let again = try #require(reader.appendedRecords(atPath: path, from: appended.endOffset))
        #expect(again.records == 0)
    }

    @Test func spansMoreThanOneChunk() throws {
        let lineCount = FileTranscriptAppendReader.chunkBytes / 2 + 100
        let path = try scratchFile(String(repeating: "x\n", count: lineCount))
        defer { try? FileManager.default.removeItem(atPath: path) }
        let appended = try #require(
            FileTranscriptAppendReader().appendedRecords(atPath: path, from: 0))
        #expect(appended.records == lineCount)
    }

    @Test func anUnreadableFileAnswersNilNeverZero() {
        let reader = FileTranscriptAppendReader()
        #expect(reader.endOffset(atPath: "/nonexistent/tbd/session.jsonl") == nil)
        #expect(reader.appendedRecords(atPath: "/nonexistent/tbd/session.jsonl", from: 0) == nil)
    }
}
