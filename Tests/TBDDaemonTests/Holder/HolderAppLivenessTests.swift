import Darwin
import Foundation
import TestSupport
import Testing
@testable import TBDDaemonLib
import TBDShared

/// **A sidecar disconnect is not death.**
///
/// The sidecar has a designed reconnect path, so a socket drop can leave the
/// app alive, holding its `dup`s, still reading — and seizing then is exactly
/// the double-reader corruption this whole transport exists to prevent. So the
/// daemon does not act on the drop; it acts on a *verdict* about the process
/// that was at the other end, reached from the identity it recorded when that
/// connection was adopted.
///
/// The verdict has three values and only one of them seizes:
///
///   - **confirmed gone** — the recorded pid names nothing, or names a
///     stranger. Every session that app held reverts to daemon-read.
///   - **alive** — the recorded pid still names that same process. The daemon
///     stays off the fds and awaits the reconnect and the re-claim.
///   - **not yet determined** — the kernel would not say. Treated as alive,
///     because the failure direction on this path is always toward reading
///     nothing until liveness says otherwise.
///
/// The reused-pid case is why the check is identity-verified rather than a bare
/// `kill(pid, 0)`: a dead app whose pid has been handed to something else would
/// otherwise look alive forever and stall every session it was holding.
///
/// **And one verdict is not the end of it.** An app closes its socket on its
/// way out, before it has finished exiting, so the verdict at the instant of
/// the drop can be `alive` for an app that is dying. A verdict short of death
/// starts a watch that re-checks until death is confirmed, the same app
/// reconnects, or it holds nothing — never on a budget, because an app can
/// stay alive and disconnected for as long as it runs — and at most one watch
/// runs per app. The `Re-checking` and `One watch per app` tests below drive
/// that schedule on an `EventDrivenTestClock`, with the process table changing
/// while the arbiter waits. A test whose watch would not end on its own ends
/// it by cancelling the task running it.
///
/// Tier 1, with one section of exceptions. Every test above "Which disconnect is a
/// disconnect" touches no holder, no pty and no real process — the process
/// table is scripted through `FakeProcessSignaller`, and time is virtual. The
/// tests in that section are tier 2 by `Tests/CLAUDE.md`'s taxonomy: they use
/// real `socketpair`s, real spawned receive `Thread`s, and bounded wall-clock
/// waits. This is still their right home: tier 2 belongs in the fast parallel
/// pass, and only tier 3 — an external process the test does not control —
/// moves to `TBDDaemonLiveTests`.
@Suite(.clockDriven) struct HolderAppLivenessTests {

    /// The executable the daemon recorded for the app when its sidecar
    /// connection was adopted.
    private static let appExecutable = "/opt/tbd/.build/debug/TBDApp"
    private static let appPID: Int32 = 4242

    private static func recordedIdentity(
        startedAt: Date, executable: String = appExecutable
    ) -> ProcessIdentity {
        ProcessIdentity(pid: appPID, startedAt: startedAt, commandLine: executable)
    }

    /// Records the reclaims the arbitration asked for, and for which app, so
    /// every test can assert on the *action* rather than only on the verdict
    /// that licenses it.
    private actor ReclaimSpy {
        private(set) var calls: [ProcessIdentity] = []
        func record(_ app: ProcessIdentity) -> [UUID] {
            calls.append(app)
            return []
        }
    }

    /// A process table in which the app is running, as recorded.
    private static func aliveApp(startedAt started: Date) -> FakeProcessSignaller {
        let signaller = FakeProcessSignaller()
        signaller.startTimes[appPID] = started
        signaller.cmdlines[appPID] = appExecutable
        return signaller
    }

    /// Re-checks at 250 ms and then every 500 ms, so a test steps the front
    /// of a watch in one or two short advances.
    private static let quickSchedule = SidecarDisconnectArbiter.RecheckSchedule(
        first: .milliseconds(250), ceiling: .milliseconds(500))

    private static func arbiter(
        signaller: FakeProcessSignaller,
        spy: ReclaimSpy,
        sidecar: SidecarScript = SidecarScript(sessionsHeld: 1),
        recheckSchedule: SidecarDisconnectArbiter.RecheckSchedule =
            HolderAppLivenessTests.quickSchedule,
        clock: any Clock<Duration> = EventDrivenTestClock()
    ) -> SidecarDisconnectArbiter {
        SidecarDisconnectArbiter(
            liveness: AppLivenessArbiter(signaller: signaller),
            reclaim: { await spy.record($0) },
            sessionsHeld: { _ in sidecar.sessionsHeld },
            connectedApp: { sidecar.connected },
            recheckSchedule: recheckSchedule,
            clock: clock)
    }

    /// The ruling a drop reaches when its first verdict does not end the
    /// arbitration: wait for the watch to park on its first re-check — proof
    /// it decided to keep looking rather than act — then end it by
    /// cancellation, which leaves every claim standing.
    private static func firstVerdictOfAWatch(
        on arbiter: SidecarDisconnectArbiter, clock: EventDrivenTestClock,
        identity: ProcessIdentity
    ) async throws -> SidecarDisconnectRuling {
        let arbitration = Task { await arbiter.handleDisconnect(identity: identity) }
        try await clock.requireSleeperArmed()
        arbitration.cancel()
        return await arbitration.value
    }

    // MARK: - Alive

    /// The whole point of the arbitration. The app dropped its socket and is
    /// still running, still holding its `dup`s and still reading them; the
    /// daemon must stay off those descriptors — at the drop, and at every
    /// re-check after it.
    @Test func aDisconnectFromALiveAppSeizesNothing() async throws {
        let started = Date(timeIntervalSince1970: 1_700_000_000)
        let spy = ReclaimSpy()
        let clock = EventDrivenTestClock()
        let arbiter = Self.arbiter(
            signaller: Self.aliveApp(startedAt: started), spy: spy, clock: clock)

        let arbitration = Task {
            await arbiter.handleDisconnect(identity: Self.recordedIdentity(startedAt: started))
        }
        try await clock.requireAdvanceWhenArmed(by: .milliseconds(250))
        // Re-armed: the re-check found the app alive too, and the watch goes on.
        try await clock.requireSleeperArmed()
        #expect(await spy.calls.isEmpty, "the daemon seized on an alive re-check")
        arbitration.cancel()
        let ruling = await arbitration.value

        #expect(ruling.verdict == AppLivenessVerdict.alive)
        #expect(ruling.ending == .abandoned)
        #expect(ruling.checks == 2, "the live app was not re-checked once its schedule allowed")
        #expect(await spy.calls.isEmpty, """
            the daemon seized the ptys of an app that is still alive and still reading them — the \
            double-reader corruption this transport exists to prevent
            """)
    }

    // MARK: - Confirmed gone

    /// Nothing holds the recorded pid: the app is gone, its descriptors closed
    /// with it, and no cooperation from it is needed or possible. A death seen
    /// at the drop is acted on at the drop — no watch, no wait.
    @Test func aDisconnectFromAnAppThatIsGoneRevertsItsSessions() async {
        let signaller = FakeProcessSignaller()
        signaller.behaviors[Self.appPID] = .init(aliveInitially: false)
        let spy = ReclaimSpy()
        let clock = EventDrivenTestClock()
        let app = Self.recordedIdentity(startedAt: Date(timeIntervalSince1970: 1))

        let ruling = await Self.arbiter(signaller: signaller, spy: spy, clock: clock)
            .handleDisconnect(identity: app)

        #expect(ruling.verdict == AppLivenessVerdict.confirmedGone(reason: "process-gone"))
        #expect(ruling.ending == .seized)
        #expect(ruling.checks == 1)
        #expect(!clock.hasSleeper, "a death confirmed at the drop was still waited on")
        #expect(await spy.calls == [app], """
            a confirmed-dead app left its sessions claimed: nothing drains them, no injection can \
            reach them, and every re-open is refused
            """)
    }

    /// **The point of the identity check.** The recorded pid is alive — but it
    /// belongs to something else now. A bare liveness probe would report this
    /// app as running for as long as the stranger lives, and every session it
    /// held would stay unread and unwritable behind that answer.
    ///
    /// The start time is held *equal* here on purpose, so the only thing that
    /// can produce the verdict is the executable half of the check.
    @Test func aReusedPIDRunningADifferentExecutableIsClassifiedAsDead() async {
        let started = Date(timeIntervalSince1970: 1_700_000_000)
        let signaller = FakeProcessSignaller()
        signaller.startTimes[Self.appPID] = started
        signaller.cmdlines[Self.appPID] = "/usr/bin/python3 /Users/someone/unrelated.py"
        let spy = ReclaimSpy()

        let ruling = await Self.arbiter(signaller: signaller, spy: spy)
            .handleDisconnect(identity: Self.recordedIdentity(startedAt: started))

        #expect(ruling.verdict == AppLivenessVerdict.confirmedGone(reason: "pid-reused-executable"), """
            a stranger holding the app's old pid was read as the app still running, which stalls \
            every session that app was holding for as long as the stranger lives
            """)
        #expect(ruling.ending == .seized)
        #expect(await spy.calls.count == 1)
    }

    /// The other half of the same check, and the half that survives `execve`:
    /// a process that presents the app's own executable but started at a
    /// different moment is a different process.
    @Test func aReusedPIDWithADifferentStartTimeIsClassifiedAsDead() async {
        let recordedStart = Date(timeIntervalSince1970: 1_700_000_000)
        let signaller = FakeProcessSignaller()
        signaller.startTimes[Self.appPID] = recordedStart.addingTimeInterval(90)
        signaller.cmdlines[Self.appPID] = Self.appExecutable
        let spy = ReclaimSpy()

        let ruling = await Self.arbiter(signaller: signaller, spy: spy)
            .handleDisconnect(identity: Self.recordedIdentity(startedAt: recordedStart))

        #expect(ruling.verdict == AppLivenessVerdict.confirmedGone(reason: "pid-reused-start-time"), """
            a relaunched app reusing its predecessor's pid was read as the predecessor still \
            running
            """)
        #expect(ruling.ending == .seized)
        #expect(await spy.calls.count == 1)
    }

    // MARK: - Not yet determined

    /// The kernel would not say when the process holding this pid started. That
    /// is not evidence of death, and this path may act on nothing less.
    @Test func anUnreadableStartTimeIsNotDeath() async throws {
        let signaller = FakeProcessSignaller()
        signaller.cmdlines[Self.appPID] = Self.appExecutable
        // No `startTimes` entry: `ps` answered nothing parseable.
        let spy = ReclaimSpy()
        let clock = EventDrivenTestClock()

        let ruling = try await Self.firstVerdictOfAWatch(
            on: Self.arbiter(signaller: signaller, spy: spy, clock: clock), clock: clock,
            identity: Self.recordedIdentity(startedAt: Date(timeIntervalSince1970: 1)))

        #expect(ruling.verdict == AppLivenessVerdict.undetermined(reason: "start-time-unreadable"))
        #expect(ruling.ending == .abandoned)
        #expect(ruling.checks == 1)
        #expect(await spy.calls.isEmpty, """
            an unreadable identity was treated as a confirmed death, so the daemon put itself on \
            descriptors an app may still be reading
            """)
    }

    /// An unreadable command line is the same class of non-answer, and takes
    /// the same direction — even though `commandLine` returning empty is what a
    /// pid that has just vanished looks like. "Probably gone" is not gone.
    @Test func anUnreadableCommandLineIsNotDeath() async throws {
        let started = Date(timeIntervalSince1970: 1_700_000_000)
        let signaller = FakeProcessSignaller()
        signaller.startTimes[Self.appPID] = started
        // No `cmdlines` entry.
        let spy = ReclaimSpy()
        let clock = EventDrivenTestClock()

        let ruling = try await Self.firstVerdictOfAWatch(
            on: Self.arbiter(signaller: signaller, spy: spy, clock: clock), clock: clock,
            identity: Self.recordedIdentity(startedAt: started))

        #expect(ruling.verdict == AppLivenessVerdict.undetermined(reason: "command-unreadable"))
        #expect(ruling.ending == .abandoned)
        #expect(ruling.checks == 1)
        #expect(await spy.calls.isEmpty)
    }

    /// A connection whose peer the daemon never managed to identify. There is
    /// no pid to ask about, so there is nothing to confirm — and an
    /// unidentified peer must never license a seize. Nothing is watched
    /// either: no claim names an unidentified app, so no later answer could
    /// take one back.
    @Test func aDisconnectWithNoRecordedIdentityIsNotDeath() async {
        let signaller = FakeProcessSignaller()
        let spy = ReclaimSpy()
        let clock = EventDrivenTestClock()

        let ruling = await Self.arbiter(signaller: signaller, spy: spy, clock: clock)
            .handleDisconnect(identity: nil)

        #expect(ruling.verdict == AppLivenessVerdict.undetermined(reason: "identity-unrecorded"))
        #expect(ruling.ending == .unidentified)
        #expect(!clock.hasSleeper)
        #expect(await spy.calls.isEmpty)
    }

    // MARK: - Re-checking

    /// **The bug this schedule exists for.** An app that is exiting closes its
    /// sidecar socket before it is gone, so at the drop it still answers as
    /// alive. Asked once, that verdict would hold its sessions for the
    /// daemon's whole life, refusing every attach a successor app makes; asked
    /// again a moment later, it is confirmed gone and its sessions come back.
    @Test func anAppStillExitingAtItsDisconnectIsTakenBackOnAReCheck() async throws {
        let started = Date(timeIntervalSince1970: 1_700_000_000)
        let signaller = Self.aliveApp(startedAt: started)
        let spy = ReclaimSpy()
        let clock = EventDrivenTestClock()
        let app = Self.recordedIdentity(startedAt: started)
        let arbiter = Self.arbiter(signaller: signaller, spy: spy, clock: clock)

        let arbitration = Task { await arbiter.handleDisconnect(identity: app) }
        // Parked on its first re-check: the drop found the app still running.
        try await clock.requireSleeperArmed()
        #expect(await spy.calls.isEmpty, "the arbiter seized on an alive verdict")
        // It finishes exiting while the arbiter waits. Written while the
        // arbiter is parked, so nothing reads the table concurrently.
        signaller.behaviors[Self.appPID] = .init(aliveInitially: false)
        await clock.advance(by: .milliseconds(250))
        let ruling = await arbitration.value

        #expect(ruling.ending == .seized, """
            an app confirmed gone on a re-check kept its sessions claimed — every attach the next \
            app makes is refused for the daemon's whole life
            """)
        #expect(ruling.verdict == AppLivenessVerdict.confirmedGone(reason: "process-gone"))
        #expect(ruling.checks == 2)
        #expect(await spy.calls == [app])
    }

    /// An app that reconnects is alive, and the drop that started the watch is
    /// over: its next disconnect is arbitrated from the start. So the watch
    /// stops — with nothing taken back, and no re-check left armed.
    @Test func anAppThatReconnectsIsNoLongerWatched() async throws {
        let started = Date(timeIntervalSince1970: 1_700_000_000)
        let spy = ReclaimSpy()
        let clock = EventDrivenTestClock()
        let sidecar = SidecarScript(sessionsHeld: 2)
        let app = Self.recordedIdentity(startedAt: started)
        let arbiter = Self.arbiter(
            signaller: Self.aliveApp(startedAt: started), spy: spy, sidecar: sidecar, clock: clock)

        let arbitration = Task { await arbiter.handleDisconnect(identity: app) }
        try await clock.requireSleeperArmed()
        // The sidecar reconnect lands while the arbiter waits.
        sidecar.connected = app
        await clock.advance(by: .milliseconds(250))
        let ruling = await arbitration.value

        #expect(ruling.ending == .reconnected)
        #expect(ruling.verdict == AppLivenessVerdict.alive)
        #expect(ruling.checks == 2, "the watch went on past the check that saw the reconnect")
        #expect(!clock.hasSleeper, "the arbiter is still watching an app that is connected again")
        #expect(await spy.calls.isEmpty)
    }

    /// A different app on the sidecar is not the departed one reconnecting.
    /// The successor being connected says nothing about whether the app it
    /// replaced is alive, so the watch goes on and the death is still caught.
    @Test func aSuccessorAppConnectingDoesNotEndTheWatch() async throws {
        let started = Date(timeIntervalSince1970: 1_700_000_000)
        let signaller = Self.aliveApp(startedAt: started)
        let spy = ReclaimSpy()
        let clock = EventDrivenTestClock()
        let sidecar = SidecarScript(sessionsHeld: 1)
        let app = Self.recordedIdentity(startedAt: started)
        let arbiter = Self.arbiter(signaller: signaller, spy: spy, sidecar: sidecar, clock: clock)

        let arbitration = Task { await arbiter.handleDisconnect(identity: app) }
        try await clock.requireSleeperArmed()
        sidecar.connected = ProcessIdentity(
            pid: 5353, startedAt: started.addingTimeInterval(60), commandLine: Self.appExecutable)
        try await clock.requireAdvanceWhenArmed(by: .milliseconds(250))
        // Still watching: the second check found the departed app alive and
        // the sidecar held by somebody else, so it re-armed.
        try await clock.requireSleeperArmed()
        signaller.behaviors[Self.appPID] = .init(aliveInitially: false)
        await clock.advance(by: .milliseconds(500))
        let ruling = await arbitration.value

        #expect(ruling.ending == .seized)
        #expect(ruling.checks == 3)
        #expect(await spy.calls == [app])
    }

    /// `undetermined` is re-checked exactly as `alive` is, and it never seizes
    /// while it stays undetermined — only a later answer that confirms the
    /// death does.
    @Test func anUndeterminedVerdictIsReCheckedAndNeverSeizes() async throws {
        let signaller = FakeProcessSignaller()
        signaller.cmdlines[Self.appPID] = Self.appExecutable
        // No `startTimes` entry: the start time is unreadable on every check
        // until the pid itself goes.
        let spy = ReclaimSpy()
        let clock = EventDrivenTestClock()
        let app = Self.recordedIdentity(startedAt: Date(timeIntervalSince1970: 1))
        let arbiter = Self.arbiter(signaller: signaller, spy: spy, clock: clock)

        let arbitration = Task { await arbiter.handleDisconnect(identity: app) }
        try await clock.requireAdvanceWhenArmed(by: .milliseconds(250))
        // Re-armed, so the second check ran — and came back undetermined.
        try await clock.requireSleeperArmed()
        #expect(await spy.calls.isEmpty, """
            an undetermined re-check was treated as a death, so the daemon put itself on \
            descriptors an app may still be reading
            """)
        signaller.behaviors[Self.appPID] = .init(aliveInitially: false)
        await clock.advance(by: .milliseconds(500))
        let ruling = await arbitration.value

        #expect(ruling.ending == .seized)
        #expect(ruling.verdict == AppLivenessVerdict.confirmedGone(reason: "process-gone"))
        #expect(ruling.checks == 3)
        #expect(await spy.calls == [app])
    }

    /// An app that holds nothing has nothing its death could license taking
    /// back, so a drop from it is not watched at all.
    @Test func anAppHoldingNothingIsNotWatched() async {
        let started = Date(timeIntervalSince1970: 1_700_000_000)
        let spy = ReclaimSpy()
        let clock = EventDrivenTestClock()

        let ruling = await Self.arbiter(
            signaller: Self.aliveApp(startedAt: started), spy: spy,
            sidecar: SidecarScript(sessionsHeld: 0), clock: clock)
            .handleDisconnect(identity: Self.recordedIdentity(startedAt: started))

        #expect(ruling.ending == .holdsNothing)
        #expect(ruling.checks == 1)
        #expect(!clock.hasSleeper)
        #expect(await spy.calls.isEmpty)
    }

    /// **An app that stays alive and disconnected is watched until it quits.**
    /// Two app instances taking the sidecar from each other leave exactly
    /// this — a development build beside an installed one — and so does an
    /// app that comes back under an identity the daemon could not read: the
    /// app that lost the sidecar is alive, holds its tabs, and is not seen to
    /// come back. Its claims rightly stand while it runs. When it finally
    /// quits, an hour or a day later, the watch is what takes them back; a
    /// watch that had given up on a budget would leave them claimed for the
    /// daemon's whole life, with nothing left to arbitrate them.
    ///
    /// Paced so the hour is crossed in two re-checks. The schedule has no
    /// budget, so its pacing changes only how many advances the hour takes.
    @Test func anAppThatStaysAliveAndDisconnectedIsWatchedPastAnHourUntilItQuits() async throws {
        let started = Date(timeIntervalSince1970: 1_700_000_000)
        let signaller = Self.aliveApp(startedAt: started)
        let spy = ReclaimSpy()
        let clock = EventDrivenTestClock()
        let app = Self.recordedIdentity(startedAt: started)
        let arbiter = Self.arbiter(
            signaller: signaller, spy: spy,
            recheckSchedule: .init(first: .seconds(1200), ceiling: .seconds(2400)), clock: clock)
        let watchBegan = clock.now

        let arbitration = Task { await arbiter.handleDisconnect(identity: app) }
        try await clock.requireAdvanceWhenArmed(by: .seconds(1200))
        try await clock.requireAdvanceWhenArmed(by: .seconds(2400))
        // An hour in, alive and disconnected throughout, and re-armed: still
        // watched.
        try await clock.requireSleeperArmed()
        #expect(watchBegan.duration(to: clock.now) == .seconds(3600))
        #expect(await spy.calls.isEmpty, "the daemon seized the ptys of an app that is still alive")

        // It quits, well past the hour.
        signaller.behaviors[Self.appPID] = .init(aliveInitially: false)
        await clock.advance(by: .seconds(2400))
        let ruling = await arbitration.value

        #expect(ruling.ending == .seized, """
            an app that stayed alive and disconnected past an hour kept its sessions claimed after \
            it quit — nothing drains them, and every attach to them is refused for the daemon's \
            whole life
            """)
        #expect(ruling.checks == 4)
        #expect(await spy.calls == [app])
    }

    /// The production schedule, pinned to what its doc comment claims: a
    /// first re-check inside a few hundred milliseconds for an app that is
    /// exiting, a one-minute ceiling for an app that is alive — and no end,
    /// because a watch lasts as long as its app is alive and disconnected.
    @Test func theDefaultScheduleIsQuickFirstCheapLaterAndNeverRunsOut() {
        let schedule = SidecarDisconnectArbiter.defaultRecheckSchedule
        var delays = [schedule.first]
        while delays.count < 100 {
            delays.append(schedule.delay(after: delays[delays.count - 1]))
        }
        let firstFour: Duration = delays.prefix(4).reduce(Duration.zero, +)
        let settledAtTheCeiling = delays.suffix(50).allSatisfy { $0 == .seconds(60) }
        #expect(delays.first == .milliseconds(250))
        #expect(firstFour <= .seconds(4),
                "an exiting app is not re-checked four times inside four seconds")
        #expect(delays.max() == .seconds(60))
        #expect(settledAtTheCeiling, "a long watch does not settle at one re-check a minute")
    }

    // MARK: - One watch per app

    /// **A second departure of a watched app joins the watch already
    /// running.** The same app reconnecting and dropping again, or losing the
    /// sidecar to another instance, must not start a second watch beside the
    /// first: that doubles the `ps` load and races the first to the same
    /// take-back, announcing one death twice. The death is still caught, and
    /// taken back once. And once the watch has ended, the next departure is
    /// arbitrated afresh rather than absorbed into a watch that is gone.
    @Test func aSecondDepartureOfTheSameAppJoinsTheWatchAlreadyRunning() async throws {
        let started = Date(timeIntervalSince1970: 1_700_000_000)
        let signaller = Self.aliveApp(startedAt: started)
        let spy = ReclaimSpy()
        let clock = EventDrivenTestClock()
        let app = Self.recordedIdentity(startedAt: started)
        let arbiter = Self.arbiter(signaller: signaller, spy: spy, clock: clock)

        let first = Task { await arbiter.handleDisconnect(identity: app) }
        try await clock.requireSleeperArmed()

        let second = await arbiter.handleDisconnect(identity: app)

        #expect(second.ending == .absorbed, "a second departure of a watched app started its own watch")
        #expect(second.checks == 0, "an absorbed departure ran a liveness check of its own")
        #expect(second.verdict == nil)
        #expect(clock.sleeperCount == 1, "two watches are re-checking the same app")

        signaller.behaviors[Self.appPID] = .init(aliveInitially: false)
        await clock.advance(by: .milliseconds(250))
        let ruling = await first.value

        #expect(ruling.ending == .seized)
        #expect(ruling.checks == 2)
        #expect(await spy.calls == [app], "one app's death took its sessions back more than once")

        let afterTheWatch = await arbiter.handleDisconnect(identity: app)
        #expect(afterTheWatch.ending == .seized, """
            a departure after the watch had ended was absorbed into a watch that no longer exists, \
            so nothing arbitrated it
            """)
        #expect(afterTheWatch.checks == 1)
    }

    /// **An absorbed departure is not lost to a watch that was about to
    /// end.** Here it lands while a round is between reading "connected
    /// again" and acting on that — the connection the app came back on
    /// dropping straight away. The round must not end the watch on what it
    /// read: the departure was absorbed on the strength of this watch going
    /// on, so ending would leave it arbitrated by nobody, and an app that then
    /// died would keep its sessions claimed for the daemon's whole life. The
    /// round runs again instead, finds the app alive and disconnected, and the
    /// watch catches its death.
    @Test func aDepartureReportedWhileARoundSettlesKeepsTheWatchGoing() async throws {
        let started = Date(timeIntervalSince1970: 1_700_000_000)
        let signaller = Self.aliveApp(startedAt: started)
        let spy = ReclaimSpy()
        let clock = EventDrivenTestClock()
        let app = Self.recordedIdentity(startedAt: started)
        let midRound = DepartureMidRound()
        let arbiter = SidecarDisconnectArbiter(
            liveness: AppLivenessArbiter(signaller: signaller),
            reclaim: { await spy.record($0) },
            sessionsHeld: { _ in 1 },
            connectedApp: {
                // The first read finds the app connected again, and its new
                // connection drops before the round acts on that: the
                // departure is reported into the very watch doing the
                // reading, which is suspended right here and so free to take
                // it. Every later read finds the app gone from the sidecar.
                guard let watching = midRound.takeArbiter() else { return nil }
                let ruling = await watching.handleDisconnect(identity: app)
                midRound.record(ruling)
                return app
            },
            recheckSchedule: Self.quickSchedule,
            clock: clock)
        midRound.arm(arbiter)

        let arbitration = Task { await arbiter.handleDisconnect(identity: app) }
        // Still watching: the round that read the reconnect ran again on the
        // departure it absorbed, and re-armed.
        try await clock.requireSleeperArmed()
        let absorbed = try #require(midRound.ruling, "the departure mid-round was never reported")
        #expect(absorbed.ending == .absorbed)

        signaller.behaviors[Self.appPID] = .init(aliveInitially: false)
        await clock.advance(by: .milliseconds(250))
        let ruling = await arbitration.value

        #expect(ruling.ending == .seized, """
            the watch ended on a reconnect it read before a departure it had absorbed, so that \
            departure was arbitrated by nobody and the dead app's sessions stay claimed
            """)
        #expect(ruling.checks == 3)
        #expect(await spy.calls == [app])
    }

    // MARK: - Which disconnect is a disconnect

    /// A reconnect tears the *old* socket down, so its receive thread exits
    /// exactly as a dead app's does. When the app on the new connection is the
    /// same one, that exit is not a disconnect: arbitrating it would ask "is
    /// the app alive?" about an app that has just proved it is by connecting
    /// again.
    @Test func theSameAppReconnectingIsNotADisconnect() async throws {
        let (oldServerFD, oldClientFD) = try Self.socketPair()
        let (newServerFD, newClientFD) = try Self.socketPair()
        defer { Darwin.close(oldClientFD) }

        let app = ProcessIdentity(
            pid: 11, startedAt: Date(timeIntervalSince1970: 10), commandLine: "app")
        let disconnects = DisconnectLog()
        let exits = DisconnectLog()
        let server = FDVendingServer(peerIdentity: { _ in app })
        await server.setOnClientDisconnect { disconnects.record($0) }
        await server.setOnReceiveLoopExit { exits.record(nil) }

        await server.adoptConnection(fd: oldServerFD)
        // The reconnect. `adoptConnection` shuts the old socket down, so its
        // receive thread leaves `read()` and signals its own exit.
        await server.adoptConnection(fd: newServerFD)
        #expect(await waitUntil { exits.count == 1 }, "the superseded receive thread never exited")
        #expect(disconnects.count == 0, """
            a reconnect was arbitrated as an app death, so the daemon would seize the ptys of an \
            app that is demonstrably alive — it is connected right now
            """)

        // And the connection that IS current still reports its own drop.
        Darwin.close(newClientFD)
        #expect(await waitUntil { disconnects.count == 1 }, "a live app's drop went unreported")
        #expect(disconnects.all == [app])

        await server.stop()
    }

    /// **A different app taking the sidecar is the old app's departure.** Its
    /// connection is torn down by the adoption rather than by its own exit, so
    /// no receive loop of its will ever report it — and if it then dies, the
    /// sessions it held stay claimed for the daemon's whole life. So the
    /// adoption reports it, once, with the successor already recorded as the
    /// connected app: the arbiter asking "is that same app connected again?"
    /// must never be told yes about the app it is watching.
    @Test func aDifferentAppTakingTheSidecarIsArbitratedAsTheOldAppsDeparture() async throws {
        let (oldServerFD, oldClientFD) = try Self.socketPair()
        let (newServerFD, newClientFD) = try Self.socketPair()
        defer { Darwin.close(oldClientFD); Darwin.close(newClientFD) }

        let oldApp = ProcessIdentity(
            pid: 11, startedAt: Date(timeIntervalSince1970: 10), commandLine: "old")
        let newApp = ProcessIdentity(
            pid: 22, startedAt: Date(timeIntervalSince1970: 20), commandLine: "new")
        let identities = [oldServerFD: oldApp, newServerFD: newApp]
        let disconnects = DisconnectLog()
        let exits = DisconnectLog()
        let server = FDVendingServer(peerIdentity: { identities[$0] })
        await server.setOnClientDisconnect { disconnects.record($0) }
        await server.setOnReceiveLoopExit { exits.record(nil) }

        await server.adoptConnection(fd: oldServerFD)
        await server.adoptConnection(fd: newServerFD)

        // Reported by the adoption itself, synchronously on the actor, so it is
        // already in the log when the call returns.
        #expect(disconnects.all == [oldApp], """
            a different app took the sidecar and the app it replaced was never arbitrated, so if \
            that app dies every session it held stays claimed for the daemon's whole life
            """)
        #expect(await server.currentClientIdentity() == newApp)

        // The replaced connection's own exit adds nothing: one departure, one
        // arbitration.
        #expect(await waitUntil { exits.count == 1 }, "the superseded receive thread never exited")
        #expect(disconnects.all == [oldApp], "the replaced app's departure was arbitrated twice")

        await server.stop()
    }

    /// A replaced connection whose peer was never identified names no pid, and
    /// no viewer claim names an unidentified app, so there is nothing an
    /// arbitration could decide. It is not reported.
    @Test func aReplacedConnectionThatWasNeverIdentifiedIsNotArbitrated() async throws {
        let (oldServerFD, oldClientFD) = try Self.socketPair()
        let (newServerFD, newClientFD) = try Self.socketPair()
        defer { Darwin.close(oldClientFD); Darwin.close(newClientFD) }

        let newApp = ProcessIdentity(
            pid: 22, startedAt: Date(timeIntervalSince1970: 20), commandLine: "new")
        // Only the new connection's peer can be identified.
        let identities = [newServerFD: newApp]
        let disconnects = DisconnectLog()
        let exits = DisconnectLog()
        let server = FDVendingServer(peerIdentity: { identities[$0] })
        await server.setOnClientDisconnect { disconnects.record($0) }
        await server.setOnReceiveLoopExit { exits.record(nil) }

        await server.adoptConnection(fd: oldServerFD)
        await server.adoptConnection(fd: newServerFD)
        #expect(await waitUntil { exits.count == 1 }, "the superseded receive thread never exited")

        #expect(disconnects.count == 0, "an unidentified connection's replacement was arbitrated")
        #expect(await server.currentClientIdentity() == newApp)

        await server.stop()
    }

    /// The other half of the nil decision: a successor the daemon could not
    /// identify does not excuse the app it replaced. Whether that app is still
    /// there is answered from its own identity, and an unidentified successor
    /// can never be mistaken for it.
    @Test func anUnidentifiedSuccessorStillHasTheReplacedAppArbitrated() async throws {
        let (oldServerFD, oldClientFD) = try Self.socketPair()
        let (newServerFD, newClientFD) = try Self.socketPair()
        defer { Darwin.close(oldClientFD); Darwin.close(newClientFD) }

        let oldApp = ProcessIdentity(
            pid: 11, startedAt: Date(timeIntervalSince1970: 10), commandLine: "old")
        // Only the old connection's peer can be identified.
        let identities = [oldServerFD: oldApp]
        let disconnects = DisconnectLog()
        let server = FDVendingServer(peerIdentity: { identities[$0] })
        await server.setOnClientDisconnect { disconnects.record($0) }

        await server.adoptConnection(fd: oldServerFD)
        await server.adoptConnection(fd: newServerFD)

        #expect(disconnects.all == [oldApp])
        #expect(await server.currentClientIdentity() == nil)

        await server.stop()
    }

    private static func socketPair() throws -> (Int32, Int32) {
        var pair: [Int32] = [-1, -1]
        try pair.withUnsafeMutableBufferPointer { buf in
            guard socketpair(AF_UNIX, SOCK_STREAM, 0, buf.baseAddress) == 0 else {
                throw FDChannelError.sendFailed(errno)
            }
        }
        return (pair[0], pair[1])
    }
}

/// Thread-safe record of what the sidecar reported, written from the receive
/// thread and read from the test's task.
private final class DisconnectLog: @unchecked Sendable {
    private let lock = NSLock()
    private var entries: [ProcessIdentity?] = []

    func record(_ identity: ProcessIdentity?) {
        lock.withLock { entries.append(identity) }
    }
    var count: Int { lock.withLock { entries.count } }
    var all: [ProcessIdentity?] { lock.withLock { entries } }
}

/// Hands a test's `connectedApp` seam the arbiter it is wired into, once, so
/// the seam can report a departure from inside a watch's round, and keeps the
/// ruling that departure got. Lock-guarded: armed from the test's task, taken
/// from the arbiter's.
private final class DepartureMidRound: @unchecked Sendable {
    private let lock = NSLock()
    private var arbiter: SidecarDisconnectArbiter?
    private var absorbed: SidecarDisconnectRuling?

    func arm(_ arbiter: SidecarDisconnectArbiter) {
        lock.withLock { self.arbiter = arbiter }
    }

    /// The arbiter on the first call, nil on every call after it.
    func takeArbiter() -> SidecarDisconnectArbiter? {
        lock.withLock {
            let taken = arbiter
            arbiter = nil
            return taken
        }
    }

    func record(_ ruling: SidecarDisconnectRuling) {
        lock.withLock { absorbed = ruling }
    }

    var ruling: SidecarDisconnectRuling? { lock.withLock { absorbed } }
}

/// What the arbiter is told about the sidecar between its checks, scripted by
/// the test: how many sessions the departed app holds, and which app is
/// connected now. Lock-guarded because the arbiter reads it from its own task
/// while the test writes it from another.
///
/// Internal rather than private because `HolderClaimOwnershipTests` drives the
/// same arbiter against a real registry and needs the same connection script.
final class SidecarScript: @unchecked Sendable {
    private let lock = NSLock()
    private var held: Int
    private var current: ProcessIdentity?

    init(sessionsHeld: Int = 0, connected: ProcessIdentity? = nil) {
        held = sessionsHeld
        current = connected
    }

    var sessionsHeld: Int {
        get { lock.withLock { held } }
        set { lock.withLock { held = newValue } }
    }

    var connected: ProcessIdentity? {
        get { lock.withLock { current } }
        set { lock.withLock { current = newValue } }
    }
}
