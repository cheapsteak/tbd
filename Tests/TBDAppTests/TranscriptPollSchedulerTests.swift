import Foundation
import Testing
@testable import TBDApp

@Suite("TranscriptPollPolicy")
struct TranscriptPollPolicyTests {

    @Test("a visible pane polls at 100ms while the app is active")
    func foregroundActive() {
        #expect(TranscriptPollPolicy.interval(tier: .foreground, appActive: true)
                == .milliseconds(100))
    }

    @Test("a pane that is alive but not visible polls at 2s")
    func backgroundActive() {
        #expect(TranscriptPollPolicy.interval(tier: .background, appActive: true)
                == .seconds(2))
    }

    @Test("an inactive app drops every tier to 10s")
    func inactiveAppOverridesTier() {
        #expect(TranscriptPollPolicy.interval(tier: .foreground, appActive: false)
                == .seconds(10))
        #expect(TranscriptPollPolicy.interval(tier: .background, appActive: false)
                == .seconds(10))
    }

    @Test("the tiers are strictly ordered fastest to slowest")
    func tiersAreOrdered() {
        #expect(TranscriptPollPolicy.foreground < TranscriptPollPolicy.background)
        #expect(TranscriptPollPolicy.background < TranscriptPollPolicy.inactive)
    }
}

@Suite("TranscriptPollScheduler")
struct TranscriptPollSchedulerTests {

    @Test("deregistering a session stops tracking it")
    func deregisterStops() async {
        let scheduler = TranscriptPollScheduler(source: TranscriptSource())
        await scheduler.register(sessionID: "s1", path: "/nonexistent", tier: .background)
        await scheduler.deregister(sessionID: "s1")
        #expect(await scheduler.registeredSessionIDs.isEmpty)
    }

    @Test("registering twice replaces rather than duplicates")
    func registerIsIdempotent() async {
        let scheduler = TranscriptPollScheduler(source: TranscriptSource())
        await scheduler.register(sessionID: "s1", path: "/a", tier: .background)
        await scheduler.register(sessionID: "s1", path: "/b", tier: .foreground)
        #expect(await scheduler.registeredSessionIDs == ["s1"])
    }

    @Test("nothing unregistered is tracked")
    func nothingUnregisteredIsTracked() async {
        let scheduler = TranscriptPollScheduler(source: TranscriptSource())
        #expect(await scheduler.registeredSessionIDs.isEmpty)
    }

    private static let line = #"{"type":"user","uuid":"a","timestamp":"2026-08-26T10:00:00.000Z","message":{"role":"user","content":"hello"}}"#

    private func tempTranscript(_ name: String) throws -> String {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("tbd-poll-scheduler-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let file = dir.appendingPathComponent("\(name).jsonl")
        try (Self.line + "\n").write(to: file, atomically: true, encoding: .utf8)
        return file.path
    }

    /// Cancelling the poll task is only half of ending a registration: the
    /// source holds every item it parsed for that session, and nothing else in
    /// the app removes an entry. Without the `forget` inside `deregister` the
    /// retained set is bounded only by "distinct sessions ever viewed".
    @Test("deregistering a session releases the transcript the source built")
    func deregisterReleasesSourceState() async throws {
        let path = try tempTranscript("s1")
        let source = TranscriptSource()
        let scheduler = TranscriptPollScheduler(source: source)

        await scheduler.register(sessionID: "s1", path: path, tier: .background)
        await source.refresh(sessionID: "s1", path: path)
        #expect(await source.items(sessionID: "s1").isEmpty == false)
        #expect(await source.trackedSessionCount == 1)

        await scheduler.deregister(sessionID: "s1")
        #expect(await source.items(sessionID: "s1").isEmpty)
        #expect(await source.trackedSessionCount == 0,
                "a deregistered session must leave nothing resident")
    }

    /// `/clear` and `/compact` mint a new Claude session id for the same
    /// terminal. The live pane's `.task(id:)` key carries the session id, so the
    /// outgoing task deregisters the id it captured at start — the OLD one —
    /// while the incoming task registers the new one. This models that pair and
    /// pins that the rollover does not accumulate one resident transcript per
    /// generation.
    @Test("a session rollover leaves nothing resident for the old id")
    func rolloverDoesNotOrphanTheOldSession() async throws {
        let oldPath = try tempTranscript("old")
        let newPath = try tempTranscript("new")
        let source = TranscriptSource()
        let scheduler = TranscriptPollScheduler(source: source)

        await TranscriptPaneRegistration.apply(
            enabled: true, sessionID: "old", path: oldPath,
            tier: .foreground, scheduler: scheduler)
        await source.refresh(sessionID: "old", path: oldPath)
        #expect(await source.trackedSessionCount == 1)

        // The pane's task is torn down and rebuilt under the new id.
        await scheduler.deregister(sessionID: "old")
        await TranscriptPaneRegistration.apply(
            enabled: true, sessionID: "new", path: newPath,
            tier: .foreground, scheduler: scheduler)
        await source.refresh(sessionID: "new", path: newPath)

        #expect(await source.items(sessionID: "old").isEmpty,
                "the superseded session must not stay resident")
        #expect(await source.trackedSessionCount == 1,
                "exactly the live session, not one entry per rollover")
        #expect(await scheduler.registeredSessionIDs == ["new"])

        await scheduler.deregister(sessionID: "new")
        #expect(await source.trackedSessionCount == 0)
    }
}
