import Foundation
import Testing
@testable import TBDApp
import TBDShared
import TestSupport

// Tier 1: virtual time only. Drivers sync through an injected closure.

/// `RemoteTranscriptSyncSession`: what the live pane decides from what it
/// observes — sync only while on screen and the app is active, and on a
/// selection change stop the old session's driver before starting the new
/// one's. Positive assertions go through `syncs.next(timeout: TestDeadlines.saturatedPass)`; negative ones read
/// the recorder after `settle()`.
@MainActor
@Suite("Remote transcript sync session", .clockDriven, .serialized)
struct RemoteTranscriptSyncSessionTests {
    private static let first = RemoteSessionSelection(provider: "acme", sessionID: "s1")
    private static let second = RemoteSessionSelection(provider: "acme", sessionID: "s2")
    private static let interval = Duration.seconds(3)
    private static let mainActorHop = TestDeadlines.saturatedPass

    @MainActor
    private final class Harness {
        let clock = EventDrivenTestClock()
        /// The session id of every sync, in order.
        let syncs = FireRecorder<String>()
        var started: [RemoteSessionSelection] = []
        var stopped: [RemoteSessionSelection] = []
        private(set) var session: RemoteTranscriptSyncSession!

        init(isOnScreen: Bool = true, appActive: Bool = true) {
            let clock = self.clock
            let syncs = self.syncs
            session = RemoteTranscriptSyncSession(
                isOnScreen: isOnScreen,
                appActive: appActive,
                makeDriver: { selection in
                    RemoteTranscriptSyncDriver(
                        selection: selection,
                        sync: { selection in
                            syncs.record(selection.sessionID)
                            return RemoteTranscriptSyncResult(
                                path: "/cache/\(selection.sessionID).jsonl",
                                generation: 1, caughtUp: true)
                        },
                        interval: RemoteTranscriptSyncSessionTests.interval,
                        clock: clock)
                },
                didStart: { [weak self] in self?.started.append($0.selection) },
                didStop: { [weak self] in self?.stopped.append($0.selection) })
        }

        func armed() async throws {
            try await clock.requireSleeperArmed(timeout: RemoteTranscriptSyncSessionTests.mainActorHop)
        }
    }

    @Test("the rule: sync only while on screen and the app is active")
    func rule() {
        #expect(RemoteTranscriptSyncSession.shouldSync(isOnScreen: true, appActive: true))
        #expect(!RemoteTranscriptSyncSession.shouldSync(isOnScreen: false, appActive: true))
        #expect(!RemoteTranscriptSyncSession.shouldSync(isOnScreen: true, appActive: false))
        #expect(!RemoteTranscriptSyncSession.shouldSync(isOnScreen: false, appActive: false))
    }

    @Test("hiding the pane stops syncing; showing it again syncs at once")
    func stopsWhenHidden() async throws {
        let h = Harness()
        defer { h.session.stop() }
        h.session.start(Self.first, agentState: nil)
        #expect(await h.syncs.next(timeout: TestDeadlines.saturatedPass) == "s1")
        try await h.armed()

        h.session.setOnScreen(false)
        await settle()
        await h.clock.advance(by: .seconds(30))
        await settle()
        #expect(h.syncs.values == ["s1"], "a hidden pane must not sync")

        h.session.setOnScreen(true)
        #expect(await h.syncs.next(timeout: TestDeadlines.saturatedPass) == "s1")
    }

    @Test("an inactive app stops syncing; becoming active again syncs at once")
    func stopsWhenAppInactive() async throws {
        let h = Harness()
        defer { h.session.stop() }
        h.session.start(Self.first, agentState: nil)
        #expect(await h.syncs.next(timeout: TestDeadlines.saturatedPass) == "s1")
        try await h.armed()

        h.session.setAppActive(false)
        await settle()
        await h.clock.advance(by: .seconds(30))
        await settle()
        #expect(h.syncs.values == ["s1"], "an inactive app must not sync")

        h.session.setAppActive(true)
        #expect(await h.syncs.next(timeout: TestDeadlines.saturatedPass) == "s1")
    }

    @Test("starting hidden or inactive makes a driver but does not sync")
    func startsIdleWhenNotShowing() async {
        let hidden = Harness(isOnScreen: false)
        defer { hidden.session.stop() }
        hidden.session.start(Self.first, agentState: nil)
        await settle()
        #expect(hidden.syncs.values.isEmpty)
        #expect(hidden.session.driver != nil)

        let inactive = Harness(appActive: false)
        defer { inactive.session.stop() }
        inactive.session.start(Self.first, agentState: nil)
        await settle()
        #expect(inactive.syncs.values.isEmpty)
    }

    @Test("a selection change stops the old session's driver and syncs the new one")
    func selectionChangeSwaps() async throws {
        let h = Harness()
        defer { h.session.stop() }
        h.session.start(Self.first, agentState: nil)
        #expect(await h.syncs.next(timeout: TestDeadlines.saturatedPass) == "s1")
        try await h.armed()
        let firstDriver = h.session.driver

        h.session.start(Self.second, agentState: nil)
        #expect(await h.syncs.next(timeout: TestDeadlines.saturatedPass) == "s2", "the new session syncs at once")
        #expect(h.stopped == [Self.first])
        #expect(h.started == [Self.first, Self.second])
        #expect(h.session.driver !== firstDriver)
        #expect(h.session.driver?.selection == Self.second)

        // Only the new driver keeps a cadence: a tick syncs s2 and never s1.
        // The old driver's loop resumed (and withdrew its sleeper) before the
        // new one's first sync ran, so the sleeper this waits for is the new
        // driver's. Were the old driver still running, its own tick would
        // fire on the advance below and put an "s1" in the recorder.
        try await h.armed()
        await h.clock.advance(by: Self.interval)
        #expect(await h.syncs.next(timeout: TestDeadlines.saturatedPass) == "s2")
        await settle()
        #expect(h.syncs.values == ["s1", "s2", "s2"])
    }

    @Test("stop ends syncing and reports the driver stopped")
    func stopEnds() async throws {
        let h = Harness()
        h.session.start(Self.first, agentState: nil)
        #expect(await h.syncs.next(timeout: TestDeadlines.saturatedPass) == "s1")
        try await h.armed()

        h.session.stop()
        #expect(h.session.driver == nil)
        #expect(h.stopped == [Self.first])
        await settle()
        await h.clock.advance(by: .seconds(30))
        await settle()
        #expect(h.syncs.values == ["s1"])
    }
}
