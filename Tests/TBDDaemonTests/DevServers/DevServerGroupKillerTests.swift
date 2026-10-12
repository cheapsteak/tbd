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

    /// A pid in group 0 or 1 does not lead it, so the group is never
    /// signalled — only the pid.
    @Test(arguments: [Int32(0), Int32(1)])
    func aPidInGroupZeroOrOneIsSignalledAlone(_ pgid: Int32) async {
        let s = FakeDevServerSignalling()
        s.add(pid: 500, pgid: pgid, start: start)
        #expect(await killer(s).kill(target()) == .terminatedAlone(pid: 500, pgid: pgid))
        #expect(s.sentSignals.isEmpty)
        #expect(s.sentToProcesses == [.init(pgid: 500, signal: SIGTERM)])
    }

    /// Review Focus 4: a pid leading the daemon's own group is refused.
    @Test func theDaemonsOwnGroupIsRefused() async {
        let s = FakeDevServerSignalling(own: 777)
        s.add(pid: 777, pgid: 777, start: start)
        guard case .refused = await killer(s).kill(target(777)) else { Issue.record("not refused"); return }
        #expect(s.sentSignals.isEmpty)
        #expect(s.sentToProcesses.isEmpty)
    }

    @Test func theDaemonItselfIsRefused() async {
        let s = FakeDevServerSignalling(own: 777, ownPID: 900)
        s.add(pid: 900, pgid: 777, start: start)
        guard case .refused = await killer(s).kill(target(900)) else { Issue.record("not refused"); return }
        #expect(s.sentSignals.isEmpty)
        #expect(s.sentToProcesses.isEmpty)
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

    /// The group is signalled only when the pid leads it.
    @Test func aGroupLeaderTakesItsWholeGroup() async {
        let s = FakeDevServerSignalling()
        s.add(pid: 500, pgid: 500, start: start)
        s.add(pid: 501, pgid: 500, start: start)
        #expect(await killer(s).kill(target(500)) == .terminated(pgid: 500))
        #expect(s.sentSignals == [.init(pgid: 500, signal: SIGTERM)])
        #expect(s.sentToProcesses.isEmpty)
        #expect(!s.isAlive(501))
    }

    /// `tbd server report --pid $!` from a shell without job control: the
    /// server shares the shell's group, which may be an agent's. Only the
    /// pid is signalled; the rest of its group lives.
    @Test func aPidThatDoesNotLeadItsGroupIsSignalledAlone() async {
        let s = FakeDevServerSignalling()
        s.add(pid: 500, pgid: 500, start: start)
        s.add(pid: 600, pgid: 500, start: start)
        #expect(await killer(s).kill(target(600)) == .terminatedAlone(pid: 600, pgid: 500))
        #expect(s.sentSignals.isEmpty)
        #expect(s.sentToProcesses == [.init(pgid: 600, signal: SIGTERM)])
        #expect(s.isAlive(500), "the shared group's leader must survive")
    }

    @Test func aLonePidThatIgnoresSIGTERMIsSIGKILLedAfterTheGrace() async {
        let clock = TestClock()
        let s = FakeDevServerSignalling()
        s.add(pid: 500, pgid: 500, start: start, diesOn: [SIGKILL])
        s.add(pid: 600, pgid: 500, start: start, diesOn: [SIGKILL])
        let k = killer(s, clock: clock)
        let task = Task { await k.kill(target(600)) }
        await clock.advanceWhenSuspended(by: .seconds(5))
        #expect(await task.value == .killedAlone(pid: 600, pgid: 500))
        #expect(s.sentToProcesses == [.init(pgid: 600, signal: SIGTERM), .init(pgid: 600, signal: SIGKILL)])
        #expect(s.sentSignals.isEmpty)
        #expect(s.isAlive(500))
    }

    /// A first-hand pid is anchored by the start time the kill reads itself.
    @Test func aFirstHandTargetIsSignalledWithoutARecordedStart() async {
        let s = FakeDevServerSignalling()
        s.add(pid: 500, pgid: 500, start: start.addingTimeInterval(3600))
        #expect(await killer(s).kill(.firstHand(pid: 500)) == .terminated(pgid: 500))
    }
}
