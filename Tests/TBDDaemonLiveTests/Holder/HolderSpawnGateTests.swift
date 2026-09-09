import Clocks
import Darwin
import Foundation
import TestSupport
import Testing
@testable import TBDDaemonLib
@testable import TBDShared

/// The gate that decides which transport a new session is born onto, and the
/// read that renders it afterwards.
///
/// Both branches, because `pty_holder_enabled` is a behaviour-gating
/// conditional. The two that carry the most weight are not the happy paths:
///
///   - `terminalOutputReadsTheHolderEmulator` asserts that `capture-pane` was
///     **never called**. A handler that rendered the emulator *and* captured a
///     pane would satisfy every assertion about the returned text while still
///     shelling out to a tmux server the holder transport exists to avoid.
///   - `flagFlipDoesNotMigrateRunningSessions` flips the flag off under a live
///     session. The flag gates spawning, not servicing: a running holder owns a
///     pty that already exists, and no preference can un-own it.
///
/// Every holder here runs a **controlled** program, never the developer's login
/// shell or a real agent. The lever is the registry's `environment`: it is the
/// daemon's own environment in production — which is exactly what the tmux path
/// reads `$SHELL` from, through the server it started — so pinning it here
/// pins the shell the production composition picks, without touching the
/// production composition.
@Suite(.serialized)
struct HolderSpawnGateTests {

    // MARK: - The gate

    /// Flag off: today's behaviour, unchanged, and no rendezvous anywhere.
    ///
    /// The socket assertion is the one that would catch a gate that spawned a
    /// holder *and* a window: the row would still read `.tmux`, and only the
    /// absence of the rendezvous says nothing was started behind it.
    @Test func flagOffSpawnsOntoTmux() async throws {
        let fixture = try await GateFixture.make(flagEnabled: false)
        defer { fixture.tearDown() }

        let created = try await fixture.spawnPrimaryTerminals()

        let primary = try #require(try await fixture.db.terminals.get(id: created[0].id))
        #expect(primary.transport == .tmux)
        #expect(!primary.tmuxWindowID.isEmpty, "a tmux session was created with no window")
        #expect(primary.holderPID == nil)
        #expect(primary.childPID == nil)

        let socketPath = try HolderRendezvous.socketPath(
            sessionID: primary.id, environment: fixture.environment)
        #expect(
            !FileManager.default.fileExists(atPath: socketPath),
            "a holder rendezvous was created for a tmux-transport session")

        // The unchanged half of the setup-hook decision: with the flag off the
        // Setup tab is created whether or not the repo has a hook, exactly as
        // it always has been.
        #expect(created.count == 2)
        #expect(created[1].label == TerminalLabel.setup)
    }

    /// Flag on: a real holder, a real job, and a row that names both.
    ///
    /// `holderPID` and `childPID` are asserted separately and both are checked
    /// for liveness, because holder death is deliberately not child death — a
    /// row that recorded one pid twice would look fine here and be unable to
    /// reclaim anything later.
    @Test func flagOnSpawnsOntoHolder() async throws {
        let fixture = try await GateFixture.make(flagEnabled: true)
        defer { fixture.tearDown() }

        let created = try await fixture.spawnPrimaryTerminals()

        let primary = try #require(try await fixture.db.terminals.get(id: created[0].id))
        #expect(primary.transport == .holder)
        let holderPID = try #require(primary.holderPID)
        let childPID = try #require(primary.childPID)
        #expect(holderPID != childPID)
        #expect(holderProcessIsAlive(holderPID))
        #expect(holderProcessIsAlive(childPID))
        #expect(primary.tmuxWindowID.isEmpty)
        #expect(primary.tmuxPaneID.isEmpty)

        let socketPath = try HolderRendezvous.socketPath(
            sessionID: primary.id, environment: fixture.environment)
        #expect(
            FileManager.default.fileExists(atPath: socketPath),
            "no holder rendezvous at \(socketPath) for a holder-transport session")

        // The reader was born with this job, so whatever the job says about its
        // modes on startup lands in this emulator and its flags are the child's
        // — the other half of the fact `HolderAdoptionTests` asserts negatively
        // for a session adopted while it was already running.
        let reader = try #require(await fixture.registry.reader(for: primary.id))
        #expect(
            await reader.modeReading().modesObserved,
            "a freshly spawned reader reported its child's modes as unobserved")

        // The other half of the setup-hook decision: this repo has no setup
        // hook, so on the holder path no tmux server is started for a bare
        // shell — and no `new-window` was ever issued.
        #expect(created.count == 1)
        let issued = fixture.tmuxCommands()
        #expect(
            !issued.contains(where: { $0.contains("new-window") }),
            "the holder path created a tmux window: \(issued)")
        #expect(
            !issued.contains(where: { $0.contains("new-session") }),
            "the holder path started a tmux server: \(issued)")
    }

    /// A spawned session's drain loop is counted exactly like an adopted
    /// one's.
    ///
    /// `spawn` and `beginAdoption` are the registry's two publish sites, and
    /// `peakLiveDrainLoops` is the one instrument for "two readers on one pty"
    /// — the byte theft object identity cannot see. A publish that counted only
    /// `drainLoopsStarted` left the live count at zero for every spawned
    /// session, so the peak could not rise above zero however many loops ran
    /// beside it, and the release's unconditional decrement then drove the
    /// count negative and kept it there.
    ///
    /// The second half is what sees that drift: after the first session is
    /// released the registry spawns another, and a live count that had gone to
    /// -1 leaves the peak at 0 rather than 1. It pins the decrement too — a
    /// release that stopped the reader without dropping the count would put the
    /// peak at 2 here.
    @Test func aSpawnedSessionCountsItsDrainLoopLikeAnAdoptedOne() async throws {
        let fixture = try await GateFixture.make(flagEnabled: true)
        defer { fixture.tearDown() }

        let created = try await fixture.spawnPrimaryTerminals()
        let terminalID = created[0].id
        #expect(await fixture.registry.drainLoopsStarted == 1)
        #expect(await fixture.registry.peakLiveDrainLoops == 1, """
            a spawned session's drain loop was never counted live, so nothing can see a second \
            reader started beside it
            """)

        await fixture.registry.release(terminalID: terminalID)
        let second = try await fixture.spawnPrimaryTerminals()
        let secondPrimary = try #require(try await fixture.db.terminals.get(id: second[0].id))
        #expect(
            secondPrimary.transport == .holder,
            "the second session did not take the holder path")
        #expect(await fixture.registry.drainLoopsStarted == 2)
        #expect(await fixture.registry.peakLiveDrainLoops == 1, """
            the live drain-loop count drifted across a release: one loop was live at a time \
            throughout, and the peak says otherwise
            """)
    }

    /// Flag on, registry present, but nothing to spawn with: the create still
    /// succeeds, on tmux.
    ///
    /// This is the shape a real daemon has whenever its `TBDHolder` binary is
    /// missing — an upgrade that moved it, a partial build — because
    /// `Daemon.swift` builds the registry regardless: adoption of an
    /// already-running holder needs no executable, and a user whose sessions are
    /// live must not lose them. So the gate cannot read "registry present" as
    /// "can spawn". If it does, `spawn` throws `holderExecutableUnavailable`
    /// with nothing catching it and the whole worktree create fails — a flag
    /// that is merely on takes the user's ability to open a worktree away.
    @Test func missingHolderBinaryFallsBackToTmuxInsteadOfFailingTheCreate() async throws {
        let fixture = try await GateFixture.make(flagEnabled: true, spawnerAvailable: false)
        defer { fixture.tearDown() }

        #expect(
            fixture.registry.canSpawn == false,
            "the fixture did not reproduce a registry with no spawner")

        let created = try await fixture.spawnPrimaryTerminals()

        let primary = try #require(try await fixture.db.terminals.get(id: created[0].id))
        #expect(primary.transport == .tmux)
        #expect(!primary.tmuxWindowID.isEmpty)
        #expect(primary.holderPID == nil)
        #expect(primary.childPID == nil)

        let socketPath = try HolderRendezvous.socketPath(
            sessionID: primary.id, environment: fixture.environment)
        #expect(
            !FileManager.default.fileExists(atPath: socketPath),
            "a holder rendezvous was created by a registry that cannot spawn")

        // And the fallback is the tmux path *whole*, not a half-taken holder
        // path: the Setup tab is created unconditionally there, exactly as with
        // the flag off.
        #expect(created.count == 2)
        #expect(created[1].label == TerminalLabel.setup)
    }

    // MARK: - Extra terminals

    /// `terminal.create` with the flag off: today's behaviour, unchanged — a
    /// tmux window, a tmux row, no rendezvous anywhere.
    @Test func terminalCreateFlagOffStaysOnTmux() async throws {
        let fixture = try await GateFixture.make(flagEnabled: false)
        defer { fixture.tearDown() }

        let terminal = try await fixture.terminalCreate(
            TerminalCreateParams(worktreeID: fixture.worktree.id, cmd: "htop"))

        let row = try #require(try await fixture.db.terminals.get(id: terminal.id))
        #expect(row.transport == .tmux)
        #expect(!row.tmuxWindowID.isEmpty)
        #expect(row.holderPID == nil)
        #expect(row.childPID == nil)
        let socketPath = try HolderRendezvous.socketPath(
            sessionID: row.id, environment: fixture.environment)
        #expect(
            !FileManager.default.fileExists(atPath: socketPath),
            "a holder rendezvous was created for a tmux-transport extra terminal")
    }

    /// `terminal.create` with the flag on: an extra terminal is born onto a
    /// real holder exactly as a primary is — a holder, a job, a row naming
    /// both, an empty tmux coordinate, and no tmux server started for it.
    ///
    /// A shell command, because the holder runs any command and the gate must
    /// not be Claude-shaped: a port that routed only `type: .claude` to the
    /// holder would pass every Claude-typed assertion and leave every plain
    /// terminal on tmux.
    @Test func terminalCreateFlagOnSpawnsAnExtraTerminalOntoTheHolder() async throws {
        let fixture = try await GateFixture.make(flagEnabled: true)
        defer { fixture.tearDown() }

        let terminal = try await fixture.terminalCreate(
            TerminalCreateParams(worktreeID: fixture.worktree.id, cmd: "htop"))

        let row = try #require(try await fixture.db.terminals.get(id: terminal.id))
        #expect(row.transport == .holder)
        let holderPID = try #require(row.holderPID)
        let childPID = try #require(row.childPID)
        #expect(holderPID != childPID)
        #expect(holderProcessIsAlive(holderPID))
        #expect(holderProcessIsAlive(childPID))
        #expect(row.holderChildStartedAt != nil, "the identity anchor was not stamped at spawn")
        #expect(row.tmuxWindowID.isEmpty)
        #expect(row.tmuxPaneID.isEmpty)
        #expect(row.transcriptStreamPath == nil, "a shell was routed through the model proxy")

        let socketPath = try HolderRendezvous.socketPath(
            sessionID: row.id, environment: fixture.environment)
        #expect(
            FileManager.default.fileExists(atPath: socketPath),
            "no holder rendezvous at \(socketPath) for a holder-transport extra terminal")
        #expect(await fixture.registry.reader(for: row.id) != nil)

        let issued = fixture.tmuxCommands()
        #expect(
            !issued.contains(where: { $0.contains("new-window") }),
            "the holder path created a tmux window: \(issued)")
        #expect(
            !issued.contains(where: { $0.contains("new-session") }),
            "the holder path started a tmux server: \(issued)")
    }

    /// An extra Claude terminal on the holder is routed through the model
    /// proxy exactly as a primary session is: one route minted for this
    /// terminal, its stream path stamped in the row's insert, and the pids
    /// beside it.
    @Test func terminalCreateRoutesAnExtraClaudeTerminalLikeAPrimary() async throws {
        let fixture = try await GateFixture.make(flagEnabled: true)
        defer { fixture.tearDown() }
        try await fixture.db.config.setTranscriptStreamingEnabled(true)
        let supervisor = RoutingRecorder()
        fixture.router.modelProxySupervisor = supervisor

        let terminal = try await fixture.terminalCreate(
            TerminalCreateParams(worktreeID: fixture.worktree.id, type: .claude))

        let row = try #require(try await fixture.db.terminals.get(id: terminal.id))
        #expect(row.transport == .holder)
        #expect(row.holderPID != nil)
        #expect(row.childPID != nil)
        #expect(row.kind == .claude)
        let routed = supervisor.made
        #expect(routed.map(\.terminalID) == [row.id])
        #expect(routed.first?.streamingEnabled == true)
        #expect(supervisor.retired.isEmpty, "the route was retired under a spawn that succeeded")
        let streamPath = try #require(row.transcriptStreamPath)
        #expect(streamPath == TBDConstants.streamFilePath(
            terminalID: row.id, environment: fixture.environment))
    }

    /// A Codex extra terminal takes the holder too, as the primary path's
    /// Codex branch does. The executable is a stub path: the job is the pinned
    /// gate shell, which ignores its argv.
    @Test func terminalCreateFlagOnSpawnsACodexTerminalOntoTheHolder() async throws {
        let fixture = try await GateFixture.make(flagEnabled: true)
        defer { fixture.tearDown() }

        let terminal = try await fixture.terminalCreate(
            TerminalCreateParams(worktreeID: fixture.worktree.id, type: .codex))

        let row = try #require(try await fixture.db.terminals.get(id: terminal.id))
        #expect(row.transport == .holder)
        #expect(row.kind == .codex)
        #expect(row.label == TerminalLabel.codex)
        #expect(row.holderPID != nil)
        #expect(row.childPID != nil)
        #expect(row.transcriptStreamPath == nil, "Codex was routed through the model proxy")
        #expect(row.tmuxWindowID.isEmpty)
    }

    /// `terminal.continueInCodex` spawns through the same function, so the
    /// resumed Codex terminal is born onto the holder with the flag on.
    @Test func continueInCodexFlagOnSpawnsOntoTheHolder() async throws {
        let fixture = try await GateFixture.make(flagEnabled: true)
        defer { fixture.tearDown() }
        let source = try await fixture.seedClaudeSourceTerminal()

        let terminalID = try await fixture.continueInCodex(terminalID: source.id)

        let row = try #require(try await fixture.db.terminals.get(id: terminalID))
        #expect(row.transport == .holder)
        #expect(row.kind == .codex)
        #expect(row.holderPID != nil)
        #expect(row.childPID != nil)
        #expect(row.tmuxWindowID.isEmpty)
        // The source is preserved, as it always was.
        #expect(try await fixture.db.terminals.get(id: source.id) != nil)
    }

    // MARK: - The read

    /// `terminal.output` on a holder row renders the daemon's emulator, and
    /// `capture-pane` is never reached.
    ///
    /// The negative half is asserted two ways on purpose. The call counter
    /// catches a handler that captured a pane and threw the result away; the
    /// poisoned capture text catches one that captured a pane and *returned*
    /// it, which a counter alone would report as a pass if the count assertion
    /// were ever relaxed.
    @Test func terminalOutputReadsTheHolderEmulator() async throws {
        let fixture = try await GateFixture.make(flagEnabled: true)
        defer { fixture.tearDown() }

        let created = try await fixture.spawnPrimaryTerminals()
        let terminalID = created[0].id

        let output = try await pollUntil("the job's output to reach the daemon's emulator") {
            let text = try await fixture.terminalOutput(terminalID: terminalID)
            return text.contains("GATE-OK")
        }
        let rendered = try await fixture.terminalOutput(terminalID: terminalID)
        #expect(output, "rendered: \(rendered.debugDescription)")
        #expect(!rendered.contains(GateFixture.poisonedPaneText))
        #expect(
            fixture.capturePaneCalls() == 0,
            "terminal.output shelled out to tmux capture-pane for a holder session")
    }

    /// A tmux row still reads through `capture-pane`.
    ///
    /// The branch's other arm: without this, a read that always rendered the
    /// emulator (or always answered "no reader") would pass every assertion
    /// above.
    @Test func terminalOutputStillCapturesPanesForTmuxSessions() async throws {
        let fixture = try await GateFixture.make(flagEnabled: false)
        defer { fixture.tearDown() }

        let created = try await fixture.spawnPrimaryTerminals()
        let rendered = try await fixture.terminalOutput(terminalID: created[0].id)

        #expect(rendered.contains(GateFixture.poisonedPaneText))
        #expect(fixture.capturePaneCalls() == 1)
    }

    // MARK: - The flag gates spawning, not servicing

    /// Flipping the flag off does not migrate a session that is already
    /// running.
    ///
    /// Its pty exists, its job is attached to it, and a preference cannot undo
    /// either. So the row must still read `.holder` and must still serve its
    /// screen — and a *new* session created afterwards must land on tmux, which
    /// is what proves the flip took effect at all rather than being ignored.
    @Test func flagFlipDoesNotMigrateRunningSessions() async throws {
        let fixture = try await GateFixture.make(flagEnabled: true)
        defer { fixture.tearDown() }

        let created = try await fixture.spawnPrimaryTerminals()
        let terminalID = created[0].id
        let served = try await pollUntil("the holder session's first output") {
            try await fixture.terminalOutput(terminalID: terminalID).contains("GATE-OK")
        }
        #expect(served)

        try await fixture.db.config.setPtyHolderEnabled(false)

        let afterFlip = try #require(try await fixture.db.terminals.get(id: terminalID))
        #expect(afterFlip.transport == .holder, "flipping the flag migrated a live session")
        #expect(afterFlip.holderPID != nil)
        let stillServed = try await fixture.terminalOutput(terminalID: terminalID)
        #expect(
            stillServed.contains("GATE-OK"),
            "a live holder session stopped serving output when the flag went off")
        #expect(fixture.capturePaneCalls() == 0)

        // And the flip is not a no-op: the next session lands on tmux.
        let second = try await fixture.spawnPrimaryTerminals()
        let secondPrimary = try #require(try await fixture.db.terminals.get(id: second[0].id))
        #expect(secondPrimary.transport == .tmux)
    }

    // MARK: - What the holder path deliberately does NOT do

    /// Session recapture is scheduled for a tmux primary and not for a holder
    /// one.
    ///
    /// Recapture reads a tmux pane's process, and a holder row's `paneID` is
    /// empty by construction, so scheduling it there polls a coordinate that
    /// can never resolve — and, worse, would then write whatever it *did* find
    /// onto the holder row.
    ///
    /// **Both arms run in one test, in this order, and that is the whole
    /// instrument.** The negative alone would pass just as well against a
    /// recapture that never fires for anybody. The holder session is created
    /// first, and the probe's clock is immediate, so a recapture armed for it
    /// would have recorded its pane before the tmux control's did; observing
    /// the control's write is therefore proof that the holder's absence is real
    /// and not merely early. The target list is asserted whole rather than
    /// searched, so a recapture armed for the holder session alongside the tmux
    /// one still fails — whichever coordinate it was given.
    @Test func recaptureIsScheduledForTmuxSessionsAndNotForHolderOnes() async throws {
        let recapture = RecaptureProbe()
        let fixture = try await GateFixture.make(flagEnabled: true, recapture: recapture)
        defer { fixture.tearDown() }

        let holderCreated = try await fixture.spawnClaudePrimaryTerminals(
            carryover: ConversationCarryover(
                sourceSessionID: "HOLDER-SOURCE", notesSeed: "# carried\n"))
        let holderID = holderCreated[0].id
        let holderRow = try #require(try await fixture.db.terminals.get(id: holderID))
        #expect(holderRow.transport == .holder)
        #expect(holderRow.tmuxPaneID.isEmpty)

        try await fixture.db.config.setPtyHolderEnabled(false)
        let tmuxCreated = try await fixture.spawnClaudePrimaryTerminals(
            carryover: ConversationCarryover(
                sourceSessionID: "TMUX-SOURCE", notesSeed: "# carried\n"))
        let tmuxID = tmuxCreated[0].id
        let tmuxRow = try #require(try await fixture.db.terminals.get(id: tmuxID))
        #expect(tmuxRow.transport == .tmux)

        // The control. Its scheduler runs on virtual time, so this waits only
        // for the recapture task to be *scheduled*, not for a delay to elapse.
        // The deadline is a hang-catcher sized against the fast parallel pass,
        // where a runnable task can sit behind thousands of others — the
        // suite's 20 s default timed out on a box at load average 30 with the
        // capture never having run. It costs a passing run nothing.
        let landed = try await pollUntil(
            "the tmux session's recapture to write", timeout: 90
        ) {
            try await fixture.db.terminals.get(id: tmuxID)?.claudeSessionID
                == RecaptureProbe.detectedSessionID
        }
        #expect(landed)
        #expect(recapture.targets == [
            .tmuxPane(server: fixture.worktree.tmuxServer, paneID: tmuxRow.tmuxPaneID)
        ])

        let holderAfter = try #require(try await fixture.db.terminals.get(id: holderID))
        #expect(
            holderAfter.claudeSessionID == "HOLDER-SOURCE",
            """
            recapture ran against a holder session and overwrote its session ID \
            with \(holderAfter.claudeSessionID ?? "nil")
            """)
    }

    /// Archived-session restores follow the primary's transport.
    ///
    /// The restore decides through the same gate and spawns through the same
    /// function as every other tab, so under a holder primary the restored row
    /// is a holder row too — and, critically, NO tmux server is started for it.
    /// The `new-session` assertion is the one that would catch a restore that
    /// still asked for a server it no longer needs: the row would look right
    /// and a tmux server would be running behind it.
    @Test func archivedSessionRestoresFollowTheHolderPrimary() async throws {
        let fixture = try await GateFixture.make(flagEnabled: true)
        defer { fixture.tearDown() }

        let created = try await fixture.spawnClaudePrimaryTerminals(
            archivedClaudeSessions: ["ARCHIVED-PRIMARY", "ARCHIVED-RESTORED"])

        let primary = try #require(try await fixture.db.terminals.get(id: created[0].id))
        #expect(primary.transport == .holder, "the primary did not take the holder path")
        #expect(primary.claudeSessionID == "ARCHIVED-PRIMARY")

        let restored = try #require(
            try await fixture.db.terminals.list(worktreeID: fixture.worktree.id)
                .first { $0.claudeSessionID == "ARCHIVED-RESTORED" },
            "the second archived session was never restored")
        #expect(
            restored.transport == .holder,
            "an archived-session restore was left on tmux under a holder primary")
        let holderPID = try #require(restored.holderPID)
        let childPID = try #require(restored.childPID)
        #expect(holderPID != childPID)
        #expect(holderProcessIsAlive(holderPID))
        #expect(holderProcessIsAlive(childPID))
        #expect(restored.tmuxWindowID.isEmpty)
        #expect(restored.tmuxPaneID.isEmpty)

        let issued = fixture.tmuxCommands()
        #expect(
            !issued.contains(where: { $0.contains("new-session") }),
            "the restore started a tmux server it does not need: \(issued)")
        #expect(
            !issued.contains(where: { $0.contains("new-window") }),
            "the restore created a tmux window: \(issued)")
    }

    /// The other arm: with the flag off a restore is a tmux window, resuming
    /// the session it was archived with. Without this, a restore that always
    /// took the holder — or never restored at all — would pass above.
    @Test func archivedSessionRestoresStayOnTmuxWithTheFlagOff() async throws {
        let fixture = try await GateFixture.make(flagEnabled: false)
        defer { fixture.tearDown() }

        _ = try await fixture.spawnClaudePrimaryTerminals(
            archivedClaudeSessions: ["ARCHIVED-PRIMARY", "ARCHIVED-RESTORED"])

        let restored = try #require(
            try await fixture.db.terminals.list(worktreeID: fixture.worktree.id)
                .first { $0.claudeSessionID == "ARCHIVED-RESTORED" },
            "the second archived session was never restored")
        #expect(restored.transport == .tmux)
        #expect(!restored.tmuxWindowID.isEmpty)
        #expect(restored.holderPID == nil)
        #expect(restored.childPID == nil)

        let issued = fixture.tmuxCommands()
        #expect(
            issued.contains(where: { $0.contains("new-session") }),
            "the restore ran without a tmux server: \(issued)")
        #expect(
            issued.contains(where: {
                $0.contains("new-window") && $0.contains("--resume ARCHIVED-RESTORED")
            }),
            "no tmux window was created to resume the archived session: \(issued)")
    }

    // MARK: - Revive from history

    /// `terminalHistory.revive` with the flag on: the revived tab is born onto
    /// a real holder, with no tmux server anywhere behind it.
    @Test func historyReviveFlagOnSpawnsOntoTheHolder() async throws {
        let fixture = try await GateFixture.make(flagEnabled: true)
        defer { fixture.tearDown() }
        let entryID = try await fixture.seedClosedShellHistoryEntry()

        let revived = try await fixture.historyRevive(entryID: entryID)

        let row = try #require(try await fixture.db.terminals.get(id: revived.id))
        #expect(row.transport == .holder)
        let holderPID = try #require(row.holderPID)
        let childPID = try #require(row.childPID)
        #expect(holderPID != childPID)
        #expect(holderProcessIsAlive(holderPID))
        #expect(holderProcessIsAlive(childPID))
        #expect(row.tmuxWindowID.isEmpty)
        #expect(row.tmuxPaneID.isEmpty)

        let socketPath = try HolderRendezvous.socketPath(
            sessionID: row.id, environment: fixture.environment)
        #expect(
            FileManager.default.fileExists(atPath: socketPath),
            "no holder rendezvous at \(socketPath) for a revived holder tab")

        let issued = fixture.tmuxCommands()
        #expect(
            !issued.contains(where: { $0.contains("new-window") }),
            "the revive created a tmux window: \(issued)")
        #expect(
            !issued.contains(where: { $0.contains("new-session") }),
            "the revive started a tmux server: \(issued)")
    }

    /// The other arm, unchanged: a revive with the flag off is a tmux window
    /// in a tmux server.
    @Test func historyReviveFlagOffStaysOnTmux() async throws {
        let fixture = try await GateFixture.make(flagEnabled: false)
        defer { fixture.tearDown() }
        let entryID = try await fixture.seedClosedShellHistoryEntry()

        let revived = try await fixture.historyRevive(entryID: entryID)

        let row = try #require(try await fixture.db.terminals.get(id: revived.id))
        #expect(row.transport == .tmux)
        #expect(!row.tmuxWindowID.isEmpty)
        #expect(row.holderPID == nil)
        #expect(row.childPID == nil)
        let socketPath = try HolderRendezvous.socketPath(
            sessionID: row.id, environment: fixture.environment)
        #expect(
            !FileManager.default.fileExists(atPath: socketPath),
            "a holder rendezvous was created for a tmux-transport revive")
    }

    // MARK: - Fork-session swap

    /// A `.fork` swap with the flag on lands on a real holder, and its session
    /// recapture addresses the holder's CHILD rather than a pane.
    ///
    /// The target assertion is the load-bearing half. A holder row's pane id is
    /// the empty string by construction, so a fork that kept scheduling
    /// `.tmuxPane` would poll a coordinate that can never resolve — and would
    /// write whatever it happened to find onto the row.
    @Test func forkSwapFlagOnSpawnsOntoTheHolderAndRecapturesItsChild() async throws {
        let recapture = RecaptureProbe()
        let fixture = try await GateFixture.make(flagEnabled: true, recapture: recapture)
        defer { fixture.tearDown() }
        let source = try await fixture.seedClaudeSourceTerminal()

        let response = try await fixture.forkSwap(terminalID: source.id)
        #expect(response.success, "\(response.error ?? "")")

        let forked = try #require(
            try await fixture.db.terminals.list(worktreeID: fixture.worktree.id)
                .first { $0.id != source.id },
            "the fork created no new terminal row")
        #expect(forked.transport == .holder)
        let holderPID = try #require(forked.holderPID)
        let childPID = try #require(forked.childPID)
        #expect(holderPID != childPID)
        #expect(holderProcessIsAlive(holderPID))
        #expect(holderProcessIsAlive(childPID))
        #expect(forked.tmuxWindowID.isEmpty)

        // Through the one bounded poll the suite keeps (`Tests/CLAUDE.md`
        // rule 5), and reported the one way a CI summary preserves: a timeout
        // carries its own description on the primary failure line, while a
        // harness cancellation says nothing at all — attribution for that
        // belongs to whatever did the cancelling.
        let landed = await pollUntilTrue(timeout: TestDeadlines.saturatedPass) {
            !recapture.targets.isEmpty
        }
        if landed == .timedOut {
            Issue.record(BoundedWaitTimeout(
                what: "the fork's session recapture to be scheduled",
                observed: "\(recapture.targets)",
                deadline: TestDeadlines.saturatedPass))
        }
        #expect(recapture.targets == [.holderChild(pid: childPID)])
        #expect(recapture.panes.isEmpty, "a holder fork scheduled a pane recapture")

        // The source tab is untouched — a fork copies, it does not move.
        #expect(try await fixture.db.terminals.get(id: source.id) != nil)
    }

    // MARK: - Hook tabs

    /// The pre-session hook tab is born onto the holder with the flag on, and
    /// the descriptor phase 3 carries records the pids it will need.
    @Test func preSessionHookTabSpawnsOntoTheHolder() async throws {
        let fixture = try await GateFixture.make(flagEnabled: true)
        defer { fixture.tearDown() }
        try fixture.installWorktreeHook(.preSession)

        let spawn = try #require(try await fixture.spawnPreSessionTerminal())

        #expect(spawn.transport == .holder)
        let holderPID = try #require(spawn.holderPID)
        let childPID = try #require(spawn.childPID)
        #expect(holderPID != childPID)
        #expect(holderProcessIsAlive(holderPID))
        #expect(holderProcessIsAlive(childPID))
        #expect(spawn.windowID.isEmpty)
        #expect(spawn.paneID.isEmpty)

        let row = try #require(try await fixture.db.terminals.get(id: spawn.terminalID))
        #expect(row.transport == .holder)
        #expect(row.label == TerminalLabel.preSession)

        let issued = fixture.tmuxCommands()
        #expect(
            !issued.contains(where: { $0.contains("new-session") }),
            "the pre-session hook tab started a tmux server: \(issued)")
        #expect(
            !issued.contains(where: { $0.contains("new-window") }),
            "the pre-session hook tab created a tmux window: \(issued)")
    }

    /// With a setup hook installed, the setup tab is a holder row beside the
    /// primary — still no tmux server, and two holders rather than one.
    ///
    /// The hook-less case is `flagOnSpawnsOntoHolder`'s `created.count == 1`:
    /// without a hook the tab is a bare shell and a second holder process
    /// nobody asked for.
    @Test func setupHookTabFollowsTheHolderPrimary() async throws {
        let fixture = try await GateFixture.make(flagEnabled: true)
        defer { fixture.tearDown() }
        try fixture.installWorktreeHook(.setup)

        let created = try await fixture.spawnPrimaryTerminals()

        #expect(created.count == 2)
        #expect(created[1].label == TerminalLabel.setup)
        let setup = try #require(try await fixture.db.terminals.get(id: created[1].id))
        #expect(setup.transport == .holder)
        let holderPID = try #require(setup.holderPID)
        let childPID = try #require(setup.childPID)
        #expect(holderPID != childPID)
        #expect(holderProcessIsAlive(holderPID))
        #expect(holderProcessIsAlive(childPID))
        #expect(setup.tmuxWindowID.isEmpty)

        let primary = try #require(try await fixture.db.terminals.get(id: created[0].id))
        #expect(primary.transport == .holder)
        #expect(primary.holderPID != setup.holderPID, "both tabs share one holder")

        let issued = fixture.tmuxCommands()
        #expect(
            !issued.contains(where: { $0.contains("new-session") }),
            "the setup hook tab started a tmux server: \(issued)")
        #expect(
            !issued.contains(where: { $0.contains("new-window") }),
            "the setup hook tab created a tmux window: \(issued)")
    }

    /// Setup auto-close on the holder: the tab closes, and closing it reclaims
    /// the holder instead of addressing a tmux window that never existed.
    ///
    /// Three facts, and the two after the row are what a row assertion alone
    /// would miss. `remain-on-exit` must never be issued: it is a tmux
    /// property, and the reason for setting it — keep the dead pane so the
    /// teardown can capture its scrollback — has no holder counterpart, because
    /// a holder teardown captures nothing. Then the job must be dead and the
    /// rendezvous socket gone, which together say `closeHookTerminal` reached
    /// `disposeHolder`: a teardown that deleted the row through the tmux arm
    /// would satisfy every assertion about the row while leaving a holder, a
    /// job and a socket that nothing names any more.
    ///
    /// The other arm of that same `remain-on-exit` decision is
    /// `AutoCloseSetupTests.flagOnCleanExitClosesSetupTab`, which asserts the
    /// property is set exactly once and targets the setup window.
    @Test func setupAutoCloseOnTheHolderClosesTheTabAndReclaimsItsHolder() async throws {
        let fixture = try await GateFixture.make(flagEnabled: true)
        defer { fixture.tearDown() }
        try await fixture.db.config.setAutoCloseSetup(enabled: true)
        try fixture.installWorktreeHook(.setup)

        let created = try await fixture.spawnPrimaryTerminals()

        #expect(created.count == 2)
        #expect(created[1].label == TerminalLabel.setup)
        let setup = try #require(try await fixture.db.terminals.get(id: created[1].id))
        #expect(setup.transport == .holder)
        let holderPID = try #require(setup.holderPID)
        let childPID = try #require(setup.childPID)
        // This test deletes the row teardown would otherwise sweep from, so the
        // pids are handed over the moment they are read.
        fixture.rememberHolder(holderPID: holderPID, childPID: childPID)
        #expect(holderPID != childPID)
        #expect(holderProcessIsAlive(holderPID))
        #expect(holderProcessIsAlive(childPID))

        let socketPath = try HolderRendezvous.socketPath(
            sessionID: setup.id, environment: fixture.environment)
        #expect(
            FileManager.default.fileExists(atPath: socketPath),
            "no holder rendezvous at \(socketPath) for an auto-closing setup tab")

        let issued = fixture.tmuxCommands()
        #expect(
            !issued.contains(where: { $0.contains("remain-on-exit") }),
            "the holder setup tab asked tmux to keep a pane it never had: \(issued)")
        #expect(
            !issued.contains(where: { $0.contains("new-window") }),
            "the auto-closing setup tab created a tmux window: \(issued)")
        #expect(
            !issued.contains(where: { $0.contains("new-session") }),
            "the auto-closing setup tab started a tmux server: \(issued)")

        // Stand in for the hook's clean exit: the job is the pinned gate shell,
        // which ignores the wrapper's argv, so the marker never lands on its
        // own. The spawn deleted any stale one, so this goes after it.
        try fixture.writeHookMarker(
            at: WorktreeLifecycle.setupMarkerPath(worktreeID: fixture.worktree.id),
            exitCode: 0)

        let closed = await pollUntilTrue(timeout: TestDeadlines.saturatedPass) {
            // A read that throws is not a deletion — only a row that is
            // genuinely absent ends this wait.
            do {
                return try await fixture.db.terminals.get(id: setup.id) == nil
            } catch {
                return false
            }
        }
        if closed == .timedOut {
            Issue.record(BoundedWaitTimeout(
                what: "the auto-closed setup tab's row to be deleted",
                observed: nil, deadline: TestDeadlines.saturatedPass))
        }
        let jobGone = await pollUntilTrue(timeout: TestDeadlines.saturatedPass) {
            !holderProcessIsAlive(childPID)
        }
        if jobGone == .timedOut {
            Issue.record(BoundedWaitTimeout(
                what: "the setup tab's job (pid \(childPID)) to be killed",
                observed: nil, deadline: TestDeadlines.saturatedPass))
        }
        let socketGone = await pollUntilTrue(timeout: TestDeadlines.saturatedPass) {
            !FileManager.default.fileExists(atPath: socketPath)
        }
        if socketGone == .timedOut {
            Issue.record(BoundedWaitTimeout(
                what: "the setup holder's rendezvous socket at \(socketPath) to go",
                observed: nil, deadline: TestDeadlines.saturatedPass))
        }
    }

    /// A holder-backed pre-session tab is reclaimed when the worktree row
    /// vanishes mid-wait.
    ///
    /// The cascade is what makes this the hard case: it takes the terminal row
    /// with it, so the wait returns at once AND `disposeHolder` — which reads
    /// the pids off a row — has nothing to read. The descriptor phase 2b
    /// returned is the only remaining route to that holder, and a dead job with
    /// a removed rendezvous socket is the proof it was taken. No `kill-window`,
    /// because a holder row's window id names nothing.
    @Test func phase3ReclaimsAHolderHookTabWhenTheWorktreeRowVanishes() async throws {
        let fixture = try await GateFixture.make(flagEnabled: true)
        defer { fixture.tearDown() }
        try fixture.installWorktreeHook(.preSession)

        let spawn = try #require(try await fixture.spawnPreSessionTerminal())
        #expect(spawn.transport == .holder)
        let childPID = try #require(spawn.childPID)
        // The cascade below takes the row teardown would otherwise sweep from.
        fixture.rememberHolder(holderPID: spawn.holderPID, childPID: childPID)
        #expect(holderProcessIsAlive(childPID))
        let socketPath = try HolderRendezvous.socketPath(
            sessionID: spawn.terminalID, environment: fixture.environment)
        #expect(FileManager.default.fileExists(atPath: socketPath))

        try await fixture.deleteWorktreeRow()
        await fixture.runPreSessionPhase3(spawn)

        let remaining = try await fixture.db.terminals.list(worktreeID: fixture.worktree.id)
        #expect(
            remaining.isEmpty,
            "phase 3 spawned terminals into a worktree that no longer exists")
        let issued = fixture.tmuxCommands()
        #expect(
            !issued.contains(where: { $0.contains("kill-window") }),
            "the holder hook tab was torn down through tmux: \(issued)")

        let jobGone = await pollUntilTrue(timeout: TestDeadlines.saturatedPass) {
            !holderProcessIsAlive(childPID)
        }
        if jobGone == .timedOut {
            Issue.record(BoundedWaitTimeout(
                what: "the hook tab's job (pid \(childPID)) to be killed",
                observed: nil, deadline: TestDeadlines.saturatedPass))
        }
        let socketGone = await pollUntilTrue(timeout: TestDeadlines.saturatedPass) {
            !FileManager.default.fileExists(atPath: socketPath)
        }
        if socketGone == .timedOut {
            Issue.record(BoundedWaitTimeout(
                what: "the hook holder's rendezvous socket at \(socketPath) to go",
                observed: nil, deadline: TestDeadlines.saturatedPass))
        }
    }

    /// The setup tab's other arm: with the flag off it is a tmux window, hook
    /// or no hook, exactly as it always has been.
    @Test func setupHookTabStaysOnTmuxWithTheFlagOff() async throws {
        let fixture = try await GateFixture.make(flagEnabled: false)
        defer { fixture.tearDown() }
        try fixture.installWorktreeHook(.setup)

        let created = try await fixture.spawnPrimaryTerminals()

        #expect(created.count == 2)
        let setup = try #require(try await fixture.db.terminals.get(id: created[1].id))
        #expect(setup.transport == .tmux)
        #expect(!setup.tmuxWindowID.isEmpty)
        #expect(setup.holderPID == nil)
    }
}

// MARK: - Recapture probe

/// The scheduler the create path is given in place of the real one, and the
/// record of every pane it was asked about.
///
/// Two things it deliberately does not do. It never reaches
/// `ClaudeStateDetector`, which would read a session file at a **process-wide**
/// path (`$TBD_CLAUDE_HOST_HOME/sessions/<pane pid>.json`, and a dry-run pane
/// PID is always `0`) — a file every other create-path suite's recapture would
/// read too, which is a cross-suite coupling, not a fixture. And it runs on
/// `ImmediateClock`, so the branch is asserted without waiting out the
/// production five seconds.
private final class RecaptureProbe: @unchecked Sendable {
    static let detectedSessionID = "RECAPTURED-BY-THE-PROBE"

    private let lock = NSLock()
    private var recorded: [SessionRecaptureTarget] = []

    /// Every target recapture was scheduled against, in order.
    var targets: [SessionRecaptureTarget] {
        lock.withLock { recorded }
    }

    /// The panes recapture was scheduled against, in order — the tmux targets
    /// only, so an assertion about panes keeps meaning what it always did.
    var panes: [String] {
        targets.compactMap {
            if case .tmuxPane(_, let paneID) = $0 { return paneID }
            return nil
        }
    }

    func scheduler(db: TBDDatabase, tmux: TmuxManager) -> SessionRecaptureScheduler {
        SessionRecaptureScheduler(
            db: db,
            tmux: tmux,
            // `withLock` rather than `lock()`/`unlock()`: this closure is
            // `async`, where the unscoped pair is unavailable.
            captureSessionID: { [self] target in
                lock.withLock { recorded.append(target) }
                return Self.detectedSessionID
            },
            clock: ImmediateClock())
    }
}

// MARK: - A routing recorder

/// A `ModelProxySupervisor` stand-in for the routed extra-terminal case: it
/// records the routes it was asked to mint and drops, and names a port so the
/// attachment produces a base URL. No proxy process is started — the job is the
/// gate shell, and nothing here connects to the URL.
private final class RoutingRecorder: ModelProxySupervising, @unchecked Sendable {
    struct Made: Sendable, Equatable {
        let terminalID: UUID
        let upstream: String
        let streamingEnabled: Bool
    }

    private let lock = NSLock()
    private var madeStorage: [Made] = []
    private var retiredStorage: [String] = []
    let token = "0123456789abcdef0123456789abcdef"

    var made: [Made] {
        lock.lock(); defer { lock.unlock() }
        return madeStorage
    }

    var retired: [String] {
        lock.lock(); defer { lock.unlock() }
        return retiredStorage
    }

    func makeRoute(
        terminalID: UUID, upstream: String, streamingEnabled: Bool
    ) async throws -> ModelProxyRoute {
        // `withLock` rather than `lock()`/`unlock()`: this method is `async`,
        // where the unscoped pair is unavailable.
        lock.withLock {
            madeStorage.append(Made(
                terminalID: terminalID, upstream: upstream, streamingEnabled: streamingEnabled))
        }
        return ModelProxyRoute(
            token: token, terminalID: terminalID,
            upstream: upstream, streamingEnabled: streamingEnabled)
    }

    func baseURL(for route: ModelProxyRoute) async -> String? {
        "http://127.0.0.1:51842/r/\(route.token)"
    }

    func retireRoute(token: String, terminalID: UUID) async {
        lock.withLock { retiredStorage.append(token) }
    }

    func routeToken(forTerminal terminalID: UUID) async -> String? { nil }
    func capabilitySnapshot() async -> ModelProxyCapabilitySnapshot { .none }
    func startIfEnabled() async {}
    func beginDraining() async {}
}

// MARK: - Fixture

/// A worktree, a database, a router and a registry, wired the way the daemon
/// wires them — one registry shared by the spawn path and the read path.
///
/// Three rules it exists to enforce:
///
///   1. **Nothing reaches the developer's `~/tbd`.** Every rendezvous path is
///      derived from an explicit environment dictionary.
///   2. **Nothing runs the developer's shell, or a real agent.** The pinned
///      `SHELL` in that same dictionary is a two-line script.
///   3. **Every holder and every job is killed in teardown.** Holder death is
///      not child death, so both are named.
private final class GateFixture {
    /// What a dry-run `capture-pane` answers. Deliberately a string no holder
    /// emulator could produce, so a read that went through tmux is visible in
    /// the returned text and not only in a counter.
    static let poisonedPaneText = "TMUX-CAPTURE-PANE-WAS-CALLED"

    let db: TBDDatabase
    let router: RPCRouter
    let registry: HolderRegistry
    let environment: [String: String]
    let worktree: Worktree
    let repo: Repo
    private let home: String
    private let tempDir: URL
    private let capturePaneCounter: Counter
    private let recordedCommands: CommandLog
    private var torndown = false
    private let rememberedLock = NSLock()
    private var remembered: [(holderPID: Int32?, childPID: Int32?)] = []

    /// A thread-safe tally. The dry-run hooks are `@Sendable` closures called
    /// from whatever executor the handler happens to be on.
    final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var value = 0
        func increment() {
            lock.lock(); defer { lock.unlock() }
            value += 1
        }
        var count: Int {
            lock.lock(); defer { lock.unlock() }
            return value
        }
    }

    final class CommandLog: @unchecked Sendable {
        private let lock = NSLock()
        private var entries: [String] = []
        func append(_ argv: [String]) {
            lock.lock(); defer { lock.unlock() }
            entries.append(argv.joined(separator: " "))
        }
        var all: [String] {
            lock.lock(); defer { lock.unlock() }
            return entries
        }
    }

    /// A short scratch root under the run root `scripts/test.sh` reclaims: the
    /// rendezvous socket lives under it and `sun_path` is 104 bytes, so a
    /// deeper root fails the bind rather than the assertion — and a root
    /// outside the run's scratch dir survives a killed test process forever.
    /// See `fencedScratchRoot(prefix:)`.
    private static func scratchHome() -> String {
        fencedScratchRoot(prefix: "tbdg10")
    }

    /// The stand-in login shell. It ignores the `-i -l -c <command>` argv the
    /// production composition hands it, which is the point: the job is a
    /// controlled two-line program instead of whatever the developer's `$SHELL`
    /// would have done with it.
    ///
    /// It sleeps far longer than any wait in this suite deliberately. The
    /// teardown tests wait for this job to *die*, and a sleep that could expire
    /// inside one of those windows would let a teardown that reclaimed nothing
    /// pass on the job's natural exit. Every holder started here is killed by
    /// `tearDown`, so the length costs a run nothing.
    ///
    /// The sleep is deliberately **not** `exec`ed. A hook tab's teardown
    /// identity-checks the job before signalling it
    /// (`HolderRegistry.abandonVerifiedJob`), and that check accepts only an
    /// agent binary or a login shell — so a job that replaced its own image
    /// with `sleep` would be refused as a stranger and the teardown tests would
    /// prove the refusal rather than the kill. Left un-`exec`ed, the job's
    /// command line is `/bin/sh <path> …` courtesy of the shebang, whose
    /// basename `sh` is one the check admits; the shell is the pty session's
    /// leader, so the group-widening `SIGKILL` takes the `sleep` with it.
    private static func writeGateShell(in home: String) throws -> String {
        try FileManager.default.createDirectory(
            atPath: home, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        let path = "\(home)/gate-shell"
        try """
        #!/bin/sh
        printf 'GATE-OK\\n'
        sleep 600
        """.write(toFile: path, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o700], ofItemAtPath: path)
        return path
    }

    /// - Parameter spawnerAvailable: whether the registry is given a
    ///   `HolderSpawner`. `false` is the shape a daemon has when no `TBDHolder`
    ///   binary sits beside it: `Daemon.swift` still builds the registry, so
    ///   the gate sees a non-nil one that cannot start anything.
    static func make(
        flagEnabled: Bool,
        spawnerAvailable: Bool = true,
        recapture: RecaptureProbe? = nil
    ) async throws -> GateFixture {
        let home = scratchHome()
        let shell = try writeGateShell(in: home)
        let environment = [
            "TBD_HOME": home,
            "PATH": "/usr/bin:/bin",
            "SHELL": shell,
        ]

        let capturePaneCounter = Counter()
        let recordedCommands = CommandLog()
        let tmux = TmuxManager(
            dryRun: true,
            dryRunRecorder: { argv in recordedCommands.append(argv) },
            dryRunCapturePane: { _, _ in
                capturePaneCounter.increment()
                return poisonedPaneText
            })

        let db = try TBDDatabase(inMemory: true)
        try await db.config.setPtyHolderEnabled(flagEnabled)

        let spawner: HolderSpawner?
        if spawnerAvailable {
            let executable = try #require(
                HolderProcessFixture.locateExecutable(),
                "TBDHolder must be built beside the test bundle")
            spawner = HolderSpawner(executableURL: executable)
        } else {
            spawner = nil
        }
        let registry = HolderRegistry(
            owner: HolderOwnerToken(rawValue: "acme-installation"),
            environment: environment,
            listTerminals: { [] },
            spawner: spawner)

        let (tempDir, repoDir) = try await createTestRepoResolvingSymlinks()
        let repo = try await db.repos.create(
            path: repoDir.path, displayName: "acme", defaultBranch: "main")
        let worktree = try await db.worktrees.createMain(
            repoID: repo.id, name: "main", branch: "main", path: repoDir.path,
            tmuxServer: TmuxManager.serverName(forRepoPath: repoDir.path))

        // The Claude spawn branches — the primary's and `terminal.create`'s —
        // seed folder trust and resolve a projects root through this manager.
        // Injected at the fixture's own scratch root so neither reaches the
        // developer's store — the seam `Tests/CLAUDE.md` names, rather than a
        // `setenv`. One instance for the lifecycle and the router, because the
        // router's Claude branch resolves through its own.
        let configDirManager = ClaudeProfileConfigDirManager(
            baseDirectory: URL(fileURLWithPath: home)
                .appendingPathComponent("profiles", isDirectory: true),
            hostBaseDirectory: URL(fileURLWithPath: home)
                .appendingPathComponent("claude", isDirectory: true))
        var lifecycle = WorktreeLifecycle(
            db: db, git: GitManager(), tmux: tmux, hooks: HookResolver(),
            configDirManager: configDirManager,
            // The hook-tab waits this fixture arms are polled, not slept
            // through: the setup auto-close watcher has to see a marker written
            // by the test (the job here is the pinned gate shell, which ignores
            // the wrapper's argv, so nothing writes one on its own). 0.05 keeps
            // that turnaround off the production half-second, and the timeout is
            // a hang bound rather than a budget anything is expected to use.
            preSessionTimeout: 30,
            preSessionPollInterval: 0.05)
        lifecycle.holderRegistry = registry
        if let recapture {
            lifecycle.sessionRecaptureFactory = { db, tmux in
                recapture.scheduler(db: db, tmux: tmux)
            }
        }
        let router = RPCRouter(
            db: db, lifecycle: lifecycle, tmux: tmux, startTime: Date(),
            configDirManager: configDirManager,
            actuationLog: makeTestActuationLog())
        router.holderRegistry = registry
        if let recapture {
            // The router builds its own scheduler for the swap paths, so the
            // probe has to be wired into both seams to observe a fork.
            router.sessionRecaptureFactory = { db, tmux in
                recapture.scheduler(db: db, tmux: tmux)
            }
        }
        // Codex is never launched here: the job is the pinned gate shell,
        // which ignores its argv. The stubs only have to satisfy the handlers'
        // pre-spawn resolution, so the Codex branches can reach the gate.
        router.codexExecutableResolver = { "/opt/test/bin/codex" }
        router.codexHomeEnsurer = {
            URL(fileURLWithPath: home).appendingPathComponent("codex-home", isDirectory: true)
        }
        router.codexProfileFlagResolver = { _ in "--profile" }
        router.codexSessionImport = { _, _, _, _, _ in "thread-gate-1" }

        return GateFixture(
            db: db, router: router, registry: registry, environment: environment,
            worktree: worktree, repo: repo, home: home, tempDir: tempDir,
            capturePaneCounter: capturePaneCounter, recordedCommands: recordedCommands)
    }

    private init(
        db: TBDDatabase, router: RPCRouter, registry: HolderRegistry,
        environment: [String: String], worktree: Worktree, repo: Repo,
        home: String, tempDir: URL,
        capturePaneCounter: Counter, recordedCommands: CommandLog
    ) {
        self.db = db
        self.router = router
        self.registry = registry
        self.environment = environment
        self.worktree = worktree
        self.repo = repo
        self.home = home
        self.tempDir = tempDir
        self.capturePaneCounter = capturePaneCounter
        self.recordedCommands = recordedCommands
    }

    /// The production spawn path, entered exactly as `worktree.create` enters
    /// it. `skipClaude` keeps the primary a plain shell so no agent binary is
    /// consulted; what it actually runs is the pinned `SHELL` above.
    func spawnPrimaryTerminals() async throws -> [(id: UUID, label: String)] {
        try await router.lifecycle.spawnPrimaryTerminals(
            worktree: worktree, repo: repo, skipClaude: true, preSessionTerminalID: nil)
    }

    /// The same production entry point, for the two callers that need the
    /// Claude branch: a conversation carryover (which is what schedules session
    /// recapture) and an archived-session restore.
    func spawnClaudePrimaryTerminals(
        archivedClaudeSessions: [String]? = nil,
        carryover: ConversationCarryover? = nil
    ) async throws -> [(id: UUID, label: String)] {
        try await router.lifecycle.spawnPrimaryTerminals(
            worktree: worktree, repo: repo, skipClaude: false,
            archivedClaudeSessions: archivedClaudeSessions,
            preSessionTerminalID: nil,
            carryover: carryover)
    }

    /// The `terminal.create` RPC, through the router, exactly as the app's
    /// "new terminal" and `tbd terminal create` reach it.
    func terminalCreate(_ params: TerminalCreateParams) async throws -> Terminal {
        let response = await router.handle(
            try RPCRequest(method: RPCMethod.terminalCreate, params: params))
        if let error = response.error {
            Issue.record("terminal.create failed: \(error)")
        }
        return try response.decodeResult(Terminal.self)
    }

    /// The `terminal.continueInCodex` RPC, through the router. Returns the
    /// resumed Codex terminal's id.
    func continueInCodex(terminalID: UUID) async throws -> UUID {
        let response = await router.handle(
            try RPCRequest(
                method: RPCMethod.terminalContinueInCodex,
                params: TerminalContinueInCodexParams(terminalID: terminalID)))
        if let error = response.error {
            Issue.record("terminal.continueInCodex failed: \(error)")
        }
        return try response.decodeResult(TerminalContinueInCodexResult.self).terminalID
    }

    /// A Claude terminal row with a transcript on disk — what
    /// `terminal.continueInCodex` imports from. Written directly rather than
    /// spawned, because only the row and the file are read.
    func seedClaudeSourceTerminal() async throws -> Terminal {
        let transcript = "\(home)/source.jsonl"
        try #"{"type":"user","message":{"content":"continue this"}}"#
            .write(toFile: transcript, atomically: true, encoding: .utf8)
        let source = try await db.terminals.create(
            worktreeID: worktree.id,
            tmuxWindowID: "@source",
            tmuxPaneID: "%source",
            label: TerminalLabel.claudeCode,
            claudeSessionID: "claude-session",
            kind: .claude)
        try await db.terminals.updateSession(
            id: source.id, sessionID: "claude-session", transcriptPath: transcript)
        return try #require(try await db.terminals.get(id: source.id))
    }

    /// The `terminal.output` RPC, through the router's real handler.
    func terminalOutput(terminalID: UUID, lines: Int? = nil) async throws -> String {
        let params = try JSONEncoder().encode(
            TerminalOutputParams(terminalID: terminalID, lines: lines))
        let response = try await router.handleTerminalOutput(params)
        if let error = response.error {
            Issue.record("terminal.output failed: \(error)")
            return ""
        }
        let result = try #require(response.result)
        return try JSONDecoder()
            .decode(TerminalOutputResult.self, from: Data(result.utf8)).output
    }

    func capturePaneCalls() -> Int { capturePaneCounter.count }
    func tmuxCommands() -> [String] { recordedCommands.all }

    /// Installs an executable `.worktree-hooks/<event>` in the worktree's
    /// checkout. `HookResolver` only looks at the filesystem, and this fixture's
    /// worktree path IS the repo checkout, so no commit is needed.
    ///
    /// The script itself never runs the hook tab's *program* — the job is the
    /// pinned gate shell, which ignores its argv — so what this installs is the
    /// fact that a hook RESOLVES, which is what both hook-tab decisions read.
    @discardableResult
    func installWorktreeHook(_ event: HookEvent) throws -> String {
        let dir = URL(fileURLWithPath: worktree.localPath)
            .appendingPathComponent(".worktree-hooks", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let path = dir.appendingPathComponent(event.rawValue).path
        try "#!/bin/sh\nexit 0\n".write(toFile: path, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755], ofItemAtPath: path)
        return path
    }

    /// The production pre-session spawn, entered exactly as worktree creation
    /// enters it.
    func spawnPreSessionTerminal() async throws -> PreSessionSpawn? {
        try await router.lifecycle.spawnPreSessionTerminal(
            worktree: worktree, repo: repo, worktreePath: worktree.localPath)
    }

    /// Phase 3 of the create path, entered with the descriptor phase 2b
    /// returned — the marker wait, then the primary spawn or the bail-out.
    func runPreSessionPhase3(_ spawn: PreSessionSpawn) async {
        await router.lifecycle.runPreSessionPhase3(
            preSession: spawn,
            worktree: worktree, repo: repo,
            worktreePath: worktree.localPath,
            skipClaude: true,
            completionAction: .markActive)
    }

    /// Writes the completion marker a hook would have written.
    ///
    /// Standing in for the hook is not a shortcut here: the job every holder in
    /// this fixture runs is the pinned gate shell, which ignores the `-c`
    /// command it is handed, so the wrapper's marker never lands on its own.
    /// Both spawns delete a stale marker before starting, so this must be
    /// called only after the spawn has returned.
    func writeHookMarker(at path: String, exitCode: Int) throws {
        try FileManager.default.createDirectory(
            atPath: (path as NSString).deletingLastPathComponent,
            withIntermediateDirectories: true)
        try "\(exitCode)\n".write(toFile: path, atomically: true, encoding: .utf8)
    }

    /// Deletes the worktree row, cascading every terminal row with it — what a
    /// repo removal does to a worktree whose hook tab is still being waited on.
    func deleteWorktreeRow() async throws {
        try await db.worktrees.delete(id: worktree.id)
    }

    /// The `terminalHistory.revive` RPC, through the router.
    func historyRevive(entryID: UUID) async throws -> Terminal {
        let response = await router.handle(
            try RPCRequest(
                method: RPCMethod.terminalHistoryRevive,
                params: TerminalHistoryReviveParams(
                    worktreeID: worktree.id, id: entryID)))
        if let error = response.error {
            Issue.record("terminalHistory.revive failed: \(error)")
        }
        return try response.decodeResult(Terminal.self)
    }

    /// A closed SHELL terminal in this worktree's history, ready to revive.
    func seedClosedShellHistoryEntry() async throws -> UUID {
        let closed = Terminal(
            worktreeID: worktree.id, tmuxWindowID: "@closed", tmuxPaneID: "%closed",
            label: nil, kind: .shell)
        await db.terminalHistory.store(
            terminal: closed, text: "prior shell output\n", closedAt: Date())
        return closed.id
    }

    /// The `terminal.swapProfile` RPC in `.fork` mode, through the router.
    func forkSwap(terminalID: UUID) async throws -> RPCResponse {
        await router.handle(
            try RPCRequest(
                method: RPCMethod.terminalSwapProfile,
                params: TerminalSwapProfileParams(
                    terminalID: terminalID, newProfileID: nil, mode: .fork)))
    }

    /// Records a holder and its job so `tearDown` can reclaim them from
    /// something other than a terminal row.
    ///
    /// The row-derived sweep is the normal route, and it is enough for every
    /// test that leaves its rows in place. It is not enough for the teardown
    /// tests: they assert that a row was DELETED, so the very regression they
    /// exist to catch — a teardown that removed the row and reclaimed nothing —
    /// would leave the holder and its job running for the rest of the run with
    /// nothing left naming their pids. Call this as soon as the pids are read.
    func rememberHolder(holderPID: Int32?, childPID: Int32?) {
        rememberedLock.lock()
        defer { rememberedLock.unlock() }
        remembered.append((holderPID: holderPID, childPID: childPID))
    }

    /// Kills one holder and the job it forked. Signalling a pid that is already
    /// gone is how this is expected to end on the passing path: the process has
    /// been reaped, `kill` answers `ESRCH`, and nothing happens.
    ///
    /// The job is killed by **group** where it leads one, by the same rule
    /// `HolderRegistry.jobProcessGroup` applies: a `forkpty` job is the session
    /// leader of its own pty, so its group id is its own pid, and a group id
    /// that is anything else names a group this fixture did not create and must
    /// not signal. The gate shell runs its `sleep` as an ordinary child rather
    /// than `exec`ing it, so a pid-exact kill here would leave that child
    /// behind for the rest of its ten minutes.
    private func reclaim(holderPID: Int32?, childPID: Int32?) {
        if let holderPID, holderPID > 0 {
            kill(holderPID, SIGKILL)
            var ignored: Int32 = 0
            _ = waitpid(holderPID, &ignored, 0)
        }
        if let childPID, childPID > 1, holderProcessIsAlive(childPID) {
            if getpgid(childPID) == childPID { kill(-childPID, SIGKILL) }
            kill(childPID, SIGKILL)
        }
    }

    /// Kills every holder this fixture started AND every job those holders
    /// forked, then clears the scratch roots. A test that leaves either behind
    /// leaks a process for the rest of the run — bounded at the job's own
    /// `sleep`, but that is ten minutes and it compounds across runs.
    ///
    /// Two sources, because neither covers the other: the terminal rows name
    /// every holder still on the books, and `rememberHolder` names the ones
    /// whose rows a test deleted on purpose.
    func tearDown() {
        guard !torndown else { return }
        torndown = true

        let rows = (try? blockingTerminals()) ?? []
        for row in rows where row.transport == .holder {
            reclaim(holderPID: row.holderPID, childPID: row.childPID)
        }
        rememberedLock.lock()
        let recorded = remembered
        rememberedLock.unlock()
        for entry in recorded {
            reclaim(holderPID: entry.holderPID, childPID: entry.childPID)
        }
        let registry = self.registry
        Task.detached { await registry.releaseAll() }
        try? FileManager.default.removeItem(atPath: home)
        try? FileManager.default.removeItem(at: tempDir)
    }

    /// Reads the terminal rows from a non-async `tearDown`. Bounded, and a
    /// timeout simply means the sweep below has nothing to kill by pid — the
    /// suite would rather report that than hang.
    private func blockingTerminals() throws -> [Terminal] {
        let box = ResultBox()
        let done = DispatchSemaphore(value: 0)
        let db = self.db
        Task.detached {
            box.value = try? await db.terminals.list()
            done.signal()
        }
        _ = done.wait(timeout: .now() + 5)
        return box.value ?? []
    }

    private final class ResultBox: @unchecked Sendable {
        var value: [Terminal]?
    }
}
