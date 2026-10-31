import Darwin
import Foundation
import DaemonTestSupport
import TestSupport
import Testing
@testable import TBDDaemonLib
@testable import TBDShared
import TBDKernel

/// Park and wake against a **real** holder and a **real** job.
///
/// The scripted suites state the rules; this one proves them against the
/// kernel's own answers, because the property the soak is for is not a return
/// value: it is that the process is actually gone when the row says parked, and
/// actually running when the row says awake. Nothing but a real pid can say
/// either.
///
/// Tier 3, and every rule the holder fixtures carry applies here: a scratch
/// `TBD_HOME` under the run root the wrapper reclaims, rc-free `/bin/sh` jobs, a
/// pinned `SHELL` and `PATH` so no developer profile and no real agent binary is
/// ever reached, bounded waits everywhere, and a teardown that kills the holder
/// AND the job — holder death is deliberately not child death.
@Suite(.serialized)
struct HolderHibernationLiveTests {

    /// The park's whole point, against a real job — and the rung the ladder
    /// starts at, proved by the job's own hand.
    ///
    /// Every park starts at `SIGTERM`, and that is what ends this job. The
    /// marker file is what says so rather than leaving it to be inferred from
    /// a dead pid — a `SIGKILL` cannot run a handler, so a park that skipped
    /// the `SIGTERM` rung and went straight to the forced one would leave that
    /// file absent while every other assertion below still passed.
    @Test func parkEndsTheJobAndClearsTheRow() async throws {
        let fixture = try await HibernationFixture.make()
        defer { fixture.tearDown() }
        let terminal = try await fixture.spawnHolderRow()
        let childPID = try #require(terminal.childPID)
        let holderPID = try #require(terminal.holderPID)

        // The snapshot's own precondition, asked of the registry this park
        // will ask. `.daemon` is the only source the park freezes as its
        // snapshot, and it is a fact about a real adopted reader draining a
        // real pty — the scripted suites can state the other sources, but only
        // a live holder can prove this one is what an ordinary detached
        // session actually answers.
        let reader = try #require(await fixture.registry.reader(for: terminal.id))
        let observed = try await reader.screen(
            maxLines: HibernationCoordinator.holderScreenLines)
        #expect(observed.source == .daemon,
                "a detached live session answered \(observed.source) rather than .daemon")

        let result = await fixture.coordinator.manualHibernate(terminalID: terminal.id)
        #expect(result == .ok, "park refused: \(result)")

        let parked = try #require(try await fixture.db.terminals.get(id: terminal.id))
        #expect(parked.isParked)
        #expect(parked.claudeSessionID == HibernationFixture.sessionID)
        // A parked row names no processes. These three move together: a pid
        // without its start time is a pid nothing may signal, and either one
        // left behind points the reaper at a number the kernel has recycled.
        #expect(parked.holderPID == nil)
        #expect(parked.childPID == nil)
        #expect(parked.holderChildStartedAt == nil)

        // The invariant, asked of the kernel rather than of the row. ESRCH is
        // the only answer that means gone: EPERM would mean alive and owned by
        // somebody else, which on a shared box is a real possibility for a
        // recycled pid.
        // `errno` is captured on the next line rather than read inside the
        // expectation: the message is an autoclosure, evaluated only on
        // failure, by which time any intervening libc call has clobbered it.
        let signalled = kill(childPID, 0)
        let signalErrno = errno
        #expect(signalled == -1 && signalErrno == ESRCH,
                "the job survived a park that reported .ok (kill returned \(signalled), errno \(signalErrno))")
        #expect(!holderProcessIsAlive(holderPID), "the holder outlived the park")
        // A released slot, not merely a suspended reader: `reader(for:)` answers
        // for an adopted slot and keeps answering across an attach, so nil here
        // means the registry let this session go rather than that the daemon is
        // off the pty.
        #expect(await fixture.registry.reader(for: terminal.id) == nil,
                "the registry still holds a reader for a parked session")
        // WHICH rung ended it. The job wrote this from its own `SIGTERM`
        // handler, so its existence is the one fact that separates the
        // `SIGTERM` rung from the forced teardown after it.
        #expect(FileManager.default.fileExists(atPath: fixture.jobTermMarkerPath),
                "the job never caught a SIGTERM, so the park skipped the SIGTERM rung for the forced teardown")
    }

    /// The rung after that one, on a job that declines `SIGTERM`.
    ///
    /// `trap '' TERM` is what makes this a test of the forced teardown rather
    /// than of the ladder generally: the `SIGTERM` is ignored, and the only
    /// thing left that can end this process is the `SIGKILL`
    /// `HolderRegistry.abandon` sends to its group. A park that stopped at the
    /// `SIGTERM` rung would report the child survived and roll itself back.
    @Test func parkEscalatesToTheForcedRungWhenTheJobIgnoresSIGTERM() async throws {
        // Three attempts rather than the fixture default: this poll is
        // guaranteed to fail every time, so its budget is pure wall time.
        let fixture = try await HibernationFixture.make(holderTerminateAttempts: 3)
        defer { fixture.tearDown() }
        let terminal = try await fixture.spawnHolderRow(job: HibernationFixture.signalDeafJob)
        let childPID = try #require(terminal.childPID)
        let holderPID = try #require(terminal.holderPID)

        let result = await fixture.coordinator.manualHibernate(terminalID: terminal.id)
        #expect(result == .ok, "park refused: \(result)")

        let parked = try #require(try await fixture.db.terminals.get(id: terminal.id))
        #expect(parked.isParked)
        #expect(parked.childPID == nil)
        let signalled = kill(childPID, 0)
        let signalErrno = errno
        #expect(signalled == -1 && signalErrno == ESRCH,
                "a job that ignores SIGTERM survived the park (kill returned \(signalled), errno \(signalErrno))")
        #expect(!holderProcessIsAlive(holderPID), "the holder outlived the park")
        #expect(!FileManager.default.fileExists(atPath: fixture.jobTermMarkerPath),
                "this job has no SIGTERM handler, so a marker here means the fixture wrote it")
    }

    /// A session spawned with the composer-draft feature is ended by signal
    /// and never typed into, asked of the job's own stdin rather than of the
    /// ladder's code path.
    ///
    /// The session's files say what a live mod and a confirmed, restorable
    /// draft say, so the park proceeds. A typed `/exit` would land at the end
    /// of that draft, and Enter would send it to the model; the job records
    /// every byte its terminal delivers, so an empty record and a caught
    /// `SIGTERM` together say the park signalled and typed nothing.
    /// `theStdinRecorderSeesInputWithNoLineTerminator` proves the recorder
    /// sees bytes no Enter follows, a bare `/exit` among them, which is what
    /// makes the empty record here mean something.
    @Test func parkOfAFeatureSessionSignalsAndTypesNothing() async throws {
        let fixture = try await HibernationFixture.make()
        defer { fixture.tearDown() }
        let incarnation = UUID()
        try fixture.seedComposerDraftSession(incarnation: incarnation)
        let terminal = try await fixture.spawnHolderRow(
            job: HibernationFixture.stdinRecordingJob(
                markerPath: fixture.jobTermMarkerPath, inputPath: fixture.jobInputPath),
            sessionIncarnationID: incarnation)
        let childPID = try #require(terminal.childPID)
        #expect(await pollUntil("the job's stdin recorder to come up") {
            FileManager.default.fileExists(atPath: fixture.jobInputPath)
        })

        let result = await fixture.coordinator.manualHibernate(terminalID: terminal.id)
        #expect(result == .ok, "park refused: \(result)")

        let parked = try #require(try await fixture.db.terminals.get(id: terminal.id))
        #expect(parked.isParked)
        let signalled = kill(childPID, 0)
        let signalErrno = errno
        #expect(signalled == -1 && signalErrno == ESRCH,
                "the job survived a park that reported .ok (kill returned \(signalled), errno \(signalErrno))")
        #expect(FileManager.default.fileExists(atPath: fixture.jobTermMarkerPath),
                "the job never caught a SIGTERM, so the park did not end it by signal")
        let typed = (try? String(contentsOfFile: fixture.jobInputPath, encoding: .utf8)) ?? ""
        #expect(!typed.contains("/exit"),
                "the park typed into a session spawned with the feature: \(typed.debugDescription)")
        #expect(typed.isEmpty,
                "the park wrote to the terminal of a session spawned with the feature: \(typed.debugDescription)")
    }

    /// The same recording job in a session spawned without the feature: a
    /// manual park of it ends by signal and types nothing, exactly as a park
    /// of a confirmed session does. Nothing saved its draft, so an unsent
    /// draft is lost, but it is never typed into or sent.
    @Test func parkOfALegacySessionSignalsAndTypesNothing() async throws {
        let fixture = try await HibernationFixture.make()
        defer { fixture.tearDown() }
        let terminal = try await fixture.spawnHolderRow(
            job: HibernationFixture.stdinRecordingJob(
                markerPath: fixture.jobTermMarkerPath, inputPath: fixture.jobInputPath))
        #expect(await pollUntil("the job's stdin recorder to come up") {
            FileManager.default.fileExists(atPath: fixture.jobInputPath)
        })

        let result = await fixture.coordinator.manualHibernate(terminalID: terminal.id)
        #expect(result == .ok, "park refused: \(result)")

        let parked = try #require(try await fixture.db.terminals.get(id: terminal.id))
        #expect(parked.isParked)
        #expect(FileManager.default.fileExists(atPath: fixture.jobTermMarkerPath),
                "the job never caught a SIGTERM, so the park did not end it by signal")
        let typed = (try? String(contentsOfFile: fixture.jobInputPath, encoding: .utf8)) ?? ""
        #expect(typed.isEmpty,
                "the park wrote to a legacy session's terminal: \(typed.debugDescription)")
    }

    /// A session spawned with the feature whose mod has not confirmed it — a
    /// spawn record and no heartbeat — is parked by hand without asking, by
    /// signal, and typed into no more than any other.
    @Test func manualParkOfAnUnconfirmedSessionSignalsAndTypesNothing() async throws {
        let fixture = try await HibernationFixture.make()
        defer { fixture.tearDown() }
        let incarnation = UUID()
        try fixture.seedUnconfirmedComposerDraftSession(incarnation: incarnation)
        let terminal = try await fixture.spawnHolderRow(
            job: HibernationFixture.stdinRecordingJob(
                markerPath: fixture.jobTermMarkerPath, inputPath: fixture.jobInputPath),
            sessionIncarnationID: incarnation)
        #expect(await pollUntil("the job's stdin recorder to come up") {
            FileManager.default.fileExists(atPath: fixture.jobInputPath)
        })

        let result = await fixture.coordinator.manualHibernate(terminalID: terminal.id)
        #expect(result == .ok, "park refused: \(result)")

        let parked = try #require(try await fixture.db.terminals.get(id: terminal.id))
        #expect(parked.isParked)
        #expect(FileManager.default.fileExists(atPath: fixture.jobTermMarkerPath),
                "the job never caught a SIGTERM, so the park did not end it by signal")
        let typed = (try? String(contentsOfFile: fixture.jobInputPath, encoding: .utf8)) ?? ""
        #expect(typed.isEmpty,
                "the park wrote to an unconfirmed session's terminal: \(typed.debugDescription)")
    }

    /// The control for input no Enter follows: `/exit` without Enter, an
    /// Escape and a Ctrl+C, written through the session's reader, the
    /// descriptor `terminal.send` writes to. A canonical-mode terminal would
    /// hold all of it back from the job, so a park that typed any of it would
    /// leave an empty record and the "types nothing" tests above green; this
    /// shows the recorder sees each byte as it arrives.
    @Test func theStdinRecorderSeesInputWithNoLineTerminator() async throws {
        let fixture = try await HibernationFixture.make()
        defer { fixture.tearDown() }
        let terminal = try await fixture.spawnHolderRow(
            job: HibernationFixture.stdinRecordingJob(
                markerPath: fixture.jobTermMarkerPath, inputPath: fixture.jobInputPath))
        let childPID = try #require(terminal.childPID)
        #expect(await pollUntil("the job's stdin recorder to come up") {
            FileManager.default.fileExists(atPath: fixture.jobInputPath)
        })

        let partial = "/exit\u{1B}\u{03}"
        let reader = try #require(await fixture.registry.reader(for: terminal.id))
        try await reader.write(Data(partial.utf8))

        var recorded = ""
        let seen = await pollUntilTrue(timeout: TestDeadlines.saturatedPass) {
            recorded = (try? String(contentsOfFile: fixture.jobInputPath, encoding: .utf8)) ?? ""
            return recorded.contains(partial)
        }
        // No park ends this job, and the teardown kills only the pids the row
        // names, so the job is ended by `SIGTERM`: its handler takes `cat`
        // down with it.
        if holderProcessIsAlive(childPID) {
            kill(childPID, SIGTERM)
            #expect(await pollUntil("the job to catch the SIGTERM") {
                FileManager.default.fileExists(atPath: fixture.jobTermMarkerPath)
            })
        }
        switch seen {
        case .satisfied:
            break
        case .cancelled:
            throw CancellationError()
        case .timedOut:
            throw BoundedWaitTimeout(
                what: "the job's stdin to record \(partial.debugDescription), which no Enter follows",
                observed: recorded.debugDescription, deadline: TestDeadlines.saturatedPass)
        }
    }

    /// A profile swap's park of a session spawned without the feature ends by
    /// signal and types nothing too: a typed `/exit` would land after whatever
    /// the box holds and submit it to the model.
    ///
    /// No session-mod files are seeded, so the session reads legacy; the
    /// recording job is the one `theStdinRecorderSeesInputWithNoLineTerminator`
    /// shows seeing a bare `/exit`, which is what makes the empty record here
    /// mean the swap's ladder started at SIGTERM.
    @Test func profileSwapParkOfALegacySessionSignalsAndTypesNothing() async throws {
        let fixture = try await HibernationFixture.make()
        defer { fixture.tearDown() }
        let terminal = try await fixture.spawnHolderRow(
            job: HibernationFixture.stdinRecordingJob(
                markerPath: fixture.jobTermMarkerPath, inputPath: fixture.jobInputPath))
        #expect(await pollUntil("the job's stdin recorder to come up") {
            FileManager.default.fileExists(atPath: fixture.jobInputPath)
        })

        let result = await fixture.coordinator.parkForProfileSwap(terminalID: terminal.id)
        #expect(result == .ok, "swap park refused: \(result)")

        let parked = try #require(try await fixture.db.terminals.get(id: terminal.id))
        #expect(parked.isParked)
        #expect(parked.childPID == nil)
        #expect(FileManager.default.fileExists(atPath: fixture.jobTermMarkerPath),
                "the job never caught a SIGTERM, so the swap park did not end it by signal")
        let typed = (try? String(contentsOfFile: fixture.jobInputPath, encoding: .utf8)) ?? ""
        #expect(!typed.contains("/exit"),
                "the swap park typed /exit into a legacy session: \(typed.debugDescription)")
        #expect(typed.isEmpty,
                "the swap park wrote to a legacy session's terminal: \(typed.debugDescription)")
    }

    /// Wake after that park: a fresh holder, a fresh job, and a row that names
    /// both and is no longer parked.
    ///
    /// The command the wake builds is `claude --resume …`, and nothing here
    /// runs it: `WorktreeLifecycle.holderLaunch` hands it to the registry's
    /// pinned `SHELL`, which is a two-line script that ignores its argv. That
    /// is the same lever `HolderSpawnGateTests` uses, and it is what keeps a
    /// live-process test off both the developer's login shell and a real agent.
    @Test func wakeStartsAFreshHolderAndUnparksTheRow() async throws {
        let fixture = try await HibernationFixture.make()
        defer { fixture.tearDown() }
        let terminal = try await fixture.spawnHolderRow()

        #expect(await fixture.coordinator.manualHibernate(terminalID: terminal.id) == .ok)

        let result = await fixture.coordinator.wake(terminalID: terminal.id)
        #expect(result.isOk, "wake refused: \(result)")

        let woken = try #require(try await fixture.db.terminals.get(id: terminal.id))
        #expect(!woken.isParked)
        let holderPID = try #require(woken.holderPID, "the woken row records no holder")
        let childPID = try #require(woken.childPID, "the woken row records no child")
        #expect(holderPID != childPID, "one pid was recorded twice")
        #expect(holderProcessIsAlive(holderPID))
        #expect(holderProcessIsAlive(childPID))
        // The identity anchor for the NEW child. Without it the reaper would
        // measure this process against a row created before the park and read
        // it as a stranger.
        let startedAt = try #require(
            woken.holderChildStartedAt, "the woken row records no child start time")
        #expect(abs(startedAt.timeIntervalSince(Date())) < 300)
        #expect(await fixture.registry.reader(for: terminal.id) != nil,
                "the registry did not adopt the woken session's holder")

        // WHAT it launched. Every assertion above is satisfied by a holder
        // running the wrong command entirely — a fresh session instead of a
        // resume, or one attributed to another terminal — because a row and a
        // pid cannot see an argv. The stub can.
        //
        // Waiting on the env file is what makes the argv file safe to read:
        // the stub writes the argv first and the environment last.
        let launched = await pollUntil("the woken session to reach its claude stub") {
            (try? String(contentsOfFile: fixture.launchEnvPath, encoding: .utf8))?
                .contains("TBD_TERMINAL_ID=") ?? false
        }
        #expect(launched, "the wake never launched anything through the pinned shell")
        let argv = ((try? String(contentsOfFile: fixture.launchArgvPath, encoding: .utf8)) ?? "")
            .split(separator: "\n").map(String.init)
        let resumeIndex = argv.firstIndex(of: "--resume")
        #expect(resumeIndex != nil, "the wake did not resume anything: \(argv)")
        if let resumeIndex, resumeIndex + 1 < argv.count {
            // Adjacency, not mere presence: `--resume` and the session id have
            // to be one flag, or a resume of some OTHER session would pass.
            #expect(argv[resumeIndex + 1] == HibernationFixture.sessionID,
                    "resumed the wrong session: \(argv)")
        }
        let launchEnv = (try? String(contentsOfFile: fixture.launchEnvPath, encoding: .utf8)) ?? ""
        // The two ids every hook, notification and transcript write is
        // attributed by. Delivered as inline exports ahead of the command, so
        // reading them back OUT of the process environment is what proves the
        // delivery, not just the composition.
        #expect(launchEnv.contains("TBD_WORKTREE_ID=\(fixture.worktree.id.uuidString)"),
                "the woken agent is attributed to the wrong worktree: \(launchEnv)")
        #expect(launchEnv.contains("TBD_TERMINAL_ID=\(terminal.id.uuidString)"),
                "the woken agent is attributed to the wrong terminal: \(launchEnv)")

        // Tear the woken session down through the same door the delete path
        // uses, so neither the holder nor its job outlives the test.
        _ = await fixture.registry.abandon(terminal: woken)
        _ = await pollUntil("the woken job to be reclaimed") {
            !holderProcessIsAlive(childPID)
        }
        // Row-driven teardown must not signal these numbers afterwards: they
        // are free now, and the next process to take one is somebody else's.
        try await fixture.db.terminals.setHolderProcess(
            id: terminal.id, holderPID: nil, childPID: nil, startedAt: nil)
    }

    /// The safety rollback: the park's own invariant, on the one path that
    /// reaches it.
    ///
    /// A real job cannot survive the `SIGKILL` the escalation sends, so this
    /// branch is unreachable against a real process table — which is why it
    /// shipped untested. The verdict does not come from the process table
    /// directly, though: it comes from `childIsGone`, whose two sources are the
    /// registry's remembered status and the coordinator's injected
    /// `signaller`. `abandon(terminal:)` nils the first as part of the
    /// escalation, by design, so a signaller that answers "alive" with a
    /// non-zombie `stat` is enough to make the poll say "still running" for as
    /// long as it is asked — whatever the kernel thinks.
    ///
    /// The escalation still really runs: the holder is torn down and the job is
    /// killed for real, through the registry, which the fake cannot reach. What
    /// is under test is only what the coordinator does with a verdict it cannot
    /// turn into "gone" — roll the park intent back rather than finalize a row
    /// that claims parked over a live child.
    @Test func parkRollsBackWhenTheChildOutlivesTheEscalation() async throws {
        let fixture = try await HibernationFixture.make(
            holderTerminateAttempts: 3, holderEscalationAttempts: 3,
            signaller: AlwaysAliveSignaller())
        defer { fixture.tearDown() }
        let terminal = try await fixture.spawnHolderRow()
        let childPID = try #require(terminal.childPID)
        let holderPID = try #require(terminal.holderPID)
        let startedAt = try #require(terminal.holderChildStartedAt)
        let incarnationBefore = terminal.sessionIncarnationID

        // Arm the idle marker through the real sweep before parking, so the
        // "the refusal cleared its markers" assertion below has something to
        // clear. Without this the markers are nil going in and nil coming out,
        // and the assertion passes whether or not the branch resets them.
        //
        // One sweep is all it takes and all that is wanted: the row is at rest
        // but nowhere near a one-minute window, so the gate answers
        // `.notIdleLongEnough`, which seeds `idleSince` and fires nothing.
        // The row is reported idle first: a row whose activity is unknown
        // never arms the marker at all.
        try await fixture.db.terminals.setActivityState(
            id: terminal.id, activityState: .idle, source: .derived)
        try await fixture.db.config.setAutoHibernate(enabled: true, idleMinutes: 1)
        await fixture.coordinator.sweep()
        let armed = await fixture.coordinator.idleSince[terminal.id]
        #expect(armed != nil,
                "the sweep never armed the idle marker, so nothing below discriminates")

        let result = await fixture.coordinator.manualHibernate(terminalID: terminal.id)

        guard case .notEligible(let reason) = result else {
            Issue.record(
                "the park reported \(result) for a child it could never confirm gone")
            return
        }
        // The pid is the whole operational value of this refusal — it is the
        // only handle anybody has on a process whose holder has just been torn
        // down — and "survived" is what stops the text reading like a park that
        // worked.
        #expect(reason.contains("\(childPID)"),
                "the refusal does not name the child that outlived it: \(reason)")
        #expect(reason.contains("survived"),
                "the refusal does not say what happened: \(reason)")

        let after = try #require(try await fixture.db.terminals.get(id: terminal.id))
        // THE invariant. All three, because `isParked` is a disjunction and a
        // rollback that nilled only one of the two columns would still satisfy
        // the column assertion it happened to clear.
        #expect(after.hibernatedAt == nil, "the row claims parked over a live child")
        #expect(after.suspendedAt == nil, "the row claims suspended over a live child")
        #expect(!after.isParked, "the row claims parked over a live child")
        // The park intent is two writes, not one: the columns above and the
        // pending incarnation `beginHibernatedShellRespawn` rotated in. A
        // rollback that left the latter behind would fence the next legitimate
        // replacement against an incarnation no launch will ever confirm.
        #expect(after.pendingSessionIncarnationID == nil,
                "the park intent's pending incarnation outlived the rollback")
        #expect(after.sessionIncarnationID == incarnationBefore,
                "the rollback promoted or rotated the durable incarnation")

        // And the other half of "left awake for reconciliation to judge": the
        // row must still name the processes. These three are the last record of
        // a child whose holder is gone, so erasing them here would hide it from
        // the reconcile arm and from the reaper's holder leg — the two things
        // the refusal explicitly hands it to.
        #expect(after.holderPID == holderPID, "the rollback erased the holder pid")
        #expect(after.childPID == childPID, "the rollback erased the child pid")
        #expect(after.holderChildStartedAt == startedAt,
                "the rollback erased the child's identity anchor")

        // The markers, cleared like every other refusal in the method. Leaving
        // them armed would re-fire this identical doomed park on every sweep.
        let idleMarker = await fixture.coordinator.idleSince[terminal.id]
        let killMarker = await fixture.coordinator.pendingKillSince[terminal.id]
        #expect(idleMarker == nil, "the rollback left the idle marker armed")
        #expect(killMarker == nil, "the rollback left the kill debounce armed")

        // Asked again, the coordinator refuses rather than reporting the
        // session already parked — the state it would report if the rollback
        // had left the row claiming a park. It refuses for the reader the
        // escalation destroyed, which is the honest description of what this
        // session now is.
        let asked = await fixture.coordinator.manualHibernate(terminalID: terminal.id)
        #expect(asked == .notEligible(reason: HibernationCoordinator.holderNoReaderRefusal),
                "a second park did not refuse on the torn-down holder: \(asked)")

        // The escalation was not a dry run, and this is what makes the pid
        // assertions above safe to leave standing: the numbers on that row name
        // nothing now. Teardown reads the row, so clear them here rather than
        // letting it signal pids the kernel is free to hand to somebody else.
        let reclaimed = await pollUntil("the escalation to reclaim the job and the holder") {
            !holderProcessIsAlive(childPID) && !holderProcessIsAlive(holderPID)
        }
        #expect(reclaimed, "the escalation did not tear down what the refusal says it did")
        try await fixture.db.terminals.setHolderProcess(
            id: terminal.id, holderPID: nil, childPID: nil, startedAt: nil)
    }

    /// "Keep when uncertain", on the park path: a recorded pid that now names a
    /// stranger is signalled by nothing at all.
    ///
    /// The stranger is arranged through the signaller rather than through the
    /// process table, because a real pid reissued to somebody else's work is
    /// the one condition a test cannot ask a kernel for. Everything else is
    /// real: a real holder, a real job, and a real teardown afterwards.
    ///
    /// The job declines `SIGHUP` and nothing else, which is what makes its
    /// survival mean something. Telling the holder to let go — which this
    /// refusal still does, since a daemon reading a pty whose job it cannot
    /// identify is worse than one that has let go — closes the pty master and
    /// hangs the job up, so a default-disposition job would die of that and the
    /// assertion below could not tell it from a park that signalled. This one
    /// survives the hangup and would not survive either signal.
    @Test func parkRefusesToSignalAChildItCannotVerify() async throws {
        let stranger = StrangerSignaller()
        let fixture = try await HibernationFixture.make(signaller: stranger)
        defer { fixture.tearDown() }
        let terminal = try await fixture.spawnHolderRow(job: HibernationFixture.hangupDeafJob)
        let childPID = try #require(terminal.childPID)
        let startedAt = try #require(terminal.holderChildStartedAt)

        let result = await fixture.coordinator.manualHibernate(terminalID: terminal.id)

        guard case .notEligible(let reason) = result else {
            Issue.record("the park reported \(result) for a pid it could not verify")
            return
        }
        #expect(reason.contains("\(childPID)"),
                "the refusal does not name the pid it declined to signal: \(reason)")
        #expect(reason.contains("could not be verified"),
                "the refusal does not say why it stopped: \(reason)")

        // Nothing was asked of the process table, which is the whole claim.
        // Asserting on the request rather than on the survivor is what makes
        // this independent of what a signal would have done.
        #expect(stranger.signalsRequested().isEmpty,
                "the park signalled a pid it could not verify: \(stranger.signalsRequested())")
        // And the job really is still there. A `SIGTERM` or a `SIGKILL` would
        // have ended it; the hangup the holder's forget delivered did not.
        #expect(holderProcessIsAlive(childPID),
                "the job died, so something ended it after the identity check refused")

        let after = try #require(try await fixture.db.terminals.get(id: terminal.id))
        #expect(!after.isParked, "a refused park still parked the row")
        #expect(after.pendingSessionIncarnationID == nil,
                "the park intent's pending incarnation outlived the rollback")
        // The pids stay, because the row left awake is the last record of a
        // session the reconcile arm and the reaper's holder leg now have to
        // judge — both of which apply this same identity check and will keep
        // for this same reason.
        #expect(after.childPID == childPID, "the refusal erased the child pid")
        #expect(after.holderChildStartedAt == startedAt,
                "the refusal erased the child's identity anchor")
        // The holder was told to let go, so the daemon is off this pty.
        #expect(await fixture.registry.reader(for: terminal.id) == nil,
                "the daemon is still reading a session whose job it cannot identify")
    }

    /// The wake's adopt guard, on the row shape that made it necessary: parked,
    /// naming no processes, behind a holder that is alive and adopted.
    ///
    /// That row is what a daemon killed between `HolderRegistry.spawn`
    /// publishing its reader and `wakeHolderSection` persisting the pids leaves
    /// behind, and `adoptAll` re-adopts the holder on the next start regardless
    /// of park state — so the reader is back while the row still names nothing.
    /// Un-parking it without restoring the pids would put that session beyond
    /// every reclaimer this transport has, permanently and silently.
    ///
    /// The nil pids are written directly rather than produced by killing a
    /// daemon, and that is the whole of the simulation: the state under test is
    /// the row, and the registry either holds a live reader for the session or
    /// it does not.
    @Test func wakeRestoresThePidsOfARowThatLostThemMidSpawn() async throws {
        let fixture = try await HibernationFixture.make()
        defer { fixture.tearDown() }
        let terminal = try await fixture.spawnHolderRow()
        let childPID = try #require(terminal.childPID)
        let holderPID = try #require(terminal.holderPID)

        // The crash window, reproduced as state: the row is parked and names
        // nothing, while the registry is still reading the session's holder.
        try await fixture.db.terminals.setHolderProcess(
            id: terminal.id, holderPID: nil, childPID: nil, startedAt: nil)
        try await fixture.db.terminals.setHibernated(
            id: terminal.id, sessionID: HibernationFixture.sessionID)
        #expect(await fixture.registry.reader(for: terminal.id) != nil,
                "the fixture lost its reader, so this test would exercise the wrong branch")

        let result = await fixture.coordinator.wake(terminalID: terminal.id)
        #expect(result.isOk, "wake refused: \(result)")

        let woken = try #require(try await fixture.db.terminals.get(id: terminal.id))
        #expect(!woken.isParked)
        // The pid anchor, restored from what the registry itself observed.
        #expect(woken.childPID == childPID,
                "the woken row names \(String(describing: woken.childPID)) rather than the child the registry is reading")
        #expect(woken.holderPID == holderPID,
                "the woken row names \(String(describing: woken.holderPID)) rather than the holder the registry is reading")
        #expect(woken.holderChildStartedAt != nil,
                "the row was un-parked with no identity anchor for its child")
        // Asked of the process table rather than of the row: the number is only
        // an anchor if it still names this session's job.
        #expect(holderProcessIsAlive(childPID), "the restored child pid names nothing")
        let command = ProductionProcessSignaller().commandLine(childPID) ?? ""
        #expect(AgentReaper.isHolderChildExecutable(command),
                "the restored pid names something no holder would have forked: \(command)")

        // And nothing was spawned. Two independent facts: the registry is still
        // reading the ORIGINAL session (a spawn would have been refused by the
        // creation lock, or would have replaced these pids with a second
        // generation's), and the wake's pinned shell — which every spawned
        // holder runs and this session's job does not — never ran.
        #expect(await fixture.registry.reader(for: terminal.id) != nil,
                "the wake released the reader it was supposed to adopt")
        #expect(!FileManager.default.fileExists(atPath: fixture.launchArgvPath),
                "the wake spawned a second holder instead of adopting the live one")
    }

    /// The guard's other leg, with a holder on the other end: the row is
    /// parked over a holder and a job that are both running, and this daemon
    /// holds no reader for them — what a startup adoption that failed leaves.
    ///
    /// The wake must adopt the holder before it un-parks the row. Un-parked
    /// without a reader, the session is awake and nobody drains it: its job
    /// cannot finish exiting, no park can end it, and only an attach would
    /// ever adopt it.
    ///
    /// The reader is released rather than never built, because a release is
    /// the one way to take this daemon off a session while leaving its holder
    /// and job untouched — exactly the state the leg exists for.
    @Test func wakeAdoptsTheHolderOfARowParkedWithNoReader() async throws {
        let fixture = try await HibernationFixture.make()
        defer { fixture.tearDown() }
        let terminal = try await fixture.spawnHolderRow()
        let childPID = try #require(terminal.childPID)

        await fixture.registry.release(terminalID: terminal.id)
        try await fixture.db.terminals.setHibernated(
            id: terminal.id, sessionID: HibernationFixture.sessionID)
        #expect(await fixture.registry.reader(for: terminal.id) == nil,
                "the fixture kept its reader, so this test would exercise the other leg")
        #expect(holderProcessIsAlive(childPID))

        let result = await fixture.coordinator.wake(terminalID: terminal.id)
        #expect(result == .ok(sessionIncarnationID: nil),
                "the wake did not stop at the live holder: \(result)")

        let woken = try #require(try await fixture.db.terminals.get(id: terminal.id))
        #expect(!woken.isParked)
        let reader = try #require(
            await fixture.registry.reader(for: terminal.id),
            "the wake un-parked the row without adopting its holder, so nothing drains the session")
        #expect(await reader.isDraining)
        #expect(await fixture.registry.adoptedProcess(for: terminal.id)?.childPID == childPID,
                "the wake adopted something other than the session's own job")
        #expect(woken.childPID == childPID)
        #expect(!FileManager.default.fileExists(atPath: fixture.launchArgvPath),
                "the wake spawned a second holder instead of adopting the live one")
    }

    /// The wake's adoption waiting behind a release when a teardown lands.
    ///
    /// The row is parked over a live holder whose reader is on its way out,
    /// held mid-release. The wake finds no reader, verifies the child, and its
    /// adoption waits for the release. A delete's teardown arrives during that
    /// wait — `abandon` marks the session let go and queues behind the same
    /// release. When the release lands, the wake's adoption must see the
    /// teardown on its next pass rather than open a fresh hand-over against a
    /// holder being told to forget its session; a publish there would also
    /// have erased the mark and let the wake un-park a torn-down row.
    @Test func aTeardownWhileTheWakeWaitsOnAReleaseKeepsTheRowParked() async throws {
        // A budget far past the test, so the wait the test controls is the
        // only thing that ends the wake's adoption.
        let fixture = try await HibernationFixture.make(attachAdoptionBudget: .seconds(600))
        defer { fixture.tearDown() }
        let terminal = try await fixture.spawnHolderRow()
        try await fixture.db.terminals.setHibernated(
            id: terminal.id, sessionID: HibernationFixture.sessionID)
        let loopsBefore = await fixture.registry.drainLoopsStarted
        // The concurrent work below captures the two actors and the row, never
        // the fixture: it is a non-Sendable class, and a task closure must be.
        let registry = fixture.registry
        let coordinator = fixture.coordinator

        let hold = ReleaseHold()
        await registry.setReleaseBarrier(hold.hook())
        let releasing = Task { await registry.release(terminalID: terminal.id) }
        let parked = await pollUntilTrue(timeout: TestDeadlines.saturatedPass) {
            await hold.parked == 1
        }
        let waking = Task { await coordinator.wake(terminalID: terminal.id) }
        // The wake's adoption is the registry's first `adopt`; once it has
        // consulted the slot it is waiting on the release.
        let waiting = await pollUntilTrue(timeout: TestDeadlines.saturatedPass) {
            await fixture.registry.adoptionCallsEntered == 1
        }
        let tearingDown = Task { await registry.abandon(terminal: terminal) }
        let marked = await pollUntilTrue(timeout: TestDeadlines.saturatedPass) {
            await fixture.registry.letGo(for: terminal.id)?.reason == .teardown
        }
        await hold.release()
        await releasing.value
        _ = await tearingDown.value
        let result = await waking.value

        guard parked == .satisfied, waiting == .satisfied, marked == .satisfied else {
            Issue.record(BoundedWaitTimeout(
                what: "the release to park, the wake to wait on it, and the teardown to mark it",
                observed: "parked \(parked), waiting \(waiting), marked \(marked); wake \(result)",
                deadline: TestDeadlines.saturatedPass))
            return
        }
        guard case .respawnFailed = result else {
            Issue.record("the wake un-parked a row torn down while it waited: \(result)")
            return
        }
        let after = try #require(try await fixture.db.terminals.get(id: terminal.id))
        #expect(after.isParked, "the wake un-parked a row a teardown let go")
        #expect(await fixture.registry.reader(for: terminal.id) == nil,
                "a reader was published for a holder being told to forget its session")
        #expect(await fixture.registry.drainLoopsStarted == loopsBefore,
                "the wake's adoption opened a fresh hand-over after the teardown")
        #expect(await fixture.registry.letGo(for: terminal.id)?.reason == .teardown,
                "the teardown's let-go was erased")
    }

    /// Teardown's second pass, against the branch where the first one has
    /// nothing to read.
    ///
    /// `tearDown` kills what the ROWS still name, which is the right default —
    /// a park clears the pids off its row precisely because those processes are
    /// gone, so a teardown working from a remembered list alone would signal
    /// numbers the kernel has since reissued. But the read can come back empty:
    /// its gate is bounded, and an expiry returns `[]`. On that branch the
    /// by-rows sweep kills nothing, and what it failed to kill is a process
    /// built to outlive this one — `TBDHolder` `setsid`s away and ignores
    /// `SIGHUP` so it survives the daemon's death, which means it survives a
    /// dead test process too, re-parents to launchd, and keeps its job running.
    /// One did, for 24 hours.
    ///
    /// **The row is deleted rather than the gate starved**, because what that
    /// branch means to `tearDown` is "there is no row here to read", and an
    /// empty terminals table is exactly that — immediately, instead of after a
    /// two-minute gate this test would otherwise have to sit through.
    ///
    /// Reverting `sweepRememberedProcesses` fails this test: both pids are
    /// still alive when the poll gives up.
    @Test func tearDownKillsWhatItSpawnedWhenNoRowNamesItAnyMore() async throws {
        let fixture = try await HibernationFixture.make()
        defer { fixture.tearDown() }
        let terminal = try await fixture.spawnHolderRow()
        let holderPID = try #require(terminal.holderPID)
        let childPID = try #require(terminal.childPID)
        #expect(holderProcessIsAlive(holderPID), "the holder never came up")
        #expect(holderProcessIsAlive(childPID), "the job never came up")

        // The state the expired gate leaves teardown in: a live holder, a live
        // job, and nothing in the database naming either.
        try await fixture.db.terminals.delete(id: terminal.id)
        #expect(try await fixture.db.terminals.list().isEmpty,
                "the row is still there, so the by-rows sweep would cover this")

        fixture.tearDown()

        #expect(await pollUntil("the holder to be killed by the remembered-pid sweep") {
            !holderProcessIsAlive(holderPID)
        })
        #expect(await pollUntil("the job to be killed by the remembered-pid sweep") {
            !holderProcessIsAlive(childPID)
        })
    }
}

// MARK: - A process table that never concedes

/// Answers "alive, this session's own child, and not a corpse" for every pid,
/// forever.
///
/// Two questions have to be answered together, because the park asks both. The
/// liveness pair — `isAlive` and `stat` — is what `childIsGone` reads: a `Z…`
/// stat is gone (a zombie is past its last instruction) and everything else is
/// running, so a fake that answered nil for `stat` would be relying on that
/// branch's nil handling rather than stating the case. Answering `"S"` states
/// it.
///
/// The identity pair — `startTime` and `commandLine` — is what every rung of
/// the ladder verifies before it signals, and it must pass here or this test
/// would measure the identity refusal instead of the rollback it is named for.
/// `Date()` sits well inside `AgentReaper.defaultHolderIdentityWindow` of the
/// row's own anchor, and `/bin/sh` is what this fixture's job really is.
///
/// The signal members are no-ops, which is deliberate rather than lazy: the
/// escalation the test is about reaches the job through the REGISTRY, not
/// through this seam, so a fake that quietly swallowed a real `kill` would turn
/// "the escalation ran" into an untestable claim — and a `SIGTERM` rung that
/// went through here must land nowhere, or the job would die and the branch
/// under test would never be reached.
/// Holds every release that reaches the registry's release seam until the
/// test lets it through. Suspends rather than blocking a thread.
private actor ReleaseHold {
    private var released = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private(set) var parked = 0

    func park() async {
        if released { return }
        parked += 1
        await withCheckedContinuation { waiters.append($0) }
    }

    func release() {
        released = true
        for waiter in waiters { waiter.resume() }
        waiters.removeAll()
    }

    nonisolated func hook() -> @Sendable () async -> Void {
        { [self] in await self.park() }
    }
}

private struct AlwaysAliveSignaller: ProcessSignaller {
    func isAlive(_ pid: Int32) -> Bool { true }
    func terminate(_ pid: Int32) {}
    func forceKill(_ pid: Int32) {}
    func children(ofServerPID serverPID: Int32) -> [Int32] { [] }
    func commandLine(_ pid: Int32) -> String? { "/bin/sh" }
    func stat(_ pid: Int32) -> String? { "S" }
    func startTime(_ pid: Int32) -> Date? { Date() }
}

/// A process table on which every pid is a stranger: alive, and started long
/// before the row that names it.
///
/// The one shape the identity check exists for — a pid the kernel has reissued
/// to somebody else's work — and the only one no real process table can be
/// asked to produce on demand. Every signal it is asked for is RECORDED and
/// none is delivered, so a test can assert what the park tried to do
/// independently of what survived.
private final class StrangerSignaller: ProcessSignaller, @unchecked Sendable {
    private let lock = NSLock()
    private var calls: [String] = []

    /// Every signal this seam was asked to deliver, in order.
    func signalsRequested() -> [String] { lock.withLock { calls } }

    func isAlive(_ pid: Int32) -> Bool { true }
    func terminate(_ pid: Int32) { lock.withLock { calls.append("terminate(\(pid))") } }
    func forceKill(_ pid: Int32) { lock.withLock { calls.append("forceKill(\(pid))") } }
    func terminateProcessOnly(_ pid: Int32) {
        lock.withLock { calls.append("terminateProcessOnly(\(pid))") }
    }
    func forceKillProcessOnly(_ pid: Int32) {
        lock.withLock { calls.append("forceKillProcessOnly(\(pid))") }
    }
    func children(ofServerPID serverPID: Int32) -> [Int32] { [] }
    func commandLine(_ pid: Int32) -> String? { "/bin/sh" }
    func stat(_ pid: Int32) -> String? { "S" }
    /// Two hours before any row in this suite was written — far outside
    /// `AgentReaper.defaultHolderIdentityWindow`, which is five minutes.
    func startTime(_ pid: Int32) -> Date? { Date(timeIntervalSinceNow: -7200) }
}

// MARK: - Fixture

/// A database, a worktree, a real `HolderRegistry` with a real spawner, and a
/// coordinator wired to both — assembled the way `Daemon.swift` assembles them.
private final class HibernationFixture {
    /// The session id the row carries and the wake resumes. Never reaches a
    /// real Claude: the pinned shell ignores the argv it is handed.
    static let sessionID = "sess-holder-hibernation"

    /// The default job: it never reads its terminal, and it is honest about
    /// `SIGTERM`.
    ///
    /// It catches `SIGTERM` and leaves a mark before exiting — which is what
    /// makes "the SIGTERM rung ended this job" an observable claim rather than
    /// an inference from a dead pid: a `SIGKILL` cannot run a handler, so the
    /// marker exists if and only if the `SIGTERM` rung is what worked.
    ///
    /// The loop sleeps in fifths of a second because a POSIX shell runs a trap
    /// only after the foreground command it was waiting on completes; a
    /// one-second sleep would put up to a second of the poll window between the
    /// signal and the handler for no benefit.
    static func termAwareJob(markerPath: String) -> String {
        "trap 'printf term > \"\(markerPath)\"; exit 0' TERM; while :; do sleep 0.2; done"
    }

    /// A job that ignores `SIGTERM` outright, so only the forced rung — the
    /// holder let go of, the process group `SIGKILL`ed — can end it.
    static let signalDeafJob = "trap '' TERM; while :; do sleep 0.2; done"

    /// `termAwareJob`, plus a record of every byte its terminal delivers.
    ///
    /// The terminal is saved on descriptor 3 first because a non-interactive
    /// shell gives a background command `/dev/null` for stdin, and only an
    /// explicit redirection overrides that. `cat` copies what it reads into
    /// `inputPath` as it reads it. The `SIGTERM` handler ends `cat` too, so
    /// the job leaves no process behind that the row does not name.
    ///
    /// The holder never sets termios, so the pty starts in canonical mode,
    /// where the line discipline holds input back until a newline arrives:
    /// `cat` would never see `/exit` typed without Enter, or a bare Escape.
    /// `stty -icanon` hands `cat` every byte as it arrives, and `-isig` makes
    /// a typed Ctrl+C a recorded byte rather than a `SIGINT`. A failed `stty`
    /// leaves `stty-failed` in the record, ahead of anything `cat` appends, so
    /// a test that expects an empty record fails instead of passing on a
    /// recorder that could not see what it was there to catch.
    static func stdinRecordingJob(markerPath: String, inputPath: String) -> String {
        "exec 3<&0; "
            + "stty -icanon -isig min 1 time 0 <&3 || printf stty-failed > \"\(inputPath)\"; "
            + "cat <&3 >> \"\(inputPath)\" & reader=$!; "
            + "trap 'printf term > \"\(markerPath)\"; kill $reader 2>/dev/null; exit 0' TERM; "
            + "while :; do sleep 0.2; done"
    }

    /// A job that ignores `SIGHUP` and nothing else.
    ///
    /// For the one test that must distinguish "the park signalled this pid"
    /// from "the pty master closed underneath it": telling a holder to let go
    /// hangs its job up, which a default-disposition job dies of, so a job that
    /// declines the hangup is the only one whose survival proves nothing was
    /// signalled. `SIGTERM` and `SIGKILL` both still end it.
    static let hangupDeafJob = "trap '' HUP; while :; do sleep 0.2; done"

    let db: TBDDatabase
    let registry: HolderRegistry
    let coordinator: HibernationCoordinator
    let environment: [String: String]
    let worktree: Worktree

    /// Where the `claude` stub records the argv it was launched with, one
    /// argument per line, and the `TBD_` environment it saw. Neither exists
    /// until a wake has actually launched something.
    var launchArgvPath: String { "\(home)/launch-argv" }
    var launchEnvPath: String { "\(home)/launch-env" }

    /// Where `termAwareJob` records that it caught a `SIGTERM`. Absent until
    /// one is actually delivered and handled.
    var jobTermMarkerPath: String { "\(home)/job-caught-term" }

    /// Where `stdinRecordingJob` copies what its terminal delivers.
    var jobInputPath: String { "\(home)/job-stdin" }

    /// The sessions root the coordinator reads session-mod files from, inside
    /// this fixture's scratch root. Empty unless a test seeds it, so every
    /// session reads as spawned without the feature by default.
    var sessionsDir: URL {
        URL(fileURLWithPath: home).appendingPathComponent("sessions", isDirectory: true)
    }

    private let home: String
    private let tempDir: URL
    private var torndown = false

    /// A pid this fixture spawned, and the kernel's record of when that pid
    /// started.
    ///
    /// The start time is what makes the pid safe to signal later. A pid is free
    /// the instant its corpse is collected, and on a box running dozens of
    /// agent sessions the next process to take it is somebody else's — so
    /// `tearDown` signals a remembered pid only when the kernel still reports
    /// the same start instant, which is the answer `AgentReaper` gives to the
    /// same question about a holder row.
    private struct SpawnedProcess {
        let pid: Int32
        /// nil when the pid was already gone by the time it was recorded, which
        /// makes it unidentifiable and therefore never signalled.
        let startedAt: Date?
        /// Whether this process is a child of the test process itself. The
        /// holder is — `HolderSpawner` `posix_spawn`s it directly — so its
        /// corpse must be reaped or it outlives the suite. The job is the
        /// holder's child, not ours, and the kernel reaps it.
        let ourChild: Bool
    }

    private var spawned: [SpawnedProcess] = []

    /// A short scratch root under the run root `scripts/test.sh` reclaims: the
    /// rendezvous socket lives under it and `sun_path` is 104 bytes, so a deeper
    /// root fails the bind rather than the assertion.
    private static func scratchHome() -> String {
        fencedScratchRoot(prefix: "tbdhib")
    }

    /// The stand-in login shell the WAKE spawn runs, plus the `claude` stub it
    /// puts ahead of everything else on PATH.
    ///
    /// The shell HONOURS its `-i -l -c <command>` argv rather than ignoring it,
    /// because that argv is the artifact under test. Evaluating it is what
    /// turns the composition's inline `export TBD_…` statements into real
    /// environment variables and what launches "claude" — so the stub can
    /// record the argv and the environment the resumed agent would actually
    /// have been given. Nothing here can reach a real agent: `claude` resolves
    /// to the stub, which is a four-line script.
    ///
    /// The stub returns instead of blocking, so the shell reaches its
    /// `exec sleep` and the job stays exactly one pid — the one the row names
    /// and the one teardown kills. A stub that blocked would leave a grandchild
    /// no row names.
    private static func writeGateShell(in home: String) throws -> String {
        try FileManager.default.createDirectory(
            atPath: home, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        let binDir = "\(home)/bin"
        try FileManager.default.createDirectory(
            atPath: binDir, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])

        // The argv file is written first and the env file last, so a reader
        // that waits for the env file has a complete argv file to read.
        try """
        #!/bin/sh
        printf '%s\\n' "$@" > "\(home)/launch-argv"
        printf 'WOKE-OK\\n'
        env | grep '^TBD_' > "\(home)/launch-env"
        """.write(toFile: "\(binDir)/claude", atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o700], ofItemAtPath: "\(binDir)/claude")

        let path = "\(home)/gate-shell"
        // The command is the LAST argument whatever flags precede it, which is
        // what keeps this shell honest about a `shellFlags` change.
        try """
        #!/bin/sh
        PATH="\(binDir):$PATH"
        export PATH
        for tbd_arg in "$@"; do tbd_command="$tbd_arg"; done
        eval "$tbd_command"
        exec sleep 30
        """.write(toFile: path, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o700], ofItemAtPath: path)
        return path
    }

    /// - Parameters:
    ///   - holderTerminateAttempts: how many times the poll after the `SIGTERM`
    ///     rung asks whether the job is gone. 25 at this fixture's 100 ms
    ///     interval is 2.5 s, which is generous next to the fifth of a second a
    ///     cooperating job takes to reach its trap and mean next to the shipped
    ///     five seconds. A test that has arranged for that poll to NEVER
    ///     succeed passes a small number and buys back the wall time.
    ///   - holderEscalationAttempts: how many times the post-escalation poll
    ///     asks whether the job is gone. The shipped default is generous
    ///     because a real `SIGKILL` lands on a real process table; a test that
    ///     has arranged for the poll to NEVER succeed pays every attempt, so it
    ///     passes a small number and buys back the wall time.
    ///   - signaller: the process table the park's liveness poll reads. The
    ///     real one by default — the whole point of this suite is the kernel's
    ///     own answers — overridden only where the branch under test is one no
    ///     real process can reach.
    static func make(
        holderTerminateAttempts: Int = 25,
        holderEscalationAttempts: Int = 100,
        signaller: any ProcessSignaller = ProductionProcessSignaller(),
        attachAdoptionBudget: Duration = HolderRegistry.defaultAttachAdoptionBudget
    ) async throws -> HibernationFixture {
        let home = scratchHome()
        let shell = try writeGateShell(in: home)
        let environment = [
            "TBD_HOME": home,
            "PATH": "/usr/bin:/bin",
            "SHELL": shell,
        ]

        let db = try TBDDatabase(inMemory: true)
        try await db.config.setPtyHolderEnabled(true)

        let executable = try #require(
            HolderProcessFixture.locateExecutable(),
            "TBDHolder must be built beside the test bundle")
        let registry = HolderRegistry(
            owner: HolderOwnerToken(rawValue: "acme-installation"),
            environment: environment,
            listTerminals: { [] },
            spawner: HolderSpawner(executableURL: executable),
            attachAdoptionBudget: attachAdoptionBudget)

        let (tempDir, repoDir) = try await createTestRepoResolvingSymlinks()
        let repo = try await db.repos.create(
            path: repoDir.path, displayName: "acme", defaultBranch: "main")
        let worktree = try await db.worktrees.createMain(
            repoID: repo.id, name: "main", branch: "main", path: repoDir.path,
            tmuxServer: TmuxManager.serverName(forRepoPath: repoDir.path))

        let coordinator = HibernationCoordinator(
            db: db,
            // Dry-run and never reached: both branches under test fork away
            // from tmux before the first call. A recorder is not needed here —
            // `HolderTmuxAssumptionGateTests` asserts the "no tmux was touched"
            // half without spawning anything.
            tmux: TmuxManager(dryRun: true),
            // The profile/host stores the wake preamble seeds folder trust and
            // resolves a projects root through, kept inside this fixture's own
            // scratch root.
            configDirManager: ClaudeProfileConfigDirManager(
                baseDirectory: URL(fileURLWithPath: home)
                    .appendingPathComponent("profiles", isDirectory: true),
                hostBaseDirectory: URL(fileURLWithPath: home)
                    .appendingPathComponent("claude", isDirectory: true)),
            // 100 ms paces every poll of the holder ladder. The `SIGTERM` and
            // escalation budgets are generous by default — they wait on a real
            // process table on a machine that may be loaded, and a short budget
            // there would fail this test for scheduling rather than for
            // behaviour. A caller that has arranged for a poll to fail every
            // time overrides its budget, since there the generosity is pure
            // wall time. `exitPollAttempts` paces only the tmux park, which no
            // holder row reaches.
            exitPollAttempts: 2,
            exitPollInterval: .milliseconds(100),
            holderTerminateAttempts: holderTerminateAttempts,
            holderEscalationAttempts: holderEscalationAttempts,
            signaller: signaller,
            sessionsDir: URL(fileURLWithPath: home).appendingPathComponent("sessions", isDirectory: true),
            sessionTitles: ClaudeSessionTitleStore(),
            actuationLog: makeTestActuationLog())
        await coordinator.setHolderRegistry(registry)

        return HibernationFixture(
            db: db, registry: registry, coordinator: coordinator, environment: environment,
            worktree: worktree, home: home, tempDir: tempDir)
    }

    private init(
        db: TBDDatabase, registry: HolderRegistry, coordinator: HibernationCoordinator,
        environment: [String: String], worktree: Worktree, home: String, tempDir: URL
    ) {
        self.db = db
        self.registry = registry
        self.coordinator = coordinator
        self.environment = environment
        self.worktree = worktree
        self.home = home
        self.tempDir = tempDir
    }

    /// A real holder supervising a real job, plus the row that names both —
    /// created in the order `WorktreeLifecycle+Create` creates them, so the
    /// registry has adopted the session before anything reads its screen.
    /// `sessionIncarnationID` is the incarnation a spawn made with a
    /// session-mod feature writes into its row.
    func spawnHolderRow(job: String? = nil, sessionIncarnationID: UUID? = nil) async throws -> Terminal {
        let terminalID = UUID()
        let handle = try await registry.spawn(
            terminalID: terminalID,
            launch: HolderLaunchRequest(
                executable: "/bin/sh",
                arguments: ["-c", job ?? Self.termAwareJob(markerPath: jobTermMarkerPath)],
                workingDirectory: "/tmp",
                environment: ["PATH": "/usr/bin:/bin", "TERM": "xterm-256color"],
                columns: 80,
                rows: 24))
        remember(handle)
        _ = try await db.terminals.create(
            id: terminalID,
            worktreeID: worktree.id,
            tmuxWindowID: "",
            tmuxPaneID: "",
            label: TerminalLabel.claudeCode,
            claudeSessionID: Self.sessionID,
            kind: .claude,
            transport: .holder,
            holderPID: handle.holderPID,
            childPID: handle.childPID,
            holderChildStartedAt: Date(),
            sessionIncarnationID: sessionIncarnationID)
        return try #require(try await db.terminals.get(id: terminalID))
    }

    /// Writes the daemon's spawn record for a spawn made with the
    /// composer-draft feature, naming `incarnation`, and nothing from the mod.
    /// The park then reads the feature as unknown (`no-alive-file`).
    func seedUnconfirmedComposerDraftSession(incarnation: UUID) throws {
        let nowMs = Int64((Date().timeIntervalSince1970 * 1000).rounded())
        try SessionModFiles.writeSpawnRecord(
            .init(sessionId: Self.sessionID, incarnationId: incarnation.uuidString,
                  spawnedAtMs: nowMs, features: ["composer-draft"]),
            sessionsDir: sessionsDir)
    }

    /// Writes the session's files as a spawn made with the composer-draft
    /// feature and a live mod leave them: the daemon's spawn record naming
    /// `incarnation`, a heartbeat from now, and a saved draft marked
    /// restorable. The park then reads the feature as confirmed.
    func seedComposerDraftSession(incarnation: UUID) throws {
        let nowMs = Int64((Date().timeIntervalSince1970 * 1000).rounded())
        try SessionModFiles.writeSpawnRecord(
            .init(sessionId: Self.sessionID, incarnationId: incarnation.uuidString,
                  spawnedAtMs: nowMs, features: ["composer-draft"]),
            sessionsDir: sessionsDir)
        let directory = sessionsDir.appendingPathComponent(Self.sessionID, isDirectory: true)
        try JSONEncoder().encode(SessionModFiles.AliveRecord(
            sessionId: Self.sessionID, incarnationId: incarnation.uuidString,
            features: ["composer-draft"], heartbeatAtMs: nowMs))
            .write(to: directory.appendingPathComponent(SessionModFiles.aliveFileName))
        try JSONEncoder().encode(SessionModFiles.ComposerDraftRecord(
            sessionId: Self.sessionID, hasDraft: true, text: "half-written prompt", cursor: 19,
            restorable: true, savedAtMs: nowMs))
            .write(to: directory.appendingPathComponent(SessionModFiles.composerDraftFileName))
    }

    /// Records the pair this spawn produced, and names it in the run log.
    ///
    /// **The log line is the diagnosis, and it is written because one was
    /// missing.** A holder that outlived a run was found a day later with its
    /// job still looping, and nothing could be said about how it got there: the
    /// worktree that ran the suite had been archived and deleted, so there was
    /// no way to tell a crashed test process from a teardown that ran and
    /// missed. A pid and the scratch root it belongs to, printed at spawn,
    /// makes the next occurrence answerable from the run log alone.
    ///
    /// stderr rather than `print`, for the same reason `FlakyTestSupport` uses
    /// it: stdout is Swift Testing's, and both streams reach the tee'd run log.
    private func remember(_ handle: HolderHandle) {
        spawned.append(SpawnedProcess(
            pid: handle.holderPID,
            startedAt: ProcessStartTime.startTime(pid: handle.holderPID),
            ourChild: true))
        spawned.append(SpawnedProcess(
            pid: handle.childPID,
            startedAt: ProcessStartTime.startTime(pid: handle.childPID),
            ourChild: false))
        let line = "HibernationFixture: holder pid \(handle.holderPID), "
            + "job pid \(handle.childPID), scratch root \(home)\n"
        FileHandle.standardError.write(Data(line.utf8))
    }

    /// Kills whatever the ROWS still name, sweeps whatever they no longer do,
    /// then clears the scratch roots.
    ///
    /// Reading the rows rather than a list of everything ever spawned is the
    /// safety property: a park clears the pids off its row precisely because
    /// those processes are gone, and a teardown working from a remembered list
    /// would signal numbers the kernel has already handed to somebody else — on
    /// a box running dozens of agent sessions, to somebody else's work. The
    /// remembered list is still swept, in `sweepRememberedProcesses`, but only
    /// where the kernel's start time still says the pid is the one this fixture
    /// spawned — which is how that pass gets the rows' safety without the rows.
    func tearDown() {
        guard !torndown else { return }
        torndown = true

        for row in (try? blockingTerminals()) ?? [] where row.transport == .holder {
            if let holderPID = row.holderPID, holderPID > 1 {
                kill(holderPID, SIGKILL)
                var ignored: Int32 = 0
                _ = waitpid(holderPID, &ignored, 0)
            }
            if let childPID = row.childPID, childPID > 1, holderProcessIsAlive(childPID) {
                kill(childPID, SIGKILL)
            }
        }
        sweepRememberedProcesses()
        // Whatever a reader is still draining is named only by the registry, so
        // release them all. Detached because teardown is not async.
        let registry = self.registry
        Task.detached { await registry.releaseAll() }
        try? FileManager.default.removeItem(atPath: home)
        try? FileManager.default.removeItem(at: tempDir)
    }

    /// The second pass, for the branch where the first one has nothing to work
    /// from.
    ///
    /// **Reading the rows is the right default and it has one hole.**
    /// `blockingTerminals` waits up to `TestGate.deadline` and returns `[]` on
    /// expiry — and on that branch the sweep above kills nothing at all, while
    /// the holder it would have killed is a process built to outlive this one:
    /// `TBDHolder` calls `setsid()` and ignores `SIGHUP`
    /// (`Sources/TBDHolder/Holder.swift`) so it survives the daemon's death,
    /// which means it survives a dead test process just as well. It re-parents
    /// to launchd and keeps its job running, and nothing in the product
    /// reclaims it: `OrphanGC` enumerates the real `~/tbd/holders` and
    /// `AgentReaper` works from `terminal` rows this in-memory database never
    /// gave anyone. One such holder ran for 24 hours.
    ///
    /// So the pids this fixture spawned are remembered as well, and swept here
    /// — **identity-checked**, which is what makes remembering safe. The reason
    /// the by-rows pass exists is that a park CLEARS the pids off its row
    /// precisely because those processes are gone, and a teardown working from
    /// a remembered list alone would signal numbers the kernel has since handed
    /// to somebody else's work. Comparing the kernel's start time against the
    /// one recorded at spawn answers that: a reissued pid reports a different
    /// instant and is left alone, exactly as `AgentReaper` leaves one alone.
    ///
    /// The two passes cannot fight. A pid the rows already accounted for is
    /// either reaped — `ProcessStartTime` reports nothing and it is skipped —
    /// or a corpse waiting to be, which a second `SIGKILL` cannot disturb.
    private func sweepRememberedProcesses() {
        for process in spawned {
            guard let anchor = process.startedAt,
                  let current = ProcessStartTime.startTime(pid: process.pid),
                  // Both values come from the same kernel field, so a match is
                  // exact; the tolerance only keeps the comparison from turning
                  // on floating-point equality.
                  abs(current.timeIntervalSince(anchor)) < 0.001
            else { continue }
            kill(process.pid, SIGKILL)
            if process.ourChild {
                var ignored: Int32 = 0
                _ = waitpid(process.pid, &ignored, 0)
            }
        }
    }

    /// Reads the terminal rows from a non-async `tearDown`.
    ///
    /// `tearDown` runs from a `defer` in the test body, so the thread this
    /// blocks belongs to the cooperative pool and cannot be moved from here.
    /// What CAN be moved is the side that releases the gate: started with
    /// `gateHoldingTask` it runs on a thread these tests own — and the
    /// executor preference carries into the store actor it hops through — so
    /// the read can always reach `signal()` however saturated the pool is.
    /// `Task.detached` took no preference at all and queued the release behind
    /// the very pool this wait is starving.
    ///
    /// `waitForGate` supplies the bound and names the gate if it ever expires,
    /// which is all a teardown can usefully do about one: a timeout simply
    /// means the sweep above has nothing to kill by pid.
    private func blockingTerminals() throws -> [Terminal] {
        let box = ResultBox()
        let done = DispatchSemaphore(value: 0)
        let db = self.db
        _ = gateHoldingTask {
            box.value = try? await db.terminals.list()
            done.signal()
        }
        done.waitForGate("HibernationFixture.tearDown reading the terminal rows")
        return box.value ?? []
    }

    private final class ResultBox: @unchecked Sendable {
        var value: [Terminal]?
    }
}
