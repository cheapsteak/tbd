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

    /// Collects what the scheduler published, so a test can assert on the
    /// absence of a notification as well as its presence.
    private actor NotifyRecorder {
        private(set) var published: [String] = []
        func record(_ sessionID: String) { published.append(sessionID) }
    }

    /// The interleaving `deregister` cannot rule out by ordering: it cancels
    /// the poll task, but a `refresh` the task had already entered is not
    /// interrupted and has no cancellation check of its own, so it can land on
    /// the source *after* `forget` did and recreate the entry.
    ///
    /// The two `refresh` calls stand in for one tick's own — the first for the
    /// work done while the registration was live, the second for the same call
    /// arriving late — and `finishTick` is that tick resuming afterwards. Only
    /// the second `refresh` matters to the assertion; the first is there so the
    /// entry being resurrected is one that genuinely existed.
    ///
    /// Fails against the pre-fix scheduler: the tail of a tick did nothing but
    /// notify, so the resurrected entry stayed resident and
    /// `trackedSessionCount` read 1 for a session nothing was registered for.
    @Test("a refresh that lands after deregistration leaves nothing resident")
    func staleTickDoesNotResurrectTheSession() async throws {
        let path = try tempTranscript("s1")
        let source = TranscriptSource()
        let scheduler = TranscriptPollScheduler(source: source)

        await scheduler.register(sessionID: "s1", path: path, tier: .background)
        let generation = try #require(await scheduler.registeredGeneration(sessionID: "s1"))
        await source.refresh(sessionID: "s1", path: path)

        await scheduler.deregister(sessionID: "s1")
        #expect(await source.trackedSessionCount == 0)

        await source.refresh(sessionID: "s1", path: path)
        #expect(await source.trackedSessionCount == 1,
                "precondition: the late refresh has recreated the entry")

        await scheduler.finishTick(sessionID: "s1", generation: generation, hasNews: true)
        #expect(await source.trackedSessionCount == 0,
                "a tick that outlived its registration must leave nothing resident")
    }

    /// The second half of the same race. Even with the resurrected entry swept
    /// up, a change computed before deregistration must not reach
    /// `AppState.sessionTranscripts`: the history pane and the overlay read that
    /// store too, so publishing there paints a session the pane has let go.
    ///
    /// Fails against the pre-fix scheduler, which called the change handler
    /// whenever the refresh reported news, with no reference to whether the
    /// registration that asked for it still existed.
    @Test("a change computed before deregistration is not published")
    func staleTickDoesNotPublish() async throws {
        let scheduler = TranscriptPollScheduler(source: TranscriptSource())
        let recorder = NotifyRecorder()
        await scheduler.setOnChange { await recorder.record($0) }

        await scheduler.register(sessionID: "s1", path: "/nonexistent", tier: .background)
        let generation = try #require(await scheduler.registeredGeneration(sessionID: "s1"))
        await scheduler.deregister(sessionID: "s1")

        await scheduler.finishTick(sessionID: "s1", generation: generation, hasNews: true)
        #expect(await recorder.published.isEmpty,
                "a deregistered session must not be published into the transcript store")
    }

    /// The discriminator for the two tests above: the guard must reject a stale
    /// tick without also silencing a live one. Without this, a `finishTick` that
    /// never published would pass both of them.
    @Test("a tick that still owns its registration publishes")
    func liveTickPublishes() async throws {
        let scheduler = TranscriptPollScheduler(source: TranscriptSource())
        let recorder = NotifyRecorder()
        await scheduler.setOnChange { await recorder.record($0) }

        await scheduler.register(sessionID: "s1", path: "/nonexistent", tier: .background)
        let generation = try #require(await scheduler.registeredGeneration(sessionID: "s1"))

        await scheduler.finishTick(sessionID: "s1", generation: generation, hasNews: true)
        #expect(await recorder.published == ["s1"])

        await scheduler.deregister(sessionID: "s1")
    }

    /// A re-registration is not a deregistration. The outgoing tick must not
    /// sweep away an entry the incoming registration now covers — that would be
    /// a re-parse from byte zero every time a pane re-declares itself — but it
    /// must not publish under the new registration's name either, since its
    /// change was computed against what the old one declared.
    @Test("a tick superseded by a re-registration neither publishes nor evicts")
    func supersededTickLeavesTheNewRegistrationAlone() async throws {
        let path = try tempTranscript("s1")
        let source = TranscriptSource()
        let scheduler = TranscriptPollScheduler(source: source)
        let recorder = NotifyRecorder()
        await scheduler.setOnChange { await recorder.record($0) }

        await scheduler.register(sessionID: "s1", path: path, tier: .background)
        let stale = try #require(await scheduler.registeredGeneration(sessionID: "s1"))
        await source.refresh(sessionID: "s1", path: path)
        await scheduler.register(sessionID: "s1", path: path, tier: .background)

        await scheduler.finishTick(sessionID: "s1", generation: stale, hasNews: true)
        #expect(await source.trackedSessionCount == 1,
                "the live registration's entry must survive the superseded tick")
        #expect(await recorder.published.isEmpty)

        await scheduler.deregister(sessionID: "s1")
        #expect(await source.trackedSessionCount == 0)
    }
}
