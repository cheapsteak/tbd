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
}
