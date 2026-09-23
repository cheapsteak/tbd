import Darwin
import Foundation
import TestSupport
import Testing
@testable import TBDDaemonLib
@testable import TBDShared

/// "Switch account" on a holder-backed tab, against a **real** holder and a
/// **real** job.
///
/// The scripted suites state the routing and the refusals; this one proves the
/// composition, because what the spec promises is not a return value: the old
/// process is gone, a new one runs under the same row, the session id did not
/// change, and the command the new child was given is a resume of that very
/// session. Only a real pid and a real argv can say any of it.
@Suite(.serialized)
struct HolderProfileSwapLiveTests {

    /// The session the row carries. Never reaches a real Claude: `PATH` finds
    /// a four-line stub first.
    static let sessionID = "sess-holder-profile-swap"

    /// A job that ignores `/exit` — it never reads its terminal — and exits on
    /// `SIGTERM`. The middle rung of the park's ladder is therefore what ends
    /// it, which is the ordinary case for an agent that is busy.
    static let job = "while :; do sleep 0.2; done"

    /// The line the resume fixture's job appends to its transcript on the way
    /// out, standing in for the tail Claude flushes when the park's polite
    /// `/exit` reaches it. Everything about the re-carry hangs on this landing
    /// in the transcript AFTER the handler's pre-park copy was taken.
    static let flushMarker = "flushed as the job ended"

    @Test func inPlaceSwapReparksAndResumesUnderTheNewAccount() async throws {
        let fixture = try await SwapFixture.make()
        defer { fixture.tearDown() }
        let terminal = try await fixture.spawnHolderRow(blank: false, flushOnTerm: true)
        let oldChild = try #require(terminal.childPID)
        let oldHolder = try #require(terminal.holderPID)

        let response = await fixture.router.handle(try RPCRequest(
            method: RPCMethod.terminalSwapProfile,
            params: TerminalSwapProfileParams(
                terminalID: terminal.id,
                newProfileID: fixture.destProfileID,
                mode: .inPlace)))
        #expect(response.success, "the swap failed: \(response.error ?? "")")

        let after = try #require(try await fixture.db.terminals.get(id: terminal.id))
        #expect(after.id == terminal.id, "the swap moved the session to another row")
        #expect(after.claudeSessionID == Self.sessionID,
                "the swap changed the session id an in-place switch must preserve")
        #expect(after.profileID == fixture.destProfileID, "the row is not on the new account")
        #expect(!after.isParked, "the swap left the row parked")

        // The process table, which is where the claim actually lives.
        let goneSignal = kill(oldChild, 0)
        let goneErrno = errno
        #expect(goneSignal == -1 && goneErrno == ESRCH,
                "the old job survived the swap (kill returned \(goneSignal), errno \(goneErrno))")
        // Bounded rather than immediate. The holder is `posix_spawn`ed by this
        // process, so between its exit and `HolderRegistry.reap` collecting it
        // it is a ZOMBIE — and `kill(pid, 0)` answers a corpse exactly as it
        // answers a running process. The reap runs on its own 2 s budget, so an
        // immediate read reddens on a saturated runner for a process that is
        // already dead.
        await pollUntil("the old holder to be reaped") { !holderProcessIsAlive(oldHolder) }
        let newChild = try #require(after.childPID, "the swapped row records no child")
        let newHolder = try #require(after.holderPID, "the swapped row records no holder")
        fixture.remember(holderPID: newHolder, childPID: newChild)
        #expect(newChild != oldChild && newHolder != oldHolder,
                "the swap re-used the pids of the session it just ended")
        #expect(holderProcessIsAlive(newChild), "the swapped row's job is not running")
        #expect(after.holderChildStartedAt != nil,
                "the swapped row has no identity anchor for its new child")

        // WHAT it launched. Every assertion above is satisfied by a holder
        // running the wrong command entirely. The stub is what can tell.
        //
        // Waiting on the env file is what makes the argv file safe to read:
        // the stub writes the argv first and the environment last.
        let launched = await pollUntil("the swapped session to reach its claude stub") {
            (try? String(contentsOfFile: fixture.launchEnvPath, encoding: .utf8))?
                .contains("TBD_TERMINAL_ID=") ?? false
        }
        #expect(launched, "the swap never launched anything through the pinned shell")
        let argv = ((try? String(contentsOfFile: fixture.launchArgvPath, encoding: .utf8)) ?? "")
            .split(separator: "\n").map(String.init)
        let resumeIndex = argv.firstIndex(of: "--resume")
        #expect(resumeIndex != nil, "the swap did not resume anything: \(argv)")
        if let resumeIndex, resumeIndex + 1 < argv.count {
            // Adjacency, not mere presence: a resume of some OTHER session
            // would pass a containment check.
            #expect(argv[resumeIndex + 1] == Self.sessionID, "resumed the wrong session: \(argv)")
        }
        let launchEnv = (try? String(contentsOfFile: fixture.launchEnvPath, encoding: .utf8)) ?? ""
        #expect(launchEnv.contains("TBD_TERMINAL_ID=\(terminal.id.uuidString)"),
                "the resumed agent is attributed to the wrong terminal: \(launchEnv)")

        // WHAT it has to resume FROM. The handler copies the transcript into
        // the destination profile before it parks anything, and that copy skips
        // a destination that already exists — so a turn written while the park
        // is ending (which is exactly what the polite `/exit` asks Claude for)
        // reaches the source jsonl and nothing else. This job writes such a
        // turn from its `SIGTERM` trap; the copy the resume reads has to carry
        // it.
        let source = try #require(
            try? String(contentsOfFile: fixture.sourceTranscriptPath, encoding: .utf8))
        #expect(source.contains(Self.flushMarker),
                "the job never wrote its ending turn, so this test cannot see a stale copy")
        let carried = try #require(
            try? String(contentsOfFile: fixture.destTranscriptPath.path, encoding: .utf8),
            "no transcript reached \(fixture.destTranscriptPath.path)")
        #expect(carried.contains(Self.flushMarker),
                "the resumed session reads a copy taken before the park flushed its last turn")
    }

    /// The blink between the park and the re-home is not an unowned window.
    ///
    /// The three verbs the arm composes each singleflight themselves and each
    /// releases when it returns, so for the length of the transcript re-carry
    /// the row is parked with neither `hibernatesInFlight` nor `wakesInFlight`
    /// naming it. The app wakes exactly the active tab's parked terminal on a
    /// selection change, and the tab "Switch account" was pressed on IS the
    /// active tab — so an ordinary focus-wake can arrive precisely here. The
    /// arm therefore holds a swap claim across the whole composition and an
    /// arriving wake is answered `.inFlight`.
    ///
    /// This is the genuine concurrent wake, driven through the coordinator's
    /// public entry point — the same call the app's focus rail makes — rather
    /// than staged by claiming a set. Without the claim it is not merely
    /// untidy: the wake un-parks the row and spawns a holder under the account
    /// the switch is moving OFF, and the re-home then refuses, so the two
    /// assertions after the seam are what make this test discriminate.
    @Test func inPlaceSwapRefusesAWakeArrivingBetweenTheParkAndTheReHome() async throws {
        let fixture = try await SwapFixture.make()
        defer { fixture.tearDown() }
        let terminal = try await fixture.spawnHolderRow(blank: false, flushOnTerm: true)
        let oldChild = try #require(terminal.childPID)
        let oldHolder = try #require(terminal.holderPID)

        let coordinator = fixture.router.hibernationCoordinator
        let raced = RacedWakeRecorder()
        fixture.router.holderSwapBetweenParkAndReHome = { terminalID in
            raced.record(await coordinator.wake(terminalID: terminalID))
        }

        let response = await fixture.router.handle(try RPCRequest(
            method: RPCMethod.terminalSwapProfile,
            params: TerminalSwapProfileParams(
                terminalID: terminal.id,
                newProfileID: fixture.destProfileID,
                mode: .inPlace)))
        fixture.router.holderSwapBetweenParkAndReHome = nil

        #expect(raced.value == .inFlight,
                "a focus-wake arriving mid-swap was answered \(String(describing: raced.value)) instead of in-flight, and raced the re-home")

        // And the swap itself finished as it always does.
        #expect(response.success, "the swap failed: \(response.error ?? "")")
        let after = try #require(try await fixture.db.terminals.get(id: terminal.id))
        #expect(after.profileID == fixture.destProfileID,
                "the refused wake cost the swap its re-home")
        #expect(!after.isParked, "the swap left the row parked")
        #expect(after.claudeSessionID == Self.sessionID,
                "the swap changed the session id an in-place switch must preserve")
        let goneSignal = kill(oldChild, 0)
        let goneErrno = errno
        #expect(goneSignal == -1 && goneErrno == ESRCH,
                "the old job survived the swap (kill returned \(goneSignal), errno \(goneErrno))")
        await pollUntil("the old holder to be reaped") { !holderProcessIsAlive(oldHolder) }
        let newChild = try #require(after.childPID, "the swapped row records no child")
        let newHolder = try #require(after.holderPID, "the swapped row records no holder")
        fixture.remember(holderPID: newHolder, childPID: newChild)
        // Exactly one holder ran under this row at the end of it: a wake that
        // had been let through would have spawned a second generation the row
        // no longer names, which no reconciler here could reach.
        #expect(newChild != oldChild && newHolder != oldHolder,
                "the swap re-used the pids of the session it just ended")
        #expect(holderProcessIsAlive(newChild), "the swapped row's job is not running")
        #expect(await coordinator.isSwapInFlight(terminalID: terminal.id) == false,
                "the swap did not release its claim on the row")
    }

    /// The other plan. A blank session resumed would show "no conversation
    /// found", so the tmux arm spawns fresh instead and this one matches it.
    @Test func inPlaceSwapOfABlankSessionSpawnsFresh() async throws {
        let fixture = try await SwapFixture.make()
        defer { fixture.tearDown() }
        let deltas = SwapDeltaRecorder()
        deltas.subscribe(to: fixture.router)
        let terminal = try await fixture.spawnHolderRow(blank: true)
        let oldHolder = try #require(terminal.holderPID)

        let response = await fixture.router.handle(try RPCRequest(
            method: RPCMethod.terminalSwapProfile,
            params: TerminalSwapProfileParams(
                terminalID: terminal.id,
                newProfileID: fixture.destProfileID,
                mode: .inPlace)))
        #expect(response.success, "the swap failed: \(response.error ?? "")")

        let after = try #require(try await fixture.db.terminals.get(id: terminal.id))
        #expect(!after.isParked)
        #expect(after.profileID == fixture.destProfileID)
        let freshID = try #require(after.claudeSessionID)
        #expect(freshID != Self.sessionID,
                "a blank session was re-homed under the id it could not resume")
        let newHolder = try #require(after.holderPID, "the swapped row records no holder")
        let newChild = try #require(after.childPID, "the swapped row records no child")
        fixture.remember(holderPID: newHolder, childPID: newChild)
        // Bounded, for the reason the resume test spells out: an unreaped
        // holder is a zombie, and `kill(pid, 0)` cannot tell one from a running
        // process.
        await pollUntil("the old holder to be reaped") { !holderProcessIsAlive(oldHolder) }

        // The app throws the `.inPlace` result away and reconciles its cached
        // row from the deltas alone, so the fresh conversation reaches it only
        // if the arm broadcasts one. Nothing above this line can tell: the row
        // read from the database is right either way.
        let sessions = deltas.terminalSessions()
        #expect(sessions.contains { $0.terminalID == terminal.id && $0.sessionID == freshID },
                "the swap never told the app its fresh session id: \(sessions.map(\.sessionID))")
        // The pair the app reconciles from has to agree with the row. The
        // fresh id and the row's transcript path are written by the SAME
        // guarded statement as the profile — one write, so no failure can land
        // the row on the new account still naming the conversation the fresh
        // spawn replaced — and the announcement carries what that write left.
        // Atomicity itself is not observable from out here (the arm makes one
        // store call and either it commits or nothing does); what is
        // observable is that the three facts never disagree.
        let announced = try #require(
            sessions.last { $0.terminalID == terminal.id },
            "no session delta named the swapped row")
        #expect(announced.sessionID == freshID,
                "the app was told a different conversation than the row holds")
        #expect(announced.transcriptPath == after.transcriptPath,
                "the announcement names a transcript the row does not")
        #expect(after.transcriptPath == nil,
                "the fresh conversation inherited the blank session's transcript file")

        let launched = await pollUntil("the swapped session to reach its claude stub") {
            (try? String(contentsOfFile: fixture.launchEnvPath, encoding: .utf8))?
                .contains("TBD_TERMINAL_ID=") ?? false
        }
        #expect(launched, "the swap never launched anything through the pinned shell")
        let argv = ((try? String(contentsOfFile: fixture.launchArgvPath, encoding: .utf8)) ?? "")
            .split(separator: "\n").map(String.init)
        #expect(!argv.contains("--resume"),
                "a blank session was resumed rather than started fresh: \(argv)")
        let idIndex = argv.firstIndex(of: "--session-id")
        #expect(idIndex != nil, "the fresh spawn named no session: \(argv)")
        if let idIndex, idIndex + 1 < argv.count {
            #expect(argv[idIndex + 1] == freshID,
                    "the row and the spawn disagree about the new session: \(argv)")
        }
    }

    /// The same second failure outcome, for the plan that mints a NEW session
    /// id: a blank session, which is spawned fresh rather than resumed.
    ///
    /// It gets a test of its own because a blank session is the one shape for
    /// which a half-finished swap could cost the user more than the account
    /// switch. The fresh id is written by the same guarded statement as the
    /// profile, so a re-home that fails writes neither: the row keeps the
    /// conversation it had, on the account it had, and the next wake resumes
    /// something that exists. A fresh id recorded against a re-home that never
    /// landed would leave the row naming a conversation with no transcript
    /// anywhere — the "no conversation found" the swap exists to avoid.
    @Test func inPlaceSwapOfABlankSessionWhoseReHomeFailsKeepsTheBlankConversation() async throws {
        let fixture = try await SwapFixture.make()
        defer { fixture.tearDown() }
        let terminal = try await fixture.spawnHolderRow(blank: true)
        let oldChild = try #require(terminal.childPID)
        let oldHolder = try #require(terminal.holderPID)
        let originalTranscriptPath = terminal.transcriptPath

        let db = fixture.db
        let worktreeID = fixture.worktree.id
        fixture.router.holderSwapBetweenParkAndReHome = { _ in
            // Archived is outside `[worktree.status]` — the handler captured
            // `.main` at entry — so the lock refuses before any write runs.
            try? await db.worktrees.updateStatus(id: worktreeID, status: .archived)
        }

        let response = await fixture.router.handle(try RPCRequest(
            method: RPCMethod.terminalSwapProfile,
            params: TerminalSwapProfileParams(
                terminalID: terminal.id,
                newProfileID: fixture.destProfileID,
                mode: .inPlace)))

        #expect(!response.success, "a swap whose re-home could not run reported success")
        let error = response.error ?? "success"
        #expect(error.contains("It is parked on its previous account"),
                "the failure does not say where the row was left: \(error)")

        let after = try #require(try await fixture.db.terminals.get(id: terminal.id))
        #expect(after.isParked, "a failed re-home left the row awake")
        #expect(after.profileID == nil,
                "a re-home that threw still moved the row to the new account")
        #expect(after.claudeSessionID == Self.sessionID,
                "a failed re-home renamed the conversation it did not move")
        #expect(after.transcriptPath == originalTranscriptPath,
                "a failed re-home changed the transcript the row names")
        #expect(after.holderPID == nil && after.childPID == nil,
                "a failed re-home left a replacement process on the row")
        let goneSignal = kill(oldChild, 0)
        let goneErrno = errno
        #expect(goneSignal == -1 && goneErrno == ESRCH,
                "the park did not end the old job (kill returned \(goneSignal), errno \(goneErrno))")
        // Bounded for the reason the resume test spells out: an unreaped holder
        // is a zombie, and `kill(pid, 0)` cannot tell one from a running
        // process.
        await pollUntil("the old holder to be reaped") { !holderProcessIsAlive(oldHolder) }

        let rows = try fixture.actuationRows()
        #expect(rows.last?["result"] as? String == "transport-failed",
                "a failed re-home was recorded as something other than transport-failed: \(rows)")

        // The retry the message promises. The row is parked, so the swap takes
        // the cold path: re-home, no park, no wake, no process to interrupt —
        // and the cold path re-homes the row AS IT STANDS, so the blank
        // conversation goes with it rather than being replaced.
        fixture.router.holderSwapBetweenParkAndReHome = nil
        try await fixture.db.worktrees.updateStatus(id: worktreeID, status: .main)

        let retry = await fixture.router.handle(try RPCRequest(
            method: RPCMethod.terminalSwapProfile,
            params: TerminalSwapProfileParams(
                terminalID: terminal.id,
                newProfileID: fixture.destProfileID,
                mode: .inPlace)))
        #expect(retry.success, "the retry the failure message promises failed: \(retry.error ?? "")")

        let retried = try #require(try await fixture.db.terminals.get(id: terminal.id))
        #expect(retried.profileID == fixture.destProfileID,
                "the retry did not re-home the row to the new account")
        #expect(retried.isParked, "the cold path woke a row it must only have re-homed")
        #expect(retried.holderPID == nil && retried.childPID == nil,
                "the cold path started a process for a parked row")
        #expect(retried.claudeSessionID == Self.sessionID,
                "the cold path renamed the conversation it re-homed")

        // And what a wake of that re-homed row then does. Recorded rather than
        // designed: the cold path re-homes a parked row without touching its
        // session, so the row still names the blank conversation and an
        // ordinary wake resumes THAT id on the new account — the same thing a
        // wake does for any parked row. The assertions are held to what that
        // guarantees: the row wakes, on the destination account, under the id
        // it was re-homed with.
        let woken = await fixture.router.handle(try RPCRequest(
            method: RPCMethod.terminalWake,
            params: TerminalWakeParams(terminalID: terminal.id)))
        #expect(woken.success, "the re-homed blank row would not wake: \(woken.error ?? "")")

        let awake = try #require(try await fixture.db.terminals.get(id: terminal.id))
        #expect(!awake.isParked, "the wake left the row parked")
        #expect(awake.profileID == fixture.destProfileID,
                "the wake moved the row off the account the retry re-homed it to")
        #expect(awake.claudeSessionID == Self.sessionID,
                "the wake changed the session id the cold path preserved")
        let newHolder = try #require(awake.holderPID, "the woken row records no holder")
        let newChild = try #require(awake.childPID, "the woken row records no child")
        fixture.remember(holderPID: newHolder, childPID: newChild)
    }

    /// The spec's second failure outcome: a re-home that fails after the park
    /// succeeded leaves the row **parked on the old account**, and a retry
    /// takes the cold path.
    ///
    /// Only a live park can reach that window. The re-home's write is guarded
    /// twice — a CAS on the terminal row, and the worktree-server lock's
    /// `allowedStatuses` — and both are checked inside the same closure that
    /// does the write, so there is no instant visible from outside the RPC at
    /// which either can be made to fail. `holderSwapBetweenParkAndReHome` is
    /// that instant: the swap has parked the row and re-read it, and has
    /// written nothing. Moving the worktree out of the status the handler
    /// captured at entry is what the lock refuses.
    ///
    /// What the test is for is the guarantee rather than the mechanism — that
    /// a failure here costs the user the account switch and nothing else. The
    /// park really ended the child, so the row must still name the session, on
    /// the profile it started on, with no replacement process anywhere.
    @Test func inPlaceSwapWhoseReHomeFailsLeavesTheRowParkedOnTheOldAccount() async throws {
        let fixture = try await SwapFixture.make()
        defer { fixture.tearDown() }
        let terminal = try await fixture.spawnHolderRow(blank: false, flushOnTerm: true)
        let oldChild = try #require(terminal.childPID)
        let oldHolder = try #require(terminal.holderPID)

        let db = fixture.db
        let worktreeID = fixture.worktree.id
        fixture.router.holderSwapBetweenParkAndReHome = { _ in
            // Archived is outside `[worktree.status]` — the handler captured
            // `.main` at entry — so the lock refuses before any write runs.
            try? await db.worktrees.updateStatus(id: worktreeID, status: .archived)
        }

        let response = await fixture.router.handle(try RPCRequest(
            method: RPCMethod.terminalSwapProfile,
            params: TerminalSwapProfileParams(
                terminalID: terminal.id,
                newProfileID: fixture.destProfileID,
                mode: .inPlace)))

        #expect(!response.success, "a swap whose re-home could not run reported success")
        let error = response.error ?? "success"
        #expect(error.contains("It is parked on its previous account"),
                "the failure does not say where the row was left: \(error)")

        let after = try #require(try await fixture.db.terminals.get(id: terminal.id))
        #expect(after.isParked, "a failed re-home left the row awake")
        #expect(after.profileID == nil,
                "a re-home that threw still moved the row to the new account")
        #expect(after.claudeSessionID == Self.sessionID,
                "a failed re-home lost the conversation the next wake has to resume")
        #expect(after.holderPID == nil && after.childPID == nil,
                "a failed re-home left a replacement process on the row")
        // The park is real, so the pre-swap generation is really gone.
        let goneSignal = kill(oldChild, 0)
        let goneErrno = errno
        #expect(goneSignal == -1 && goneErrno == ESRCH,
                "the park did not end the old job (kill returned \(goneSignal), errno \(goneErrno))")
        // Bounded for the reason the resume test spells out: an unreaped holder
        // is a zombie, and `kill(pid, 0)` cannot tell one from a running
        // process.
        await pollUntil("the old holder to be reaped") { !holderProcessIsAlive(oldHolder) }

        let rows = try fixture.actuationRows()
        #expect(rows.last?["result"] as? String == "transport-failed",
                "a failed re-home was recorded as something other than transport-failed: \(rows)")

        // And the retry the message promises. The row is parked, so the swap
        // takes the cold path at the top of the handler: re-home, no park, no
        // wake, no process to interrupt.
        fixture.router.holderSwapBetweenParkAndReHome = nil
        try await fixture.db.worktrees.updateStatus(id: worktreeID, status: .main)

        let retry = await fixture.router.handle(try RPCRequest(
            method: RPCMethod.terminalSwapProfile,
            params: TerminalSwapProfileParams(
                terminalID: terminal.id,
                newProfileID: fixture.destProfileID,
                mode: .inPlace)))
        #expect(retry.success, "the retry the failure message promises failed: \(retry.error ?? "")")

        let retried = try #require(try await fixture.db.terminals.get(id: terminal.id))
        #expect(retried.profileID == fixture.destProfileID,
                "the retry did not re-home the row to the new account")
        #expect(retried.isParked, "the cold path woke a row it must only have re-homed")
        #expect(retried.holderPID == nil && retried.childPID == nil,
                "the cold path started a process for a parked row")
    }

    /// The spec's third failure outcome, through the RPC: a wake that cannot
    /// start a holder leaves the row **parked on the new account**, so the
    /// switch has taken effect at the account level and the next wake retries
    /// the resume.
    ///
    /// It is the one outcome whose response is SUCCESS-shaped. The other two
    /// return `.error`, because nothing about the session moved; this one
    /// returns the re-homed row, and says the resume did not happen only in the
    /// actuation record. That asymmetry is the contract this test exists to
    /// pin, and no direct call to the wake half can see it.
    ///
    /// The failure is staged on the registry rather than through a router seam:
    /// the spawner resolves its executable path on every spawn, so removing the
    /// fixture's own symlink to `TBDHolder` between the row's creation and the
    /// swap reproduces the daemon whose helper moved — the spec's named wake
    /// failure — with the park, the re-home and every other half untouched.
    @Test func inPlaceSwapWhoseWakeFailsLeavesTheRowParkedOnTheNewAccount() async throws {
        let fixture = try await SwapFixture.make()
        defer { fixture.tearDown() }
        let terminal = try await fixture.spawnHolderRow(blank: false, flushOnTerm: true)
        let oldChild = try #require(terminal.childPID)
        let oldHolder = try #require(terminal.holderPID)

        // The running holder has already exec'd, so it and its job are
        // unaffected: only the NEXT spawn — the swap's wake — has nothing to
        // start.
        try fixture.removeHolderHelper()

        let response = await fixture.router.handle(try RPCRequest(
            method: RPCMethod.terminalSwapProfile,
            params: TerminalSwapProfileParams(
                terminalID: terminal.id,
                newProfileID: fixture.destProfileID,
                mode: .inPlace)))

        #expect(response.success,
                "a wake failure was reported as an RPC error: \(response.error ?? "")")
        let returned = try response.decodeResult(Terminal.self)
        #expect(returned.id == terminal.id, "the swap moved the session to another row")
        #expect(returned.profileID == fixture.destProfileID,
                "the response does not carry the account the switch took effect on")
        #expect(returned.isParked, "the response claims a row a failed wake left awake")
        #expect(returned.holderPID == nil && returned.childPID == nil,
                "the response names processes no wake started")

        let after = try #require(try await fixture.db.terminals.get(id: terminal.id))
        #expect(after.isParked, "a failed wake left the row awake")
        #expect(after.profileID == fixture.destProfileID,
                "a failed wake un-did the re-home; the switch must stand at the account level")
        #expect(after.claudeSessionID == Self.sessionID,
                "a failed wake lost the conversation the next wake has to resume")
        #expect(after.holderPID == nil && after.childPID == nil,
                "a failed wake recorded processes nothing started")
        // Routing, as far as this fixture can see it. Its router carries no
        // model proxy supervisor, so the arm's attachment is `.unproxied`: no
        // route is minted and there is no route file to linger. The row's
        // stream path is therefore nil on both paths and this assertion is a
        // floor rather than a discriminator — it says only that a wake which
        // started nothing left no stream file pointing at it. A test that
        // watched a real route being retired would need a supervisor, which is
        // the proxy suites' subject rather than this one's.
        #expect(after.transcriptStreamPath == nil,
                "a wake that started nothing stamped a transcript stream path")

        // The park is real, so the pre-swap generation is really gone.
        let goneSignal = kill(oldChild, 0)
        let goneErrno = errno
        #expect(goneSignal == -1 && goneErrno == ESRCH,
                "the park did not end the old job (kill returned \(goneSignal), errno \(goneErrno))")
        // Bounded for the reason the resume test spells out: an unreaped holder
        // is a zombie, and `kill(pid, 0)` cannot tell one from a running
        // process.
        await pollUntil("the old holder to be reaped") { !holderProcessIsAlive(oldHolder) }
        #expect(!FileManager.default.fileExists(atPath: fixture.launchArgvPath),
                "a wake that could not start a holder still launched something")

        let rows = try fixture.actuationRows()
        #expect(rows.last?["result"] as? String == "transport-failed",
                "a failed wake was recorded as something other than transport-failed: \(rows)")
        let recorded = rows.last?["error"] as? String ?? ""
        #expect(recorded.contains("starting a holder for this session failed"),
                "the actuation does not name the wake half as what failed: \(recorded)")

        // And the retry the outcome promises: the row is parked on the new
        // account, so an ordinary focus-style wake resumes it there.
        try fixture.restoreHolderHelper()
        let woken = await fixture.router.handle(try RPCRequest(
            method: RPCMethod.terminalWake,
            params: TerminalWakeParams(terminalID: terminal.id)))
        #expect(woken.success, "the retry the failure promises failed: \(woken.error ?? "")")

        let resumed = try #require(try await fixture.db.terminals.get(id: terminal.id))
        #expect(!resumed.isParked, "the retry left the row parked")
        #expect(resumed.profileID == fixture.destProfileID,
                "the retry resumed the session on the account the swap left")
        #expect(resumed.claudeSessionID == Self.sessionID,
                "the retry changed the session id the swap preserved")
        let newHolder = try #require(resumed.holderPID, "the woken row records no holder")
        let newChild = try #require(resumed.childPID, "the woken row records no child")
        fixture.remember(holderPID: newHolder, childPID: newChild)

        let launched = await pollUntil("the retried wake to reach its claude stub") {
            (try? String(contentsOfFile: fixture.launchEnvPath, encoding: .utf8))?
                .contains("TBD_TERMINAL_ID=") ?? false
        }
        #expect(launched, "the retry never launched anything through the pinned shell")
        let argv = ((try? String(contentsOfFile: fixture.launchArgvPath, encoding: .utf8)) ?? "")
            .split(separator: "\n").map(String.init)
        let resumeIndex = argv.firstIndex(of: "--resume")
        #expect(resumeIndex != nil, "the retry did not resume anything: \(argv)")
        if let resumeIndex, resumeIndex + 1 < argv.count {
            // Adjacency, not mere presence, for the reason the resume test
            // gives: a resume of some other session would pass containment.
            #expect(argv[resumeIndex + 1] == Self.sessionID,
                    "the retry resumed the wrong session: \(argv)")
        }
    }
}

// MARK: - Raced wake recorder

/// What the coordinator answered a wake that arrived while a swap held the
/// row. A box rather than a returned value because the wake is made from
/// inside the router's seam closure, which returns nothing.
private final class RacedWakeRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: WakeResult?

    func record(_ result: WakeResult) {
        lock.withLock { stored = result }
    }

    var value: WakeResult? {
        lock.withLock { stored }
    }
}

// MARK: - Delta recorder

/// Every `StateDelta` the router broadcast while a test ran.
///
/// The app's `.inPlace` path discards the RPC's result and reconciles from
/// these, so a swap that updates the database and tells nobody is invisible to
/// a test that only reads rows.
private final class SwapDeltaRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [StateDelta] = []

    func subscribe(to router: RPCRouter) {
        router.subscriptions.addSubscriber { [weak self] data in
            guard let delta = try? JSONDecoder().decode(StateDelta.self, from: data) else {
                return true
            }
            guard let self else { return false }
            self.lock.withLock { self.values.append(delta) }
            return true
        }
    }

    func terminalSessions() -> [TerminalSessionDelta] {
        lock.withLock { values }.compactMap { delta in
            guard case .terminalSessionUpdated(let session) = delta else { return nil }
            return session
        }
    }
}

// MARK: - Fixture

/// A database, a worktree on disk, a real `HolderRegistry` with a real
/// spawner, and an `RPCRouter` whose hibernation coordinator shares that
/// registry — assembled the way `Daemon.swift` assembles them.
private final class SwapFixture {

    let db: TBDDatabase
    let registry: HolderRegistry
    let router: RPCRouter
    let worktree: Worktree
    let destProfileID: UUID

    /// Where the stub `claude` records the argv it was launched with, one
    /// argument per line, and the `TBD_` environment it saw. Neither exists
    /// until the swap has actually launched something. The argv file is
    /// written first and the env file last, so a reader that waits for the env
    /// file has a complete argv file to read.
    var launchArgvPath: String { "\(home)/launch-argv" }
    var launchEnvPath: String { "\(home)/launch-env" }

    /// Every actuation line the log holds, decoded. A swap whose transport
    /// half failed is visible nowhere else: the arm reports the failure out of
    /// band, so a test reading only the response and the row cannot tell a
    /// completed swap from one recorded `transport-failed`.
    func actuationRows() throws -> [[String: Any]] {
        guard let contents = try? String(
            contentsOfFile: "\(home)/actuations.jsonl", encoding: .utf8) else { return [] }
        return try contents
            .split(separator: "\n", omittingEmptySubsequences: true)
            .map { line in
                try #require(
                    try JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any])
            }
    }

    /// The row's own transcript — the jsonl the SOURCE side writes, which is
    /// what a live agent would still be appending to as its park ends.
    var sourceTranscriptPath: String {
        "\(home)/\(HolderProfileSwapLiveTests.sessionID).jsonl"
    }

    /// Where a `claude --resume` under the DESTINATION profile looks for that
    /// conversation: the derived cwd-slug directory under the destination
    /// config dir's `projects/` tree. Named the way the product names it, so
    /// the assertion cannot pass against a copy the resume would never read.
    var destTranscriptPath: URL {
        TranscriptProjectDirSync.derivedProjectDir(
            worktreePath: worktree.localPath,
            projectsRoot: configDirManager
                .configDirectory(forProfileID: destProfileID)
                .appendingPathComponent("projects", isDirectory: true)
        ).appendingPathComponent("\(HolderProfileSwapLiveTests.sessionID).jsonl")
    }

    private let configDirManager: ClaudeProfileConfigDirManager
    private let home: String
    private let tempDir: URL
    /// The symlink the spawner spawns from, and what it points at.
    private let helperLinkPath: String
    private let helperTargetPath: String
    private var torndown = false

    /// A pid this fixture spawned, and the kernel's record of when that pid
    /// started.
    ///
    /// The start time is what makes the pid safe to signal later. A pid is
    /// free the instant its corpse is collected, and on a box running dozens
    /// of agent sessions the next process to take it is somebody else's — so
    /// `tearDown` signals a remembered pid only while the kernel still reports
    /// the same start instant, which is the answer `AgentReaper` gives to the
    /// same question about a holder row.
    private struct SpawnedProcess {
        let pid: Int32
        /// nil when the pid was already gone by the time it was recorded,
        /// which makes it unidentifiable and therefore never signalled.
        let startedAt: Date?
        /// Whether this process is a child of the test process itself. The
        /// holder is — `HolderSpawner` `posix_spawn`s it directly — so its
        /// corpse must be reaped or it outlives the suite. The job is the
        /// holder's child, not ours, and the kernel reaps it.
        let ourChild: Bool
    }

    private var spawned: [SpawnedProcess] = []

    /// The stand-in login shell the wake spawn runs, plus the `claude` stub it
    /// puts ahead of everything else on PATH.
    ///
    /// The shell HONOURS its `-i -l -c <command>` argv rather than ignoring
    /// it, because that argv is the artifact under test: evaluating it turns
    /// the composition's inline `export TBD_…` statements into real
    /// environment variables and launches "claude", so the stub can record
    /// both. The stub returns rather than blocking, so the shell reaches its
    /// `exec sleep` and the job stays exactly one pid — the one the row names
    /// and the one teardown kills.
    private static func writeGateShell(in home: String) throws -> String {
        try FileManager.default.createDirectory(
            atPath: home, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        let binDir = "\(home)/bin"
        try FileManager.default.createDirectory(
            atPath: binDir, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        try """
        #!/bin/sh
        printf '%s\\n' "$@" > "\(home)/launch-argv"
        printf 'SWAPPED-OK\\n'
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

    static func make() async throws -> SwapFixture {
        let home = fencedScratchRoot(prefix: "tbdswp")
        let shell = try writeGateShell(in: home)
        let environment = ["TBD_HOME": home, "PATH": "/usr/bin:/bin", "SHELL": shell]

        let db = try TBDDatabase(inMemory: true)
        try await db.config.setPtyHolderEnabled(true)

        let executable = try #require(
            HolderProcessFixture.locateExecutable(),
            "TBDHolder must be built beside the test bundle")
        // The spawner is pointed at a symlink this fixture owns rather than at
        // the build product itself, so a test can take the helper away — see
        // `removeHolderHelper` — without touching a file every other suite on
        // this machine spawns from. `posix_spawn` resolves the link on each
        // spawn, which is what makes the removal a live fact rather than a
        // value captured at construction.
        let helperLink = "\(home)/TBDHolder"
        try FileManager.default.createSymbolicLink(
            atPath: helperLink, withDestinationPath: executable.path)
        let registry = HolderRegistry(
            owner: HolderOwnerToken(rawValue: "acme-installation"),
            environment: environment,
            listTerminals: { [] },
            spawner: HolderSpawner(executableURL: URL(fileURLWithPath: helperLink)))

        let tmux = TmuxManager(dryRun: true)
        let configDirManager = ClaudeProfileConfigDirManager(
            baseDirectory: URL(fileURLWithPath: home)
                .appendingPathComponent("profiles", isDirectory: true),
            hostBaseDirectory: URL(fileURLWithPath: home)
                .appendingPathComponent("claude", isDirectory: true))
        let lifecycle = WorktreeLifecycle(
            db: db, git: GitManager(), tmux: tmux, hooks: HookResolver(),
            configDirManager: configDirManager)
        let router = RPCRouter(
            db: db, lifecycle: lifecycle, tmux: tmux, startTime: Date(),
            configDirManager: configDirManager,
            actuationLog: ActuationLog(path: "\(home)/actuations.jsonl"))
        router.holderRegistry = registry
        await router.hibernationCoordinator.setHolderRegistry(registry)

        let (tempDir, repoDir) = try await createTestRepoResolvingSymlinks()
        let repo = try await db.repos.create(
            path: repoDir.path, displayName: "acme", defaultBranch: "main")
        let worktree = try await db.worktrees.createMain(
            repoID: repo.id, name: "main", branch: "main", path: repoDir.path,
            tmuxServer: TmuxManager.serverName(forRepoPath: repoDir.path))
        let dest = try await db.modelProfiles.create(name: "Dest", kind: .oauth)

        return SwapFixture(
            db: db, registry: registry, router: router, worktree: worktree,
            destProfileID: dest.id, configDirManager: configDirManager,
            home: home, tempDir: tempDir,
            helperLinkPath: helperLink, helperTargetPath: executable.path)
    }

    /// Takes the `TBDHolder` helper out from under the spawner, leaving every
    /// holder that is already running untouched — which is precisely the state
    /// the spec names as a wake failure ("the `TBDHolder` helper missing beside
    /// the daemon, a spawn that threw"). Only the symlink is removed; the build
    /// product it pointed at is never touched.
    func removeHolderHelper() throws {
        try FileManager.default.removeItem(atPath: helperLinkPath)
    }

    /// Puts it back, for the retry half of a test that removed it.
    func restoreHolderHelper() throws {
        try FileManager.default.createSymbolicLink(
            atPath: helperLinkPath, withDestinationPath: helperTargetPath)
    }

    private init(
        db: TBDDatabase, registry: HolderRegistry, router: RPCRouter,
        worktree: Worktree, destProfileID: UUID,
        configDirManager: ClaudeProfileConfigDirManager, home: String, tempDir: URL,
        helperLinkPath: String, helperTargetPath: String
    ) {
        self.db = db
        self.registry = registry
        self.router = router
        self.worktree = worktree
        self.destProfileID = destProfileID
        self.configDirManager = configDirManager
        self.home = home
        self.tempDir = tempDir
        self.helperLinkPath = helperLinkPath
        self.helperTargetPath = helperTargetPath
    }

    /// A real holder supervising a real job, plus the row that names both —
    /// created in the order `WorktreeLifecycle+Create` creates them, so the
    /// registry has adopted the session before the swap reads anything.
    ///
    /// `blank: false` writes a transcript with one complete turn in it, which
    /// is what makes the swap plan a resume; `blank: true` leaves the row with
    /// no transcript at all, which is what makes it plan a fresh spawn.
    ///
    /// `flushOnTerm: true` swaps the job for one that appends a turn to the
    /// row's transcript from its `SIGTERM` trap before exiting — the stand-in
    /// for what a real Claude does when the park's polite `/exit` reaches it,
    /// and the only way a test can tell a transcript carried before the park
    /// from one re-taken after it. It still ends on the ladder's `SIGTERM`
    /// rung, so the park it drives is the same park.
    func spawnHolderRow(blank: Bool, flushOnTerm: Bool = false) async throws -> Terminal {
        let terminalID = UUID()
        let arguments = flushOnTerm
            ? [try writeFlushOnTermJob()]
            : ["-c", HolderProfileSwapLiveTests.job]
        let handle = try await registry.spawn(
            terminalID: terminalID,
            launch: HolderLaunchRequest(
                executable: "/bin/sh",
                arguments: arguments,
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
            claudeSessionID: HolderProfileSwapLiveTests.sessionID,
            kind: .claude,
            transport: .holder,
            holderPID: handle.holderPID,
            childPID: handle.childPID,
            holderChildStartedAt: Date())
        if !blank {
            let transcript = "\(home)/\(HolderProfileSwapLiveTests.sessionID).jsonl"
            try #"{"type":"user","message":{"content":"switch me"}}"#
                .write(toFile: transcript, atomically: true, encoding: .utf8)
            try await db.terminals.updateSession(
                id: terminalID,
                sessionID: HolderProfileSwapLiveTests.sessionID,
                transcriptPath: transcript)
        }
        return try #require(try await db.terminals.get(id: terminalID))
    }

    /// The job that flushes on the way out, as a script file rather than a
    /// `-c` string: the trap body carries quoted JSON, and a file keeps that
    /// out of two layers of Swift and shell quoting.
    ///
    /// `sleep 0.2` rather than a longer nap because a POSIX shell runs a trap
    /// only once its foreground child returns — the append therefore lands
    /// within a fifth of a second of the `SIGTERM`, and always before the exit
    /// the park is polling for.
    private func writeFlushOnTermJob() throws -> String {
        let path = "\(home)/flush-on-term-job"
        try """
        #!/bin/sh
        flush() {
            printf '%s\\n' \
        '{"type":"assistant","message":{"content":"\(HolderProfileSwapLiveTests.flushMarker)"}}' \
        >> "\(sourceTranscriptPath)"
            exit 0
        }
        trap flush TERM
        while :; do sleep 0.2; done
        """.write(toFile: path, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o700], ofItemAtPath: path)
        return path
    }

    /// Records the pair this spawn produced, and names it in the run log.
    ///
    /// The log line is the diagnosis: a holder that outlives a run is a
    /// `setsid` process that re-parents to launchd and keeps its job going,
    /// and a pid printed with the scratch root it belongs to is what makes the
    /// next occurrence answerable from the run log alone. stderr rather than
    /// `print`, for the reason `FlakyTestSupport` uses it: stdout is Swift
    /// Testing's, and both streams reach the tee'd run log.
    private func remember(_ handle: HolderHandle) {
        remember(holderPID: handle.holderPID, childPID: handle.childPID)
    }

    /// Same recording, for a generation this fixture never got a `HolderHandle`
    /// for — the swap's own wake spawns its replacement holder inside the
    /// router, and the only way this fixture learns those two pids is the row
    /// the swap leaves behind (`after.holderPID` / `after.childPID`). Called
    /// from each test right after it reads that row, so the sweep pass below
    /// can end the post-swap generation by pid, identity-checked, exactly like
    /// the pre-swap one.
    fileprivate func remember(holderPID: Int32, childPID: Int32) {
        spawned.append(SpawnedProcess(
            pid: holderPID,
            startedAt: ProcessStartTime.startTime(pid: holderPID),
            ourChild: true))
        spawned.append(SpawnedProcess(
            pid: childPID,
            startedAt: ProcessStartTime.startTime(pid: childPID),
            ourChild: false))
        let line = "SwapFixture: holder pid \(holderPID), "
            + "job pid \(childPID), scratch root \(home)\n"
        FileHandle.standardError.write(Data(line.utf8))
    }

    /// Kills whatever the rows still name, sweeps whatever they no longer do,
    /// then clears the scratch roots.
    ///
    /// Reading the rows rather than a remembered list is the safety property:
    /// a park clears the pids off its row precisely because those processes
    /// are gone, and signalling a remembered number on a box running dozens of
    /// agent sessions would signal somebody else's work. The row pass is also
    /// what reaches the generation the WAKE spawned when this pass runs first —
    /// each test hands that generation's pids to `remember` right after it
    /// reads them off `after`, so the sweep pass below can also end it by pid,
    /// identity-checked, if the row read above ever comes back empty instead.
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
        let registry = self.registry
        Task.detached { await registry.releaseAll() }
        try? FileManager.default.removeItem(atPath: home)
        try? FileManager.default.removeItem(at: tempDir)
    }

    /// The second pass, for the branch where the first one has nothing to work
    /// from.
    ///
    /// `blockingTerminals` waits up to `TestGate.deadline` and returns `[]` on
    /// expiry — and on that branch the sweep above kills nothing, while the
    /// holder it would have killed is a process built to outlive this one:
    /// `TBDHolder` calls `setsid()` and ignores `SIGHUP`, so it survives a dead
    /// test process and keeps its job running, and nothing in the product
    /// reclaims it (`OrphanGC` enumerates the real `~/tbd/holders`, and
    /// `AgentReaper` works from rows this in-memory database never gave
    /// anyone).
    ///
    /// Remembering is safe here only because the kill is identity-checked:
    /// a reissued pid reports a different start instant and is left alone,
    /// exactly as `AgentReaper` leaves one alone. The two passes cannot fight
    /// — a pid the rows already accounted for is either reaped, and reports no
    /// start time at all, or a corpse a second `SIGKILL` cannot disturb.
    private func sweepRememberedProcesses() {
        for process in spawned {
            guard let anchor = process.startedAt,
                  let current = ProcessStartTime.startTime(pid: process.pid),
                  // Both values come from the same kernel field, so a match is
                  // exact; the tolerance only keeps the comparison off
                  // floating-point equality.
                  abs(current.timeIntervalSince(anchor)) < 0.001
            else { continue }
            kill(process.pid, SIGKILL)
            if process.ourChild {
                var ignored: Int32 = 0
                _ = waitpid(process.pid, &ignored, 0)
            }
        }
    }

    /// The rows, read from a non-async teardown on a bounded wait.
    ///
    /// `gateHoldingTask` / `waitForGate` rather than `Task.detached` and a raw
    /// semaphore wait: a teardown that blocks a cooperative-pool thread can
    /// deadlock the runner, and the gate helpers are the repo's answer to it
    /// (`Tests/CLAUDE.md`, "Thread-blocking gates run off the cooperative
    /// pool"). Same spelling as `HibernationFixture.blockingTerminals`.
    private func blockingTerminals() throws -> [Terminal] {
        let box = ResultBox()
        let done = DispatchSemaphore(value: 0)
        let db = self.db
        _ = gateHoldingTask {
            box.value = try? await db.terminals.list()
            done.signal()
        }
        done.waitForGate("SwapFixture.tearDown reading the terminal rows")
        return box.value ?? []
    }

    private final class ResultBox: @unchecked Sendable {
        var value: [Terminal]?
    }
}
