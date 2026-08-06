import Clocks
import Foundation
import TestSupport
import Testing
@testable import TBDDaemonLib
@testable import TBDShared

/// Tier 2 — dry-run tmux, a real (temp-directory) actuation log, an in-memory
/// database, and a `TestClock` for the key pacing.
///
/// `terminal.send` grew a payload vocabulary (`--text` or `--keys`), a dispatch
/// envelope on every non-empty text payload, and an opt-in delivery
/// acknowledgement behind a default-off flag. These prove the composed bytes
/// that reach the pane, what the record stores about them, which shapes are
/// refused and on which side of the row, and that the observation is armed for
/// exactly one kind of send and never for any other.
@Suite("terminal.send payloads, envelope and verification", .clockDriven)
struct TerminalSendDispatchTests {

    // MARK: - Fixture

    /// Thread-safe collector for tmux argv lists invoked during dryRun.
    private final class ArgvRecorder: @unchecked Sendable {
        private let lock = NSLock()
        private var _calls: [[String]] = []
        var calls: [[String]] {
            lock.lock(); defer { lock.unlock() }
            return _calls
        }
        func record(_ args: [String]) {
            lock.lock(); defer { lock.unlock() }
            _calls.append(args)
        }
    }

    /// Collects the payloads handed to `pasteText` — the argv cannot carry
    /// them, since the real path passes the body through a temp file.
    private final class PasteRecorder: @unchecked Sendable {
        private let lock = NSLock()
        private var _pastes: [String] = []
        var pastes: [String] {
            lock.lock(); defer { lock.unlock() }
            return _pastes
        }
        func record(_ bytes: Data) {
            lock.lock(); defer { lock.unlock() }
            _pastes.append(String(decoding: bytes, as: UTF8.self))
        }
    }

    /// Stands in for the verifier that will fill `RPCRouter.deliveryVerifier`.
    /// Records every arming, so "exactly once" and "never" are both assertable.
    private final class RecordingVerifier: DeliveryVerificationArming, @unchecked Sendable {
        struct Arming: Sendable, Equatable {
            let actuationID: String
            let terminalID: UUID
            let deliveredPayload: String
            let submit: Bool
        }
        private let lock = NSLock()
        private var _armings: [Arming] = []
        var armings: [Arming] {
            lock.lock(); defer { lock.unlock() }
            return _armings
        }
        func armVerification(
            actuationID: String, terminalID: UUID, sessionID: String?,
            deliveredPayload: String, submit: Bool
        ) async {
            lock.withLock {
                _armings.append(Arming(
                    actuationID: actuationID, terminalID: terminalID,
                    deliveredPayload: deliveredPayload, submit: submit))
            }
        }
    }

    /// The error a `.transportFails` fixture's paste fails with.
    private struct PaneVanished: Error {}

    private struct Fixture {
        let router: RPCRouter
        let terminal: Terminal
        let recorder: ArgvRecorder
        let pastes: PasteRecorder
        let verifier: RecordingVerifier
        let logPath: String
    }

    /// A shell-kind target: the envelope and `--verify` both withhold there.
    private func makeShellFixture() async throws -> Fixture {
        try await makeFixture(kind: .shell)
    }

    private func makeFixture(
        clock: (any Clock<Duration>)? = nil, kind: TerminalKind = .claude
    ) async throws -> Fixture {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("tbd-send-dispatch-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let logPath = directory.appendingPathComponent("actuations.jsonl").path

        let recorder = ArgvRecorder()
        let pastes = PasteRecorder()
        let tmux = TmuxManager(
            dryRun: true,
            dryRunRecorder: { recorder.record($0) },
            // `.live(terminalID: nil)` — alive, carrying no identity — is the
            // branch that proceeds, so the target check is not what these are
            // about. `TerminalSendTargetCheckTests` owns that.
            dryRunPaneSendTarget: { _, _ in .live(terminalID: nil) },
            dryRunPasteBytes: { _, _, bytes in
                pastes.record(bytes)
            })
        let db = try TBDDatabase(inMemory: true)
        let router = RPCRouter(
            db: db,
            lifecycle: WorktreeLifecycle(
                db: db, git: GitManager(), tmux: tmux, hooks: HookResolver()),
            tmux: tmux,
            startTime: Date(),
            actuationLog: ActuationLog(path: logPath))
        let verifier = RecordingVerifier()
        router.deliveryVerifier = verifier
        if let clock {
            router.pacedKeySender = PacedKeySender(clock: clock)
        }
        let repo = try await db.repos.create(
            path: "/tmp/acme-\(UUID().uuidString)", displayName: "acme", defaultBranch: "main")
        let worktree = try await db.worktrees.create(
            repoID: repo.id, name: "acme-wt", branch: "main",
            path: FileManager.default.temporaryDirectory.path, tmuxServer: "tbd-acme")
        // Agent by default: the envelope rides sends to agents, not to shells.
        let terminal = try await db.terminals.create(
            worktreeID: worktree.id, tmuxWindowID: "@3", tmuxPaneID: "%7", kind: kind)
        return Fixture(
            router: router, terminal: terminal, recorder: recorder, pastes: pastes,
            verifier: verifier, logPath: logPath)
    }

    /// A fixture whose paste always throws, for the transport-failure branch.
    private func makeFailingPasteFixture() async throws -> Fixture {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("tbd-send-fail-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let logPath = directory.appendingPathComponent("actuations.jsonl").path

        let recorder = ArgvRecorder()
        let pastes = PasteRecorder()
        // A dry-run TmuxManager cannot be made to fail a paste, so the failure
        // is staged one layer out: the pane consultation throws, which the
        // handler classifies as a transport failure. Same branch, same question
        // — does a failed send arm an observation?
        let tmux = TmuxManager(
            dryRun: true,
            dryRunRecorder: { recorder.record($0) },
            dryRunPaneSendTarget: { _, _ in throw PaneVanished() },
            dryRunPasteBytes: { _, _, bytes in pastes.record(bytes) })
        let db = try TBDDatabase(inMemory: true)
        let router = RPCRouter(
            db: db,
            lifecycle: WorktreeLifecycle(
                db: db, git: GitManager(), tmux: tmux, hooks: HookResolver()),
            tmux: tmux,
            startTime: Date(),
            actuationLog: ActuationLog(path: logPath))
        let verifier = RecordingVerifier()
        router.deliveryVerifier = verifier
        let repo = try await db.repos.create(
            path: "/tmp/acme-\(UUID().uuidString)", displayName: "acme", defaultBranch: "main")
        let worktree = try await db.worktrees.create(
            repoID: repo.id, name: "acme-wt", branch: "main",
            path: FileManager.default.temporaryDirectory.path, tmuxServer: "tbd-acme")
        // An agent terminal: the envelope rides sends to agents, not to shells.
        let terminal = try await db.terminals.create(
            worktreeID: worktree.id, tmuxWindowID: "@3", tmuxPaneID: "%7", kind: .claude)
        return Fixture(
            router: router, terminal: terminal, recorder: recorder, pastes: pastes,
            verifier: verifier, logPath: logPath)
    }

    private func send(
        _ fixture: Fixture,
        text: String? = nil,
        keys: String? = nil,
        submit: Bool? = nil,
        verify: Bool? = nil,
        actor: ActuationActor? = nil
    ) async throws -> RPCResponse {
        await fixture.router.handle(try RPCRequest(
            method: RPCMethod.terminalSend,
            params: TerminalSendParams(
                terminalID: fixture.terminal.id, text: text, keys: keys,
                submit: submit, verify: verify),
            actor: actor))
    }

    private func rows(at path: String) throws -> [[String: Any]] {
        guard let contents = try? String(contentsOfFile: path, encoding: .utf8) else { return [] }
        return try contents
            .split(separator: "\n", omittingEmptySubsequences: true)
            .map { line in
                try #require(
                    try JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any])
            }
    }

    private func requestRow(at path: String) throws -> [String: Any] {
        try #require(try rows(at: path).first)
    }

    private func lastOutcome(at path: String) throws -> [String: Any] {
        try #require(try rows(at: path).last)
    }

    // MARK: - The envelope

    /// The whole composed payload, asserted as one string rather than as
    /// fragments: the tag, its two attributes in order, the newline, and the
    /// caller's text untouched behind it. A fragment assertion would pass on a
    /// payload with the pieces in the wrong places.
    @Test("the envelope's exact bytes prefix the text, carrying the row's own id")
    func envelopeExactBytes() async throws {
        let fixture = try await makeFixture()
        #expect(try await send(fixture, text: "rebase onto main", submit: true).success)

        let rowID = try #require(try requestRow(at: fixture.logPath)["id"] as? String)
        #expect(fixture.pastes.pastes == [
            "<tbd-dispatch id=\"\(rowID)\" from=\"anonymous\"/>\nrebase onto main"
        ])
    }

    /// A shell is not a reader of envelopes. It has no transcript to join back
    /// to, and `--submit` would run the tag as a command line of its own before
    /// the caller's text ever ran — so a `tbd terminal send --text "ls"
    /// --submit` into a shell pane would execute a syntax error first. Sending
    /// into a plain shell is a supported thing to do, so this is a real target.
    @Test("a shell target receives the caller's text with no envelope")
    func shellTargetGetsNoEnvelope() async throws {
        let fixture = try await makeShellFixture()
        #expect(try await send(fixture, text: "ls -la", submit: true).success)

        #expect(fixture.pastes.pastes == ["ls -la"])
        #expect(fixture.pastes.pastes.allSatisfy { !$0.contains("tbd-dispatch") })
    }

    /// And a shell cannot be verified at all: with no transcript, the re-check
    /// could only ever answer `undetermined`. Refuse rather than promise
    /// evidence this target can never produce.
    @Test("--verify against a shell target is refused, and nothing is typed")
    func verifyAgainstShellRefused() async throws {
        let fixture = try await makeShellFixture()
        let response = try await send(fixture, text: "ls", submit: true, verify: true)

        #expect(!response.success)
        #expect(response.error?.contains("shell session") == true)
        #expect(fixture.pastes.pastes.isEmpty)
        #expect(fixture.verifier.armings.isEmpty)
        let outcome = try lastOutcome(at: fixture.logPath)
        #expect(outcome["result"] as? String == "refused")
        #expect(outcome["reason"] as? String == "not-eligible")
    }

    /// Codex is an agent, so it gets attribution — a composer does not execute
    /// the tag, and knowing who is addressing you is worth having on any agent.
    @Test("a codex target still receives the envelope")
    func codexTargetGetsTheEnvelope() async throws {
        let fixture = try await makeFixture(kind: .codex)
        #expect(try await send(fixture, text: "status?", submit: true).success)

        let rowID = try #require(try requestRow(at: fixture.logPath)["id"] as? String)
        #expect(fixture.pastes.pastes == [
            "<tbd-dispatch id=\"\(rowID)\" from=\"anonymous\"/>\nstatus?"
        ])
    }

    /// But it cannot be verified. §12 gives Codex a different adapter — the
    /// app-server protocol's in-protocol acknowledgement — and this slice
    /// implements only the Claude transcript read, which would answer
    /// `undetermined` forever. Refuse rather than promise evidence the target
    /// cannot produce, exactly as for a shell.
    @Test("--verify against a codex target is refused until its adapter exists")
    func verifyAgainstCodexRefused() async throws {
        let fixture = try await makeFixture(kind: .codex)
        let response = try await send(fixture, text: "status?", submit: true, verify: true)

        #expect(!response.success)
        #expect(response.error?.contains("only") == true)
        #expect(fixture.pastes.pastes.isEmpty)
        #expect(fixture.verifier.armings.isEmpty)
        let outcome = try lastOutcome(at: fixture.logPath)
        #expect(outcome["result"] as? String == "refused")
        #expect(outcome["reason"] as? String == "not-eligible")
    }

    // MARK: - The retry's own production path

    /// `redeliverVerifiedPayload` is what the verifier's injected seam actually
    /// calls, and every verifier test fakes it — so its guards need exercising
    /// here or nowhere. It re-checks eligibility and the addressed conversation,
    /// not just the pane, because the gap between the observation and the paste
    /// spans a DB write, two reads and a serializer queue.
    @Test("the retry re-pastes the identical bytes when the target still qualifies")
    func redeliveryPastesWhenEligible() async throws {
        let fixture = try await makeFixture()
        let outcome = await fixture.router.redeliverVerifiedPayload(
            terminalID: fixture.terminal.id,
            sessionID: fixture.terminal.claudeSessionID,
            payload: "<tbd-dispatch id=\"abc\" from=\"anonymous\"/>\nstatus?",
            submit: true)

        #expect(outcome == .dispatched)
        #expect(fixture.pastes.pastes == [
            "<tbd-dispatch id=\"abc\" from=\"anonymous\"/>\nstatus?"
        ])
    }

    /// A `/clear` between the observation and the retry rebinds the terminal to
    /// a new conversation while keeping its pane. The payload is an instruction
    /// addressed to the session that is no longer there.
    @Test("the retry refuses a terminal rebound to another session, and types nothing")
    func redeliveryRefusesARebindingSession() async throws {
        let fixture = try await makeFixture()
        try await fixture.router.db.terminals.updateSession(
            id: fixture.terminal.id, sessionID: "session-after-clear", transcriptPath: nil)

        let outcome = await fixture.router.redeliverVerifiedPayload(
            terminalID: fixture.terminal.id,
            sessionID: "session-at-dispatch",
            payload: "status?", submit: true)

        #expect(outcome == .refused(.targetMismatch))
        #expect(fixture.pastes.pastes.isEmpty)
    }

    /// And a target that stopped being verifiable — a `recreateWindow` turning
    /// an agent terminal into a shell while keeping its id — refuses too. The
    /// payload it is holding opens with an envelope a shell would execute.
    @Test("the retry refuses a target that is no longer an observable agent")
    func redeliveryRefusesAnIneligibleTarget() async throws {
        let fixture = try await makeShellFixture()
        let outcome = await fixture.router.redeliverVerifiedPayload(
            terminalID: fixture.terminal.id,
            sessionID: fixture.terminal.claudeSessionID,
            payload: "<tbd-dispatch id=\"abc\" from=\"anonymous\"/>\nstatus?",
            submit: true)

        #expect(outcome == .refused(.notEligible))
        #expect(fixture.pastes.pastes.isEmpty)
    }

    /// `from` is the row's own actor, not a constant: the receiving agent sees
    /// who is addressing it, down to the rail when a daemon rail sends.
    @Test("the envelope's from attribute names the declared actor")
    func envelopeNamesActor() async throws {
        let fixture = try await makeFixture()
        #expect(try await send(
            fixture, text: "continue", submit: true,
            actor: .daemon(rail: "limit-resume")).success)

        let rowID = try #require(try requestRow(at: fixture.logPath)["id"] as? String)
        #expect(fixture.pastes.pastes == [
            "<tbd-dispatch id=\"\(rowID)\" from=\"daemon:limit-resume\"/>\ncontinue"
        ])
    }

    /// The envelope rides every text send, verified or not — a prefix that
    /// appears only sometimes is one no reader can rely on.
    @Test("an unverified, unsubmitted send still carries the envelope")
    func envelopeRidesEveryTextSend() async throws {
        let fixture = try await makeFixture()
        #expect(try await send(fixture, text: "note to self").success)

        let rowID = try #require(try requestRow(at: fixture.logPath)["id"] as? String)
        #expect(fixture.pastes.pastes == [
            "<tbd-dispatch id=\"\(rowID)\" from=\"anonymous\"/>\nnote to self"
        ])
    }

    /// The envelope is transport framing whose id is the row's own, so storing
    /// it would duplicate the row's identifier into its own body.
    @Test("the row records the caller's text WITHOUT the envelope")
    func rowRecordsTextVerbatim() async throws {
        let fixture = try await makeFixture()
        #expect(try await send(fixture, text: "rebase onto main", submit: true).success)

        let request = try requestRow(at: fixture.logPath)
        #expect(request["message"] as? String == "rebase onto main")
        #expect(request["submit"] as? Bool == true)
        // Not armed, so the field that identifies sends owing an observation
        // must be absent — not present-and-false.
        #expect(request["verify"] == nil)
    }

    /// `tbd terminal send --text "" --submit` is a real way to press Enter and
    /// must not start pasting a tag.
    @Test("empty text still pastes nothing and still presses Enter")
    func emptyTextPastesNothingStillSubmits() async throws {
        let fixture = try await makeFixture()
        #expect(try await send(fixture, text: "", submit: true).success)

        #expect(fixture.pastes.pastes.isEmpty)
        #expect(!fixture.recorder.calls.contains { $0.contains("load-buffer") })
        #expect(!fixture.recorder.calls.contains { $0.contains("paste-buffer") })
        #expect(fixture.recorder.calls.contains {
            $0.contains("send-keys") && $0.contains("Enter")
        })
    }

    @Test("empty text without submit types nothing at all")
    func emptyTextNoSubmitTypesNothing() async throws {
        let fixture = try await makeFixture()
        #expect(try await send(fixture, text: "").success)
        #expect(fixture.pastes.pastes.isEmpty)
        #expect(fixture.recorder.calls.isEmpty)
    }

    // MARK: - Keys

    @Test("--keys sends each named key in order, paced through the injected clock")
    func keysSentInOrderPaced() async throws {
        let clock = TestClock()
        let fixture = try await makeFixture(clock: clock)

        async let response = send(fixture, keys: "Escape C-c Enter")
        await clock.advanceWhenSuspended(by: PacedKeySender.interKeyPause)
        await clock.advanceWhenSuspended(by: PacedKeySender.interKeyPause)
        #expect(try await response.success)

        let sent = fixture.recorder.calls
            .filter { $0.contains("send-keys") }
            .compactMap(\.last)
        #expect(sent == ["Escape", "C-c", "Enter"])
        // Keys carry no envelope: a key sequence has nowhere to put a line of
        // text, and typing one ahead of an interrupt would itself be an act.
        #expect(fixture.pastes.pastes.isEmpty)
    }

    @Test("a keys row records the keys verbatim, with submit and verify absent")
    func keysRowShape() async throws {
        let clock = TestClock()
        let fixture = try await makeFixture(clock: clock)

        async let response = send(fixture, keys: "Escape Enter")
        await clock.advanceWhenSuspended(by: PacedKeySender.interKeyPause)
        #expect(try await response.success)

        let request = try requestRow(at: fixture.logPath)
        #expect(request["message"] as? String == "Escape Enter")
        #expect(request["submit"] == nil)
        #expect(request["verify"] == nil)
        #expect(try lastOutcome(at: fixture.logPath)["result"] as? String == "dispatched")
    }

    /// The cap is enforced at the daemon, before a row exists — a typo that
    /// expands into thousands of keys names no coherent act. Spelled as a
    /// literal 33 for the reason `PacedKeySenderTests.countCapped` records:
    /// `maxKeys + 1` would move with a raised cap and stay green.
    @Test("a keys payload past the 32-key cap is rejected before any row is written")
    func keysPastCapRejected() async throws {
        let fixture = try await makeFixture()
        let overCap = Array(repeating: "Escape", count: 33).joined(separator: " ")

        let response = try await send(fixture, keys: overCap)
        #expect(!response.success)
        #expect(response.error?.contains("32") == true)
        #expect(fixture.recorder.calls.isEmpty)
        #expect(try rows(at: fixture.logPath).isEmpty)
    }

    // The cap's inclusive edge — exactly `maxKeys` is accepted — is proven in
    // `PacedKeySenderTests.countCapped` rather than here: driving 32 paced keys
    // through the router would need 31 chained clock advances, and
    // `Tests/CLAUDE.md` keeps advance chains in single digits.

    @Test("a keys payload naming nothing is rejected before any row is written")
    func emptyKeysRejected() async throws {
        let fixture = try await makeFixture()
        let response = try await send(fixture, keys: "   ")
        #expect(!response.success)
        #expect(fixture.recorder.calls.isEmpty)
        #expect(try rows(at: fixture.logPath).isEmpty)
    }

    // MARK: - Malformed shapes: rejected BEFORE any row is written

    /// All four (plus the empty-text corollary) share one property that is the
    /// whole point of the line: no row. `RPCRouter+Actuation`'s rule is that a
    /// row must not be written for a request that was never about to be
    /// dispatched, and none of these named a coherent act.
    @Test("both payloads at once is rejected, with no row")
    func bothPayloadsRejected() async throws {
        let fixture = try await makeFixture()
        let response = try await send(fixture, text: "hi", keys: "Enter")
        #expect(!response.success)
        #expect(response.error?.contains("not both") == true)
        #expect(fixture.recorder.calls.isEmpty)
        #expect(try rows(at: fixture.logPath).isEmpty)
    }

    @Test("neither payload is rejected, with no row")
    func neitherPayloadRejected() async throws {
        let fixture = try await makeFixture()
        let response = try await send(fixture)
        #expect(!response.success)
        #expect(fixture.recorder.calls.isEmpty)
        #expect(try rows(at: fixture.logPath).isEmpty)
    }

    @Test("--verify with --keys is rejected, with no row")
    func verifyWithKeysRejected() async throws {
        let fixture = try await makeFixture()
        let response = try await send(fixture, keys: "Enter", verify: true)
        #expect(!response.success)
        #expect(response.error?.contains("transcript") == true)
        #expect(fixture.recorder.calls.isEmpty)
        #expect(try rows(at: fixture.logPath).isEmpty)
    }

    @Test("--submit with --keys is rejected, with no row")
    func submitWithKeysRejected() async throws {
        let fixture = try await makeFixture()
        let response = try await send(fixture, keys: "Escape", submit: true)
        #expect(!response.success)
        #expect(response.error?.contains("Enter is itself a key") == true)
        #expect(fixture.recorder.calls.isEmpty)
        #expect(try rows(at: fixture.logPath).isEmpty)
    }

    @Test("--verify without --submit is rejected, with no row")
    func verifyWithoutSubmitRejected() async throws {
        let fixture = try await makeFixture()
        let response = try await send(fixture, text: "hi", verify: true)
        #expect(!response.success)
        #expect(response.error?.contains("--submit") == true)
        #expect(fixture.recorder.calls.isEmpty)
        #expect(try rows(at: fixture.logPath).isEmpty)
    }

    /// The same reason one step earlier: an empty payload pastes nothing, so no
    /// envelope is ever written for an observation to find.
    @Test("--verify with empty text is rejected, with no row")
    func verifyWithEmptyTextRejected() async throws {
        let fixture = try await makeFixture()
        let response = try await send(fixture, text: "", submit: true, verify: true)
        #expect(!response.success)
        #expect(fixture.recorder.calls.isEmpty)
        #expect(try rows(at: fixture.logPath).isEmpty)
    }

    // MARK: - The flag: both branches

    /// Not a silent downgrade to an unverified send. A caller that asked for
    /// evidence must never be answered with a silence that reads like
    /// confirmation — that would rebuild the failure class §12 exists to end.
    @Test("--verify while the flag is off is refused, after the row, naming the flag")
    func verifyRefusedWhileFlagOff() async throws {
        let fixture = try await makeFixture()
        #expect(try await fixture.router.db.config.get().deliveryVerificationEnabled == false)

        let response = try await send(fixture, text: "status?", submit: true, verify: true)
        #expect(!response.success)
        #expect(response.error?.contains("delivery_verification_enabled") == true)

        // Nothing typed.
        #expect(fixture.recorder.calls.isEmpty)
        #expect(fixture.pastes.pastes.isEmpty)
        // But a row and a refusal outcome, so the morning shows the near-miss.
        let written = try rows(at: fixture.logPath)
        #expect(written.count == 2)
        #expect(written.first?["verify"] as? Bool == true)
        let outcome = try #require(written.last)
        #expect(outcome["result"] as? String == "refused")
        #expect(outcome["reason"] as? String == "not-eligible")
        #expect(!written.contains { $0["result"] as? String == "dispatched" })
        // And no observation was armed on a send that never happened.
        #expect(fixture.verifier.armings.isEmpty)
    }

    @Test("--verify while the flag is on dispatches and arms the observation")
    func verifyArmedWhileFlagOn() async throws {
        let fixture = try await makeFixture()
        try await fixture.router.db.config.setDeliveryVerification(enabled: true)

        #expect(try await send(fixture, text: "status?", submit: true, verify: true).success)

        let request = try requestRow(at: fixture.logPath)
        let rowID = try #require(request["id"] as? String)
        #expect(request["verify"] as? Bool == true)
        #expect(try lastOutcome(at: fixture.logPath)["result"] as? String == "dispatched")

        // Exactly once, carrying the delivered bytes INCLUDING the envelope so
        // a retry re-delivers byte-identically and still joins on this row.
        #expect(fixture.verifier.armings.count == 1)
        let arming = try #require(fixture.verifier.armings.first)
        #expect(arming.actuationID == rowID)
        #expect(arming.terminalID == fixture.terminal.id)
        #expect(arming.submit)
        #expect(arming.deliveredPayload
            == "<tbd-dispatch id=\"\(rowID)\" from=\"anonymous\"/>\nstatus?")
        #expect(arming.deliveredPayload == fixture.pastes.pastes.first)
    }

    /// An ordinary send must cost nothing the verification path costs — the
    /// observation is not armed, so no transcript is ever read for it.
    @Test("a verify-less send arms no observation")
    func verifylessSendArmsNothing() async throws {
        let fixture = try await makeFixture()
        try await fixture.router.db.config.setDeliveryVerification(enabled: true)

        #expect(try await send(fixture, text: "status?", submit: true).success)
        #expect(fixture.verifier.armings.isEmpty)
    }

    @Test("a keys send arms no observation, flag on or off")
    func keysSendArmsNothing() async throws {
        let clock = TestClock()
        let fixture = try await makeFixture(clock: clock)
        try await fixture.router.db.config.setDeliveryVerification(enabled: true)

        async let response = send(fixture, keys: "Escape Enter")
        await clock.advanceWhenSuspended(by: PacedKeySender.interKeyPause)
        #expect(try await response.success)
        #expect(fixture.verifier.armings.isEmpty)
    }

    /// A send that never reached the transport has nothing to observe: arming
    /// one would put an act on the observation ladder that never got dispatched.
    @Test("a transport failure arms no observation")
    func transportFailureArmsNothing() async throws {
        let fixture = try await makeFailingPasteFixture()
        try await fixture.router.db.config.setDeliveryVerification(enabled: true)

        let response = try await send(fixture, text: "status?", submit: true, verify: true)
        #expect(!response.success)
        #expect(try lastOutcome(at: fixture.logPath)["result"] as? String == "transport-failed")
        #expect(fixture.verifier.armings.isEmpty)
    }

    // MARK: - Wire compatibility

    /// The exact JSON an older CLI sends — `text` and `submit`, no `keys`, no
    /// `verify`. It must decode and behave as it always did.
    @Test("the old wire shape decodes and behaves exactly as before")
    func oldWireShapeUnchanged() async throws {
        let fixture = try await makeFixture()
        let json = """
            {"terminalID":"\(fixture.terminal.id.uuidString)","text":"rebase onto main","submit":true}
            """

        let response = await fixture.router.handle(
            RPCRequest(method: RPCMethod.terminalSend, params: json))
        #expect(response.success)

        let request = try requestRow(at: fixture.logPath)
        #expect(request["message"] as? String == "rebase onto main")
        #expect(request["submit"] as? Bool == true)
        #expect(request["verify"] == nil)
        #expect(try lastOutcome(at: fixture.logPath)["result"] as? String == "dispatched")

        // Same tmux commands as ever: bracketed paste, then a separate Enter.
        let calls = fixture.recorder.calls
        #expect(calls.contains { $0.contains("load-buffer") })
        #expect(calls.contains { $0.contains("paste-buffer") })
        #expect(calls.contains { $0.contains("send-keys") && $0.contains("Enter") })
        #expect(fixture.verifier.armings.isEmpty)
    }

    /// Bare `--text`, the shape that decodes with `submit` absent entirely.
    @Test("the old wire shape without submit still types without submitting")
    func oldWireShapeWithoutSubmit() async throws {
        let fixture = try await makeFixture()
        let json = """
            {"terminalID":"\(fixture.terminal.id.uuidString)","text":"hello"}
            """

        #expect(await fixture.router.handle(
            RPCRequest(method: RPCMethod.terminalSend, params: json)).success)
        #expect(!fixture.recorder.calls.contains { $0.contains("send-keys") })
        #expect(try requestRow(at: fixture.logPath)["submit"] as? Bool == false)
    }

    // MARK: - The operator's enable path

    /// The flag has to be flippable for its soak, and readable back so an
    /// operator can tell which branch the daemon is on.
    @Test("config.setDeliveryVerification flips the flag and capabilities reports it")
    func operatorEnablePath() async throws {
        let fixture = try await makeFixture()

        #expect(try await fixture.router.db.config.get().deliveryVerificationEnabled == false)
        let off = try await fixture.router.handle(
            RPCRequest(method: RPCMethod.daemonCapabilities))
            .decodeResult(DaemonCapabilitiesResult.self)
        #expect(off.deliveryVerificationEnabled == false)

        #expect(await fixture.router.handle(try RPCRequest(
            method: RPCMethod.configSetDeliveryVerification,
            params: ConfigSetDeliveryVerificationParams(enabled: true))).success)
        #expect(try await fixture.router.db.config.get().deliveryVerificationEnabled == true)

        let on = try await fixture.router.handle(
            RPCRequest(method: RPCMethod.daemonCapabilities))
            .decodeResult(DaemonCapabilitiesResult.self)
        #expect(on.deliveryVerificationEnabled == true)
    }
}
