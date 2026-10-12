import Clocks
import Foundation
import Testing
import TestSupport
@testable import TBDDaemonLib
@testable import TBDShared

@Suite("Dev server group kill", .clockDriven)
struct DevServerGroupKillerTests {
    private let start = Date(timeIntervalSince1970: 1_760_190_000)
    private func target(_ pid: Int32 = 500) -> DevServerKillTarget {
        DevServerKillTarget(pid: pid, expectedStart: start, tolerance: 1)
    }
    private func killer(_ s: FakeDevServerSignalling, clock: any Clock<Duration> = TestClock()) -> DevServerGroupKiller {
        // pollInterval == grace: crossing the grace is a single advance.
        DevServerGroupKiller(signalling: s, grace: .seconds(5), pollInterval: .seconds(5),
                             postKillWait: .zero, clock: clock)
    }

    @Test func aGroupThatExitsOnSIGTERMIsNeverSIGKILLed() async {
        let s = FakeDevServerSignalling()
        s.add(pid: 500, pgid: 500, start: start, diesOn: [SIGTERM])
        #expect(await killer(s).kill(target()) == .terminated(pgid: 500))
        #expect(s.sentSignals == [.init(pgid: 500, signal: SIGTERM)])
    }

    @Test func SIGKILLWaitsForTheFullGrace() async {
        let clock = TestClock()
        let s = FakeDevServerSignalling()
        s.add(pid: 500, pgid: 500, start: start, diesOn: [SIGKILL])
        let k = killer(s, clock: clock)
        let task = Task { await k.kill(target()) }
        await clock.advanceWhenSuspended(by: .seconds(4))
        #expect(s.sentSignals == [.init(pgid: 500, signal: SIGTERM)], "SIGKILL before the 5 s grace")
        await clock.advanceWhenSuspended(by: .seconds(1))
        #expect(await task.value == .killed(pgid: 500))
        #expect(s.sentSignals == [.init(pgid: 500, signal: SIGTERM), .init(pgid: 500, signal: SIGKILL)])
    }

    @Test func aSurvivorIsReportedWithItsPid() async {
        let clock = TestClock()
        let s = FakeDevServerSignalling()
        s.add(pid: 500, pgid: 500, start: start, diesOn: [])
        let k = killer(s, clock: clock)
        let task = Task { await k.kill(target()) }
        await clock.advanceWhenSuspended(by: .seconds(5))
        #expect(await task.value == .survived(pid: 500, pgid: 500))
    }

    @Test(arguments: [Int32(0), Int32(1)])
    func groupsZeroAndOneAreRefused(_ pgid: Int32) async {
        let s = FakeDevServerSignalling()
        s.add(pid: 500, pgid: pgid, start: start)
        guard case .refused = await killer(s).kill(target()) else { Issue.record("not refused"); return }
        #expect(s.sentSignals.isEmpty)
    }

    /// Review Focus 4.
    @Test func theDaemonsOwnGroupIsRefused() async {
        let s = FakeDevServerSignalling(own: 777)
        s.add(pid: 500, pgid: 777, start: start)
        guard case .refused(pgid: 777, reason: _) = await killer(s).kill(target()) else { Issue.record("not refused"); return }
        #expect(s.sentSignals.isEmpty)
    }

    @Test func aReusedPidIsNotSignalled() async {
        let s = FakeDevServerSignalling()
        s.add(pid: 500, pgid: 500, start: start.addingTimeInterval(30))
        #expect(await killer(s).kill(target()) == .notRunning)
        #expect(s.sentSignals.isEmpty)
    }

    @Test func aZombieIsNotSignalled() async {
        let s = FakeDevServerSignalling()
        s.add(pid: 500, pgid: 500, start: start, zombie: true)
        #expect(await killer(s).kill(target()) == .notRunning)
        #expect(s.sentSignals.isEmpty)
    }

    @Test func theGroupIsDerivedFromThePid() async {
        let s = FakeDevServerSignalling()
        s.add(pid: 600, pgid: 500, start: start)
        #expect(await killer(s).kill(target(600)) == .terminated(pgid: 500))
        #expect(s.sentSignals == [.init(pgid: 500, signal: SIGTERM)])
    }
}
